import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalContext } from '../util/GlobalContext';
import { Sensitivity } from '../model/DetectionConfig';

const STORE_NAME: string = 'settings';
const KEY_SENSITIVITY: string = 'sensitivity';
const KEY_THEME: string = 'theme';
const DOMAIN: number = 0x0000;
const TAG: string = 'SettingsRepository';

export type ThemeMode = 'auto' | 'dark' | 'light';

export function colorModeOf(t: ThemeMode): ConfigurationConstant.ColorMode {
  if (t === 'dark') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  if (t === 'light') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

/**
 * 用户设置持久化（preferences 键值对）。
 */
export class SettingsRepository {
  private static instance: SettingsRepository = new SettingsRepository();
  private store: preferences.Preferences | undefined = undefined;
  /** 缓存 init 的 Promise，避免并发调用重复创建 Preferences 实例 */
  private initPromise: Promise<void> | undefined = undefined;

  static getInstance(): SettingsRepository {
    return SettingsRepository.instance;
  }

  async init(): Promise<void> {
    if (this.store !== undefined) {
      return;
    }
    if (this.initPromise === undefined) {
      this.initPromise = this.doInit();
    }
    return this.initPromise;
  }

  private async doInit(): Promise<void> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
    } catch (e) {
      // 失败后清空，允许下次调用重试
      this.initPromise = undefined;
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(e));
    }
  }

  async getSensitivity(): Promise<Sensitivity> {
    const v = await this.get(KEY_SENSITIVITY, 'moderate');
    if (v === 'mild' || v === 'severe' || v === 'moderate') {
      return v;
    }
    return 'moderate';
  }

  async setSensitivity(s: Sensitivity): Promise<void> {
    await this.put(KEY_SENSITIVITY, s);
  }

  async getTheme(): Promise<ThemeMode> {
    const v = await this.get(KEY_THEME, 'auto');
    if (v === 'dark' || v === 'light' || v === 'auto') {
      return v;
    }
    return 'auto';
  }

  async setTheme(t: ThemeMode): Promise<void> {
    await this.put(KEY_THEME, t);
  }

  /**
   * 应用主题到全局色彩模式。persist 为 true 时同时落盘。
   * 启动恢复与用户切换共用此入口，保证两处行为一致。
   */
  async applyTheme(context: common.UIAbilityContext, t: ThemeMode, persist: boolean): Promise<void> {
    if (persist) {
      await this.setTheme(t);
    }
    try {
      context.getApplicationContext().setColorMode(colorModeOf(t));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(e));
    }
  }

  private async get(key: string, def: string): Promise<string> {
    if (this.store === undefined) {
      await this.init();
    }
    if (this.store === undefined) {
      return def;
    }
    try {
      const v = await this.store.get(key, def);
      return v as string;
    } catch (e) {
      return def;
    }
  }

  private async put(key: string, value: string): Promise<void> {
    if (this.store === undefined) {
      await this.init();
    }
    if (this.store === undefined) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'put failed: %{public}s', JSON.stringify(e));
    }
  }
}
