import { ShowDialogSuccessResponse } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VERSION_NAME } from 'BuildProfile';
import { SettingsRepository, ThemeMode } from '../service/SettingsRepository';
import { ReportRepository } from '../service/ReportRepository';
import { TIPS, TipItem, Sensitivity } from '../model/DetectionConfig';
import { GlobalContext } from '../util/GlobalContext';
import { TAB_BAR_CLEARANCE_VP, ThemeState } from '../util/ThemeState';

const DOMAIN: number = 0x0000;
const TAG: string = 'SettingsPage';
const SENSITIVITY_OPTIONS: Sensitivity[] = ['mild', 'moderate', 'severe'];
/** 版本号统一取自构建配置，避免与 app.json5 的 versionName 脱节 */
const APP_VERSION: string = VERSION_NAME;

/**
 * 设置页：检测灵敏度、外观主题、评分说明、关于与数据管理。
 */
@ComponentV2
export struct SettingsPage {
  /** 滚动控制器（与 HdsTabs/HdsNavigation 联动） */
  @Param scroller: Scroller = new Scroller();
  @Local sensitivity: Sensitivity = 'moderate';
  @Local theme: ThemeMode = 'auto';
  /** 「评分说明」叠层弹窗开关 */
  @Local helpOpen: boolean = false;
  /** 系统环境可观察状态（底部导航条高度），用于内容避让悬浮页签 */
  @Local sys: ThemeState = ThemeState.getInstance();

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.sensitivity = await SettingsRepository.getInstance().getSensitivity();
    this.theme = await SettingsRepository.getInstance().getTheme();
  }

  private async selectSensitivity(s: Sensitivity): Promise<void> {
    this.sensitivity = s;
    await SettingsRepository.getInstance().setSensitivity(s);
  }

  private async selectTheme(t: ThemeMode): Promise<void> {
    this.theme = t;
    await SettingsRepository.getInstance()
      .applyTheme(GlobalContext.getInstance().getContext(), t, true);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'showToast failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 打开评分说明。
   * 此前用 promptAction.showDialog：其 message 是不可滚动的 Text，
   * TIPS 拼接后约 400 字，在小屏上会被直接裁切看不到后半段。
   */
  private showScoreHelp(): void {
    this.helpOpen = true;
  }

  private showAbout(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '关于「老司机」',
      message: '一款基于手机加速度计的驾驶舒适度检测应用。\n\n' +
        '点击开始后有 5 秒准备时间。检测过程中记录急加速/急减速/急转向/摇摆四类事件，' +
        '上下颠簸按路况统计、不参与评分；结束后按事件密度、平稳巡航与强度峰值三个维度综合评分。\n\n' +
        `参考项目：motion-sickness-detector（晕不晕）\n` +
        `V${APP_VERSION}`,
      buttons: [
        { text: '关闭', color: '#0A59F7' },
      ],
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, TAG, 'showAbout dialog failed: %{public}s', JSON.stringify(e));
    });
  }

  private confirmClearHistory(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '清空历史',
      message: '确定删除全部历史报告吗？此操作不可恢复。',
      buttons: [
        { text: '取消', color: '#888888' },
        { text: '清空', color: '#F44336' },
      ],
    }).then((res: ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        this.clearHistory();
      }
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, TAG, 'confirmClearHistory dialog failed: %{public}s', JSON.stringify(e));
    });
  }

  private async clearHistory(): Promise<void> {
    await ReportRepository.getInstance().removeAll();
    this.toast('历史已清空');
  }

  build() {
    Column() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // 检测灵敏度
          Column({ space: 12 }) {
            Row() {
              Text('检测灵敏度')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
              Blank()
              Text('越灵敏越易触发')
                .fontSize(12)
                .fontColor($r('app.color.font_tertiary'))
            }
            .width('100%')
            Row({ space: 10 }) {
              this.sensChip('mild', '轻度')
              this.sensChip('moderate', '中度')
              this.sensChip('severe', '重度')
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(16)

          // 外观主题
          Column({ space: 12 }) {
            Row() {
              Text('外观')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
              Blank()
              Text('跟随系统或手动切换')
                .fontSize(12)
                .fontColor($r('app.color.font_tertiary'))
            }
            .width('100%')
            Row({ space: 10 }) {
              this.themeChip('auto', '自动')
              this.themeChip('light', '浅色')
              this.themeChip('dark', '深色')
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(16)

          // 功能菜单
          Column() {
            this.menuRow('评分说明', () => this.showScoreHelp(), $r('app.color.font_primary'))
            Divider().color($r('app.color.divider_color')).margin({ left: 16 })
            this.menuRow('关于', () => this.showAbout(), $r('app.color.font_primary'))
            Divider().color($r('app.color.divider_color')).margin({ left: 16 })
            this.menuRow('清空历史记录', () => this.confirmClearHistory(), '#F44336')
          }
          .width('100%')
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(16)
          .padding({ left: 16, right: 16 })

          Text(`V${APP_VERSION} · 纯鸿蒙原生实现 · 综合评分模型 + 路面颠簸豁免`)
            .fontSize(11)
            .fontColor($r('app.color.font_quaternary'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({
          left: 20, right: 20,
          bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()),
        })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.helpOpen, this.helpSheetBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg'),
      onDisappear: () => {
        this.helpOpen = false;
      },
    })
  }

  /** 评分说明：条目长文本需要可滚动容器，系统 showDialog 的 message 不滚动会被裁切 */
  @Builder
  helpSheetBuilder() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          ForEach(TIPS, (t: TipItem) => {
            Column({ space: 6 }) {
              Text(t.title)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_primary'))
              Text(t.content)
                .fontSize(13)
                .lineHeight(20)
                .fontColor($r('app.color.font_secondary'))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
          }, (t: TipItem) => t.key)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 灵敏度选项：等宽三段、44vp 高。
   * 44vp 是主流可及性最小热区（HarmonyOS 自身下限 40vp），此前的 40vp 偏小。
   */
  @Builder
  sensChip(s: Sensitivity, label: string) {
    Column() {
      Text(label)
        .fontSize(14)
        .fontColor(this.sensitivity === s ? '#FFFFFF' : $r('app.color.font_secondary'))
        .fontWeight(this.sensitivity === s ? FontWeight.Medium : FontWeight.Normal)
        .animation({ duration: 200, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.sensitivity === s ? '#0A59F7' : '#00000000')
    .animation({ duration: 200, curve: Curve.EaseOut })
    .onClick(() => this.selectSensitivity(s))
  }

  /** 主题选项：与 sensChip 同构（等宽三段 + 44vp），此前按文本收缩且仅约 32vp 高 */
  @Builder
  themeChip(t: ThemeMode, label: string) {
    Column() {
      Text(label)
        .fontSize(14)
        .fontColor(this.theme === t ? '#FFFFFF' : $r('app.color.font_secondary'))
        .fontWeight(this.theme === t ? FontWeight.Medium : FontWeight.Normal)
        .animation({ duration: 200, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.theme === t ? '#0A59F7' : '#00000000')
    .animation({ duration: 200, curve: Curve.EaseOut })
    .onClick(() => this.selectTheme(t))
  }

  @Builder
  menuRow(label: string, action: () => void, color: ResourceColor = $r('app.color.font_primary')) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor(color)
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.font_quaternary')])
        .accessibilityLevel('no')
    }
    .width('100%')
    .height(52)
    // 按压态交给框架管理：此前用 onTouch 写 @Local，TouchType.Move 会以
    // 触摸采样频率反复赋值，每帧重建整页；且手势被父级滚动接管时收不到
    // Up，按下态会永久卡住。stateStyles 由框架处理 Down/Up/Cancel 全生命周期。
    .stateStyles({
      normal: {
        .opacity(1)
      },
      pressed: {
        .opacity(0.6)
      },
    })
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onClick(() => action())
  }
}
