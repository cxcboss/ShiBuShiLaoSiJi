import { geoLocationManager } from '@kit.LocationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GeoUtil } from '../util/GeoUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'LocationTracker';

/** GPS 定位点 */
export interface GpsPoint {
  lat: number;
  lng: number;
  ts: number;
  /** 速度 km/h（系统上报或位移推算） */
  speedKmh: number;
  /** 系统上报方向角（度，相对正北），不可用时为 undefined */
  direction?: number;
  /** 定位精度半径（米），不可用时为 undefined */
  accuracy?: number;
}

/** 轨迹抽稀最小距离（米） */
const MIN_SPACING_M: number = 10;
/** 单点累加的最小距离过滤（低于此值视为定位抖动） */
const MIN_ADD_M: number = 1;
/** 轨迹点数上限：10m 抽稀下约 20km 即触顶，超量会拖大报告体积并拖慢轨迹绘制 */
const MAX_PATH_POINTS: number = 2000;
/** 速度异常值上限（km/h），超过视为无效上报 */
const MAX_SPEED_KMH: number = 300;

/**
 * 定位追踪：连续定位，累加行驶距离（Haversine），维护 GPS 轨迹与当前车速。
 * 车速优先使用系统上报的 location.speed（m/s），无有效值时由位移/时间推算。
 */
export class LocationTracker {
  private static instance: LocationTracker = new LocationTracker();
  private running: boolean = false;
  private last: GpsPoint | undefined = undefined;
  private lastRecorded: GpsPoint | undefined = undefined;
  private distanceM: number = 0;
  private path: GpsPoint[] = [];
  private speedKmh: number = 0;
  private onUpdateCb: ((pt: GpsPoint) => void) | undefined = undefined;
  private callback: (location: geoLocationManager.Location) => void = () => {
  };

  static getInstance(): LocationTracker {
    return LocationTracker.instance;
  }

  setOnUpdate(cb: (pt: GpsPoint) => void): void {
    this.onUpdateCb = cb;
  }

  getDistance(): number {
    return this.distanceM;
  }

  getPath(): GpsPoint[] {
    return this.path;
  }

  /** 当前车速（km/h） */
  getSpeed(): number {
    return this.speedKmh;
  }

  /** 最近一次事件可用坐标 */
  getLast(): GpsPoint | undefined {
    return this.last;
  }

  /** 开始连续定位；订阅失败（权限缺失/定位服务未开）返回 false */
  start(): boolean {
    if (this.running) {
      return true;
    }
    this.running = true;
    this.distanceM = 0;
    this.path = [];
    this.last = undefined;
    this.lastRecorded = undefined;
    this.speedKmh = 0;

    this.callback = (location: geoLocationManager.Location): void => {
      const lat: number = location.latitude;
      const lng: number = location.longitude;
      if (lat === 0 && lng === 0) {
        return;
      }
      const pt: GpsPoint = { lat, lng, ts: Date.now(), speedKmh: 0 };
      pt.speedKmh = this.resolveSpeed(location, pt);
      // 方向角与精度半径只有系统上报才有，推算速度路径下为 undefined；
      // 记录到标定文件里用于离线核对"车体前向轴 vs 真实航向"
      pt.direction = Number.isFinite(Number(location.direction)) ? Number(location.direction) : undefined;
      pt.accuracy = Number.isFinite(Number(location.accuracy)) ? Number(location.accuracy) : undefined;
      this.speedKmh = pt.speedKmh;
      this.pushPoint(pt);
    };

    try {
      const request: geoLocationManager.ContinuousLocationRequest = {
        interval: 1,
        locationScenario: geoLocationManager.UserActivityScenario.NAVIGATION,
      };
      geoLocationManager.on('locationChange', request, this.callback);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'start location failed: %{public}s', JSON.stringify(e));
      this.running = false;
      return false;
    }
  }

  /** 速度解析：系统上报优先，无效时位移/Δt 推算 */
  private resolveSpeed(loc: geoLocationManager.Location, pt: GpsPoint): number {
    const sysSpeedMs: number = Number(loc.speed);
    // 上报的 0 m/s 是合法值（等红灯/停车/挪车），不能当作"无效"回落到陈旧速度，
    // 否则 DetectionEngine 的低速工况豁免（<5km/h）永不触发，
    // 怠速与手持抖动会被记成真实驾驶事件。仅 NaN/负值/超上限视为无效上报。
    if (Number.isFinite(sysSpeedMs) && sysSpeedMs >= 0 && sysSpeedMs * 3.6 < MAX_SPEED_KMH) {
      return Math.round(sysSpeedMs * 3.6 * 10) / 10;
    }
    if (this.last !== undefined) {
      const dt: number = (pt.ts - this.last.ts) / 1000;
      const d: number = GeoUtil.distanceM(this.last.lat, this.last.lng, pt.lat, pt.lng);
      if (dt > 0 && dt < 30 && d >= 0.5) {
        const v: number = (d / dt) * 3.6;
        if (v < MAX_SPEED_KMH) {
          return Math.round(v * 10) / 10;
        }
      }
    }
    return this.speedKmh;
  }

  /**
   * 点数触顶时对半抽稀，规模压回一半（此后每累积 1000 点才再触发一次，开销可摊薄）。
   * 始终保留末点，否则轨迹末端会滞后于当前位置。
   */
  private decimatePath(): void {
    const last: GpsPoint = this.path[this.path.length - 1];
    const kept: GpsPoint[] = [];
    for (let i = 0; i < this.path.length - 1; i += 2) {
      kept.push(this.path[i]);
    }
    kept.push(last);
    this.path = kept;
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    try {
      geoLocationManager.off('locationChange', this.callback);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stop location failed: %{public}s', JSON.stringify(e));
    }
  }

  private pushPoint(pt: GpsPoint): void {
    if (this.last !== undefined) {
      const d: number = GeoUtil.distanceM(this.last.lat, this.last.lng, pt.lat, pt.lng);
      if (d > MIN_ADD_M) {
        // 位移可采信上限 = 两次定位车速的较大者 × 时间差。
        // 旧实现用 300km/h 兜底，等于给 GPS 漂移开了绿灯：真机实测手机平放桌面 81s，
        // 期间上报车速 0~1.8km/h、漂移位移最大 95m，里程被累加成 271m，
        // 界面上就成了"静止 5 秒已同行 0.1 公里"。
        // 按车速钳位后同一段只记到 5m；行驶中失锁重定位的 100~500m 跳变
        // 因为上报车速本身就是真实速度，仍然全额计入。
        const dtSec: number = (pt.ts - this.last.ts) / 1000;
        const vKmh: number = Math.max(this.last.speedKmh, pt.speedKmh);
        const plausible: number = dtSec > 0 ? (vKmh / 3.6) * dtSec : 0;
        this.distanceM += Math.min(d, plausible);
      }
    }
    this.last = pt;
    // 抽稀：与上一个记录点距离 ≥10m 才入轨迹
    if (this.lastRecorded === undefined ||
      GeoUtil.distanceM(this.lastRecorded.lat, this.lastRecorded.lng, pt.lat, pt.lng) >= MIN_SPACING_M) {
      this.path.push(pt);
      this.lastRecorded = pt;
      if (this.path.length > MAX_PATH_POINTS) {
        this.decimatePath();
      }
    }
    if (this.onUpdateCb !== undefined) {
      this.onUpdateCb(pt);
    }
  }
}
