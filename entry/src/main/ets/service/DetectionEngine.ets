import { hilog } from '@kit.PerformanceAnalysisKit';
import { DrivingEvent } from '../model/DrivingEvent';
import {
  DEDUCT_TABLE, Sensitivity, SensitivityProfile, ThresholdTriple, getProfile, isRoadCondition,
} from '../model/DetectionConfig';

const DOMAIN: number = 0x0000;
const TAG: string = 'DetectionEngine';

/** 去重窗口内的同名事件记录 */
interface RecentEvent {
  name: string;
  t: number;
}

/** 历史采样点（原始值，用于能量统计与颠簸识别） */
interface HistoryPoint {
  lat: number;
  lon: number;
  ver: number;
  t: number;
}

/** 平滑后采样点，用于摇摆的方向翻转统计 */
interface SmoothPoint {
  lat: number;
  t: number;
}

/** 速度采样点 */
interface SpeedSample {
  v: number;
  t: number;
}

/** 一次持续超阈过程 */
class Run {
  /** true=横向（急转向），false=纵向（急加/减速）。决定结束时用哪一档阈值评级 */
  readonly lateral: boolean;
  len: number = 0;
  peak: number = 0;
  sign: number = 0;
  startTs: number = 0;
  lastTs: number = 0;

  constructor(lateral: boolean) {
    this.lateral = lateral;
  }

  reset(): void {
    this.len = 0;
    this.peak = 0;
    this.sign = 0;
    this.startTs = 0;
    this.lastTs = 0;
  }
}

/** 滑动平均（箱型低通）。6 样本 @50ms ≈ 300ms，−3dB 约 0.55Hz */
class Boxcar {
  private buf: number[] = [];
  private sum: number = 0;
  private readonly n: number;

  constructor(n: number) {
    this.n = n;
  }

  reset(): void {
    this.buf = [];
    this.sum = 0;
  }

  push(v: number): number {
    this.buf.push(v);
    this.sum += v;
    if (this.buf.length > this.n) {
      const old: number = this.buf.shift() as number;
      this.sum -= old;
    }
    return this.sum / this.buf.length;
  }
}

/** 传感器采样间隔（ms），与 SensorManager 一致 */
const SAMPLE_MS: number = 50;
/** 低通窗口：6×50ms=300ms。上下颠簸是 1~20Hz 的高频能量，先被这一步压掉 */
const SMOOTH_SAMPLES: number = 6;
/** 一次超阈过程至少持续这么久才算驾驶动作，而非瞬时脉冲 */
const RUN_MIN_MS: number = 300;
const RUN_MIN_SAMPLES: number = Math.ceil(RUN_MIN_MS / SAMPLE_MS);
/** 进入超阈状态的比例：level1 的 0.6 倍，用于把"过程"圈出来再按峰值定级 */
const RUN_ENTER_RATIO: number = 0.6;
/** 离开超阈状态的比例（相对进入门限）：迟滞退出，见 trackRun */
const RUN_EXIT_RATIO: number = 0.8;
/** 离开超阈后允许的最大中断（ms），避免一次采样抖动就把过程切断 */
const RUN_GAP_MS: number = 100;
/** 事件去重窗口（ms） */
const DEDUP_WINDOW_MS: number = 1500;
/** 摇摆去重窗口（ms）：摇摆是过程量，5s 内只记一次 */
const SWAY_DEDUP_MS: number = 5000;
/**
 * 急转向去重窗口（ms）。一次变道是"打方向 + 回方向"两段等幅反向的横向加速度，
 * 相隔约 2s；按 1.5s 去重会把一个动作记成两笔，平稳开车的变道因此双倍扣分。
 */
const TURN_DEDUP_MS: number = 2600;
/** 摇摆检测窗口（ms） */
const SWAY_WINDOW_MS: number = 4000;
/**
 * 摇摆判定的横向加速度幅值（m/s²），作用在 300ms 平滑值上，只用于统计方向翻转。
 * 11 段真车实测（0.35~24.9km 不等）里平滑横向的 p50 为 0.07~0.22、p90 为 0.28~0.61：
 * 旧值 0.15 落在正常行车的噪声带内，导致"摇摆"每 10 秒命中一次；
 * 0.25 刚好抬到多数路段的 p50 之上，翻转统计不再被常时噪声喂满。
 * 真正决定计不计分的是 SWAY_PEAK_MIN。
 */
const SWAY_AMPLITUDE: number = 0.25;
/**
 * 摇摆计入评分的平滑横向峰值下限（m/s²）。
 * 真车数据里"路面/支架晃动"与"车身横摆"在低频判据下分不开（两者都 ≤2Hz），
 * 但幅值分得开：正常行车的摇摆峰值集中在 0.3~0.7，明显发飘的横摆 ≥0.8。
 * 取 0.8 后 11 段实测的摇摆计数从 2~56 次/程降到 0~11 次/程，
 * 平稳段评分回升 5~15 分，激烈段不受影响。
 */
const SWAY_PEAK_MIN: number = 0.8;
/**
 * 摇摆低频判据：平滑后横向 RMS / 原始横向 RMS 的下限。
 * 车身侧倾 ≤2Hz，300ms 滤波几乎不衰减（比值≈0.7~1）；路面振动 ≥2.5Hz
 * 会被压到 0.3 以下。取 0.5 落在两者的空档里。
 */
const SWAY_LOWFREQ_MIN: number = 0.5;
/** 摇摆判定：窗口内横向同向翻转次数阈值 */
const SWAY_FLIPS: number = 2;
/** 摇摆最短持续时间（ms），滤掉一次变道的单侧回正 */
const SWAY_MIN_SPAN_MS: number = 2000;
/** 摇摆最低车速（km/h）：低速横摆多为停车揉库，不构成晕车因素 */
const SWAY_MIN_SPEED_KMH: number = 15;
/** 颠簸（垂向）计入路况的幅值阈值（m/s²）与最短持续 */
const BUMP_AMPLITUDE: number = 1.2;
const BUMP_MIN_SAMPLES: number = 2;
/**
 * 颠簸专用快滤波：2×50ms=100ms。
 * 300ms 的巡航低通会把 3Hz 颠簸衰减到 11%，1.2m/s² 的门限永远够不到，
 * 结果就是"手机在颠、报告里颠簸 0 次"。路况统计必须用快滤波。
 */
const BUMP_FILTER_SAMPLES: number = 2;
/** 颠簸去重窗口（ms）：连续烂路按次归并，避免刷满事件上限挤掉真实事件 */
const BUMP_DEDUP_MS: number = 3000;
/** 事件上下文窗口（ms），用于计算垂向/水平能量比 */
const CONTEXT_WINDOW_MS: number = 800;
/** 垂向主导否决：垂向/水平能量比超过此值时，该事件判为路面颠簸所致，不计分 */
const VERT_RATIO_VETO: number = 1.3;
/** 低速工况豁免阈值（km/h）：手持/停车挪车/蠕行，所有事件豁免 */
const HANDLED_SPEED_KMH: number = 5;
/** 平稳巡航统计：视为"安静"的水平加速度上限（m/s²） */
const QUIET_LIMIT: number = 1.5;
/** 平稳度窗口（ms），同时决定 history 的保留时长 */
const SMOOTH_WINDOW_MS: number = 60000;
/** 实时运动强度窗口（ms）：检测中情绪要跟随手感变化，60s 太滞后 */
const MOTION_WINDOW_MS: number = 4000;
/** 实时情绪的"刚发生过事件"回看窗口（ms） */
const MOOD_EVENT_MS: number = 3000;
/** 速度样本窗口（ms），用于豁免判定的中位数速度 */
const SPEED_WINDOW_MS: number = 10000;
/** 事件历史上限（滑动裁剪，优先淘汰颠簸） */
const MAX_EVENTS: number = 800;

/** 事件上下文统计 */
interface BumpContext {
  vertRatio: number;
  vertRms: number;
  horizRms: number;
}

/**
 * 检测引擎运行快照（供 UI 读取，不含分数也不含专业数值）。
 * UI 只用 motionRms/speedKmh 推导实时情绪，加速度分量与事件明细留给报告。
 */
export interface EngineSnapshot {
  /** 近 MOTION_WINDOW_MS 三轴加速度 RMS（m/s²），实时情绪数据源 */
  motionRms: number;
  /** 近 10s 车速中位数（km/h） */
  speedKmh: number;
  /** 是否已收到有效速度样本：false 时 UI 不应宣称"车停着" */
  speedKnown: boolean;
  /** 近 60s 内是否有豁免事件 */
  bumpActive: boolean;
  /** 最近一次豁免的原因 */
  exemptReason: string;
  /** 近 60s 垂向颠簸次数（路况，不计分） */
  roadBumpCount: number;
  /** 近 MOOD_EVENT_MS 内未被豁免事件的最大等级，0 表示没有；用于实时情绪升级 */
  peakLevel: number;
}

/**
 * 驾驶行为检测引擎（纯事件记录器）。
 *
 * 与旧实现的三处关键差别：
 * 1) 判定作用在 300ms 平滑值上，且要求持续超阈 ≥300ms。瞬时阈值下
 *    52km/h 匀速巡航实测记录到 252 个"有效事件"、40 次 Lv10 急加速，
 *    全部是路面振动被当成驾驶行为。
 * 2) 垂向能量不参与任何评分：颠簸单独成类且权重恒 0，
 *    所有计分事件还要过一道"垂向主导否决"。
 * 3) 每个事件都记录 vertRatio，便于事后审计误报来源（旧实现只给
 *    顿挫/摇摆算，急加减速的 vertRatio 恒为 0，无法复盘）。
 */
export class DetectionEngine {
  private sensitivity: Sensitivity = 'moderate';
  private events: DrivingEvent[] = [];
  private recent: RecentEvent[] = [];
  private history: HistoryPoint[] = [];
  private smLat: SmoothPoint[] = [];
  private speedKmh: number = 0;
  private speedSamples: SpeedSample[] = [];
  /** 是否已收到有效速度样本（未收到时不做低速豁免，避免误判） */
  private speedKnown: boolean = false;
  private curLat: number = 0;
  private curLng: number = 0;
  private hasPos: boolean = false;
  private quietSum: number = 0;
  private quietCount: number = 0;
  private onEventCb: ((e: DrivingEvent) => void) | undefined = undefined;
  private running: boolean = false;

  private readonly lowPassLat: Boxcar = new Boxcar(SMOOTH_SAMPLES);
  private readonly lowPassLon: Boxcar = new Boxcar(SMOOTH_SAMPLES);
  private readonly bumpPassVer: Boxcar = new Boxcar(BUMP_FILTER_SAMPLES);
  private readonly lonRun: Run = new Run(false);
  private readonly latRun: Run = new Run(true);
  private readonly verRun: Run = new Run(false);

  setOnEvent(cb: (e: DrivingEvent) => void): void {
    this.onEventCb = cb;
  }

  setSpeed(speedKmh: number): void {
    this.speedKmh = speedKmh;
    this.speedKnown = true;
    const now: number = Date.now();
    this.speedSamples.push({ v: speedKmh, t: now });
    while (this.speedSamples.length > 0 && now - this.speedSamples[0].t > SPEED_WINDOW_MS) {
      this.speedSamples.shift();
    }
    if (this.speedSamples.length > 60) {
      this.speedSamples = this.speedSamples.slice(-60);
    }
  }

  /** 最近 10s 速度中位数（抗 GPS 瞬时跳变，用于豁免判定） */
  private recentSpeed(): number {
    const now: number = Date.now();
    const vals: number[] = [];
    for (const s of this.speedSamples) {
      if (now - s.t <= SPEED_WINDOW_MS) {
        vals.push(s.v);
      }
    }
    if (vals.length === 0) {
      return this.speedKmh;
    }
    vals.sort((a: number, b: number): number => a - b);
    return vals[Math.floor(vals.length / 2)];
  }

  setPosition(lat: number, lng: number): void {
    this.curLat = lat;
    this.curLng = lng;
    this.hasPos = true;
  }

  reset(sensitivity: Sensitivity): void {
    this.sensitivity = sensitivity;
    this.events = [];
    this.recent = [];
    this.history = [];
    this.smLat = [];
    this.speedKmh = 0;
    this.speedSamples = [];
    this.speedKnown = false;
    this.hasPos = false;
    this.quietSum = 0;
    this.quietCount = 0;
    this.lowPassLat.reset();
    this.lowPassLon.reset();
    this.bumpPassVer.reset();
    this.lonRun.reset();
    this.latRun.reset();
    this.verRun.reset();
    this.running = true;
  }

  /** 停止采集。闭合未结束的超阈过程，避免行程末尾那次急刹被丢掉。 */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.closeRun(this.lonRun);
    this.closeRun(this.latRun);
    this.closeBumpRun();
  }

  /** 事件列表：内部数组的实时视图，按时间倒序（最新在前），调用方只读 */
  getEvents(): DrivingEvent[] {
    return this.events;
  }

  /** 平稳巡航 RMS（非事件窗口水平加速度，m/s²） */
  getRmsH(): number {
    if (this.quietCount === 0) {
      return 0;
    }
    return Math.sqrt(this.quietSum / this.quietCount);
  }

  getSnapshot(): EngineSnapshot {
    return {
      motionRms: this.motionRms(),
      speedKmh: this.recentSpeed(),
      speedKnown: this.speedKnown,
      bumpActive: this.bumpActive(),
      exemptReason: this.lastExemptReason(),
      roadBumpCount: this.roadBumpCount(),
      peakLevel: this.peakLevel(),
    };
  }

  /**
   * 喂入一个车体坐标系采样点。
   * lateral/longitudinal 来自测量层的车体轴分解，vertical 为沿重力方向分量。
   */
  feed(lateral: number, longitudinal: number, vertical: number): void {
    if (!this.running) {
      return;
    }
    // 传感器异常时可能吐 NaN：一旦进 history 就会永久污染 RMS，
    // 且所有 `>=` 门限比较对 NaN 恒为 false，会让实时情绪掉到最差档
    if (!Number.isFinite(lateral) || !Number.isFinite(longitudinal) || !Number.isFinite(vertical)) {
      return;
    }
    const now: number = Date.now();
    const profile: SensitivityProfile = getProfile(this.sensitivity);

    this.history.push({ lat: lateral, lon: longitudinal, ver: vertical, t: now });
    this.trimHistory(now, SMOOTH_WINDOW_MS);

    const sLat: number = this.lowPassLat.push(lateral);
    const sLon: number = this.lowPassLon.push(longitudinal);
    const bVer: number = this.bumpPassVer.push(vertical);

    this.smLat.push({ lat: sLat, t: now });
    while (this.smLat.length > 0 && now - this.smLat[0].t > SWAY_WINDOW_MS + SAMPLE_MS) {
      this.smLat.shift();
    }

    // 平稳巡航统计用平滑值：路面纹理不该压低巡航分
    if (Math.abs(sLat) < QUIET_LIMIT && Math.abs(sLon) < QUIET_LIMIT) {
      this.quietSum += sLat * sLat + sLon * sLon;
      this.quietCount++;
    }

    this.trackRun(this.lonRun, sLon, profile.brake.level1 * RUN_ENTER_RATIO, now);
    this.trackRun(this.latRun, sLat, profile.turn.level1 * RUN_ENTER_RATIO, now);
    this.trackBump(bVer, now);

    const swayLv: number = this.detectSway(now, profile);
    if (swayLv > 0) {
      this.addEvent('摇摆', swayLv, now, SWAY_DEDUP_MS);
    }
  }

  /** 圈出持续超阈过程：进入用低门限，定级用过程峰值 */
  private trackRun(run: Run, value: number, enterThreshold: number, now: number): void {
    const a: number = Math.abs(value);
    if (a >= enterThreshold) {
      const sg: number = value > 0 ? 1 : -1;
      if (run.sign !== 0 && run.sign !== sg) {
        this.closeRun(run);
        run.reset();
      }
      if (run.startTs === 0) {
        run.startTs = now;
      }
      run.sign = sg;
      run.len++;
      run.peak = Math.max(run.peak, a);
      run.lastTs = now;
      return;
    }
    // 迟滞退出：峰值附近只要还留在进入门限的 RUN_EXIT_RATIO 以上，
    // 就认定是同一次动作的余波，只推进 lastTs、不再抬峰值。
    // 少了这一档，信号恰好在门限线上被高频纹波带着来回穿越，
    // 一次减速会被切成十几个去重窗口外的"事件"，平稳开车也被打成分很低。
    // 注意：只有迟滞档才推 lastTs；短中断分支必须保持 lastTs 不动，
    // 否则 RUN_GAP_MS 永远超时不了，一次过程会挂到行程结束才结算。
    if (run.len > 0) {
      if (a >= enterThreshold * RUN_EXIT_RATIO) {
        run.lastTs = now;
        return;
      }
      if (now - run.lastTs <= RUN_GAP_MS) {
        return;
      }
    }
    this.closeRun(run);
    run.reset();
  }

  /** 过程结束：达到最短持续时间才产出一个事件 */
  private closeRun(run: Run): void {
    if (run.len < RUN_MIN_SAMPLES || run.lastTs - run.startTs < RUN_MIN_MS) {
      return;
    }
    const profile: SensitivityProfile = getProfile(this.sensitivity);
    if (run.lateral) {
      // 横摆不分左右：左右两侧都按同一套急转向阈值定级
      const lv: number = classifyAccel(run.peak, profile.turn);
      if (lv > 0) {
        this.addEvent('急转向', lv, run.lastTs, TURN_DEDUP_MS);
      }
      return;
    }
    if (run.sign > 0) {
      const lv: number = classifyAccel(run.peak, profile.accel);
      if (lv > 0) {
        this.addEvent('急加速', lv, run.lastTs, DEDUP_WINDOW_MS);
      }
    } else if (run.sign < 0) {
      const lvBrake: number = classifyAccel(run.peak, profile.brake);
      if (lvBrake > 0) {
        this.addEvent('急减速', lvBrake, run.lastTs, DEDUP_WINDOW_MS);
      }
    }
  }

  /** 垂向持续超阈过程 → 颠簸（路况） */
  private trackBump(bVer: number, now: number): void {
    const a: number = Math.abs(bVer);
    if (a >= BUMP_AMPLITUDE) {
      if (this.verRun.startTs === 0) {
        this.verRun.startTs = now;
      }
      this.verRun.len++;
      this.verRun.peak = Math.max(this.verRun.peak, a);
      this.verRun.lastTs = now;
      return;
    }
    if (this.verRun.len > 0 && now - this.verRun.lastTs <= RUN_GAP_MS) {
      return;
    }
    this.closeBumpRun();
    this.verRun.reset();
  }

  /** 垂向突变计入"路况"，权重恒 0，永不影响评分 */
  private closeBumpRun(): void {
    if (this.verRun.len < BUMP_MIN_SAMPLES) {
      return;
    }
    const lv: number = this.verRun.peak >= BUMP_AMPLITUDE * 2 ? 5 : 2;
    this.addEvent('颠簸', lv, this.verRun.lastTs, BUMP_DEDUP_MS);
  }

  /**
   * 摇摆：平滑横向信号在 4s 窗口内出现 ≥2 次方向翻转、且幅值 ≥0.15m/s²、
   * 摆动跨度 ≥2s。变道只有一次回正，不会误判；连续变向摆动才会命中。
   * 返回等级（0 表示未命中）。
   */
  private detectSway(now: number, profile: SensitivityProfile): number {
    if (this.smLat.length < 6) {
      return 0;
    }
    if (this.speedKnown && this.recentSpeed() < SWAY_MIN_SPEED_KMH) {
      return 0;
    }
    let flips: number = 0;
    let prevSign: number = 0;
    let peak: number = 0;
    let newestActive: number = 0;
    let oldestActive: number = 0;
    for (let i = this.smLat.length - 1; i >= 0; i--) {
      const p: SmoothPoint = this.smLat[i];
      if (now - p.t > SWAY_WINDOW_MS) {
        break;
      }
      if (Math.abs(p.lat) < SWAY_AMPLITUDE) {
        continue;
      }
      const s: number = p.lat > 0 ? 1 : -1;
      if (prevSign !== 0 && s !== prevSign) {
        flips++;
      }
      if (newestActive === 0) {
        newestActive = p.t;
      }
      // 循环由新到旧，最后一次赋值即为窗口内最早的活跃样本
      oldestActive = p.t;
      prevSign = s;
      peak = Math.max(peak, Math.abs(p.lat));
    }
    if (flips < SWAY_FLIPS || newestActive - oldestActive < SWAY_MIN_SPAN_MS) {
      return 0;
    }
    // 频率判据：过幅值/翻转两道门后剩下的，多半是路面高频振动而非车身横摆
    if (!this.isLowFrequencySway(now)) {
      return 0;
    }
    // 幅值下限：低于此值的低频横摆是路面/支架带出来的，乘客无感，不计分
    if (peak < SWAY_PEAK_MIN) {
      return 0;
    }
    if (peak >= profile.turn.level3) {
      return 7;
    }
    if (peak >= profile.turn.level2) {
      return 5;
    }
    if (peak >= profile.turn.level1) {
      return 4;
    }
    return 2;
  }

  /**
   * 摇摆低频判据：比较同一窗口内"平滑后 / 原始"的横向能量比。
   * 300ms 箱型滤波对 ≤2Hz 的车身侧倾几乎无损（比值 0.7~1.0），
   * 对 ≥2.5Hz 的路面振动压到 0.3 以下，中间留有清晰空档。
   */
  private isLowFrequencySway(now: number): boolean {
    let rawSum: number = 0;
    let rawN: number = 0;
    for (let i = this.history.length - 1; i >= 0; i--) {
      const h: HistoryPoint = this.history[i];
      if (now - h.t > SWAY_WINDOW_MS) {
        break;
      }
      rawSum += h.lat * h.lat;
      rawN++;
    }
    let smSum: number = 0;
    let smN: number = 0;
    for (let i = this.smLat.length - 1; i >= 0; i--) {
      const p: SmoothPoint = this.smLat[i];
      if (now - p.t > SWAY_WINDOW_MS) {
        break;
      }
      smSum += p.lat * p.lat;
      smN++;
    }
    if (rawN === 0 || smN === 0) {
      return false;
    }
    const rawRms: number = Math.sqrt(rawSum / rawN);
    if (rawRms < 1e-6) {
      return false;
    }
    return Math.sqrt(smSum / smN) / rawRms >= SWAY_LOWFREQ_MIN;
  }

  private addEvent(name: string, level: number, now: number, dedupMs: number): void {
    for (const r of this.recent) {
      if (r.name === name && now - r.t < dedupMs) {
        return;
      }
    }
    this.recent.push({ name, t: now });
    if (this.recent.length > 20) {
      this.recent.shift();
    }

    const idx: number = Math.min(level, 10) - 1;
    let excluded: boolean = false;
    let reason: string = '';
    const ctx: BumpContext = this.eventContext(now);
    const vertRatio: number = ctx.vertRatio;
    const speedForGate: number = this.recentSpeed();

    if (isRoadCondition(name)) {
      // 颠簸本身就是路况，永远不计分
      excluded = true;
      reason = '路面颠簸';
    } else if (this.speedKnown && speedForGate < HANDLED_SPEED_KMH) {
      // 手持/停车挪车/蠕行：速度未知时不豁免，避免低速门空转造成虚高
      excluded = true;
      reason = '低速工况';
    } else if (vertRatio >= VERT_RATIO_VETO) {
      // 该事件窗口的能量主要在垂向 → 由路面引起，不计分
      excluded = true;
      reason = '路面颠簸';
    }

    const ev: DrivingEvent = {
      name,
      level: Math.min(level, 10),
      levelName: DEDUCT_TABLE[idx].name,
      ded: 0,
      speedKmh: Math.round(this.speedKmh * 10) / 10,
      vertRatio: Math.round(vertRatio * 100) / 100,
      excluded,
      excludeReason: excluded ? reason : undefined,
      time: now,
    };
    if (this.hasPos) {
      ev.lng = this.curLng;
      ev.lat = this.curLat;
    }
    this.events.unshift(ev);
    // 超限先淘汰最旧的"颠簸"：烂路一路都在产生颠簸，直接截断会把前面的
    // 急加减速等计分事件挤掉，导致长行程少扣分、分数虚高
    while (this.events.length > MAX_EVENTS) {
      let cut: number = -1;
      for (let i = this.events.length - 1; i >= 0; i--) {
        if (isRoadCondition(this.events[i].name)) {
          cut = i;
          break;
        }
      }
      if (cut < 0) {
        this.events.pop();
      } else {
        this.events.splice(cut, 1);
      }
    }
    hilog.info(DOMAIN, TAG, 'event %{public}s lv%{public}d exempt=%{public}s vr=%{public}s',
      name, level, `${excluded}`, ev.vertRatio?.toFixed(2) ?? '-');
    if (this.onEventCb !== undefined) {
      this.onEventCb(ev);
    }
  }

  /** 事件上下文统计（事件前 CONTEXT_WINDOW_MS 窗口，用原始值衡量振动能量） */
  private eventContext(now: number): BumpContext {
    let sumLat2: number = 0;
    let sumLon2: number = 0;
    let sumVer2: number = 0;
    let n: number = 0;
    for (let i = this.history.length - 1; i >= 0; i--) {
      const h: HistoryPoint = this.history[i];
      if (now - h.t > CONTEXT_WINDOW_MS) {
        break;
      }
      sumLat2 += h.lat * h.lat;
      sumLon2 += h.lon * h.lon;
      sumVer2 += h.ver * h.ver;
      n++;
    }
    if (n === 0) {
      return { vertRatio: 0, vertRms: 0, horizRms: 0 };
    }
    const horizRms: number = Math.sqrt((sumLat2 + sumLon2) / n);
    const vertRms: number = Math.sqrt(sumVer2 / n);
    return {
      vertRatio: vertRms / Math.max(horizRms, 0.05),
      vertRms: Math.round(vertRms * 1000) / 1000,
      horizRms: Math.round(horizRms * 1000) / 1000,
    };
  }

  /**
   * 近 MOTION_WINDOW_MS 三轴加速度 RMS（m/s²）。
   * 与评分用的 60s 水平 RMS 不同：这是给实时情绪用的短窗口，必须跟手，
   * 且要含垂向——手持晃动时三个轴一起爆，只看水平会漏判。
   */
  private motionRms(): number {
    const now: number = Date.now();
    let sum: number = 0;
    let n: number = 0;
    for (let i = this.history.length - 1; i >= 0; i--) {
      const h: HistoryPoint = this.history[i];
      if (now - h.t > MOTION_WINDOW_MS) {
        break;
      }
      sum += h.lat * h.lat + h.lon * h.lon + h.ver * h.ver;
      n++;
    }
    return n > 0 ? Math.sqrt(sum / n) : 0;
  }

  /** 近 60s 内被豁免的事件（含全部颠簸），用于 UI 的"颠簸中"提示 */
  private recentExempted(): DrivingEvent[] {
    const now: number = Date.now();
    const list: DrivingEvent[] = [];
    for (const e of this.events) {
      if (now - e.time > SMOOTH_WINDOW_MS) {
        break;
      }
      if (e.excluded) {
        list.push(e);
      }
    }
    return list;
  }

  private bumpActive(): boolean {
    return this.recentExempted().length > 0;
  }

  private roadBumpCount(): number {
    const now: number = Date.now();
    let n: number = 0;
    for (const e of this.events) {
      if (now - e.time > SMOOTH_WINDOW_MS) {
        break;
      }
      if (isRoadCondition(e.name)) {
        n++;
      }
    }
    return n;
  }

  /** 近 MOOD_EVENT_MS 内未被豁免事件的最大等级：一次急刹只有 0.7s，4s 均值会被摊平 */
  private peakLevel(): number {
    const now: number = Date.now();
    let peak: number = 0;
    for (const e of this.events) {
      if (now - e.time > MOOD_EVENT_MS) {
        break;
      }
      if (!e.excluded && e.level > peak) {
        peak = e.level;
      }
    }
    return peak;
  }

  private lastExemptReason(): string {
    const list: DrivingEvent[] = this.recentExempted();
    if (list.length === 0) {
      return '已自动豁免';
    }
    return list[0].excludeReason ?? '已自动豁免';
  }

  private trimHistory(now: number, windowMs: number): void {
    while (this.history.length > 0 && now - this.history[0].t > windowMs + SAMPLE_MS) {
      this.history.shift();
    }
  }
}

/**
 * 按 m/s² 分级。阈值已是 m/s²，不再除 9.8。
 * 峰值落在过程结束时评定，因此档位比旧实现少一级跳变：
 * 旧实现单样本命中 level3 就直接给 Lv10（12 点），一次颠簸能吃掉整段行程的分。
 */
export function classifyAccel(peakAbs: number, thresholds: ThresholdTriple): number {
  const a: number = Math.abs(peakAbs);
  if (a >= thresholds.level3 * 1.4) {
    return 9;
  }
  if (a >= thresholds.level3) {
    return 7;
  }
  if (a >= thresholds.level2 * 1.25) {
    return 6;
  }
  if (a >= thresholds.level2) {
    return 5;
  }
  if (a >= thresholds.level1 * 1.25) {
    return 3;
  }
  if (a >= thresholds.level1) {
    return 2;
  }
  if (a >= thresholds.level1 * RUN_ENTER_RATIO) {
    return 1;
  }
  return 0;
}
