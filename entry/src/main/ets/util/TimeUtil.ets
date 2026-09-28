export class TimeUtil {
  /**
   * 时长格式化：不足 1 小时输出 mm:ss，达到 1 小时输出 h:mm:ss。
   * 旧实现只有 mm:ss，1 小时以上的行程会显示成 "75:03"。
   */
  static formatDuration(totalSeconds: number): string {
    const secs: number = Math.max(0, Math.floor(totalSeconds));
    const h: number = Math.floor(secs / 3600);
    const m: number = Math.floor((secs % 3600) / 60);
    const s: number = secs % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }

  /** 格式化为 "MM-DD HH:mm:ss" */
  static formatDateTime(ts: number): string {
    const d = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }

  /** 格式化为 "HH:mm" */
  static formatTime(ts: number): string {
    const d = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  /** 格式化为 "YYYY-MM-DD" */
  static formatDate(ts: number): string {
    const d = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }
}
