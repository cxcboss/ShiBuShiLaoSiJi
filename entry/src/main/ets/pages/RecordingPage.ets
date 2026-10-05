import { common } from '@kit.AbilityKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SensorManager, Vec3 } from '../service/SensorManager';
import { OrientationCalibrator, VehicleAccel } from '../service/OrientationCalibrator';
import { DetectionEngine, EngineSnapshot } from '../service/DetectionEngine';
import { CalibrationRecorder } from '../service/CalibrationRecorder';
import { ScoringEngine, ScoreResult } from '../service/ScoringEngine';
import { LocationTracker, GpsPoint } from '../service/LocationTracker';
import { ContinuousTaskService } from '../service/ContinuousTaskService';
import { VibrationHelper } from '../service/VibrationHelper';
import { NotificationHelper } from '../service/NotificationHelper';
import { ReportRepository } from '../service/ReportRepository';
import { PermissionHelper, LocationGrants } from '../service/PermissionHelper';
import { DrivingReport } from '../model/DrivingReport';
import { DrivingEvent } from '../model/DrivingEvent';
import {
  APP_SENSITIVITY, levelOf, moodOf, randomSlogan, reactionOf, Mood, Reaction
} from '../model/DetectionConfig';
import { TimeUtil } from '../util/TimeUtil';
import { GlobalContext } from '../util/GlobalContext';
import { TAB_BAR_CLEARANCE_VP, ThemeState } from '../util/ThemeState';
import { SettingsRepository } from '../service/SettingsRepository';
import { MoodStage } from '../components/MoodStage';

const TICK_MS: number = 200;
/** 启动点击后的准备倒计时：留时间把手机放稳，否则放置过程本身会被记成驾驶事件 */
const COUNTDOWN_SEC: number = 5;
const COUNTDOWN_MS: number = 1000;
/** 检测中展示的最近"乘客内心戏"条数 */
const REACTION_LIMIT: number = 4;
/** 合并同类反应时向前扫描的事件数：手持走路实测 1 秒一条，只取 4 条会全是同一句话 */
const REACTION_SCAN: number = 12;
/**
 * 近窗有效事件达到该数即点名"鲁莽驾驶"：扫描窗 12 条里一半以上计分，
 * 正常路况不可能这么密，只有连续激烈操作才会触发。
 */
const WILD_HITS: number = 6;
/**
 * 运动强度包络的释放系数（每 tick 0.2s 乘一次）：快攻慢放。
 * 手一停，4s 均值会立刻跌破手持门限，不做包络表情就会在 🤳 与 🙂 之间反复跳。
 * 0.95 是用实测手晃数据回放扫参定的：手持状态占比从 52%/67% 提到 52%/78%，
 * 而平稳巡航、烂路、激烈驾驶三种合成场景的表情分布不受影响。
 */
const MOTION_DECAY: number = 0.95;

/**
 * 检测中实时反馈的一条乘客反应（由事件翻译而来，不含专业数值）。
 * 同时也是 reactionRow 的参数类型：必须按对象传参（按引用），
 * 且与 ForEach 元素同型，否则 @Builder 传参会触发 ArkTS 结构化类型限制。
 */
interface LiveReaction {
  key: string;
  emoji: string;
  text: string;
  muted: boolean;
  /** 同一句反应重复出现的次数，>1 时在行尾显示 ×N */
  count: number;
}

@ComponentV2
export struct RecordingPage {
  /** 报告生成后回调给根容器展示（传报告对象） */
  @Param onShowReport: (report: DrivingReport) => void = () => {
  };

  @Local running: boolean = false;
  /** 启动流程进行中（权限弹窗、倒计时），用于阻断重复点击 */
  @Local starting: boolean = false;
  /** 5s 准备倒计时进行中 */
  @Local counting: boolean = false;
  /** 倒计时剩余秒数 */
  @Local countdownLeft: number = 0;
  /** 系统环境可观察状态（底部导航条高度），用于避让悬浮页签 */
  @Local sys: ThemeState = ThemeState.getInstance();
  @Local durationSec: number = 0;
  @Local distanceM: number = 0;
  /** 检测中的实时情绪（表情 + 一句话），由引擎快照的运动强度与车速推导 */
  @Local mood: Mood = moodOf(0, 0, false, 0);
  /** 最近若干条事件的趣味文案 */
  @Local reactions: LiveReaction[] = [];
  /** 新事件计数，驱动表情弹跳 */
  @Local pulseKey: number = 0;
  /** 真正惊动乘客的次数（豁免事件不计） */
  @Local alertCount: number = 0;
  @Local degraded: boolean = false;
  @Local bumpActive: boolean = false;
  @Local exemptReason: string = '已自动豁免';
  /** 近 60s 垂向颠簸次数：路况统计，不参与评分 */
  @Local roadBumpCount: number = 0;
  /** 检测暂停中（手动暂停按钮或握持自动暂停） */
  @Local paused: boolean = false;
  /** 暂停来源：true = 系统检测到手机被握持；false = 用户手动暂停 */
  @Local pausedByHold: boolean = false;
  /** 放回手机后的恢复倒计时（秒）：0 表示尚未放回或非握持暂停 */
  @Local resumeCountdown: number = 0;

  private scroller: Scroller = new Scroller();
  private engine: DetectionEngine = new DetectionEngine();
  private ctx: common.UIAbilityContext | undefined = undefined;
  private timer: number = -1;
  private autoStopTimer: number = -1;
  private startTs: number = 0;
  /** 暂停累计时长（毫秒）：行程时长要扣除暂停段，避免虚增 */
  private pausedMsTotal: number = 0;
  /** 本次暂停的起点时间戳 */
  private pausedAtTs: number = 0;
  /** 放回手机后 3 秒恢复的每秒倒数定时器句柄 */
  private resumeTimer: number = -1;
  /** 握持自动暂停开关是否打开 */
  private holdWatchOn: boolean = false;
  /** 握持检测事件回调（保存引用以便 off 精确退订） */
  private holdCallback: ((status: motion.HoldingHandStatus) => void) | undefined = undefined;
  /** 最近一条事件的时间戳，用于判断是否有新事件（事件数达上限后不再增长） */
  private lastEventTs: number = 0;
  /** 运动强度包络（快攻慢放），只参与情绪推导，不显示数值 */
  private motionHeld: number = 0;
  /** 页面已销毁：倒计时 await 期间被回收时，据此放弃后续启动，避免残留传感器订阅 */
  private destroyed: boolean = false;
  /** 倒计时被用户取消 */
  private countdownAbort: boolean = false;

  aboutToAppear(): void {
    this.ctx = GlobalContext.getInstance().getContext();
    if (GlobalContext.getInstance().getAutoStart()) {
      this.start();
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    const wasRunning: boolean = this.running;
    this.haltAll();
    // 页面销毁时若仍在检测，落盘保留本次行程，避免整段数据静默丢失。
    // 此时不再弹报告（组件即将卸载），仅持久化。
    if (wasRunning) {
      this.persistReport(false);
    }
  }

  /** showToast 可能抛异常，统一收敛以免产生未处理异常 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(0x0000, 'RecordingPage', 'showToast failed: %{public}s', JSON.stringify(e));
    }
  }

  start(): void {
    if (this.running || this.starting) {
      hilog.info(0x0000, 'RecordingPage', 'start() ignored: running=%{public}s starting=%{public}s',
        `${this.running}`, `${this.starting}`);
      return;
    }
    hilog.info(0x0000, 'RecordingPage', 'start() called, ctx=%{public}s', this.ctx !== undefined ? 'defined' : 'undefined');
    this.prepareAndStart();
  }

  private async prepareAndStart(): Promise<void> {
    hilog.info(0x0000, 'RecordingPage', 'prepareAndStart() entered');
    // 整个启动流程（含权限弹窗与倒计时）期间置位，阻断重复点击。
    // 否则权限弹窗期间二次点击会并发跑第二遍：engine.reset 清空状态，
    // 且下面的 setInterval 句柄被覆盖，旧 timer 永远无法 clear（200ms 定时器泄漏）。
    this.starting = true;
    this.countdownAbort = false;
    try {
      if (this.destroyed) {
        return;
      }
      // 权限申请必须在倒计时之前：系统弹窗一压住倒计时，5 秒准备就作废了
      if (!await this.ensureLocationGrants()) {
        return;
      }
      if (!await this.runCountdown()) {
        hilog.info(0x0000, 'RecordingPage', 'countdown unfinished, start aborted');
        return;
      }
      this.beginDetection();
    } finally {
      this.starting = false;
    }
  }

  /** 定位权限按需申请：精确+后台定位是评分与轨迹的基础，未获授权不应开始 */
  private async ensureLocationGrants(): Promise<boolean> {
    if (this.ctx === undefined) {
      hilog.warn(0x0000, 'RecordingPage', 'ctx is undefined, skipping permission request');
      return true;
    }
    hilog.info(0x0000, 'RecordingPage', 'calling PermissionHelper.requestLocationGrants');
    const grants: LocationGrants = await PermissionHelper.requestLocationGrants(this.ctx);
    hilog.info(0x0000, 'RecordingPage', 'grants result: allowed=%{public}s, precise=%{public}s, background=%{public}s',
      `${grants.allowed}`, `${grants.precise}`, `${grants.background}`);
    if (!grants.allowed) {
      hilog.warn(0x0000, 'RecordingPage', 'location not allowed, aborting start');
      this.toast('需要定位权限才能开始检测，请在设置中开启后重试');
      return false;
    }
    if (!grants.precise || !grants.background) {
      hilog.warn(0x0000, 'RecordingPage', 'incomplete location grants');
      this.toast('未获完整定位权限，评分与轨迹可能受影响');
    }
    return true;
  }

  /**
   * 5 秒准备倒计时：点完按钮后有足够时间把手机放到车内摆稳。
   * 返回 false 表示没走完（用户取消或页面已销毁），调用方必须放弃启动，
   * 否则会留下无人退订的传感器订阅。
   */
  private async runCountdown(): Promise<boolean> {
    this.counting = true;
    try {
      for (let i = COUNTDOWN_SEC; i >= 1; i--) {
        this.countdownLeft = i;
        await this.sleep(COUNTDOWN_MS);
        if (this.countdownAbort || this.destroyed) {
          return false;
        }
      }
      return true;
    } finally {
      this.counting = false;
      this.countdownLeft = 0;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private cancelCountdown(): void {
    this.countdownAbort = true;
  }

  /** 倒计时走完，正式开始采集 */
  private beginDetection(): void {
    const recorder: CalibrationRecorder = CalibrationRecorder.getInstance();
    recorder.start(APP_SENSITIVITY);
    this.engine.reset(APP_SENSITIVITY);
    OrientationCalibrator.getInstance().reset();
    this.reactions = [];
    this.alertCount = 0;
    this.durationSec = 0;
    this.distanceM = 0;
    this.lastEventTs = 0;
    this.pulseKey = 0;
    this.motionHeld = 0;
    this.mood = moodOf(0, 0, false, 0);
    this.bumpActive = false;
    this.roadBumpCount = 0;
    this.paused = false;
    this.pausedByHold = false;
    this.resumeCountdown = 0;
    this.pausedMsTotal = 0;
    this.startTs = Date.now();
    this.setupHoldWatcher();

    this.engine.setOnEvent((e: DrivingEvent): void => {
      recorder.event(e.time, e.name, e.level, e.excluded, e.speedKmh ?? 0, e.vertRatio ?? 0);
      // 被豁免的事件（路况/低速）不算惊动乘客；仅严重且计分的事件震动提醒（内部 60s 节流）
      if (!e.excluded) {
        this.alertCount++;
        if (e.level >= 6) {
          VibrationHelper.getInstance().vibrate();
        }
      }
    });

    SensorManager.getInstance().startAccel((v: Vec3): void => {
      recorder.gravity(v);
      OrientationCalibrator.getInstance().update({ x: v.x, y: v.y, z: v.z });
    });
    SensorManager.getInstance().startLinear((v: Vec3): void => {
      // 暂停（手动/握持）期间冻结引擎：传感器数据不产生事件，恢复后从当前姿态继续
      if (this.paused) {
        return;
      }
      const cal: OrientationCalibrator = OrientationCalibrator.getInstance();
      const proj: VehicleAccel = cal.horizontalize(v.x, v.y, v.z);
      recorder.linear(v);
      recorder.projected(v.ts, proj.lateral, proj.longitudinal, proj.vertical);
      this.engine.feed(proj.lateral, proj.longitudinal, proj.vertical);
    });

    LocationTracker.getInstance().setOnUpdate((pt: GpsPoint): void => {
      // 暂停期间 GPS 不喂引擎也不学前向轴，避免手持走动污染速度与车体方向
      if (this.paused) {
        return;
      }
      const spd: number = pt.speedKmh;
      this.engine.setSpeed(spd);
      this.engine.setPosition(pt.lat, pt.lng);
      // 车体前向轴由"GPS 速度导数 × 同窗水平加速度"在线学习，手机怎么放都不影响纵轴含义
      OrientationCalibrator.getInstance().onSpeed(spd, pt.ts);
      recorder.gps(pt.ts, pt.lat, pt.lng, spd, pt.direction ?? -1, pt.accuracy ?? -1);
    });
    if (!LocationTracker.getInstance().start()) {
      this.toast('定位不可用，本次检测仅依据传感器');
    }

    if (this.ctx !== undefined) {
      ContinuousTaskService.getInstance().start(this.ctx);
      NotificationHelper.getInstance().publishDetecting('正在检测驾驶行为，结束后生成综合评分报告');
    }

    this.running = true;
    this.timer = setInterval(() => this.tick(), TICK_MS);
    // 自动停止的时长从倒计时之后起算，调试参数含义才是"检测 N 毫秒"
    const autoStopMs: number = GlobalContext.getInstance().getAutoStopMs();
    if (autoStopMs > 0) {
      this.autoStopTimer = setTimeout(() => {
        this.autoStopTimer = -1;
        if (this.running) {
          this.stop();
        }
      }, autoStopMs);
    }
  }

  /**
   * 订阅系统握持检测（MultimodalAwarenessKit，API 20+）：
   * 开关开启且设备支持时，检测中手机被拿起自动暂停，放回静止 3 秒后恢复。
   * 订阅失败（权限拒绝/能力缺失）只提示并继续正常检测，不阻塞启动流程。
   */
  private async setupHoldWatcher(): Promise<void> {
    this.holdWatchOn = await SettingsRepository.getInstance().getHoldPause();
    if (!this.holdWatchOn) {
      return;
    }
    if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      this.toast('当前设备不支持握持检测，自动暂停不可用');
      return;
    }
    this.holdCallback = (status: motion.HoldingHandStatus): void => {
      if (!this.running) {
        return;
      }
      if (status === motion.HoldingHandStatus.NOT_HELD) {
        this.scheduleHoldResume();
      } else if (status !== motion.HoldingHandStatus.UNKNOWN_STATUS) {
        this.pauseDetection(true);
      }
    };
    try {
      motion.on('holdingHandChanged', this.holdCallback);
    } catch (e) {
      this.holdCallback = undefined;
      hilog.warn(0x0000, 'RecordingPage', 'hold subscribe failed: %{public}s', JSON.stringify(e));
      this.toast('握持检测订阅失败，自动暂停不可用');
    }
  }

  /** 暂停检测：byHold=系统握持检测触发，否则为用户手动暂停。重复暂停安全 */
  private pauseDetection(byHold: boolean): void {
    if (!this.running || this.paused) {
      return;
    }
    this.paused = true;
    this.pausedByHold = byHold;
    this.pausedAtTs = Date.now();
    LocationTracker.getInstance().setFrozen(true);
  }

  /** 手机被放回：进入 3 秒倒数（每秒刷新界面倒计时），期间再次拿起则取消 */
  private scheduleHoldResume(): void {
    if (!this.paused) {
      return;
    }
    if (this.resumeTimer !== -1) {
      clearInterval(this.resumeTimer);
      this.resumeTimer = -1;
    }
    this.resumeCountdown = 3;
    this.resumeTimer = setInterval(() => {
      this.resumeCountdown--;
      if (this.resumeCountdown <= 0) {
        if (this.resumeTimer !== -1) {
          clearInterval(this.resumeTimer);
          this.resumeTimer = -1;
        }
        this.resumeDetection();
      }
    }, 1000);
  }

  /** 恢复检测：累计暂停时长（行程时长会扣除），解除里程冻结 */
  private resumeDetection(): void {
    if (!this.paused) {
      return;
    }
    this.pausedMsTotal += Date.now() - this.pausedAtTs;
    this.pausedAtTs = 0;
    this.paused = false;
    this.pausedByHold = false;
    this.resumeCountdown = 0;
    LocationTracker.getInstance().setFrozen(false);
    this.toast('已恢复检测');
  }

  private tick(): void {
    const snap: EngineSnapshot = this.engine.getSnapshot();
    const raw: number = snap.motionRms;
    this.motionHeld = raw > this.motionHeld ? raw : this.motionHeld * MOTION_DECAY;
    const mood: Mood = moodOf(this.motionHeld, snap.speedKmh, snap.speedKnown, snap.peakLevel);
    // 暂停期间时长停在暂停起点：行程时长 = 墙钟差 - 暂停累计
    const endTs: number = this.paused ? this.pausedAtTs : Date.now();
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.mood = mood;
      this.distanceM = LocationTracker.getInstance().getDistance();
      this.durationSec = Math.floor(Math.max(0, endTs - this.startTs - this.pausedMsTotal) / 1000);
      this.bumpActive = snap.bumpActive;
      this.exemptReason = snap.exemptReason;
      this.roadBumpCount = snap.roadBumpCount;
    });
    this.degraded = ContinuousTaskService.getInstance().isDegraded;

    // 以"最新事件时间戳"而非"事件总数"判断是否有新事件：
    // events 达 MAX_EVENTS 上限后长度不再增长，用长度比较会让列表永久冻结。
    const evs: DrivingEvent[] = this.engine.getEvents();
    const newestTs: number = evs.length > 0 ? evs[0].time : 0;
    if (newestTs > this.lastEventTs) {
      this.lastEventTs = newestTs;
      const list: LiveReaction[] = [];
      let validHits: number = 0;
      for (let i = 0; i < evs.length && i < REACTION_SCAN; i++) {
        const e: DrivingEvent = evs[i];
        // 计数不被 REACTION_LIMIT 截断：鲁莽预警看的是近窗有效事件总量
        if (!e.excluded) {
          validHits++;
        }
        const r: Reaction = reactionOf(e.name, e.level, e.excluded);
        // 同一句内心戏只占一行：手持实测 43s 能产生 39 条事件，
        // 逐条直出会刷成四行一模一样的"虚惊一场，不扣分"
        const dup: LiveReaction | undefined = list.find((x: LiveReaction) => x.text === r.text);
        if (dup !== undefined) {
          dup.count++;
        } else if (list.length < REACTION_LIMIT) {
          list.push({ key: `${e.time}-${e.name}`, emoji: r.emoji, text: r.text, muted: e.excluded, count: 1 });
        }
      }
      // 近窗一半以上是有效事件：不再逐条玩梗，直接点名鲁莽驾驶压在最前面
      if (validHits >= WILD_HITS) {
        list.unshift({ key: 'wild-driving', emoji: '🫠',
          text: '有点鲁莽驾驶了，脚下收着点', muted: false, count: 1 });
      }
      this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseOut }, () => {
        this.reactions = list;
        this.pulseKey++;
      });
    }
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.haltAll();
    this.persistReport(true);
  }

  private haltAll(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.autoStopTimer !== -1) {
      clearTimeout(this.autoStopTimer);
      this.autoStopTimer = -1;
    }
    if (this.resumeTimer !== -1) {
      clearInterval(this.resumeTimer);
      this.resumeTimer = -1;
    }
    // 退出检测必须退订握持事件，否则后台仍持有回调引用
    if (this.holdCallback !== undefined) {
      try {
        motion.off('holdingHandChanged', this.holdCallback);
      } catch (e) {
        hilog.warn(0x0000, 'RecordingPage', 'hold unsubscribe failed: %{public}s', JSON.stringify(e));
      }
      this.holdCallback = undefined;
    }
    this.holdWatchOn = false;
    this.paused = false;
    this.pausedByHold = false;
    this.resumeCountdown = 0;
    LocationTracker.getInstance().setFrozen(false);
    SensorManager.getInstance().stopAll();
    OrientationCalibrator.getInstance().reset();
    LocationTracker.getInstance().stop();
    if (this.ctx !== undefined) {
      ContinuousTaskService.getInstance().stop(this.ctx);
      NotificationHelper.getInstance().cancel();
    }
    this.engine.stop();
    this.running = false;
    this.reactions = [];
  }

  /**
   * 结算本次行程并落盘。show=true 时回调根容器弹出报告；
   * 页面销毁路径只落盘不弹窗（组件即将卸载）。
   * 必须在 haltAll() 之后调用：engine.stop()/LocationTracker.stop() 只停采集，
   * 不清空事件、里程与轨迹，结算数据仍然可读。
   */
  private async persistReport(show: boolean): Promise<void> {
    try {
      const distanceM: number = LocationTracker.getInstance().getDistance();
      // 结算时长同样扣除暂停段：暂停期间直接结束，时长算到暂停起点
      const endTs: number = this.paused ? this.pausedAtTs : Date.now();
      const durationSec: number = Math.floor(Math.max(0, endTs - this.startTs - this.pausedMsTotal) / 1000);
      const result: ScoreResult = ScoringEngine.getInstance()
        .compute(this.engine.getEvents(), distanceM, durationSec, this.engine.getRmsH());
      const final: number = result.finalScore;
      // 标定数据带上最终分，离线才能把"原始样本 → 事件 → 分数"整条链复算一遍
      CalibrationRecorder.getInstance().stop(durationSec, distanceM, final);
      const lv = levelOf(final);
      const now: number = Date.now();
      const report: DrivingReport = {
        id: 0,
        baseScore: result.breakdown.evScore,
        finalScore: final,
        breakdown: result.breakdown,
        level: lv.label,
        levelDesc: lv.desc,
        slogan: randomSlogan(final),
        sensitivity: APP_SENSITIVITY,
        durationSec: durationSec,
        distanceM: distanceM,
        startTime: this.startTs,
        endTime: now,
        date: TimeUtil.formatDate(this.startTs),
        events: result.events,
        gpsPath: LocationTracker.getInstance().getPath().map((p: GpsPoint): [number, number] => [p.lng, p.lat]),
      };
      const id: number = await ReportRepository.getInstance().save(report);
      report.id = id;
      this.durationSec = 0;
      this.distanceM = 0;
      if (id < 0) {
        hilog.error(0x0000, 'RecordingPage', 'report persist failed, id=%{public}d', id);
        this.toast('本次报告保存失败');
      }
      if (show) {
        this.onShowReport(report);
      }
    } catch (e) {
      hilog.error(0x0000, 'RecordingPage', 'persistReport failed: %{public}s', JSON.stringify(e));
      this.toast('结算失败，本次报告未能生成');
    }
  }

  build() {
    Column() {
      if (this.counting) {
        this.countdownView()
      } else if (!this.running) {
        this.idleView()
      } else {
        this.runningView()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 5 秒准备期：环形进度 + 剩余秒数，给用户把手机放稳的时间 */
  @Builder
  countdownView() {
    Column({ space: 24 }) {
      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: COUNTDOWN_SEC - this.countdownLeft, total: COUNTDOWN_SEC, type: ProgressType.Ring })
          .width(168)
          .height(168)
          .color('#0A59F7')
          .backgroundColor($r('app.color.card_bg_light'))
          .style({ strokeWidth: 10 })
          // 读屏会把这个环念成 "3.000000"，中间的秒数 Text 已经报过数了，环只作装饰
          .accessibilityLevel('no')
        Text(`${this.countdownLeft}`)
          .fontSize(64)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0A59F7')
      }

      Text('请将手机平放在车内')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
      Text('结束就开始记录\n这几秒让手机待在车里')
        .fontSize(15)
        .fontColor($r('app.color.font_tertiary'))
        .textAlign(TextAlign.Center)
        .lineHeight(22)

      Text('取消')
        .fontSize(16)
        .fontColor('#0A59F7')
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .onClick(() => this.cancelCountdown())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
  }

  @Builder
  idleView() {
    Column() {
      // 内容区
      Column({ space: 16 }) {
        Text('🚗')
          .fontSize(56)
        Text('准备好出发了吗？')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.Center)
        Text('把手机平放固定好\n开起来它替你看，下车给你算个分')
          .fontSize(16)
          .fontColor($r('app.color.font_tertiary'))
          .textAlign(TextAlign.Center)
          .lineHeight(24)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // 底部按钮区域
      Column({ space: 10 }) {
        Button(this.starting ? '正在准备…' : '开始检测')
          .width('100%')
          .height(48)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('#0A59F7')
          .borderRadius(24)
          .enabled(!this.starting)
          .onClick(() => this.start())
        Text('检测需要访问加速度计和定位权限')
          .fontSize(11)
          .fontColor($r('app.color.font_quaternary'))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .padding({
        left: 24, right: 24,
        bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()),
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 路况/低速豁免的口语化说明：一句话安抚，扫一眼就懂，不解释传感器 */
  private roadLine(): string {
    const base: string = this.exemptReason === '低速工况'
      ? '还在挪车，不算车技'
      : '这路是真烂，不怪你';
    return this.roadBumpCount > 0 ? `${base}，颠了 ${this.roadBumpCount} 次` : base;
  }

  /** 陪伴进度：时长与里程是行程事实，不是专业数值；时长用中文表述避免读成时刻 */
  private companionLine(): string {
    const parts: string[] = [`已同行 ${TimeUtil.formatDurationCn(this.durationSec)}`];
    if (this.distanceM >= 100) {
      parts.push(`${(this.distanceM / 1000).toFixed(1)} 公里`);
    }
    if (this.alertCount > 0) {
      parts.push(`惊动乘客 ${this.alertCount} 次`);
    }
    return parts.join(' · ');
  }

  @Builder
  runningView() {
    // Stack 让滚动内容铺满全屏（穿透状态栏与悬浮底栏），结束按钮悬浮在底栏上方；
    // 内容顶部/底部分别用占位撑出净空，滚动到头时首尾内容不被遮挡。
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.scroller) {
        Column({ space: 18 }) {
          // 乘客状态：表情 + 一句话，检测过程中不出现任何专业数值
          MoodStage({
            emoji: this.mood.emoji,
            title: this.mood.title,
            hint: this.mood.hint,
            color: this.mood.color,
            pulseKey: this.pulseKey,
          })

          Text(this.companionLine())
            .fontSize(16)
            .fontColor($r('app.color.font_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)

          // 路况/低速豁免：用安抚的口吻，不用"豁免 N 次"这类术语
          if (this.bumpActive) {
            Row({ space: 6 }) {
              Text('🛡️')
                .fontSize(15)
              Text(this.roadLine())
                .fontSize(15)
                .fontColor('#FF9800')
            }
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor('#1AFF9800')
            .borderRadius(10)
          }

          // 暂停横幅：握持暂停说明"拿起→暂停、放下→倒计时恢复"；手动暂停点横幅继续
          if (this.paused) {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.pause_fill'))
                  .fontSize(18)
                  .fontColor(['#FF9800'])
                  .accessibilityLevel('no')
                Text(this.pauseBannerTitle())
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FF9800')
              }
              Text(this.pauseBannerSub())
                .fontSize(13)
                .fontColor('#FF9800')
                .opacity(0.85)
            }
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .backgroundColor('#1AFF9800')
            .borderRadius(14)
            .onClick(() => {
              // 仅手动暂停支持点横幅恢复；握持暂停必须放下手机走 3 秒倒数
              if (!this.pausedByHold) {
                this.resumeDetection();
              }
            })
          }

          // 乘客内心戏：事件按趣味文案滚动展示，等级/扣分数值留给报告
          Column({ space: 8 }) {
            Text(this.reactions.length > 0 ? '乘客内心戏' : '目前为止')
              .fontSize(14)
              .fontColor($r('app.color.font_quaternary'))
              .width('100%')
            if (this.reactions.length > 0) {
              ForEach(this.reactions, (r: LiveReaction) => {
                this.reactionRow(r)
              }, (r: LiveReaction) => r.key)
            } else {
              this.reactionRow({ key: 'idle', emoji: '🍵', text: '乘客还很放松', muted: false, count: 1 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 后台降级
          if (this.degraded) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
                .fontSize(16)
                .fontColor(['#FF9800'])
                .accessibilityLevel('no')
              Text('后台检测受限，已切换为前台模式')
                .fontSize(13)
                .fontColor('#FF9800')
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#1AFF9800')
            .borderRadius(8)
          }

          Text('具体数字结束后在报告里看')
            .fontSize(14)
            .fontColor($r('app.color.font_quaternary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .width('100%')
        // padding 加在内容上而非 Scroll 上：Scroll 自身 padding 会内缩视口挡住穿透
        .padding({
          left: 20, right: 20,
          top: this.sys.topInsetVp(this.getUIContext()) + 8,
          // 尾部净空 = 按钮上间距 8 + 按钮 48 + 悬浮底栏净空
          bottom: 8 + 48 + TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()),
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 底部按钮区：检测中为"暂停 + 结束"双按钮；暂停态撤掉恢复按钮，
      // 只留居中的"结束检测"（恢复走横幅：握持放下 3 秒倒数 / 手动点横幅）
      if (!this.paused) {
        Row({ space: 12 }) {
          Button('暂停检测')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#0A59F7')
            .borderRadius(24)
            .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
            .onClick(() => this.onPauseButtonClick())

          Button('结束检测')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#F44336')
            .borderRadius(24)
            .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
            .onClick(() => this.stop())
        }
        .width('100%')
        .padding({ left: 44, right: 44 })
        .margin({ bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()) })
      } else {
        Button('结束检测')
          .width(220)
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('#F44336')
          .borderRadius(24)
          .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
          .margin({ bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()) })
          .onClick(() => this.stop())
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 暂停按钮：检测中则手动暂停（恢复走暂停横幅的点击），避免误触直接恢复 */
  private onPauseButtonClick(): void {
    if (!this.running) {
      return;
    }
    this.pauseDetection(false);
  }

  /**
   * 暂停横幅文案：握持暂停明确"拿起→暂停、放下→继续"，放回后显示每秒倒数；
   * 手动暂停提示点横幅恢复。
   */
  private pauseBannerTitle(): string {
    if (!this.pausedByHold) {
      return '检测已暂停';
    }
    return this.resumeCountdown > 0 ? '已放回手机' : '已拿起手机，检测自动暂停';
  }

  private pauseBannerSub(): string {
    if (!this.pausedByHold) {
      return '点击此条继续检测';
    }
    if (this.resumeCountdown > 0) {
      return `${this.resumeCountdown} 秒后自动恢复检测`;
    }
    return '放下手机后才会继续检测';
  }

  @Builder
  reactionRow($$: LiveReaction) {
    Row({ space: 10 }) {
      Text($$.emoji)
        .fontSize(22)
      Text($$.text)
        .fontSize(17)
        .fontColor($$.muted ? $r('app.color.font_tertiary') : $r('app.color.font_primary'))
        .layoutWeight(1)
      if ($$.count > 1) {
        Text(`×${$$.count}`)
          .fontSize(15)
          .fontColor($r('app.color.font_quaternary'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.chip_bg'))
    .borderRadius(12)
    .transition(TransitionEffect.translate({ y: 12 })
      .combine(TransitionEffect.OPACITY)
      .animation({ duration: 280, curve: Curve.EaseOut }))
  }
}
