import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BUILD_MODE_NAME } from 'BuildProfile';
import { GlobalContext } from '../util/GlobalContext';
import { ThemeState } from '../util/ThemeState';
import { SettingsRepository, ThemeMode } from '../service/SettingsRepository';

const DOMAIN: number = 0x0000;
const TAG: string = 'ShiBuShiLaoSiJi';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;
  private avoidAreaCb: ((opt: window.AvoidAreaOptions) => void) | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    GlobalContext.getInstance().setContext(this.context);
    ThemeState.getInstance().updateFromColorMode(this.context.config.colorMode);
    this.restoreSettings();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');

    // 调试钩子（仅 debug 构建）：--pb autoStart true --pi autoStopMs 15000
    // 赋给 string 中转一次：release 构建下 BUILD_MODE_NAME 被收窄为字面量 'release'，
    // 直接与 'debug' 比较会触发 TS2367 编译错误。
    const buildModeName: string = BUILD_MODE_NAME;
    if (buildModeName === 'debug') {
      const params: ESObject = want.parameters;
      if (params !== undefined) {
        if (params['autoStart'] === true || params['autoStart'] === 'true') {
          GlobalContext.getInstance().setAutoStart(true);
        }
        const stopMs: ESObject = params['autoStopMs'];
        if (stopMs !== undefined) {
          GlobalContext.getInstance().setAutoStopMs(Number(stopMs));
        }
      }
    }
  }

  /** 恢复用户上次选择的主题；此前无条件重置为跟随系统，导致深色/浅色设置重启即失效 */
  private async restoreSettings(): Promise<void> {
    try {
      const settings: SettingsRepository = SettingsRepository.getInstance();
      const theme: ThemeMode = await settings.getTheme();
      await settings.applyTheme(this.context, theme, false);
      // setColorMode 触发的 onConfigurationUpdate 可能晚于首帧，先按存储值同步一次。
      // auto 时保留 onCreate 从系统配置读到的值，不能覆盖。
      if (theme !== 'auto') {
        ThemeState.getInstance().isDark = theme === 'dark';
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'restoreSettings failed: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    // 沉浸式布局：内容延伸到状态栏与导航条区域，系统栏透明。
    // 这里只设置栏背景为透明，不设置 statusBarContentColor ——
    // 状态栏文字颜色由 Index 的 HdsNavigation.systemBarStyle 按深浅色统一管理，
    // 两处混设会互相覆盖导致文字色与背景色不匹配。
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.mainWindow.setWindowLayoutFullScreen(true);
      this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'set immersive layout failed: %{public}s', JSON.stringify(e));
    }
    this.watchBottomInset();
    this.watchTopInset();
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  /**
   * 监听底部导航条（手势指示条 / 三键栏）高度并写入 ThemeState。
   * 布局是全屏沉浸式的，悬浮页签会盖住列表尾部；被遮住的净空随设备和
   * 导航模式变化，写死 padding 在指示条更高的机型上会让最后一条内容不可达。
   */
  private watchBottomInset(): void {
    const win: window.Window | undefined = this.mainWindow;
    if (win === undefined) {
      return;
    }
    try {
      ThemeState.getInstance().bottomInsetPx =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      this.avoidAreaCb = (opt: window.AvoidAreaOptions): void => {
        if (opt.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          ThemeState.getInstance().bottomInsetPx = opt.area.bottomRect.height;
        }
      };
      win.on('avoidAreaChange', this.avoidAreaCb);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'watchBottomInset failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 状态栏高度写入 ThemeState：滚动内容穿透顶部时用它撑出首条净空 */
  private watchTopInset(): void {
    const win: window.Window | undefined = this.mainWindow;
    if (win === undefined) {
      return;
    }
    try {
      ThemeState.getInstance().topInsetPx =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'watchTopInset failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 深浅色变化：写入 ThemeState，驱动依赖深浅色的 UI（Tab 图标色、状态栏文字色）重绘 */
  onConfigurationUpdate(newConfig: Configuration): void {
    ThemeState.getInstance().updateFromColorMode(newConfig.colorMode);
    hilog.info(DOMAIN, TAG, 'Ability onConfigurationUpdate, isDark=%{public}s',
      `${ThemeState.getInstance().isDark}`);
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined && this.avoidAreaCb !== undefined) {
      try {
        this.mainWindow.off('avoidAreaChange', this.avoidAreaCb);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'off avoidAreaChange failed: %{public}s', JSON.stringify(e));
      }
      this.avoidAreaCb = undefined;
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
