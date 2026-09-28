/**
 * 三档灵敏度下的事件阈值，单位 m/s²。
 *
 * 量纲从旧版的 g 改成 m/s²，并且作用对象从"50ms 瞬时值"改成"300ms 平滑值"：
 * 瞬时阈值下 52km/h 匀速巡航实测能记录 252 个有效事件（中位间隔 0.64s），
 * 其中 40 次「急加速 Lv10」——路面振动被当成了驾驶行为。
 * 数值参照：舒适加减速 1~1.5、明显 1.5~2.5、激烈 2.5~3.5、紧急 >3.5 m/s²。
 */
export interface ThresholdTriple {
  level1: number;
  level2: number;
  level3: number;
}

export interface SensitivityProfile {
  brake: ThresholdTriple; // 急减速
  accel: ThresholdTriple; // 急加速
  turn: ThresholdTriple;  // 急转向
}

export type Sensitivity = 'mild' | 'moderate' | 'severe';

/** 唯一文案来源，不对外导出：调用一律走 sensitivityLabel */
const SENSITIVITY_LABELS: Map<Sensitivity, string> = new Map([
  ['mild', '轻度'],
  ['moderate', '中度'],
  ['severe', '重度'],
]);

/**
 * 灵敏度中文名。此前 if 分支把三档文案又抄了一遍，与 SENSITIVITY_LABELS
 * 构成两份真值来源（改一处漏一处），且入参写成 string 丢掉了枚举约束。
 */
export function sensitivityLabel(s: Sensitivity): string {
  return SENSITIVITY_LABELS.get(s) ?? '中度';
}

const PROFILE_MILD: SensitivityProfile = {
  brake: { level1: 1.8, level2: 2.8, level3: 4.0 },
  accel: { level1: 1.7, level2: 2.6, level3: 3.8 },
  turn: { level1: 1.6, level2: 2.5, level3: 3.6 },
};
const PROFILE_MODERATE: SensitivityProfile = {
  brake: { level1: 1.5, level2: 2.4, level3: 3.4 },
  accel: { level1: 1.4, level2: 2.2, level3: 3.2 },
  turn: { level1: 1.3, level2: 2.1, level3: 3.0 },
};
const PROFILE_SEVERE: SensitivityProfile = {
  brake: { level1: 1.2, level2: 1.9, level3: 2.8 },
  accel: { level1: 1.1, level2: 1.8, level3: 2.6 },
  turn: { level1: 1.0, level2: 1.7, level3: 2.4 },
};

export const PROFILES: Map<Sensitivity, SensitivityProfile> = new Map([
  ['mild', PROFILE_MILD],
  ['moderate', PROFILE_MODERATE],
  ['severe', PROFILE_SEVERE],
]);

export function getProfile(s: Sensitivity): SensitivityProfile {
  const p = PROFILES.get(s);
  if (p === undefined) {
    return PROFILES.get('moderate') as SensitivityProfile;
  }
  return p;
}

/** 10 级事件（名称/描述沿用参考项目，ded 仅作遗留兼容，计分用 SCORE_POINTS） */
export interface DeductItem {
  level: number;
  name: string;
  ded: number;
}

export const DEDUCT_TABLE: DeductItem[] = [
  { level: 1, name: '微弱', ded: 0.1 },
  { level: 2, name: '轻微', ded: 0.3 },
  { level: 3, name: '轻度', ded: 0.6 },
  { level: 4, name: '一般', ded: 1.0 },
  { level: 5, name: '偏强', ded: 1.5 },
  { level: 6, name: '中等', ded: 2.2 },
  { level: 7, name: '较强', ded: 3.0 },
  { level: 8, name: '强烈', ded: 4.0 },
  { level: 9, name: '剧烈', ded: 5.5 },
  { level: 10, name: '极端', ded: 7.5 },
];

/** 等级 → 计分点数（新评分模型使用，检测中不扣分，结束时统一计分） */
export const SCORE_POINTS: number[] = [0.5, 1, 1.5, 2, 3, 4, 6, 8, 10, 12];

/** 检测事件类型与权重 */
export interface EventTypeDef {
  name: string;
  weight: number;
  desc: string;
}

export const EVENT_TYPES: EventTypeDef[] = [
  { name: '急减速', weight: 1.5, desc: '纵向减速度过大' },
  { name: '急加速', weight: 0.75, desc: '纵向加速度过大' },
  { name: '急转向', weight: 0.8, desc: '横向加速度过大' },
  { name: '摇摆', weight: 0.6, desc: '横向反复摆动' },
  // 上下颠簸是路面状况不是驾驶行为，权重恒 0：即使检测出也不产生任何点数
  { name: '颠簸', weight: 0, desc: '垂向加速度突变，计入路况不计分' },
];

/** 路况类事件：只统计展示，永不参与评分 */
const ROAD_CONDITION: string[] = ['颠簸'];

export function isRoadCondition(name: string): boolean {
  return ROAD_CONDITION.indexOf(name) >= 0;
}

export function eventWeight(name: string): number {
  for (const t of EVENT_TYPES) {
    if (t.name === name) {
      return t.weight;
    }
  }
  return 1;
}

/** 7 级晕车等级（min 为下限，取第一个 min <= score 匹配）。按新评分模型区间重映射。 */
export interface LevelDef {
  min: number;
  label: string;
  desc: string;
  color: string;
}

export const LEVELS: LevelDef[] = [
  { min: 95, label: '无感', desc: '完全没有晕车感', color: '#00C853' },
  { min: 88, label: '轻微', desc: '几乎感觉不到不适', color: '#4CAF50' },
  { min: 70, label: '一般', desc: '整体平稳，偶有不适', color: '#8BC34A' },
  { min: 55, label: '小晕', desc: '开始出现晕车症状', color: '#FF9800' },
  { min: 42, label: '晕', desc: '明显晕车不适', color: '#FF5722' },
  { min: 35, label: '严重', desc: '严重晕车，难以忍受', color: '#F44336' },
  { min: 0, label: '非常严重', desc: '极度不适，建议停车', color: '#B71C1C' },
];

export function levelOf(score: number): LevelDef {
  for (const lv of LEVELS) {
    if (score >= lv.min) {
      return lv;
    }
  }
  return LEVELS[LEVELS.length - 1];
}

/** 趣味标语（threshold 降序，取第一个 score >= threshold）。阈值按新评分区间重映射。 */
export interface SloganGroup {
  threshold: number;
  texts: string[];
}

export const SLOGANS: SloganGroup[] = [
  { threshold: 100, texts: ['完美！你是漂移之神！', '铁定没有晕车的命', '这车开得比奶茶还丝滑', '坐你的车比坐沙发还舒服', '秋名山车神来了都要让位'] },
  { threshold: 95, texts: ['稳如老狗，咖啡一滴不洒', '乘客：再来一圈！', '秋名山车神认证通过', '这技术，藤原拓海都服', '坐你的车可以闭眼睡觉'] },
  { threshold: 90, texts: ['优秀！乘客表示很舒服', '这脚法，可以去开赛车了', '平稳得让人想睡觉', '你是不是偷偷练过漂移', '乘客：可以当专车司机了'] },
  { threshold: 85, texts: ['不错不错，基本功扎实', '乘客：还可以接受', '离秋名山车神只差一步', '这车开得有模有样', '乘客：下次还坐你的车'] },
  { threshold: 80, texts: ['还行吧，小瑕疵不影响大局', '乘客：嗯...还行', '偶尔浪一下也很正常', '稳中带皮，皮中带稳', '乘客：比出租车强点'] },
  { threshold: 75, texts: ['有点颠，但问题不大', '乘客：系好安全带了', '建议多练练刹车脚法', '这车开得有点上头', '乘客：还行吧，习惯了'] },
  { threshold: 70, texts: ['开始有点晕了...', '乘客：我要吐了...', '减速！减速！', '乘客：还有多久到？', '这刹车踩得有点猛啊'] },
  { threshold: 65, texts: ['晕车预警！', '乘客：求你慢点', '这车开得像过山车', '乘客：我需要一个塑料袋', '你是在开赛车吗'] },
  { threshold: 55, texts: ['危险！乘客已经在找塑料袋了', '刹车踩得像开关', '建议改坐地铁', '乘客：我要下车吐一会', '你是不是把油门当刹车了'] },
  { threshold: 45, texts: ['重灾区！乘客已投降', '这驾驶技术需要回炉重造', '晕车界的天花板', '乘客：我的胃在抗议', '你确定你有驾照？'] },
  { threshold: 38, texts: ['紧急警报！乘客已晕厥', '开车像在蹦迪', '建议把车卖了', '乘客：我已经灵魂出窍了', '你是在开碰碰车吗'] },
  { threshold: 32, texts: ['史诗级灾难！', '这不是开车，这是驯兽', '乘客：我要下车！！！', '你的车技让我怀疑人生', '乘客：报警了，这算谋杀'] },
  { threshold: 25, texts: ['传说中的夺命连环弯？', '开出了海盗船的感觉', '建议原地停车', '乘客：遗书我已经写好了', '你的车技让我重新思考人生'] },
  { threshold: 15, texts: ['地狱级体验', '乘客：我选择走路', '这车有这么难开吗', '乘客：我已经在写遗书了', '你是不是在故意谋杀乘客'] },
  { threshold: 0, texts: ['超越人类极限！', '乘客：我看到了太奶奶', '这不是开车，这是刑罚', '你的车技让牛顿都哭了', '乘客：我已经放弃治疗了'] },
];

export function randomSlogan(score: number): string {
  for (const g of SLOGANS) {
    if (score >= g.threshold) {
      const idx: number = Math.floor(Math.random() * g.texts.length);
      return g.texts[idx];
    }
  }
  return '';
}

/**
 * 检测中的实时情绪（乘客状态）。
 * 检测页不出现 m/s²、Lv、RMS 等专业数值，只把传感器读数翻译成人话，
 * 专业数据一律留在结束后的行程报告里。
 */
export interface Mood {
  key: string;
  emoji: string;
  title: string;
  hint: string;
  color: string;
}

/**
 * 手持/走动判据：三轴运动强度下限（m/s²）。
 * 实测：平放静止 0.03、车内怠速 0.11、平稳巡航 0.26、烂路巡航 1.6（峰值 2.1），
 * 而手持走路 4s RMS 中位数 3.0、手持乱晃 10.5。取 2.5 能把走动识别成"不在车上"，
 * 又离静止/怠速有两个数量级的余量；烂路靠车速门限（<5km/h）挡住，不会被误判。
 */
const HANDLED_MOTION: number = 2.5;
/** 车速未知时的剧烈程度上限（m/s²）：超过即视为乘客已经开始难受 */
const ROUGH_MOTION: number = 4.0;
/** 手持时的车速上限（km/h），与低速豁免同一口径 */
const HANDLED_SPEED_KMH: number = 5;
/**
 * 完全静止判据：几乎无加速度且车速接近 0。
 * 上限取 3km/h 而不是 1：室内 GPS 漂移实测就有 0.3~1.8km/h，
 * 卡 1km/h 会让"平放在桌上"永远识别成静止不了。
 */
const STILL_MOTION: number = 0.35;
const STILL_SPEED_KMH: number = 3;

const MOOD_STILL: Mood = {
  key: 'still', emoji: '😴', color: '#9E9E9E',
  title: '车停着，乘客在打盹', hint: '开起来才有分',
};
const MOOD_HANDLED: Mood = {
  key: 'handled', emoji: '🤳', color: '#0A59F7',
  title: '手机好像不在车上', hint: '平放固定好才测得准',
};
const MOOD_SMOOTH: Mood = {
  key: 'smooth', emoji: '😎', color: '#00C853',
  title: '乘客：这车比沙发还稳', hint: '继续保持',
};
const MOOD_OK: Mood = {
  key: 'ok', emoji: '🙂', color: '#8BC34A',
  title: '乘客表示可以接受', hint: '整体没什么波澜',
};
const MOOD_WOBBLY: Mood = {
  key: 'wobbly', emoji: '😨', color: '#FF9800',
  title: '乘客悄悄系紧了安全带', hint: '脚下收着点',
};
const MOOD_ROUGH: Mood = {
  key: 'rough', emoji: '🤢', color: '#F44336',
  title: '乘客在找塑料袋', hint: '慢一点，再慢一点',
};

/**
 * 由近 4s 三轴运动强度、车速与"刚发生的事件等级"推导实时情绪。
 * motionRms 单位 m/s²；speedKnown=false 时不宣称"停着"，避免无 GPS 误报。
 * peakLevel 用来补上短促的剧烈动作：一次 0.7s 急刹在 4s 均值里只剩 1m/s²，
 * 只看均值表情根本来不及反应。
 */
export function moodOf(motionRms: number, speedKmh: number, speedKnown: boolean, peakLevel: number): Mood {
  if (motionRms >= HANDLED_MOTION && speedKnown && speedKmh < HANDLED_SPEED_KMH) {
    return MOOD_HANDLED;
  }
  if (peakLevel >= 7) {
    return MOOD_ROUGH;
  }
  if (peakLevel >= 4) {
    return MOOD_WOBBLY;
  }
  if (motionRms < STILL_MOTION && speedKnown && speedKmh < STILL_SPEED_KMH) {
    return MOOD_STILL;
  }
  if (motionRms < 0.8) {
    return MOOD_SMOOTH;
  }
  if (motionRms < 2.0) {
    return MOOD_OK;
  }
  if (motionRms < ROUGH_MOTION) {
    return MOOD_WOBBLY;
  }
  return MOOD_ROUGH;
}

/** 单条事件的趣味反馈：emoji + 乘客内心戏 */
export interface Reaction {
  emoji: string;
  text: string;
}

const REACTION_ROAD: Reaction = { emoji: '🛣️', text: '路面的锅，不扣分' };
const REACTION_REASSURE: Reaction = { emoji: '🛡️', text: '虚惊一场，不扣分' };

/** 下标 0/1/2 依次对应 轻微(Lv1-3) / 一般(Lv4-6) / 严重(Lv7+) */
const RE_BRAKE: Reaction[] = [
  { emoji: '🙂', text: '刹得从容' },
  { emoji: '😳', text: '乘客往前扑了一下' },
  { emoji: '😱', text: '乘客咖啡差点洒了' },
];
const RE_ACCEL: Reaction[] = [
  { emoji: '🙂', text: '起步顺滑' },
  { emoji: '😮', text: '乘客抓住了扶手' },
  { emoji: '🚀', text: '后背被按进座椅' },
];
const RE_TURN: Reaction[] = [
  { emoji: '😉', text: '变道干净利落' },
  { emoji: '😵', text: '乘客脑瓜子嗡嗡的' },
  { emoji: '🌀', text: '车门还关着吗' },
];
const RE_SWAY: Reaction[] = [
  { emoji: '😐', text: '有点晃，乘客在忍' },
  { emoji: '🥴', text: '乘客开始沉默了' },
  { emoji: '😨', text: '让我先缓缓' },
];
const RE_BUMP: Reaction[] = [
  { emoji: '🛣️', text: '路面有点碎' },
  { emoji: '🛣️', text: '这路考验乘客的胃' },
  { emoji: '🤢', text: '颠得灵魂出窍' },
];

const REACTIONS: Map<string, Reaction[]> = new Map([
  ['急减速', RE_BRAKE],
  ['急加速', RE_ACCEL],
  ['急转向', RE_TURN],
  ['摇摆', RE_SWAY],
  ['颠簸', RE_BUMP],
]);

/** 事件 → 趣味文案：豁免事件只安抚不提分，路况事件明确"不算你的分" */
export function reactionOf(name: string, level: number, excluded: boolean): Reaction {
  if (excluded) {
    return isRoadCondition(name) ? REACTION_ROAD : REACTION_REASSURE;
  }
  const list: Reaction[] | undefined = REACTIONS.get(name);
  if (list === undefined) {
    return { emoji: '✨', text: '乘客：一切尽在掌握' };
  }
  return list[level >= 7 ? 2 : (level >= 4 ? 1 : 0)];
}

/** 评分说明 */
export interface TipItem {
  key: string;
  title: string;
  content: string;
}

export const TIPS: TipItem[] = [
  {
    key: 'collect',
    title: '检测过程',
    content: '点击开始后有 5 秒准备时间，把手机平放在车内即可。检测过程中只记录驾驶事件，不计算分数；'
      + '结束后根据全程里程、时长与事件整体数据一次性评分。',
  },
  {
    key: 'ev',
    title: '事件密度分（70%）',
    content: '统计急加速、急减速、急转向、摇摆四类事件，按严重程度折算点数后除以行驶里程（公里）归一。'
      + '判定作用在 300 毫秒平滑后的加速度上，并要求连续超阈 300 毫秒以上；'
      + '超阈过程按迟滞退出（回落到门限 80% 以下才算结束），信号在门限线附近抖动不会被切成好几起事件。'
      + '一次变道的"打方向 + 回方向"合并为一次急转向。'
      + '里程越长、事件越稀，得分越高；事件再多，分数也只逼近下限不会归零。'
      + 'GPS 中断时按时长按城市均速折算等效里程，避免把长行程错当短行程。',
  },
  {
    key: 'rms',
    title: '平稳巡航分（15%）',
    content: '计算全程非事件时段的水平加速度均方根（不含垂向），衡量巡航的丝滑程度。'
      + '0.35m/s² 以内视为正常路面质感不扣分，越抖扣分越多。',
  },
  {
    key: 'ctrl',
    title: '强度峰值分（15%）',
    content: '按全程最严重的一次事件扣分。密度只能说明"有多少次"，峰值才说明"有多吓人"——'
      + '一次从高速上的紧急制动，不该因为全程只有这一次而拿满分。',
  },
  {
    key: 'conf',
    title: '样本充分度',
    content: '满 5 公里或 10 分钟视为样本充分。样本不足时分数只按已有数据计算，并在报告中标注"样本不足"，'
      + '不再向任何中性值回拉——旧版本把不足 1 公里的行程一律钉在 75 分，'
      + '导致手机静止平放也是 75，平稳开车也被压到 75，这个钳位已经删除。',
  },
  {
    key: 'exempt',
    title: '上下颠簸不计入评分',
    content: '颠簸（垂向加速度突变）属于路况而非驾驶行为，权重恒为 0，只在报告里作路况统计。'
      + '摇摆另有一道频率判据：车身侧倾是 2Hz 以内的低频，300 毫秒滤波后能量几乎不衰减；'
      + '路面振动在 3Hz 以上，滤波后只剩一两成。平滑前后能量比过低即判为振动，不计入摇摆。'
      + '此外四类计分事件还要各过一道否决：事件窗口内垂向能量占主导（垂向/水平 ≥1.3）判为路面所致，'
      + '低速工况（低于 5km/h 的手持、挪车、怠速）也一律豁免，豁免原因会在事件上标注。',
  },
];
