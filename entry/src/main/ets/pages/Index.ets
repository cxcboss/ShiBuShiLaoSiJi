import { DrivingReport } from '../model/DrivingReport';
import { RecordingPage } from './RecordingPage';
import { HistoryPage } from './HistoryPage';
import { SettingsPage } from './SettingsPage';
import { ReportSheet } from '../components/ReportSheet';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs, HdsTabsController, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeState } from '../util/ThemeState';

/**
 * 应用根容器：HDS 官方组件体系（深度适配 6.0+）。
 * - 顶部：HdsNavigation 官方标题栏（透明背景，内容自动下移避让状态栏；状态栏文字颜色由 systemBarStyle 按深浅色管理）
 * - 首页：HdsTabs 官方底部页签（原生默认样式，无悬浮/无自定义效果）
 * - 报告：bindSheet 叠层弹窗（下滑可关闭，关闭左上角 / 分享右上角，事件分类汇总）
 * 根容器扩展系统安全区：背景延伸到状态栏与导航条区域（无突兀色差）。
 */
@Entry
@ComponentV2
struct Index {
  /** 仅作 HdsNavigation 的路由栈宿主：报告已改为 bindSheet，全应用无 pushPath，故无需响应式 */
  private pathStack: NavPathStack = new NavPathStack();
  @Local currentTab: number = 0;
  @Local historyTick: number = 0;
  @Local recordTick: number = 0;
  @Local currentReport: DrivingReport | undefined = undefined;
  @Local reportSheetOpen: boolean = false;
  /** 深浅色可观察状态：由 EntryAbility 在配置变化时写入，驱动 Tab 色与状态栏文字色重绘 */
  @Local theme: ThemeState = ThemeState.getInstance();
  private tabsController: HdsTabsController = new HdsTabsController();
  private historyScroller: ListScroller = new ListScroller();
  private settingsScroller: Scroller = new Scroller();

  private isDarkMode(): boolean {
    return this.theme.isDark;
  }

  /** 未选中页签颜色：深色模式白色，浅色模式黑色 */
  private inactiveColor(): ResourceColor {
    return this.isDarkMode() ? '#FFFFFF' : '#000000';
  }

  /** 状态栏文字颜色样式（HdsNavigation 官方 systemBarStyle，跟随深浅色；滚动前后一致，避免变色） */
  private systemBarStyle(): window.SystemBarStyle {
    return { statusBarContentColor: this.isDarkMode() ? '#FFFFFF' : '#000000' };
  }

  /** 官方底部页签：BottomTabBarStyle + SymbolGlyphModifier（选中品牌蓝 / 未选中深浅色自适应） */
  private tabStyle(label: string, icon: Resource): BottomTabBarStyle {
    const symbol: TabBarSymbol = {
      normal: new SymbolGlyphModifier(icon)
        .fontColor([this.inactiveColor()])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .fontSize(24),
      selected: new SymbolGlyphModifier(icon)
        .fontColor(['#0A59F7'])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .fontSize(24),
    } as TabBarSymbol;
    return new BottomTabBarStyle(symbol, label).labelStyle({
      unselectedColor: this.inactiveColor(),
      selectedColor: '#0A59F7',
    });
  }

  aboutToAppear(): void {
    this.tabsController.bindScroller(1, this.historyScroller);
    this.tabsController.bindScroller(2, this.settingsScroller);
  }

  aboutToDisappear(): void {
    this.tabsController.unbindScroller(this.historyScroller);
    this.tabsController.unbindScroller(this.settingsScroller);
  }

  build() {
    Stack() {
      HdsNavigation(this.pathStack) {
        // ── 官方底部页签（HdsTabs 原生默认，无悬浮无自定义） ──
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            RecordingPage({ refreshTick: this.recordTick,
              onShowReport: (r: DrivingReport) => { this.showReport(r); } })
          }
          .tabBar(this.tabStyle('检测', $r('sys.symbol.car')))

          TabContent() {
            HistoryPage({ refreshTick: this.historyTick, scroller: this.historyScroller,
              onShowReport: (r: DrivingReport) => { this.showReport(r); } })
          }
          .tabBar(this.tabStyle('历史', $r('sys.symbol.clock')))

          TabContent() {
            SettingsPage({ scroller: this.settingsScroller })
          }
          .tabBar(this.tabStyle('设置', $r('sys.symbol.gearshape')))
        }
        .barPosition(BarPosition.End)
        .barOverlap(true)
        .vertical(false)
        .barFloatingStyle({
          barBottomMargin: 28,
          gradientMask: {
            maskColor: $r('app.color.tab_bar_mask'),
            maskHeight: 92,
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
          },
        })
        .onChange((index: number) => this.onTabChange(index))
      }
      .titleBar({
        enableComponentSafeArea: true,
        style: {
          scrollEffectOpts: {
            enableScrollEffect: false,
            scrollEffectType: ScrollEffectType.COMMON_BLUR,
          },
          originalStyle: {
            backgroundStyle: {
              backgroundColor: Color.Transparent,
            },
          },
        },
        content: {
          title: { mainTitle: '' },
        },
      })
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(true)
      .systemBarStyle(this.systemBarStyle(), this.systemBarStyle())
      .bindToScrollable([this.historyScroller, this.settingsScroller])
      .mode(NavigationMode.Stack)
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.reportSheetOpen, this.reportSheetBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg'),
      onDisappear: () => {
        this.reportSheetOpen = false;
        this.currentReport = undefined;
      },
    })
  }

  /** 报告叠层弹窗内容（外层必须包 Column，直接返回自定义组件会导致弹窗不显示） */
  @Builder
  reportSheetBuilder() {
    Column() {
      if (this.currentReport !== undefined) {
        ReportSheet({
          report: this.currentReport,
          onClose: () => {
            this.reportSheetOpen = false;
          },
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  private showReport(r: DrivingReport): void {
    this.currentReport = r;
    this.reportSheetOpen = true;
  }

  private onTabChange(index: number): void {
    hilog.info(0x0000, 'Index', 'onTabChange -> %{public}d', index);
    if (index === this.currentTab) {
      return;
    }
    this.currentTab = index;
    if (index === 1) {
      this.historyTick++;
    }
    if (index === 0) {
      this.recordTick++;
    }
  }
}
