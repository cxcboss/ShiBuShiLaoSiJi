import { sensor } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'SensorManager';

/** 三维加速度采样 */
export interface Vec3 {
  x: number;
  y: number;
  z: number;
  ts: number;
}

/**
 * 传感器管理：封装 SensorServiceKit 订阅/退订，统一错误处理。
 * - LINEAR_ACCELEROMETER：去重力线性加速度（事件检测主数据源）
 * - ACCELEROMETER：含重力加速度（姿态/水平补偿）
 * - GYROSCOPE：角速度（辅助）
 */
export class SensorManager {
  private static instance: SensorManager = new SensorManager();
  private linearOn: boolean = false;
  private accelOn: boolean = false;

  static getInstance(): SensorManager {
    return SensorManager.instance;
  }

  /** 线性加速度（去重力），50ms 采样 */
  startLinear(cb: (v: Vec3) => void): void {
    if (this.linearOn) {
      return;
    }
    try {
      sensor.on(sensor.SensorId.LINEAR_ACCELEROMETER, (d: sensor.LinearAccelerometerResponse) => {
        cb({ x: d.x, y: d.y, z: d.z, ts: Date.now() });
      }, { interval: 50000000 });
      this.linearOn = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startLinear failed: %{public}s', JSON.stringify(e));
    }
  }

  stopLinear(): void {
    if (!this.linearOn) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.LINEAR_ACCELEROMETER);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stopLinear failed: %{public}s', JSON.stringify(e));
    }
    this.linearOn = false;
  }

  /** 含重力加速度，100ms 采样（用于姿态校准） */
  startAccel(cb: (v: Vec3) => void): void {
    if (this.accelOn) {
      return;
    }
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (d: sensor.AccelerometerResponse) => {
        cb({ x: d.x, y: d.y, z: d.z, ts: Date.now() });
      }, { interval: 100000000 });
      this.accelOn = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startAccel failed: %{public}s', JSON.stringify(e));
    }
  }

  stopAccel(): void {
    if (!this.accelOn) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stopAccel failed: %{public}s', JSON.stringify(e));
    }
    this.accelOn = false;
  }

  // 陀螺仪订阅已移除：从未启用，且 GYROSCOPE 权限已随权限清理一并删除（上架要求权限与功能对应）。

  stopAll(): void {
    this.stopLinear();
    this.stopAccel();
  }
}
