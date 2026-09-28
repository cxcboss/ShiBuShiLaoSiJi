import { ConfigurationConstant } from '@kit.AbilityKit';

/**
 * 悬浮底部页签自身占用的竖向净空（vp），与 Index 中 barFloatingStyle 的
 * barBottomMargin(28) + 页签高度相匹配；列表尾部还需再叠加系统导航条高度。
 */
export const TAB_BAR_CLEARANCE_VP: number = 96;

/**
 * 全局深浅色状态。
 *
 * 存在的理由：`context.config.colorMode` 是普通属性读取，不具备响应式能力。
 * 组件若直接读它来决定 Tab 图标色、状态栏文字色，系统切换深浅色后
 * build() 不会重跑，颜色会一直停留在旧值。
 * 这里用 @ObservedV2 + @Trace 把它变成可观察状态，由 EntryAbility
 * 在 onCreate / onConfigurationUpdate 中写入。
 */
@ObservedV2
export class ThemeState {
  private static instance: ThemeState = new ThemeState();

  @Trace isDark: boolean = false;
  /** 底部导航条/三键栏高度（px），由 EntryAbility 随 avoidAreaChange 写入 */
  @Trace bottomInsetPx: number = 0;

  /** 底部避让高度（vp）：px→vp 需要 UIContext，故由调用方传入 */
  bottomInsetVp(ui: UIContext): number {
    return ui.px2vp(this.bottomInsetPx);
  }

  static getInstance(): ThemeState {
    return ThemeState.instance;
  }

  updateFromColorMode(mode: ConfigurationConstant.ColorMode | undefined): void {
    this.isDark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
}
