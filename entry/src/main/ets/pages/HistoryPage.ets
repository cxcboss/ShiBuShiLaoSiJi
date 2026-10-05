import { ReportRepository } from '../service/ReportRepository';
import { DrivingReport } from '../model/DrivingReport';
import { TimeUtil } from '../util/TimeUtil';
import { TAB_BAR_CLEARANCE_VP, ThemeState } from '../util/ThemeState';
import { HdsSnackBar } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HistoryPage';

@ComponentV2
export struct HistoryPage {
  @Param refreshTick: number = 0;
  /** 滚动控制器（与 HdsNavigation 的滚动模糊联动，由根容器 bindToScrollable 注册） */
  @Param scroller: ListScroller = new ListScroller();
  /** 点击报告卡片回调给根容器展示（传报告对象） */
  @Param onShowReport: (report: DrivingReport) => void = () => {
  };
  @Local reports: DrivingReport[] = [];
  @Local loading: boolean = false;
  /** 系统环境可观察状态（底部导航条高度），用于列表尾部避让悬浮页签 */
  @Local sys: ThemeState = ThemeState.getInstance();
  /** 进行中的加载，并发调用共享同一次请求而非直接丢弃 */
  private loadPromise: Promise<void> | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  @Monitor('refreshTick')
  onRefreshTick(): void {
    if (this.refreshTick > 0) {
      this.load();
    }
  }

  async load(): Promise<void> {
    if (this.loadPromise === undefined) {
      this.loadPromise = this.doLoad();
    }
    return this.loadPromise;
  }

  private async doLoad(): Promise<void> {
    this.loading = true;
    try {
      this.reports = await ReportRepository.getInstance().loadAll();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(e));
    } finally {
      this.loading = false;
      this.loadPromise = undefined;
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'showToast failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 数据行：时长 / 里程 / 事件数。
   * 时长用中文表述（"37分16秒"），mm:ss 在列表里会被读成时刻（此前用户反馈过）；
   * 路况豁免数不再展示——它是引擎内部的口径说明，用户只关心"记了几笔"。
   */
  private summaryLine(r: DrivingReport): string {
    return `${TimeUtil.formatDurationCn(r.durationSec)} · ${(r.distanceM / 1000).toFixed(1)} km · 事件 ${r.events.length}`;
  }

  build() {
    Column() {
      if (this.loading && this.reports.length === 0) {
        // 首次加载态：不能先闪一下"暂无行程报告"再变列表
        Column({ space: 12 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.font_tertiary'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.reports.length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(56)
            .fontColor([$r('app.color.font_quaternary')])
          Text('暂无行程报告')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_secondary'))
          Text('完成一次检测后，报告会保存在这里')
            .fontSize(13)
            .fontColor($r('app.color.font_quaternary'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
      } else {
        List({ space: 12, scroller: this.scroller }) {
          // 首部占位撑出状态栏净空：视口穿透到屏幕顶，滚到顶时第一张卡停在状态栏下方
          ListItem() {
            Row()
              .width('100%')
              .height(this.sys.topInsetVp(this.getUIContext()) + 8)
          }

          ForEach(this.reports, (r: DrivingReport) => {
            ListItem() {
              this.tripCard(r)
            }
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
            .swipeAction({
              end: {
                builder: (): void => {
                  this.deleteButton(r)
                },
                actionAreaDistance: 96,
                onAction: (): void => {
                  this.removeReport(r);
                },
              }
            })
          }, (r: DrivingReport) => `${r.id}`)

          // 尾部占位撑出悬浮底栏净空：List 的 padding 会内缩滚动视口（卡片在
          // 底栏上方就被裁掉），改用占位让卡片滚动时从底栏下方穿过，
          // 滚到底时最后一张完整停在底栏上方（高度已扣除列表 12vp 间距）。
          ListItem() {
            Row()
              .width('100%')
              .height(TAB_BAR_CLEARANCE_VP - 12 + this.sys.bottomInsetVp(this.getUIContext()))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        // 视口穿透到屏幕上下边缘：卡片滚动时从状态栏与悬浮底栏下方穿过
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 行程卡片（用户反馈旧版"数字+小字散在卡片边缘"非常糟糕，重做）：
   * - 左侧 70vp 评分块：分数加粗居中 + 等级小字，垫中性灰底成为视觉锚点
   *   （评分是核心信息放最显眼处；按需求暂不上等级色，仅中性灰）
   * - 中间竖分隔线隔开评分与行程事实：时间 + 中文时长/里程/事件
   * - 按压态由 stateStyles 管理，触摸 Down/Up 全生命周期交给框架
   */
  @Builder
  tripCard(r: DrivingReport) {
    Row({ space: 14 }) {
      Column({ space: 2 }) {
        Text(`${Math.round(r.finalScore)}`)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
          .maxLines(1)
          .accessibilityText(`${Math.round(r.finalScore)} 分`)
        Text(r.level)
          .fontSize(11)
          .fontColor($r('app.color.font_secondary'))
          .maxLines(1)
      }
      .width(70)
      .height(70)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.track_bg'))
      .borderRadius(16)

      Divider()
        .vertical(true)
        .height(40)
        .strokeWidth(1)
        .color($r('app.color.divider_color'))
        .accessibilityLevel('no')

      Column({ space: 5 }) {
        Text(TimeUtil.formatHistoryTime(r.startTime))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.summaryLine(r))
          .fontSize(13)
          .fontColor($r('app.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.font_quaternary')])
        .accessibilityLevel('no')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      normal: {
        .opacity(1)
      },
      pressed: {
        .opacity(0.75)
      },
    })
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onClick(() => this.onShowReport(r))
  }

  /** 滑动露出的删除按钮：红底垃圾桶，点击或滑过 actionAreaDistance 触发删除 */
  @Builder
  deleteButton(r: DrivingReport) {
    Row() {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
        .accessibilityLevel('no')
    }
    .width(72)
    .height('100%')
    .padding({ left: 12 })
    .margin({ left: 4 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F44336')
    .borderRadius(16)
    .accessibilityText(`删除 ${TimeUtil.formatHistoryTime(r.startTime)} 的报告`)
    .onClick(() => this.removeReport(r))
  }

  private async removeReport(r: DrivingReport): Promise<void> {
    await ReportRepository.getInstance().removeById(r.id);
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.reports = this.reports.filter((item: DrivingReport): boolean => item.id !== r.id);
    });
    // 官方 HdsSnackBar：提供撤销入口，防止误删
    const snackBar = new HdsSnackBar(this.getUIContext());
    snackBar.show({}, { title: '已删除该条记录' }, {
      content: '撤销',
      onContentClick: () => {
        this.restoreReport(r);
      },
    });
  }

  private async restoreReport(r: DrivingReport): Promise<void> {
    try {
      await ReportRepository.getInstance().save(r);
      // save() 是 INSERT，会分配新的自增 id，且 loadAll 按 createTime 倒序返回。
      // 直接把 r 塞到数组头部会让内存顺序与数据库不一致、id 也对不上，
      // 因此统一重新加载，保证 id 与排序都以库为准。
      await this.load();
      this.toast('已恢复');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'restore failed: %{public}s', JSON.stringify(e));
      this.toast('恢复失败');
    }
  }
}
