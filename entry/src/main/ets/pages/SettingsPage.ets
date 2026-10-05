import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsRepository, ThemeMode } from '../service/SettingsRepository';
import { TIPS, TipItem } from '../model/DetectionConfig';
import { GlobalContext } from '../util/GlobalContext';
import { ThemeState } from '../util/ThemeState';

const DOMAIN: number = 0x0000;
const TAG: string = 'SettingsPage';
/** 握持自动暂停依赖系统的多模态感知能力（API 20+ 起提供握持检测） */
const HOLD_PAUSE_SYS_CAP: string = 'SystemCapability.MultimodalAwareness.Motion';

/** 隐私政策条目（应用内展示；与商店上架资料中的隐私政策保持一致口径） */
const PRIVACY_SECTIONS: TipItem[] = [
  {
    key: 'privacy-collect',
    title: '我们收集的信息',
    content: '为提供驾驶舒适度检测功能，本应用会在您主动开始检测时采集：\n'
      + '1. 位置信息（精确位置与后台定位）：用于计算行驶距离、绘制行驶轨迹、按车速豁免误判；\n'
      + '2. 设备传感器数据（加速度计等运动传感器）：用于识别急加速、急减速、急转向等驾驶事件；\n'
      + '3. 行驶记录：每次检测的时长、里程、轨迹、事件明细与评分。',
  },
  {
    key: 'privacy-store',
    title: '数据如何存储',
    content: '上述所有数据仅保存在您的设备本地（应用沙箱内的数据库与偏好文件），本应用没有自建服务器，'
      + '不会将您的任何位置、轨迹或评分数据上传，开发者也无法读取。卸载应用即彻底删除全部数据；'
      + '您也可以在历史记录中逐条左滑删除。',
  },
  {
    key: 'privacy-use',
    title: '数据如何使用',
    content: '数据仅用于在本机生成驾驶行为报告与评分，不用于用户画像、广告或任何与核心功能无关的用途。'
      + '本应用不申请通讯录、相册、麦克风、摄像头等与功能无关的权限。',
  },
  {
    key: 'privacy-third',
    title: '第三方服务',
    content: '1. 地图展示：行程轨迹地图由华为花瓣地图（Map Kit）提供。仅当您查看轨迹地图时，'
      + '设备会向华为地图服务器请求地图瓦片，该通信受《华为隐私政策》约束，本应用不会向其提交您的轨迹数据；\n'
      + '2. 系统分享：仅当您主动点击"分享"时，评分海报与文字会交给系统分享面板，由您选择分享对象。',
  },
  {
    key: 'privacy-rights',
    title: '您的权利',
    content: '您可以随时在系统设置中关闭定位权限（功能将不可用），在应用内关闭"握持自动暂停"，'
      + '在历史记录中删除任意或全部行驶记录，或卸载应用删除所有本地数据。'
      + '如您对本政策有任何疑问，可通过应用市场页面评论区与我们联系。',
  },
  {
    key: 'privacy-update',
    title: '政策更新',
    content: '本政策自 2026 年 10 月 4 日起生效。功能发生重大变化时我们会更新本政策，'
      + '并在应用内同步展示最新版本。',
  },
];

/**
 * 「我的」页：深浅模式切换 + 握持自动暂停开关 + 评分原理说明入口。
 * 内容整体下移留出单手操作区，无版本号展示。
 */
@ComponentV2
export struct SettingsPage {
  /** 滚动控制器（与 HdsTabs/HdsNavigation 联动） */
  @Param scroller: Scroller = new Scroller();
  @Local theme: ThemeMode = 'auto';
  /** 握持自动暂停开关（检测中手机被拿起自动暂停，放回 3 秒后恢复） */
  @Local holdPause: boolean = false;
  /** 当前设备是否支持握持检测：不支持则开关置灰 */
  @Local holdSupported: boolean = true;
  /** 「评分原理说明」叠层弹窗开关 */
  @Local helpOpen: boolean = false;
  /** 「隐私政策」叠层弹窗开关 */
  @Local privacyOpen: boolean = false;
  /** 系统环境可观察状态（状态栏/底部导航条高度） */
  @Local sys: ThemeState = ThemeState.getInstance();

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.theme = await SettingsRepository.getInstance().getTheme();
    this.holdPause = await SettingsRepository.getInstance().getHoldPause();
    this.holdSupported = canIUse(HOLD_PAUSE_SYS_CAP);
  }

  private async selectTheme(t: ThemeMode): Promise<void> {
    this.theme = t;
    await SettingsRepository.getInstance()
      .applyTheme(GlobalContext.getInstance().getContext(), t, true);
  }

  private async toggleHoldPause(on: boolean): Promise<void> {
    this.holdPause = on;
    await SettingsRepository.getInstance().setHoldPause(on);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'showToast failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Column() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // 深浅模式切换
          Column({ space: 12 }) {
            Row() {
              Text('深浅模式')
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

          // 握持自动暂停开关（原理说明独立成"评分原理说明"入口）
          Column() {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('握持自动暂停')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.holdSupported ? $r('app.color.font_primary') : $r('app.color.font_quaternary'))
                Text(this.holdSupported ? '拿起手机自动暂停，放回 3 秒后恢复' :
                  '当前设备不支持握持检测')
                  .fontSize(12)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.holdPause })
                .enabled(this.holdSupported)
                .selectedColor('#0A59F7')
                .onChange((on: boolean) => {
                  this.toggleHoldPause(on);
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(16)
          .opacity(this.holdSupported ? 1 : 0.75)

          // 评分原理说明入口：点击弹出整个 App 的晕车检测评分原理介绍
          Row() {
            Text('评分原理说明')
              .fontSize(16)
              .fontColor($r('app.color.font_primary'))
            Blank()
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([$r('app.color.font_quaternary')])
              .accessibilityLevel('no')
          }
          .width('100%')
          .height(52)
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(16)
          .stateStyles({
            normal: {
              .opacity(1)
            },
            pressed: {
              .opacity(0.7)
            },
          })
          .animation({ duration: 150, curve: Curve.EaseOut })
          .onClick(() => {
            this.helpOpen = true;
          })

          // 隐私政策入口：上架审核要求应用内可查看隐私政策
          Row() {
            Text('隐私政策')
              .fontSize(16)
              .fontColor($r('app.color.font_primary'))
            Blank()
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([$r('app.color.font_quaternary')])
              .accessibilityLevel('no')
          }
          .width('100%')
          .height(52)
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(16)
          .stateStyles({
            normal: {
              .opacity(1)
            },
            pressed: {
              .opacity(0.7)
            },
          })
          .animation({ duration: 150, curve: Curve.EaseOut })
          .onClick(() => {
            this.privacyOpen = true;
          })
        }
        .width('100%')
        // 内容整体下移：状态栏高度之外再留一段，方便单手够到开关
        .padding({
          left: 20, right: 20,
          top: this.sys.topInsetVp(this.getUIContext()) + 32,
        })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.Top)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      // 隐私政策弹层挂在内层 Scroll 上：同一节点只能绑一个 bindSheet，
      // 评分说明弹层已占用外层 Column
      .bindSheet(this.privacyOpen, this.privacySheetBuilder(), {
        detents: [SheetSize.LARGE],
        preferType: SheetType.BOTTOM,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.page_bg'),
        onDisappear: () => {
          this.privacyOpen = false;
        },
      })
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.helpOpen, this.helpSheetBuilder(), {
      // 单档 LARGE：同报告弹窗，避免两档拖拽换档的重排卡顿与内容断层
      detents: [SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg'),
      onDisappear: () => {
        this.helpOpen = false;
      },
    })
  }

  /** 评分原理说明：条目长文本需要可滚动容器，系统 showDialog 的 message 不滚动会被裁切 */
  @Builder
  helpSheetBuilder() {
    Column() {
      // 固定标题栏：不随内容滚动，此区域下拉 = sheet 关闭手势。
      // 布局与报告弹窗一致：关闭在左、标题居中、右侧留白。
      Row({ space: 12 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('app.color.font_secondary')])
        }
        .width(44)
        .height(44)
        .padding(0)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(22)
        .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
        .accessibilityText('关闭评分原理说明')
        .onClick(() => {
          this.helpOpen = false;
        })

        Blank()

        Text('评分原理说明')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))

        Blank()

        // 右侧占位（无动作），保持标题几何居中
        Row()
          .width(44)
          .height(44)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      .alignItems(VerticalAlign.Center)

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
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // SELF_FIRST：内容滚到顶后手势交给 sheet——顶部继续下拉即可关闭弹层，
      // 否则下滑关闭只作用于 dragBar 一条缝（用户反馈操作区太小）
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST,
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 隐私政策：与评分说明同布局（固定标题栏 + 可滚动正文 + SELF_FIRST 下滑关闭） */
  @Builder
  privacySheetBuilder() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('app.color.font_secondary')])
        }
        .width(44)
        .height(44)
        .padding(0)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(22)
        .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
        .accessibilityText('关闭隐私政策')
        .onClick(() => {
          this.privacyOpen = false;
        })

        Blank()

        Text('隐私政策')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))

        Blank()

        Row()
          .width(44)
          .height(44)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 12 }) {
          ForEach(PRIVACY_SECTIONS, (t: TipItem) => {
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
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST,
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 主题选项：等宽三段 + 44vp（主流可及性最小热区），此前按文本收缩且仅约 32vp 高 */
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
    .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.96 })
    .animation({ duration: 200, curve: Curve.EaseOut })
    .onClick(() => this.selectTheme(t))
  }
}
