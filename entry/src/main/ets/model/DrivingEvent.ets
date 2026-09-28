/** 单次驾驶不良事件 */
export interface DrivingEvent {
  /** 事件名：急减速/急加速/急转向/摇摆/颠簸 */
  name: string;
  /** 等级 1-10 */
  level: number;
  /** 等级名称：微弱/轻微/.../极端 */
  levelName: string;
  /** 本次计分点数（结束时由评分引擎写回，检测中为 0） */
  ded: number;
  /** 事件密度系数（遗留字段，仅旧数据兼容） */
  densityFactor?: number;
  /** 事件发生位置（可选） */
  lng?: number;
  lat?: number;
  /** 事件时刻车速（km/h） */
  speedKmh?: number;
  /** 事件窗口垂向/水平能量比 */
  vertRatio?: number;
  /** 是否豁免（路面颠簸等，不计入评分） */
  excluded: boolean;
  /** 豁免原因 */
  excludeReason?: string;
  /** 事件时间戳 */
  time: number;
}
