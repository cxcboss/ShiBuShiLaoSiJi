import { ReportRepository } from '../service/ReportRepository';
import { DrivingReport } from '../model/DrivingReport';
import { levelOf, sensitivityLabel } from '../model/DetectionConfig';
import { TimeUtil } from '../util/TimeUtil';
import { TAB_BAR_CLEARANCE_VP, ThemeState } from '../util/ThemeState';
import {
  DeleteIconOptions,
  FullDeleteOptions,
  HdsListItem,
  HdsListItemCardOptions,
  HdsSnackBar,
  HdsSwipeActionOptions,
  PrefixCustomBuilder,
  SuffixArrow,
} from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HistoryPage';

/** 分数徽章底色不透明度：等级色太实会抢正文 */
const BADGE_ALPHA: number = 0.12;

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

  /** 路况/低速豁免数：一次遍历只统计一次（此前同一模板里调用两遍） */
  private exemptCount(r: DrivingReport): number {
    let n: number = 0;
    for (const e of r.events) {
      if (e.excluded) {
        n++;
      }
    }
    return n;
  }

  /**
   * 摘要行。此前第二行输出的是 "日期 + 时长"，时长被读成时刻
   * （用户反馈"2026-08-29 00:02"这种不可能的时间）：
   * 现在时刻归时刻（HH:mm），时长显式带"时长"前缀，两者分行不再混排。
   */
  private summaryLine(r: DrivingReport): string {
    const exempt: number = this.exemptCount(r);
    const parts: string[] = [`${(r.distanceM / 1000).toFixed(1)} km`, `事件 ${r.events.length}`];
    if (exempt > 0) {
      parts.push(`路况豁免 ${exempt}`);
    }
    return parts.join(' · ');
  }

  private timeLine(r: DrivingReport): string {
    return `${r.date} ${TimeUtil.formatTime(r.startTime)} · 时长 ${TimeUtil.formatDuration(r.durationSec)}`;
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
          ForEach(this.reports, (r: DrivingReport) => {
            HdsListItem({
              hdsListItemCard: this.cardOptions(r),
              swipeActionOptions: this.swipeOptions(r),
            })
          }, (r: DrivingReport) => `${r.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        // 底部留出足够空间让最后一项完全可见于悬浮底栏上方
        // barFloatingStyle barBottomMargin=28 + 底栏高度≈64 = 约 92px，再加一点余量
        .padding({
          left: 16, right: 16, top: 8,
          bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()),
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** HDS 列表项：首项自定义分数徽章，正文走主/副/描述三档，尾部标准箭头 */
  private cardOptions(r: DrivingReport): HdsListItemCardOptions {
    const opts: HdsListItemCardOptions = {
      prefixItem: new PrefixCustomBuilder((): void => {
        this.scoreBadge(r);
      }),
      textItem: {
        primaryText: { text: `${r.level} · ${sensitivityLabel(r.sensitivity)}` },
        secondaryText: { text: this.timeLine(r) },
        description: { text: this.summaryLine(r) },
      },
      suffixItem: new SuffixArrow({ color: $r('app.color.font_quaternary') }),
      cardId: `${r.id}`,
      cardBackgroundColor: $r('app.color.card_bg'),
      cardBorderRadius: 16,
      onClick: (): void => {
        this.onShowReport(r);
      },
    };
    return opts;
  }

  /**
   * HDS 标准滑动删除：图标态删除 + 全程滑动直删，
   * 替代此前手写的红底"删除"文本（不符合鸿蒙 7 的列表交互，也没有触感反馈）。
   */
  private swipeOptions(r: DrivingReport): HdsSwipeActionOptions {
    const del: DeleteIconOptions = {
      backgroundColor: '#F44336',
      iconOptions: { accessibilityText: '删除该报告' },
      onAction: (): void => {
        this.removeReport(r);
      },
    };
    const full: FullDeleteOptions = {
      isFullDelete: true,
      enableVibration: true,
      onFullDeleteAction: (): void => {
        this.removeReport(r);
      },
    };
    const opts: HdsSwipeActionOptions = {
      deleteIconOptions: del,
      fullDeleteOptions: full,
    };
    return opts;
  }

  /** 等级色分数徽章 */
  @Builder
  scoreBadge(r: DrivingReport) {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(44)
        .height(44)
        .fill(levelOf(r.finalScore).color)
        .opacity(BADGE_ALPHA)
      Text(`${r.finalScore}`)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(levelOf(r.finalScore).color)
        .accessibilityText(`${r.finalScore} 分`)
    }
    .width(44)
    .height(44)
  }

  private async removeReport(r: DrivingReport): Promise<void> {
    await ReportRepository.getInstance().removeById(r.id);
    this.reports = this.reports.filter((item: DrivingReport): boolean => item.id !== r.id);
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
