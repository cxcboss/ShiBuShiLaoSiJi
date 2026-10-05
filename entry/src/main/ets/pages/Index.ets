import { DrivingReport } from '../model/DrivingReport';
import { RecordingPage } from './RecordingPage';
import { HistoryPage } from './HistoryPage';
import { SettingsPage } from './SettingsPage';
import { ReportSheet } from '../components/ReportSheet';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs, HdsTabsController, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeState } from '../util/ThemeState';
import { GlobalContext } from '../util/GlobalContext';
import { SettingsRepository } from '../service/SettingsRepository';

/**
 * 应用根容器：HDS 官方组件体系（深度适配 6.0+）。
 * - 顶部：官方标题栏滚动模糊（scrollEffect COMMON_BLUR）——内容穿透状态栏，
 *   只有上滑内容进入状态栏底下时才出现渐变模糊；顶部净空由各页自占位；
 *   状态栏文字颜色由 systemBarStyle 按深浅色管理
 * - 底栏：HdsTabs 悬浮页签，页签顺序为 历史 / 记录 / 我的，「记录」居于中间入口，
 *   打开应用直达记录页（检测是核心动作）；列表穿透底栏用尾部占位撑净空
 * - 报告：bindSheet 叠层弹窗（下滑可关闭，关闭左上角 / 分享右上角，事件分类汇总）
 * 根容器扩展系统安全区：背景延伸到状态栏与导航条区域（无突兀色差）。
 */
@Entry
@ComponentV2
struct Index {
  /** 仅作 HdsNavigation 的路由栈宿主：报告已改为 bindSheet，全应用无 pushPath，故无需响应式 */
  private pathStack: NavPathStack = new NavPathStack();
  /** 当前页签：与 HdsTabs 的 index 双向同步，初始 1 = 打开应用直达中间「记录」页 */
  @Local currentTab: number = 1;
  @Local historyTick: number = 0;
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
    this.tabsController.bindScroller(0, this.historyScroller);
    this.tabsController.bindScroller(2, this.settingsScroller);
    this.maybeShowPrivacyDialog();
  }

  /**
   * 首次启动隐私政策弹窗：应用采集位置等个人信息，收集前必须取得用户同意
   * （应用市场审核要求）。不同意则退出应用；同意一次后不再弹出。
   */
  private maybeShowPrivacyDialog(): void {
    SettingsRepository.getInstance().isPrivacyAgreed().then((agreed: boolean) => {
      if (agreed) {
        return;
      }
      this.getUIContext().showAlertDialog({
        title: '隐私政策与个人信息保护',
        message: '欢迎使用「老司机」。\n\n'
          + '• 本应用采集的信息：位置信息（含后台定位）、加速度传感器数据、行驶记录（时长、里程、轨迹、评分）。\n'
          + '• 用途：仅在本机计算驾驶舒适度评分与绘制轨迹。\n'
          + '• 存储：所有数据仅保存在您的设备上，我们不上传、不共享给任何第三方；卸载应用即彻底删除。\n'
          + '• 地图展示由华为花瓣地图（Map Kit）提供，加载地图时设备会与华为服务器通信。\n\n'
          + '完整说明见「我的 → 隐私政策」。点击"同意"表示您已阅读并同意上述内容。',
        primaryButton: {
          value: '同意并继续',
          action: (): void => {
            SettingsRepository.getInstance().setPrivacyAgreed(true);
          },
        },
        secondaryButton: {
          value: '不同意并退出',
          action: (): void => {
            try {
              GlobalContext.getInstance().getContext().terminateSelf();
            } catch (e) {
              hilog.warn(0x0000, 'Index', 'terminateSelf failed: %{public}s', JSON.stringify(e));
            }
          },
        },
        cancel: (): void => {
          // 点弹窗外部/返回键视为未同意，同样退出，避免绕过授权继续采集
          try {
            GlobalContext.getInstance().getContext().terminateSelf();
          } catch (e) {
            hilog.warn(0x0000, 'Index', 'terminateSelf(cancel) failed: %{public}s', JSON.stringify(e));
          }
        },
        alignment: DialogAlignment.Center,
        autoCancel: true,
      });
    }).catch((e: ESObject) => {
      hilog.warn(0x0000, 'Index', 'isPrivacyAgreed failed: %{public}s', JSON.stringify(e));
    });
  }

  aboutToDisappear(): void {
    this.tabsController.unbindScroller(this.historyScroller);
    this.tabsController.unbindScroller(this.settingsScroller);
  }

  build() {
    // 对齐顶部：状态栏渐变模糊叠层必须贴顶（Stack 默认居中会把叠层放到屏幕中部）
    Stack({ alignContent: Alignment.Top }) {
      HdsNavigation(this.pathStack) {
        // ── 官方底部页签：历史 / 记录（中间入口）/ 我的 ──
        // index 响应式绑定 currentTab：深浅色切换会触发 HdsNavigation/HdsTabs 按新
        // 样式重渲染，写死初始值会把页签拉回记录页（真机实测），绑定当前值才稳。
        HdsTabs({ controller: this.tabsController, index: this.currentTab }) {
          TabContent() {
            HistoryPage({ refreshTick: this.historyTick, scroller: this.historyScroller,
              onShowReport: (r: DrivingReport) => { this.showReport(r); } })
          }
          .tabBar(this.tabStyle('历史', $r('sys.symbol.clock')))

          TabContent() {
            RecordingPage({
              onShowReport: (r: DrivingReport) => { this.showReport(r); } })
          }
          .tabBar(this.tabStyle('记录', $r('sys.symbol.car')))

          TabContent() {
            SettingsPage({ scroller: this.settingsScroller })
          }
          .tabBar(this.tabStyle('我的', $r('sys.symbol.person')))
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
      // ── 官方标题栏滚动模糊方案：titleBar 透明常驻，内容穿透状态栏，
      //    只有上滑内容进入状态栏底下时才出现渐变模糊。效果用沉浸式渐变模糊
      //    （IMMERSIVE_GRADIENT_BLUR，API 23+）：模糊随距离渐变过渡、无生硬分界，
      //    且由系统按深浅色自适应底色，联动滚动器为 bindToScrollable 注册的列表。──
      .titleBar({
        // 内容不避让标题栏安全区：列表/内容区从屏幕顶开始，滚动的卡片可滑入状态栏底下
        enableComponentSafeArea: false,
        style: {
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
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
      // 单档 LARGE：detents 两档高度时，拖拽换档每帧改变 sheet 高度、内容 Scroll
      // 连续重排，长报告实测掉帧且两档切换瞬间内容滚动位不变出现"断层"。
      // 打开即全高（dragBar 仍可下滑关闭），没有高度过渡自然无卡顿。
      detents: [SheetSize.LARGE],
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
    // 历史在 0 号位：每次切回都刷新，拿到最新落盘的报告
    if (index === 0) {
      this.historyTick++;
    }
  }
}
