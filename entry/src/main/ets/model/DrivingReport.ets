import { DrivingEvent } from './DrivingEvent';
import { ScoreBreakdown } from '../service/ScoringEngine';
import { Sensitivity } from './DetectionConfig';

/** 一次完整检测的行程报告 */
export interface DrivingReport {
  /** 记录 id（RDB 主键） */
  id: number;
  /** 事件密度分（遗留字段，兼容旧数据） */
  baseScore: number;
  /** 综合评分 */
  finalScore: number;
  /** 评分构成（新版本必填，旧数据可能缺失） */
  breakdown?: ScoreBreakdown;
  /** 晕车等级标签 */
  level: string;
  /** 等级描述 */
  levelDesc: string;
  /** 趣味标语 */
  slogan: string;
  /** 灵敏度档位（整份报告以 JSON 存入单列，写入值恒为 Sensitivity，无需迁移） */
  sensitivity: Sensitivity;
  /** 时长（秒） */
  durationSec: number;
  /** 距离（米） */
  distanceM: number;
  /** 开始时间戳 */
  startTime: number;
  /** 结束时间戳 */
  endTime: number;
  /** 日期 YYYY-MM-DD */
  date: string;
  /** 事件列表 */
  events: DrivingEvent[];
  /** GPS 轨迹 [lng, lat][] */
  gpsPath: Array<[number, number]>;
}
