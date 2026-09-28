import { DrivingEvent } from '../model/DrivingEvent';
import { SCORE_POINTS, eventWeight, isRoadCondition } from '../model/DetectionConfig';

/** 评分构成明细 */
export interface ScoreBreakdown {
  /** 事件密度分（0-100，权重 70%）：按里程归一后的每公里点数 */
  evScore: number;
  /** 平稳巡航分（0-100，权重 15%）：全程非事件时段水平加速度 RMS */
  rmsScore: number;
  /** 强度峰值分（0-100，权重 15%）：全程最严重的一次事件 */
  ctrlScore: number;
  /** 样本充分度（0-1），仅作展示；不再参与分数计算 */
  confidence: number;
  /** 有效事件数（计入评分） */
  effectiveCount: number;
  /** 豁免事件数（颠簸/低速，不计分） */
  exemptCount: number;
  /** 有效事件总点数 */
  totalPoints: number;
  /** 每公里点数，评分主口径。可选：改造前落库的旧报告没有这一项 */
  pointsPerKm?: number;
}

/** 综合评分结果 */
export interface ScoreResult {
  finalScore: number;
  breakdown: ScoreBreakdown;
  /** 已写回每事件点数的事件列表 */
  events: DrivingEvent[];
}

const EV_WEIGHT: number = 0.7;
const RMS_WEIGHT: number = 0.15;
const CTRL_WEIGHT: number = 0.15;

/** 密度惩罚上限：事件再多，密度分也只逼近 100-EV_PEN_MAX=20，永不归零 */
const EV_PEN_MAX: number = 80;
/** 密度衰减常数：每公里 5 点时惩罚到达上限的 63% */
const EV_PEN_K: number = 5;
/** 平稳巡航惩罚上限 */
const RMS_PEN_MAX: number = 15;
/** 免罚水平加速度 RMS（m/s²）：低于此值视为正常路面质感，不扣分 */
const RMS_FREE: number = 0.35;
/** 平稳度衰减常数 */
const RMS_PEN_K: number = 0.8;
/** 强度峰值惩罚上限：一次极端事件最多压掉 25 分 */
const SEV_PEN_MAX: number = 25;
/** 强度峰值衰减常数（按等级 1-10） */
const SEV_PEN_K: number = 7;
/** 里程归一下限（km）：短于此值按此长度算密度，避免除小数把惩罚放大到失真 */
const MIN_NORM_KM: number = 0.5;
/** GPS 缺失时的等效车速（km/h），用时长折算里程 */
const REF_SPEED_KMH: number = 25;
/** 样本充分度参考：5 公里或 10 分钟即算充分 */
const FULL_CONF_KM: number = 5;
const FULL_CONF_SEC: number = 600;

/**
 * 综合评分引擎：检测结束后一次性计算。
 *
 * 与旧模型的关键差别——旧模型最后一步是
 *   `raw = 75 + (composite - 75) * confidence`
 * 任何不足 1 公里或 5 分钟的行程都会被钉回 75 分：手机静止平放 45 秒
 * 也是 75「一般」，用户实测的平稳驾驶同样被压到 75 附近。这条钳位把
 * "样本不够"这一**可信度**信息偷换成了**分数**，两头都是错的。
 *
 * 新模型分数只由驾驶行为决定（三项加权，0 事件即 100 分），
 * 样本充分度只作为独立字段展示，不做任何回中。
 *
 * 里程归一同时兜住时长：`normKm = max(实际里程, 时长×参考车速, 0.5)`。
 * GPS 断流时按时长按城市均速折算等效里程，长距离行驶不会因为累积事件而吃亏，
 * 短行程里的剧烈动作也不会因为"里程短"被从轻发落。
 */
export class ScoringEngine {
  private static instance: ScoringEngine = new ScoringEngine();

  static getInstance(): ScoringEngine {
    return ScoringEngine.instance;
  }

  /**
   * @param events 全程事件（含豁免）
   * @param distanceM 行驶距离（米）
   * @param durationSec 时长（秒）
   * @param rmsH 全程非事件时段水平加速度 RMS（m/s²，由检测引擎统计，不含垂向）
   */
  compute(events: DrivingEvent[], distanceM: number, durationSec: number, rmsH: number): ScoreResult {
    let P: number = 0;
    let effectiveCount: number = 0;
    let exemptCount: number = 0;
    let peakLevel: number = 0;

    const out: DrivingEvent[] = [];
    for (const e of events) {
      // 路况类事件即便检测层漏标也在此兜住：垂向颠簸永远不参与评分
      const road: boolean = isRoadCondition(e.name);
      if (e.excluded || road) {
        exemptCount++;
        out.push(this.copy(e, 0, true, road ? '路面颠簸' : e.excludeReason));
        continue;
      }
      effectiveCount++;
      const idx: number = Math.min(Math.max(e.level, 1), 10) - 1;
      const points: number = SCORE_POINTS[idx] * eventWeight(e.name);
      P += points;
      if (e.level > peakLevel) {
        peakLevel = e.level;
      }
      out.push(this.copy(e, Math.round(points * 10) / 10, false, undefined));
    }

    const distKm: number = Math.max(distanceM / 1000, 0);
    const timeKm: number = (Math.max(durationSec, 0) / 3600) * REF_SPEED_KMH;
    const normKm: number = Math.max(distKm, timeKm, MIN_NORM_KM);
    const pkm: number = P / normKm;

    // ① 事件密度分：每公里点数指数衰减
    const evPenalty: number = EV_PEN_MAX * (1 - Math.exp(-pkm / EV_PEN_K));
    const evScore: number = 100 - evPenalty;

    // ② 平稳巡航分。引擎在无"安静样本"时返回 0（全程都处在事件窗口里），
    //    此时剧烈已被事件密度项计过，这里天然免罚，不会重复扣分。
    const rmsExcess: number = Math.max(0, rmsH - RMS_FREE);
    const rmsPenalty: number = RMS_PEN_MAX * (1 - Math.exp(-rmsExcess / RMS_PEN_K));
    const rmsScore: number = 100 - rmsPenalty;

    // ③ 强度峰值分：一次从 100km/h 的急刹比五次轻微更值得扣分，
    //    旧模型只看密度，这类行程能拿到 96 分。
    const sevPenalty: number = SEV_PEN_MAX * (1 - Math.exp(-peakLevel / SEV_PEN_K));
    const ctrlScore: number = 100 - sevPenalty;

    const composite: number = EV_WEIGHT * evScore + RMS_WEIGHT * rmsScore + CTRL_WEIGHT * ctrlScore;
    const finalScore: number = Math.min(100, Math.max(0, Math.round(composite * 10) / 10));

    const conf: number = Math.min(1, Math.max(distKm / FULL_CONF_KM, Math.max(durationSec, 0) / FULL_CONF_SEC));

    const breakdown: ScoreBreakdown = {
      evScore: Math.round(evScore * 10) / 10,
      rmsScore: Math.round(rmsScore * 10) / 10,
      ctrlScore: Math.round(ctrlScore * 10) / 10,
      confidence: Math.round(conf * 100) / 100,
      effectiveCount,
      exemptCount,
      totalPoints: Math.round(P * 10) / 10,
      pointsPerKm: Math.round(pkm * 100) / 100,
    };

    return { finalScore, breakdown, events: out };
  }

  /** 事件复制一份并写回计分点数；检测结果数组只读，不回写引擎内部状态 */
  private copy(e: DrivingEvent, ded: number, excluded: boolean, reason: string | undefined): DrivingEvent {
    return {
      name: e.name,
      level: e.level,
      levelName: e.levelName,
      ded: ded,
      lng: e.lng,
      lat: e.lat,
      speedKmh: e.speedKmh,
      vertRatio: e.vertRatio,
      excluded: excluded,
      excludeReason: reason,
      time: e.time,
    };
  }
}
