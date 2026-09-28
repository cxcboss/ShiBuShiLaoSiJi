import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'VibrationHelper';

/**
 * 事件振动反馈：检测到严重不良驾驶事件时短促震动提醒。
 */
export class VibrationHelper {
  private static instance: VibrationHelper = new VibrationHelper();
  /**
   * 严重事件的最小振动间隔（ms）。连续严重事件只提醒一次，
   * 避免长时间震动干扰驾驶。
   */
  private static readonly MIN_INTERVAL_MS: number = 60000;
  /** 告警语义的预设触感（不良驾驶事件不应使用 success 触感） */
  private static readonly EFFECT_ID: string = 'haptic.notice.warning';
  /** 设备不支持预设触感时的降级时长（ms） */
  private static readonly FALLBACK_DURATION_MS: number = 40;

  private lastTs: number = 0;
  /** 预设触感支持情况，首次探测后缓存（undefined = 尚未探测） */
  private effectSupported: boolean | undefined = undefined;

  static getInstance(): VibrationHelper {
    return VibrationHelper.instance;
  }

  /**
   * 预设触感并非所有设备都支持：OpenHarmony 侧 EffectId 仅保证 haptic.clock.timer，
   * 其余依赖设备实现。必须先探测，否则 startVibration 直接 reject，
   * 振动反馈在大量机型上静默失效。
   */
  private isEffectSupported(): boolean {
    if (this.effectSupported === undefined) {
      try {
        this.effectSupported = vibrator.isSupportEffectSync(VibrationHelper.EFFECT_ID);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'isSupportEffectSync failed: %{public}s', JSON.stringify(e));
        this.effectSupported = false;
      }
      hilog.info(DOMAIN, TAG, 'effect %{public}s supported=%{public}s',
        VibrationHelper.EFFECT_ID, `${this.effectSupported}`);
    }
    return this.effectSupported;
  }

  vibrate(): void {
    const now: number = Date.now();
    if (now - this.lastTs < VibrationHelper.MIN_INTERVAL_MS) {
      return;
    }
    this.lastTs = now;
    const effect: vibrator.VibrateEffect = this.isEffectSupported()
      ? { type: 'preset', effectId: VibrationHelper.EFFECT_ID, count: 1 }
      : { type: 'time', duration: VibrationHelper.FALLBACK_DURATION_MS };
    try {
      vibrator.startVibration(effect, { usage: 'notification' })
        .catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'startVibration rejected: code=%{public}d msg=%{public}s',
            e.code, e.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'vibrate failed: %{public}s', JSON.stringify(e));
    }
  }
}
