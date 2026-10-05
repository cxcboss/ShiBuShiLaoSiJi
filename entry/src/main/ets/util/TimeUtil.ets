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

  /**
   * 时长的中文表述：不足 1 分钟给"45秒"，不足 1 小时给"37分16秒"，
   * 达到 1 小时给"1小时37分"。"37:16" 这种 mm:ss 在列表里会被读成时刻。
   */
  static formatDurationCn(totalSeconds: number): string {
    const secs: number = Math.max(0, Math.floor(totalSeconds));
    const h: number = Math.floor(secs / 3600);
    const m: number = Math.floor((secs % 3600) / 60);
    const s: number = secs % 60;
    if (h > 0) {
      return m > 0 ? `${h}小时${m}分` : `${h}小时`;
    }
    if (m > 0) {
      return s > 0 ? `${m}分${s}秒` : `${m}分`;
    }
    return `${s}秒`;
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

  /**
   * 历史列表的时间标签：当天的行程只给时刻，今年的给"月日 + 时刻"，跨年才带年份。
   * 每行都重复完整日期是噪声——扫列表时最先要回答的是"这是什么时候跑的"。
   */
  static formatHistoryTime(ts: number): string {
    const d: Date = new Date(ts);
    const now: Date = new Date();
    const time: string = TimeUtil.formatTime(ts);
    if (d.getFullYear() === now.getFullYear() &&
      d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return time;
    }
    if (d.getFullYear() === now.getFullYear()) {
      return `${d.getMonth() + 1}月${d.getDate()}日 ${time}`;
    }
    return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${time}`;
  }
}
