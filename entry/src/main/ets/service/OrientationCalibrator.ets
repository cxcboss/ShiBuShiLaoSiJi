import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'OrientationCalibrator';

/** 原始加速度采样（含重力） */
interface RawAccel {
  x: number;
  y: number;
  z: number;
}

/** 车体坐标系加速度分量（m/s²） */
export interface VehicleAccel {
  /** 车体横向（转向输入） */
  lateral: number;
  /** 车体纵向（油门/刹车） */
  longitudinal: number;
  /** 沿重力方向分量（路面颠簸，仅用于路况识别，不参与评分） */
  vertical: number;
  /** 纵向轴是否已由真实加减速学习确定（false 时沿用"平放、y 轴朝前"约定） */
  axisLearned: boolean;
}

/** 方向学习：累计到这么多权重后才采信学到的轴向 */
const AXIS_MIN_WEIGHT: number = 3;
/** 可信加减速下限（m/s²）：低于此值时 GPS 速度导数与水平加速度方向都不可信 */
const AXIS_MIN_A: number = 0.6;
/** 用于方向学习的水平加速度下限（m/s²） */
const AXIS_MIN_HORIZ: number = 0.15;
/** 学习窗上限（s）：GPS 断流太久后的均值无意义 */
const AXIS_MAX_DT: number = 3;

/**
 * 姿态校准与车体坐标对齐。
 *
 * 两件事，缺一不可：
 * 1) 重力方向低通估计。系数必须足够小（α=0.02 @10Hz，时间常数≈5s），
 *    否则 1~2Hz 的车身运动会进入重力估计，让投影轴本身来回摆，
 *    把上下颠簸旋转进水平轴——旧实现 α=0.3（截止≈1.7Hz）正是如此。
 * 2) 把水平向量从"设备水平基"旋到"车体基"。旧实现直接令设备 x=横向、
 *    设备 y=纵向，手机横屏或立放安装时刹车会被读成转向。这里用
 *    GPS 速度导数（沿车体纵向）与同窗口水平加速度均值的方向做相关，
 *    在线学习车体前向轴，安装方式无需用户关心。
 */
export class OrientationCalibrator {
  private static instance: OrientationCalibrator = new OrientationCalibrator();

  /** 归一化重力单位向量（设备坐标系） */
  private gx: number = 0;
  private gy: number = 0;
  private gz: number = 1;
  private seeded: boolean = false;
  private static readonly ALPHA: number = 0.02;
  private static readonly NORM_FLOOR: number = 0.001;

  /** 车体前向在设备水平基下的单位向量，默认"平放、y 轴朝前" */
  private ux: number = 0;
  private uy: number = 1;
  private accX: number = 0;
  private accY: number = 0;
  private weight: number = 0;
  private axisLearned: boolean = false;

  /** 当前学习窗内的水平加速度累加 */
  private winSumX: number = 0;
  private winSumY: number = 0;
  private winN: number = 0;
  private lastSpeedKmh: number = 0;
  private lastSpeedTs: number = 0;

  static getInstance(): OrientationCalibrator {
    return OrientationCalibrator.instance;
  }

  /** 喂入含重力加速度采样（10Hz），内部低通 + 归一化；首帧直接播种以跳过收敛期 */
  update(raw: RawAccel): void {
    if (!this.seeded) {
      const n0: number = Math.sqrt(raw.x * raw.x + raw.y * raw.y + raw.z * raw.z);
      if (n0 < OrientationCalibrator.NORM_FLOOR) {
        return;
      }
      this.gx = raw.x / n0;
      this.gy = raw.y / n0;
      this.gz = raw.z / n0;
      this.seeded = true;
      return;
    }
    const a: number = OrientationCalibrator.ALPHA;
    const gx: number = this.gx + a * (raw.x - this.gx);
    const gy: number = this.gy + a * (raw.y - this.gy);
    const gz: number = this.gz + a * (raw.z - this.gz);
    const norm: number = Math.sqrt(gx * gx + gy * gy + gz * gz);
    if (norm < OrientationCalibrator.NORM_FLOOR) {
      return;
    }
    this.gx = gx / norm;
    this.gy = gy / norm;
    this.gz = gz / norm;
  }

  reset(): void {
    this.gx = 0;
    this.gy = 0;
    this.gz = 1;
    this.seeded = false;
    this.ux = 0;
    this.uy = 1;
    this.accX = 0;
    this.accY = 0;
    this.weight = 0;
    this.axisLearned = false;
    this.winSumX = 0;
    this.winSumY = 0;
    this.winN = 0;
    this.lastSpeedTs = 0;
    this.lastSpeedKmh = 0;
  }

  /** 当前是否接近平放（用于 UI 提示） */
  isFlat(): boolean {
    return Math.abs(this.gx) < 0.25 && Math.abs(this.gy) < 0.25;
  }

  /** 方向学习置信度 0~1，仅用于日志与标定分析 */
  axisConfidence(): number {
    if (this.weight <= 0) {
      return 0;
    }
    return Math.min(1, Math.sqrt(this.accX * this.accX + this.accY * this.accY) / this.weight);
  }

  /**
   * 把设备线性加速度旋到车体坐标系。
   * 先去掉重力方向分量得到水平面内的二维向量，再用学习到的前向轴分解。
   */
  horizontalize(ax: number, ay: number, az: number): VehicleAccel {
    const dot: number = ax * this.gx + ay * this.gy + az * this.gz;
    const hx: number = ax - dot * this.gx;
    const hy: number = ay - dot * this.gy;
    this.winSumX += hx;
    this.winSumY += hy;
    this.winN++;
    return {
      longitudinal: hx * this.ux + hy * this.uy,
      lateral: hy * this.ux - hx * this.uy,
      vertical: dot,
      axisLearned: this.axisLearned,
    };
  }

  /**
   * 喂入 GPS 车速（km/h）。每次回调代表一个学习窗结束：
   * 用该窗的速度导数定符号、该窗水平加速度均值定方向，加权累加。
   */
  onSpeed(speedKmh: number, ts: number): void {
    if (this.lastSpeedTs === 0) {
      this.lastSpeedTs = ts;
      this.lastSpeedKmh = speedKmh;
      return;
    }
    const dt: number = (ts - this.lastSpeedTs) / 1000;
    if (dt < 0.3) {
      return;
    }
    const along: number = (speedKmh - this.lastSpeedKmh) / 3.6 / dt;
    this.lastSpeedTs = ts;
    this.lastSpeedKmh = speedKmh;
    if (dt > AXIS_MAX_DT || this.winN === 0) {
      this.winSumX = 0;
      this.winSumY = 0;
      this.winN = 0;
      return;
    }
    const mx: number = this.winSumX / this.winN;
    const my: number = this.winSumY / this.winN;
    this.winSumX = 0;
    this.winSumY = 0;
    this.winN = 0;

    const aAbs: number = Math.abs(along);
    const mAbs: number = Math.sqrt(mx * mx + my * my);
    if (aAbs < AXIS_MIN_A || mAbs < AXIS_MIN_HORIZ) {
      return;
    }
    // 加速时水平加速度指向车体前方，减速时指向后方
    const sign: number = along > 0 ? 1 : -1;
    this.accX += sign * (mx / mAbs) * aAbs;
    this.accY += sign * (my / mAbs) * aAbs;
    this.weight += aAbs;
    if (this.weight < AXIS_MIN_WEIGHT) {
      return;
    }
    const n: number = Math.sqrt(this.accX * this.accX + this.accY * this.accY);
    if (n < OrientationCalibrator.NORM_FLOOR) {
      return;
    }
    const nx: number = this.accX / n;
    const ny: number = this.accY / n;
    // 与当前轴接近同向或反向都视为稳定，反向则翻转而不放弃学习
    const align: number = Math.abs(nx * this.ux + ny * this.uy);
    this.ux = nx;
    this.uy = ny;
    if (align > 0.9) {
      this.axisLearned = true;
    }
    hilog.info(DOMAIN, TAG, 'axis update u=(%{public}s,%{public}s) align=%{public}s conf=%{public}s',
      nx.toFixed(2), ny.toFixed(2), align.toFixed(2), this.axisConfidence().toFixed(2));
  }
}
