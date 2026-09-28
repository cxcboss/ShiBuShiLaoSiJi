import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalContext } from '../util/GlobalContext';
import { Vec3 } from './SensorManager';

const DOMAIN: number = 0x0000;
const TAG: string = 'CalibrationRecorder';

const DIR_NAME: string = 'calibration';
/** 攒够这么多行再落一次盘：20Hz 采样下约 6 秒，避免在传感器回调里做 IO */
const FLUSH_LINES: number = 120;
/** 只保留最近 N 次行程的原始数据，够标定用又不涨盘 */
const MAX_SESSIONS: number = 12;
/** 待写队列上限：句柄迟迟未就绪时防止无界增长 */
const BUF_CAP: number = 2000;

/**
 * 标定数据记录器：把一次检测过程中的原始传感器样本、定位点与产生的事件
 * 以 JSONL 落到应用沙箱 files/calibration/。
 *
 * 评分阈值必须用真实开车数据标定，而真机既无法注入传感器数据也没有离线回放入口，
 * 所以这条链路是所有阈值调整的前提。拉取方式（已验证 shell 可读该沙箱目录）：
 *   hdc file recv /data/app/el2/100/base/<bundle>/haps/entry/files/calibration/ ./
 *
 * 记录失败绝不影响检测主流程：所有 IO 均在 try/catch 内，异常只打日志。
 */
export class CalibrationRecorder {
  private static instance: CalibrationRecorder = new CalibrationRecorder();

  private recording: boolean = false;
  private file: fs.File | undefined = undefined;
  /** 文件句柄尚未就绪时先攒着，就绪后一次性补写 */
  private buf: string[] = [];
  private sessionId: number = 0;
  /** 串行化写入，避免两次 flush 并发写同一 fd */
  private writing: boolean = false;
  /** 收到 stop 时仍有写在途，写完成后再关句柄 */
  private pendingClose: boolean = false;
  private dirPath: string = '';

  static getInstance(): CalibrationRecorder {
    return CalibrationRecorder.instance;
  }

  /** 原始线性加速度（去重力），事件检测的主数据源 */
  linear(v: Vec3): void {
    this.line(`{"t":"a","ts":${v.ts},"x":${v.x},"y":${v.y},"z":${v.z}}`);
  }

  /** 含重力加速度，姿态估计输入 */
  gravity(v: Vec3): void {
    this.line(`{"t":"g","ts":${v.ts},"x":${v.x},"y":${v.y},"z":${v.z}}`);
  }

  /** 角速度 */
  gyro(v: Vec3): void {
    this.line(`{"t":"w","ts":${v.ts},"x":${v.x},"y":${v.y},"z":${v.z}}`);
  }

  /** 定位点：速度 km/h，dir 为系统上报方向角，acc 为精度半径 */
  gps(ts: number, lat: number, lng: number, speedKmh: number, direction: number, accuracy: number): void {
    this.line(`{"t":"p","ts":${ts},"lat":${lat},"lng":${lng},"spd":${speedKmh},"dir":${direction},"acc":${accuracy}}`);
  }

  /** 投影后的车体轴加速度，用于离线对比新旧测量层 */
  projected(ts: number, lateral: number, longitudinal: number, vertical: number): void {
    this.line(`{"t":"v","ts":${ts},"la":${lateral},"lo":${longitudinal},"ve":${vertical}}`);
  }

  /** 事件（含豁免标记与垂向能量比） */
  event(ts: number, name: string, level: number, excluded: boolean, speedKmh: number, vertRatio: number): void {
    this.line(`{"t":"e","ts":${ts},"n":"${name}","lv":${level},"ex":${excluded ? 1 : 0},"s":${speedKmh},"vr":${vertRatio}}`);
  }

  /** 开始记录。打开文件失败时静默降级为不记录。 */
  start(sensitivity: string): void {
    if (this.recording) {
      return;
    }
    this.recording = true;
    this.sessionId = Date.now();
    this.buf = [];
    this.file = undefined;
    this.prepare().then((): void => {
      this.line(`{"t":"meta","sid":${this.sessionId},"sens":"${sensitivity}","model":"${this.modelTag()}"}`);
    });
  }

  /** 结束记录，写汇总行并关闭句柄 */
  stop(durationSec: number, distanceM: number, score: number): void {
    if (!this.recording) {
      return;
    }
    // 直接入队而不是走 line()：line() 以 recording 为开关，此时已置 false 会把汇总行丢掉
    this.buf.push(`{"t":"end","dur":${durationSec},"dist":${Math.round(distanceM)},"score":${score}}`);
    this.recording = false;
    this.close();
  }

  /** 记录器自身的常量快照，离线重算时用来对齐版本 */
  private modelTag(): string {
    return 'rec1';
  }

  private line(s: string): void {
    if (!this.recording) {
      return;
    }
    this.buf.push(s);
    if (this.buf.length > BUF_CAP) {
      // fd 迟迟未就绪（IO 卡顿）：丢最旧的，保证内存不无限增长
      this.buf = this.buf.slice(-BUF_CAP / 2);
      return;
    }
    if (this.buf.length >= FLUSH_LINES) {
      this.pump();
    }
  }

  private async prepare(): Promise<void> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      this.dirPath = `${ctx.filesDir}/${DIR_NAME}`;
      if (!await fs.access(this.dirPath)) {
        await fs.mkdir(this.dirPath, true);
      }
      const path: string = `${this.dirPath}/s${this.sessionId}.jsonl`;
      this.file = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      this.purge();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'prepare failed: %{public}s', JSON.stringify(e));
      this.recording = false;
      this.buf = [];
    }
  }

  /** 把缓冲区写盘；fd 未就绪时保留内容等下一次调用 */
  private pump(): void {
    if (this.writing || this.buf.length === 0) {
      return;
    }
    const f: fs.File | undefined = this.file;
    if (f === undefined) {
      return;
    }
    const payload: string = this.buf.join('\n') + '\n';
    this.buf = [];
    this.writing = true;
    fs.write(f.fd, payload)
      .then((): void => {
        this.writing = false;
        if (this.buf.length > 0 && this.file !== undefined) {
          this.pump();
          return;
        }
        if (this.pendingClose) {
          this.pendingClose = false;
          this.closeHandle();
        }
      })
      .catch((e: Error): void => {
        this.writing = false;
        hilog.warn(DOMAIN, TAG, 'write failed: %{public}s', JSON.stringify(e));
        // 磁盘/句柄出错就放弃记录，不能反复重试拖慢传感器回调
        this.recording = false;
        this.pendingClose = false;
        this.buf = [];
        this.closeHandle();
      });
  }

  /**
   * 收尾：句柄不能在写请求在途时关闭，否则最后一段数据会写到已关闭的 fd。
   * 有写在进行中就置 pendingClose，由该次写入的 then 回调负责真正关闭。
   */
  private close(): void {
    if (this.file === undefined) {
      this.buf = [];
      this.pendingClose = false;
      return;
    }
    this.pendingClose = true;
    this.pump();
    if (!this.writing) {
      this.pendingClose = false;
      this.closeHandle();
    }
  }

  private closeHandle(): void {
    const f: fs.File | undefined = this.file;
    this.file = undefined;
    if (f === undefined) {
      return;
    }
    fs.close(f).catch((e: Error): void => {
      hilog.warn(DOMAIN, TAG, 'close failed: %{public}s', JSON.stringify(e));
    });
  }

  /** 只保留最近 MAX_SESSIONS 个会话文件 */
  private async purge(): Promise<void> {
    try {
      const names: string[] = await fs.listFile(this.dirPath);
      const files: string[] = names.filter((n: string): boolean => n.startsWith('s') && n.endsWith('.jsonl'));
      if (files.length <= MAX_SESSIONS) {
        return;
      }
      files.sort();
      const doomed: string[] = files.slice(0, files.length - MAX_SESSIONS);
      for (const n of doomed) {
        try {
          await fs.unlink(`${this.dirPath}/${n}`);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'purge %{public}s failed: %{public}s', n, JSON.stringify(e));
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'purge failed: %{public}s', JSON.stringify(e));
    }
  }
}
