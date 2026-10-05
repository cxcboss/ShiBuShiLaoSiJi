import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DrivingReport } from '../model/DrivingReport';
import { DrivingEvent } from '../model/DrivingEvent';
import { EVENT_TYPES, adviceOf, DriveAdvice } from '../model/DetectionConfig';
import { ScoreBreakdown } from '../service/ScoringEngine';
import { PosterGenerator, PosterData, POSTER_W, POSTER_H } from '../service/PosterGenerator';
import { TimeUtil } from '../util/TimeUtil';
import { GlobalContext } from '../util/GlobalContext';
import { TrackMapPage } from './TrackMapPage';

const DOMAIN: number = 0x0000;
const TAG: string = 'ReportSheet';

/** 海报缓存最长保留时间（秒）：cacheDir 不会即时回收，每次生成海报顺带清理更旧的 */
const MAX_POSTER_AGE_SEC: number = 86400;
/** 事件坐标是否有效 */
function hasPos(e: DrivingEvent): boolean {
  return e.lat !== undefined && e.lng !== undefined && e.lat !== 0 && e.lng !== 0;
}

/** 事件按行为分类汇总 */
interface EventSummary {
  name: string;
  count: number;
  points: number;
  exemptCount: number;
}

/**
 * 行程报告叠层弹窗：结束检测/点击历史记录后弹出。
 * - 下滑手势或点击左上角关闭按钮均可关闭
 * - 分享按钮位于右上角
 * - 事件默认按行为分类汇总（总次数/总扣分），点击可展开全部明细（懒加载）
 * - 评分使用普通配色，无彩色背景
 */
@ComponentV2
export struct ReportSheet {
  @Param report: DrivingReport = {
    id: -1, baseScore: 0, finalScore: 0, level: '', levelDesc: '', slogan: '',
    sensitivity: 'moderate', durationSec: 0, distanceM: 0, startTime: 0, endTime: 0,
    date: '', events: [], gpsPath: [],
  };
  @Param onClose: () => void = () => {
  };

  /** 海报画布仅 360x300 且只在分享时绘制；内嵌轨迹画布已移除（大数据行程滚动卡顿主因） */
  private posterSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private posterCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.posterSettings);

  @Local sharing: boolean = false;
  @Local showAll: boolean = false;
  @Local summaries: EventSummary[] = [];
  /** 给司机的建议：由事件统计规则生成 */
  @Local advices: DriveAdvice[] = [];
  /** 全屏轨迹地图开关（点击"行驶轨迹"入口行进入） */
  @Local mapOpen: boolean = false;
  private isDarkMode: boolean = false;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = GlobalContext.getInstance().getContext();
    this.isDarkMode = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.summaries = this.buildSummaries(this.report.events);
    this.advices = adviceOf(this.report.events, this.report.distanceM);
  }

  /** 按行为分类汇总：每种行为的总次数 / 有效扣分 / 豁免次数 */
  private buildSummaries(events: DrivingEvent[]): EventSummary[] {
    // 种类与展示顺序取自 EVENT_TYPES，不再在 UI 层抄一份名单（旧名单里的"顿挫"已不存在）
    const map: Map<string, EventSummary> = new Map();
    for (const t of EVENT_TYPES) {
      map.set(t.name, { name: t.name, count: 0, points: 0, exemptCount: 0 });
    }
    for (const e of events) {
      let s: EventSummary | undefined = map.get(e.name);
      if (s === undefined) {
        s = { name: e.name, count: 0, points: 0, exemptCount: 0 };
        map.set(e.name, s);
      }
      s.count++;
      if (e.excluded) {
        s.exemptCount++;
      } else {
        s.points += e.ded;
      }
    }
    const list: EventSummary[] = [];
    for (const t of EVENT_TYPES) {
      const s: EventSummary | undefined = map.get(t.name);
      if (s !== undefined && s.count > 0) {
        list.push(s);
      }
    }
    list.sort((a: EventSummary, b: EventSummary): number => b.points - a.points);
    return list;
  }

  private eventColor(e: DrivingEvent): string {
    if (e.excluded) return '#9E9E9E';
    if (e.level >= 7) return '#F44336';
    if (e.level >= 4) return '#FF9800';
    return '#FFC107';
  }

  /** 事件相对检测开始的时刻（秒→分:秒） */
  private eventTime(e: DrivingEvent): string {
    const rel: number = Math.max(0, (e.time - this.report.startTime) / 1000);
    return TimeUtil.formatDuration(rel);
  }

  private validCount(): number {
    let n: number = 0;
    for (const e of this.report.events) {
      if (!e.excluded) {
        n++;
      }
    }
    return n;
  }

  private exemptCount(): number {
    return this.report.events.length - this.validCount();
  }

  private totalPoints(): number {
    let p: number = 0;
    for (const e of this.report.events) {
      if (!e.excluded) {
        p += e.ded;
      }
    }
    return Math.round(p * 10) / 10;
  }

  build() {
    Stack() {
      Column() {
        // 顶部工具栏：关闭（左上角）| 标题 | 分享（右上角）
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
          // 按钮内仅有图标，读屏无文本可播报
          .accessibilityText('关闭报告')
          .onClick(() => this.onClose())

          Blank()

          Text('行程报告')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_primary'))

          Blank()

          Button() {
            if (this.sharing) {
              Row({ space: 6 }) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color('#0A59F7')
                Text('分享中')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#0A59F7')
              }
            } else {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.share'))
                  .fontSize(18)
                  .fontColor(['#0A59F7'])
                Text('分享')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#0A59F7')
              }
            }
          }
          .height(44)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#140A59F7')
          .borderRadius(22)
          .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
          .enabled(!this.sharing)
          .onClick(() => this.sharePoster())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })

        // 内容区（可无限滚动）
        Scroll() {
        Column({ space: 14 }) {
          // ── 综合评分（普通配色） ──
          Column({ space: 6 }) {
            Text('综合评分')
              .fontSize(13)
              .fontColor($r('app.color.font_tertiary'))
            Text(`${this.report.finalScore}`)
              .fontSize(64)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
            Text(`${this.report.level} · ${this.report.levelDesc}`)
              .fontSize(16)
              .fontColor($r('app.color.font_secondary'))
            if (this.report.slogan !== '') {
              Text(`「${this.report.slogan}」`)
                .fontSize(14)
                .fontColor($r('app.color.font_tertiary'))
                .margin({ top: 4 })
            }
          }
          .width('100%')
          .padding({ top: 16, bottom: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)

          // ── 行程概览：日期时段 + 时长/里程/事件三格（合并原两张卡，一眼看完行程事实）──
          Column({ space: 12 }) {
            Row() {
              Column({ space: 4 }) {
                Text(this.report.date)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_primary'))
                Text(`${this.startTimeText()} — ${this.endTimeText()}`)
                  .fontSize(12)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              // 用轨迹点数而非里程判断定位是否可用：怠速/挪车几分钟里程会是 0，
              // 但定位回调一直在跑，此时标"无定位数据"是错的（真机已复现）。
              Text(this.report.gpsPath.length > 0 ? '定位可用' : '无定位数据')
                .fontSize(11)
                .fontColor($r('app.color.font_quaternary'))
            }
            .width('100%')

            Divider()
              .color($r('app.color.divider_color'))

            Row() {
              this.statCell(TimeUtil.formatDuration(this.report.durationSec), '时长')
              this.statCell((this.report.distanceM / 1000).toFixed(2) + ' km', '里程')
              this.statCell(`${this.report.events.length}`, '事件')
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)

          // ── 评分构成 ──
          this.breakdownCard(this.report.breakdown)

          // ── 给司机的建议 ──
          this.adviceCard()

          // ── 行驶轨迹入口：点击进入全屏地图（MapKit 真实地图 + 轨迹/事件标记）。
          //    旧版内嵌轨迹 Canvas 在大数据行程下每帧重绘导致滚动卡顿，已移除。──
          if (this.report.gpsPath.length >= 2) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.map'))
                .fontSize(22)
                .fontColor(['#0A59F7'])
                .accessibilityLevel('no')
              Column({ space: 3 }) {
                Text('行驶轨迹')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_primary'))
                Text(`点击查看地图 · ${this.report.gpsPath.length} 个点位`)
                  .fontSize(12)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.font_quaternary')])
                .accessibilityLevel('no')
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(16)
            .stateStyles({
              normal: {
                .opacity(1)
              },
              pressed: {
                .opacity(0.75)
              },
            })
            .animation({ duration: 150, curve: Curve.EaseOut })
            .onClick(() => {
              this.mapOpen = true;
            })
          }

          // ── 事件汇总（默认）/ 明细（展开） ──
          if (this.report.events.length > 0) {
            Column({ space: 10 }) {
              Row() {
                Text('驾驶事件')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(this.showAll ? '收起' : `查看全部 ${this.report.events.length} 条`)
                  .fontSize(12)
                  .fontColor('#0A59F7')
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .backgroundColor('#140A59F7')
                  .borderRadius(10)
                  .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.94 })
                  .onClick(() => {
                    this.showAll = !this.showAll;
                  })
              }
              .width('100%')

              if (!this.showAll) {
                // 汇总：每种行为一行（总次数 / 总扣分 / 豁免）
                ForEach(this.summaries, (s: EventSummary) => {
                  Row({ space: 8 }) {
                    Text(s.name)
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.font_primary'))
                      .width(64)
                    if (s.exemptCount > 0) {
                      Text(`豁免 ${s.exemptCount} 次`)
                        .fontSize(11)
                        .fontColor('#FF9800')
                    } else {
                      Text(`${s.count} 次`)
                        .fontSize(12)
                        .fontColor($r('app.color.font_secondary'))
                    }
                    Blank()
                    Text(s.points > 0 ? `-${Math.round(s.points * 10) / 10} 点` : '不计分')
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(s.points > 0 ? '#F44336' : $r('app.color.font_quaternary'))
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                  .backgroundColor($r('app.color.card_bg'))
                  .borderRadius(10)
                }, (s: EventSummary) => `${s.name}`)

                Row() {
                  Text(`有效 ${this.validCount()} 次 · 豁免 ${this.exemptCount()} 次 · 累计扣 ${this.totalPoints()} 点`)
                    .fontSize(12)
                    .fontColor($r('app.color.font_secondary'))
                }
                .width('100%')
              } else {
                // 明细：普通 ForEach 随外层 Scroll 统一滚动。
                // 旧版内嵌 List + LazyForEach 形成双层滚动链（手势在外层/内层间切换
                // 还叠加双层 Spring 回弹），sheet 内实测上滑卡顿；明细本就是报告
                // 最后一节，行结构简单（圆点+4 个文本），几百行一次性创建开销可忽略。
                ForEach(this.report.events, (e: DrivingEvent) => {
                  this.detailRow(e)
                }, (e: DrivingEvent) => `${e.time}-${e.name}-${e.level}-${e.excluded}`)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          if (this.report.events.length === 0) {
            Text('本次行程没有记录到驾驶事件')
              .fontSize(13)
              .fontColor($r('app.color.font_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      // 弹性回弹：detents 已单档（无拖拽换档重排），Spring 不再引发卡顿
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // SELF_FIRST：内容滚到边界后手势交给 sheet——顶部继续下拉可关闭弹层，
      // 否则下滑关闭手势只作用于 dragBar 一条缝，操作区过小
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST,
      })
      }

      // 隐藏海报画布：必须挂载到组件树，getPixelMap 才能取到像素；
      // 放在 Stack 底层与内容重叠，不占用 Column 布局空间（避免挤压 Scroll 导致内容裁切）
      Canvas(this.posterCtx)
        .width(POSTER_W)
        .height(POSTER_H)
        .visibility(Visibility.Hidden)
    }
    .width('100%')
    .height('100%')
    // 全屏轨迹地图（二级界面）：点击"行驶轨迹"进入，模态全覆盖报告弹窗
    .bindContentCover(this.mapOpen, this.mapBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => {
        this.mapOpen = false;
      },
    })
  }

  /** 全屏轨迹地图内容（外层必须包容器，直接返回自定义组件会导致弹层不显示） */
  @Builder
  mapBuilder() {
    Column() {
      TrackMapPage({
        report: this.report,
        onClose: () => {
          this.mapOpen = false;
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 给司机的建议卡：按有效事件密度生成的改进点（无事件给正面认证）。
   * 端侧无免费文本总结模型（HMS 仅提供 NLP 实体抽取/语音/视觉），规则引擎
   * 结果确定、离线可用，且文案与 App 的吐槽风格一致。
   */
  @Builder
  adviceCard() {
    Column({ space: 12 }) {
      Row() {
        Text('给司机的建议')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('按事件密度生成')
          .fontSize(12)
          .fontColor($r('app.color.font_tertiary'))
      }
      .width('100%')

      ForEach(this.advices, (a: DriveAdvice) => {
        Row({ space: 12 }) {
          Text(a.icon)
            .fontSize(24)
          Column({ space: 3 }) {
            Text(a.title)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.font_primary'))
            Text(a.detail)
              .fontSize(13)
              .lineHeight(19)
              .fontColor($r('app.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding(12)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(12)
      }, (a: DriveAdvice) => a.title)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  /** 明细行：时间 + 名称 + 等级 + 点数/豁免 */
  @Builder
  detailRow(e: DrivingEvent) {    Row({ space: 10 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(this.eventColor(e))
        // 颜色圆点仅作视觉分级，语义已由后文「Lv/已豁免/-N 点」文本表达
        .accessibilityLevel('no')
      Text(this.eventTime(e))
        .fontSize(12)
        .fontColor($r('app.color.font_tertiary'))
        .width(52)
      Text(e.name)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(e.excluded ? $r('app.color.font_tertiary') : $r('app.color.font_primary'))
      Text(`Lv${e.level}`)
        .fontSize(11)
        .fontColor($r('app.color.font_quaternary'))
      if (e.excluded) {
        Text('已豁免')
          .fontSize(10)
          .fontColor('#FF9800')
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor('#1AFF9800')
          .borderRadius(5)
      }
      Blank()
      Text(e.excluded ? '—' : `-${e.ded} 点`)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(e.excluded ? $r('app.color.font_quaternary') : '#F44336')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  statCell(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.font_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.font_tertiary'))
    }
    .layoutWeight(1)
  }

  /** 评分构成卡片：三维得分条形 + 置信度 + 豁免统计（旧数据无 breakdown 时不显示） */
  @Builder
  breakdownCard(bd: ScoreBreakdown | undefined) {
    if (bd !== undefined) {
      Column({ space: 12 }) {
        Row() {
          Text('评分构成')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('检测结束后综合计算')
            .fontSize(12)
            .fontColor($r('app.color.font_tertiary'))
        }
        .width('100%')

        this.scoreBar('事件密度', bd.evScore, '70%')
        this.scoreBar('平稳巡航', bd.rmsScore, '15%')
        this.scoreBar('强度峰值', bd.ctrlScore, '15%')

        Row() {
          Text(`有效事件 ${bd.effectiveCount} 次 · 路况豁免 ${bd.exemptCount} 次`)
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
          Blank()
          Text(bd.confidence >= 1 ? '样本充分' : '样本不足 · 仅供参考')
            .fontSize(12)
            .fontColor(bd.confidence >= 1 ? $r('app.color.font_tertiary') : '#FF9800')
        }
        .width('100%')

        if (bd.pointsPerKm !== undefined) {
          Row() {
            Text(`每公里事件点数 ${bd.pointsPerKm}`)
              .fontSize(12)
              .fontColor($r('app.color.font_tertiary'))
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  scoreBar(label: string, value: number, weight: string) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(13)
          .fontColor($r('app.color.font_secondary'))
        Text(`权重 ${weight}`)
          .fontSize(11)
          .fontColor($r('app.color.font_quaternary'))
        Blank()
        Text(`${value}`)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
      }
      .width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(8)
          .borderRadius(4)
          .backgroundColor($r('app.color.track_bg'))
        Row()
          .width(`${Math.min(Math.max(value, 0), 100)}%`)
          .height(8)
          .borderRadius(4)
          .backgroundColor(value >= 88 ? '#00C853' : (value >= 65 ? '#FF9800' : '#F44336'))
      }
      .width('100%')
      .height(8)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private startTimeText(): string {
    return TimeUtil.formatTime(this.report.startTime);
  }

  private endTimeText(): string {
    return TimeUtil.formatTime(this.report.endTime);
  }

  /** 生成海报 JPEG 并写入缓存目录，返回文件路径 */
  private async writePosterFile(): Promise<string> {
    const data: PosterData = PosterGenerator.getInstance().build(this.report);
    PosterGenerator.getInstance().draw(this.posterCtx, data, POSTER_W, POSTER_H);
    const pm: image.PixelMap = this.posterCtx.getPixelMap(0, 0, POSTER_W, POSTER_H);
    const packer: image.ImagePacker = image.createImagePacker();
    let file: fs.File | undefined = undefined;
    try {
      const options: image.PackingOption = { format: 'image/jpeg', quality: 95 };
      const buf: ArrayBuffer = await packer.packToData(pm, options);
      const ctx: common.UIAbilityContext = GlobalContext.getInstance().getContext();
      const path: string = `${ctx.cacheDir}/poster_${this.report.id}.jpg`;
      file = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.write(file.fd, buf);
      return path;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'writePosterFile failed: %{public}s', JSON.stringify(e));
      throw new Error('poster write failed');
    } finally {
      // PixelMap / ImagePacker / 文件句柄均需显式释放，异常路径也要保证释放；
      // 释放动作自身也可能抛异常，逐项兜住以免掩盖原始错误。
      try {
        await pm.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'pixelMap release failed: %{public}s', JSON.stringify(e));
      }
      try {
        await packer.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'packer release failed: %{public}s', JSON.stringify(e));
      }
      if (file !== undefined) {
        try {
          await fs.close(file);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'file close failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /**
   * 清理过期海报：每次分享都会在 cacheDir 落一个 poster_<id>.jpg，
   * 系统不会主动回收，长期分享会持续累积。删除 mtime 超过 MAX_POSTER_AGE_SEC
   * 的旧文件；刚写入的本张 mtime 为当前时间，且被 keepPath 显式排除，不受影响。
   */
  private async purgeStalePosters(dir: string, keepPath: string): Promise<void> {
    let names: string[] = [];
    try {
      names = await fs.listFile(dir);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listFile failed: %{public}s', JSON.stringify(e));
      return;
    }
    const nowSec: number = Math.floor(Date.now() / 1000);
    for (const name of names) {
      if (!name.startsWith('poster_') || !name.endsWith('.jpg')) {
        continue;
      }
      const p: string = `${dir}/${name}`;
      if (p === keepPath) {
        continue;
      }
      try {
        const st: fs.Stat = await fs.stat(p);
        if (nowSec - st.mtime > MAX_POSTER_AGE_SEC) {
          await fs.unlink(p);
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'purge %{public}s failed: %{public}s', name, JSON.stringify(e));
      }
    }
  }

  private async sharePoster(): Promise<void> {
    if (this.sharing) {
      return;
    }
    this.sharing = true;
    try {
      const path: string = await this.writePosterFile();
      const ctx: common.UIAbilityContext = GlobalContext.getInstance().getContext();
      // build() 结果复用一份，避免为取文案再算一遍
      const data: PosterData = PosterGenerator.getInstance().build(this.report);
      const record: systemShare.SharedRecord = {
        utd: 'general.jpeg',
        uri: fileUri.getUriFromPath(path),
        title: '老司机评分海报',
        description: PosterGenerator.getInstance().textOf(data),
      };
      const sharedData: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
      const options: systemShare.ShareControllerOptions = {};
      await this.purgeStalePosters(ctx.cacheDir, path);
      await controller.show(ctx, options);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'sharePoster failed: %{public}s', JSON.stringify(e));
      try {
        this.getUIContext().getPromptAction().showToast({ message: '分享失败，请重试' });
      } catch (te) {
        hilog.warn(DOMAIN, TAG, 'showToast failed: %{public}s', JSON.stringify(te));
      }
    } finally {
      this.sharing = false;
    }
  }
}
