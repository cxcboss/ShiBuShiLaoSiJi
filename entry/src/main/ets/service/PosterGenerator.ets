import { DrivingReport } from '../model/DrivingReport';
import { sensitivityLabel } from '../model/DetectionConfig';
import { TimeUtil } from '../util/TimeUtil';

export interface PosterData {
  score: number;
  levelName: string;
  levelDesc: string;
  slogan: string;
  date: string;
  duration: string;
  distanceKm: string;
  eventSummary: string;
  sensitivityName: string;
  minorCount: number;
  severeCount: number;
  exemptCount: number;
  breakdownText: string;
}

export const POSTER_W: number = 360;
export const POSTER_H: number = 300;
/** "严重"事件的最小等级，与 ReportSheet.eventColor 的红色阈值保持一致（旧值 3 对应"轻度"，名不副实） */
const SEVERE_LEVEL: number = 7;

/** 多邻国风格调色板 */
const DUO_GREEN: string = '#58CC02';
const DUO_GREEN_D: string = '#58A700';
const DUO_BLUE: string = '#1CB0F6';
const DUO_BLUE_D: string = '#1899D6';
const DUO_ORANGE: string = '#FF9600';
const DUO_ORANGE_D: string = '#EC8B00';
const DUO_PURPLE: string = '#CE82FF';
const DUO_PURPLE_D: string = '#A568CC';
const DUO_RED: string = '#FF4B4B';
const DUO_RED_D: string = '#EA2B2B';

export class PosterGenerator {
  private static instance: PosterGenerator = new PosterGenerator();

  static getInstance(): PosterGenerator {
    return PosterGenerator.instance;
  }

  build(report: DrivingReport): PosterData {
    const events = report.events ?? [];
    let minorCount: number = 0;
    let severeCount: number = 0;
    let exemptCount: number = 0;
    for (const e of events) {
      if (e.excluded) {
        exemptCount++;
      } else if (e.level >= SEVERE_LEVEL) {
        severeCount++;
      } else {
        minorCount++;
      }
    }
    const distKm: number = (report.distanceM ?? 0) / 1000;
    let breakdownText: string = '';
    if (report.breakdown !== undefined) {
      breakdownText = `事件密度 ${report.breakdown.evScore} · 平稳巡航 ${report.breakdown.rmsScore} · 强度峰值 ${report.breakdown.ctrlScore}`;
    }
    return {
      score: report.finalScore,
      levelName: report.level,
      levelDesc: report.levelDesc,
      slogan: report.slogan,
      date: report.date,
      duration: this.formatDuration(report.durationSec),
      distanceKm: distKm >= 0.1 ? distKm.toFixed(1) : '<0.1',
      eventSummary: events.length.toString(),
      sensitivityName: sensitivityLabel(report.sensitivity),
      minorCount: minorCount,
      severeCount: severeCount,
      exemptCount: exemptCount,
      breakdownText: breakdownText,
    };
  }

  textOf(data: PosterData): string {
    return `我在「老司机」驾驶舒适度检测中得分 ${data.score} 分` +
      `（${data.levelName}·${data.levelDesc}），${data.slogan}` +
      `｜时长 ${data.duration}，里程约 ${data.distanceKm} km，` +
      `共 ${data.eventSummary} 次事件（轻微 ${data.minorCount} 次、严重 ${data.severeCount} 次` +
      (data.exemptCount > 0 ? `、自动豁免 ${data.exemptCount} 次` : '') + '）。';
  }

  /**
   * 多邻国风格 6:5 海报（POSTER_W x POSTER_H）：白底 + 3D 立体彩色卡片（亮色+深色投影）+ 统一大圆角。
   * 视觉层级：评分卡 > 数据卡 > 评语 > 副标。
   */
  draw(ctx: CanvasRenderingContext2D, data: PosterData, w: number, h: number): void {
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(0, 0, w, h);

    const accent: string = this.scoreMain(data.score);
    const accentD: string = this.scoreDark(data.score);
    const cardX: number = 28;
    const cardW: number = w - 56;

    // ── 顶部品牌行 ──
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
    ctx.fillStyle = DUO_GREEN;
    ctx.font = 'bold 18px sans-serif';
    ctx.fillText('老司机', cardX, 26);
    ctx.fillStyle = '#999999';
    ctx.font = '11px sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(data.date, w - cardX, 26);

    // ── 大评分 3D 卡片 ──
    const cy: number = 44;
    const ch: number = 88;
    this.duoCard(ctx, cardX, cy + 6, cardW, ch, accentD, 20);
    this.duoCard(ctx, cardX, cy, cardW, ch, accent, 20);

    // 大评分数字（左）
    ctx.textAlign = 'left';
    ctx.fillStyle = '#FFFFFF';
    ctx.font = 'bold 58px sans-serif';
    ctx.fillText(`${data.score}`, cardX + 30, cy + 70);

    // 等级徽章（右上，深色底白字）——宽度按文本实测；
    // 此前写死 44px，"非常严重"这类 4 字等级会溢出徽章
    const badge: string = data.levelName;
    ctx.textAlign = 'center';
    ctx.fillStyle = '#FFFFFF';
    ctx.font = 'bold 16px sans-serif';
    const badgeW: number = Math.max(44, Math.ceil(ctx.measureText(badge).width) + 20);
    const badgeH: number = 30;
    const badgeX: number = cardX + cardW - 24 - badgeW;
    const badgeY: number = cy + 28;
    this.duoCard(ctx, badgeX, badgeY, badgeW, badgeH, accentD, 15);
    ctx.fillText(badge, badgeX + badgeW / 2, badgeY + 22);

    // 卡片底部副标
    ctx.textAlign = 'left';
    ctx.fillStyle = 'rgba(255,255,255,0.92)';
    ctx.font = '11px sans-serif';
    ctx.fillText('驾驶舒适度得分', cardX + 30, cy + 80);

    // ── 评语 3D 卡片（橙色） ──
    const ty: number = 146;
    const th: number = 36;
    this.duoCard(ctx, cardX, ty + 5, cardW, th, DUO_ORANGE_D, 18);
    this.duoCard(ctx, cardX, ty, cardW, th, DUO_ORANGE, 18);
    ctx.textAlign = 'center';
    ctx.fillStyle = '#FFFFFF';
    ctx.font = 'bold 13px sans-serif';
    const slogan: string = this.truncate(ctx, `「${data.slogan}」`, cardW - 40);
    ctx.fillText(slogan, w / 2, ty + 24);

    // ── 数据 4 卡（统一圆角 14） ──
    const gy: number = 196;
    const gh: number = 46;
    const gap: number = 10;
    const cellW: number = (cardW - gap * 3) / 4;
    const cells: Array<[string, string, string, string]> = [
      [`${data.distanceKm}`, 'km 里程', DUO_BLUE, DUO_BLUE_D],
      [data.duration, '时长', DUO_ORANGE, DUO_ORANGE_D],
      [data.eventSummary, '事件', DUO_PURPLE, DUO_PURPLE_D],
      [data.sensitivityName, '灵敏度', DUO_RED, DUO_RED_D],
    ];
    for (let i = 0; i < cells.length; i++) {
      const x: number = cardX + i * (cellW + gap);
      this.duoCard(ctx, x, gy + 5, cellW, gh, cells[i][3], 14);
      this.duoCard(ctx, x, gy, cellW, gh, cells[i][2], 14);
      ctx.textAlign = 'center';
      ctx.fillStyle = '#FFFFFF';
      ctx.font = 'bold 20px sans-serif';
      ctx.fillText(cells[i][0], x + cellW / 2, gy + 24);
      ctx.font = '10px sans-serif';
      ctx.fillStyle = 'rgba(255,255,255,0.95)';
      ctx.fillText(cells[i][1], x + cellW / 2, gy + 40);
    }

    // ── 事件统计与等级描述行 ──
    ctx.fillStyle = accent;
    ctx.font = 'bold 13px sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText(`${data.levelDesc} · 轻微 ${data.minorCount} 次 / 严重 ${data.severeCount} 次` +
      (data.exemptCount > 0 ? ` / 豁免 ${data.exemptCount} 次` : ''), w / 2, gy + gh + 24);

    // ── 评分构成行 ──
    if (data.breakdownText !== '') {
      ctx.fillStyle = '#666666';
      ctx.font = '10px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText(this.truncate(ctx, data.breakdownText, w - 60), w / 2, gy + gh + 40);
    }

    // ── 底部 ──
    ctx.fillStyle = '#999999';
    ctx.font = '11px sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('纯鸿蒙原生实现 · 一起开得稳稳的', w / 2, h - 10);
  }

  /** 多邻国式 3D 圆角卡片：亮色主体，底部深色投影 */
  private duoCard(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, color: string, r: number): void {
    ctx.fillStyle = color;
    this.roundRectPath(ctx, x, y, w, h, r);
    ctx.fill();
  }

  private roundRectPath(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  private truncate(ctx: CanvasRenderingContext2D, text: string, maxW: number): string {
    if (ctx.measureText(text).width <= maxW) {
      return text;
    }
    let cur: string = text;
    while (cur.length > 4 && ctx.measureText(cur).width > maxW) {
      cur = cur.substring(0, cur.length - 2);
    }
    return cur + '…';
  }

  private scoreMain(score: number): string {
    if (score >= 95) return DUO_GREEN;
    if (score >= 88) return DUO_BLUE;
    if (score >= 70) return DUO_ORANGE;
    return DUO_RED;
  }

  private scoreDark(score: number): string {
    if (score >= 95) return DUO_GREEN_D;
    if (score >= 88) return DUO_BLUE_D;
    if (score >= 70) return DUO_ORANGE_D;
    return DUO_RED_D;
  }

  private formatDuration(sec: number): string {
    return TimeUtil.formatDuration(sec);
  }
}
