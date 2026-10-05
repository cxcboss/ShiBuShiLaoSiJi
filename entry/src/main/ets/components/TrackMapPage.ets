import { map, mapCommon } from '@kit.MapKit';
import { MapComponent } from '@kit.MapKit';
import { image } from '@kit.ImageKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DrivingReport } from '../model/DrivingReport';
import { DrivingEvent } from '../model/DrivingEvent';
import { TimeUtil } from '../util/TimeUtil';
import { GlobalContext } from '../util/GlobalContext';
import { ThemeState } from '../util/ThemeState';

const DOMAIN: number = 0x0000;
const TAG: string = 'TrackMapPage';

/** 事件标记上限：大头针过多会重叠盖满轨迹，只标最严重的 N 个 */
const MAX_EVENT_MARKERS: number = 12;
/** 事件小圆点图标的边长（px） */
const DOT_ICON_SIZE: number = 28;

/** 事件类型 → 标记色（ARGB），过滤 chips 上的色点与此联动 */
const EVENT_COLORS: Map<string, string> = new Map([
  ['急减速', '#E53935'],
  ['急加速', '#FB8C00'],
  ['急转向', '#8E24AA'],
  ['摇摆', '#1E88E5'],
]);

function eventColor(name: string): string {
  return EVENT_COLORS.get(name) ?? '#FF9800';
}

/** 事件坐标是否有效 */
function hasPos(e: DrivingEvent): boolean {
  return e.lat !== undefined && e.lng !== undefined && e.lat !== 0 && e.lng !== 0;
}

/** 点击地图标记弹出的详情卡内容（事件 / 起点 / 终点） */
interface PinDetail {
  /** 标题色（事件类型色 / 端点色） */
  color: string;
  title: string;
  lines: string[];
}

/**
 * 生成实心小圆点 PixelMap 作为事件标记图标（白描边）：
 * 颜色按事件类型区分（急减速红/急加速橙/急转向紫/摇摆蓝）。
 * 像素通道序为 BGRA。
 */
async function makeDotIcon(hex: string): Promise<image.PixelMap> {
  const size: number = DOT_ICON_SIZE;
  const r: number = parseInt(hex.slice(1, 3), 16);
  const g: number = parseInt(hex.slice(3, 5), 16);
  const b: number = parseInt(hex.slice(5, 7), 16);
  const buf: ArrayBuffer = new ArrayBuffer(size * size * 4);
  const view: Uint8Array = new Uint8Array(buf);
  const center: number = (size - 1) / 2;
  const radius: number = size / 2 - 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const idx: number = (y * size + x) * 4;
      const dist: number = Math.sqrt((x - center) ** 2 + (y - center) ** 2);
      if (dist <= radius - 2) {
        view[idx] = b; view[idx + 1] = g; view[idx + 2] = r; view[idx + 3] = 0xFF;
      } else if (dist <= radius) {
        view[idx] = 0xFF; view[idx + 1] = 0xFF; view[idx + 2] = 0xFF; view[idx + 3] = 0xE6;
      } else {
        view[idx + 3] = 0x00;
      }
    }
  }
  const opts: image.InitializationOptions = {
    size: { width: size, height: size },
    pixelFormat: image.PixelMapFormat.RGBA_8888,
  };
  return image.createPixelMap(buf, opts);
}

/**
 * 全屏行驶轨迹地图（二级界面，报告页点击"行驶轨迹"进入）：
 * - 首选 MapKit 真实地图：轨迹彩色线 + 起点/终点标记 + 事件点标记，支持缩放平移
 * - MapKit 初始化失败（无网络/设备不支持/服务异常）时降级为自绘示意图，
 *   与旧版报告内嵌轨迹画法一致，保证任何环境下都有轨迹可看
 * 事件点超过 50 个只保留最严重的 50 个（Marker 数量过多影响地图性能）。
 */
@ComponentV2
export struct TrackMapPage {
  @Param report: DrivingReport = {
    id: -1, baseScore: 0, finalScore: 0, level: '', levelDesc: '', slogan: '',
    sensitivity: 'moderate', durationSec: 0, distanceM: 0, startTime: 0, endTime: 0,
    date: '', events: [], gpsPath: [],
  };
  @Param onClose: () => void = () => {
  };
  /** 系统环境可观察状态（状态栏高度） */
  @Local sys: ThemeState = ThemeState.getInstance();
  /** MapKit 初始化失败：降级自绘模式 */
  @Local fallback: boolean = false;
  /** 地图加载中提示 */
  @Local loading: boolean = true;
  /** 当前事件过滤类别：'全部' 或事件名（急减速/急加速/急转向/摇摆） */
  @Local eventFilter: string = '全部';
  /** 各类别的带坐标事件数（过滤 chip 上显示） */
  @Local eventCounts: Map<string, number> = new Map<string, number>();
  /** 点击标记弹出的详情卡（事件 / 起点 / 终点）；点地图空白处关闭 */
  @Local pinDetail: PinDetail | undefined = undefined;

  private mapController: map.MapComponentController | undefined = undefined;
  /** 已添加的覆盖物引用（组件卸载时随 MapComponent 一起释放，此处仅保留强引用防回收） */
  private overlays: (map.BaseOverlay | map.TraceOverlay)[] = [];
  /** 当前在图上的事件标记（切换过滤时先全部 remove 再按类别重加） */
  private eventMarkers: map.Marker[] = [];
  /** 事件标记的位置键（切过滤移除时同步清掉反查表里的旧键） */
  private eventPosKeys: string[] = [];
  /** 事件小圆点图标缓存（按类型色各一份） */
  private dotIcons: Map<string, image.PixelMap> = new Map();
  /** 标记位置 → 详情来源键（'start'/'end'/事件下标）。markerClick 回调实例
   *  可能不带 JS 端 setTag 的值，按位置反查兜底 */
  private detailKeyByPos: Map<string, string> = new Map<string, string>();
  private mapReady: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasW: number = 340;
  private canvasH: number = 240;

  aboutToDisappear(): void {
    this.overlays = [];
    this.eventMarkers = [];
    this.eventPosKeys = [];
    this.detailKeyByPos.clear();
    this.dotIcons.clear();
    this.mapController = undefined;
    this.mapReady = false;
  }

  aboutToAppear(): void {
    // 各类别的带坐标事件数：过滤 chips 上展示，0 个的类别不显示 chip
    const counts: Map<string, number> = new Map<string, number>();
    for (const c of this.eventCategories()) {
      counts.set(c, this.report.events.filter((e: DrivingEvent): boolean => hasPos(e) && e.name === c).length);
    }
    this.eventCounts = counts;
  }

  /** 事件类别清单（与 DetectionConfig 的事件名一致） */
  private eventCategories(): string[] {
    return ['急减速', '急加速', '急转向', '摇摆'];
  }

  /** 按缓存取事件色圆点图标 */
  private async dotIconOf(name: string): Promise<image.PixelMap> {
    let pm: image.PixelMap | undefined = this.dotIcons.get(name);
    if (pm === undefined) {
      pm = await makeDotIcon(eventColor(name));
      this.dotIcons.set(name, pm);
    }
    return pm;
  }

  /** 切换事件过滤：移除当前事件标记，按类别重加（轨迹与起终点不受影响） */
  private async applyEventFilter(category: string): Promise<void> {
    if (this.eventFilter === category || this.mapController === undefined || !this.mapReady) {
      return;
    }
    this.eventFilter = category;
    this.pinDetail = undefined;
    for (const m of this.eventMarkers) {
      try {
        m.remove();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'marker remove failed: %{public}s', JSON.stringify(e));
      }
    }
    for (const k of this.eventPosKeys) {
      this.detailKeyByPos.delete(k);
    }
    this.eventMarkers = [];
    this.eventPosKeys = [];
    await this.addEventMarkers(this.mapController, category);
  }

  /** 地图初始化回调：加载轨迹与标记，异常时降级自绘 */
  private async onMapReady(controller: map.MapComponentController): Promise<void> {
    this.mapController = controller;
    // 标记点击走官方 markerClick：详情显示在底部卡片。
    // 注意：标记必须在相机动画完成后添加，动画中创建的 marker 会固定在
    // 起始视图坐标、不随相机刷新（真机验证）
    try {
      controller.on('markerClick', (m: map.Marker): void => {
        const key: string = this.markerKeyOf(m);
        this.pinDetail = key !== '' ? this.detailForKey(key) : undefined;
      });
      // 点空白收起详情卡
      controller.on('mapClick', (): void => {
        this.pinDetail = undefined;
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'click listener register failed: %{public}s', JSON.stringify(e));
    }
    try {
      const path: Array<[number, number]> = this.report.gpsPath;
      if (path.length < 2) {
        throw new Error('no gps path');
      }
      const points: mapCommon.LatLng[] = path.map((p: [number, number]): mapCommon.LatLng => {
        return { latitude: p[1], longitude: p[0] };
      });
      // 轨迹线：品牌蓝、描边观感由宽度控制（TraceOverlay 自带光晕）
      const traceParams: mapCommon.TraceOverlayParams = {
        points: points,
        width: 10,
        color: 0xE60A59F7,
      };
      const trace: map.TraceOverlay = await controller.addTraceOverlay(traceParams);
      this.overlays.push(trace);

      // 先把相机对准轨迹包围盒并等动画结束，再加标记：
      // 引擎在相机动画进行中创建的 marker 会固定在起始视图坐标、不随相机刷新，
      // 导致渲染位置与经纬度/拾取坐标错位（真机验证）。
      // padding 上边多留顶栏高度，避免贴顶图钉被返回栏遮挡
      const bounds: mapCommon.LatLngBounds = this.boundsOf(points);
      const pad: mapCommon.Padding = { left: 60, top: 220, right: 60, bottom: 120 };
      await controller.animateCameraStatus(map.newLatLngBounds(bounds, pad), 300);

      // 起点（绿"起"）/终点（红"终"）自绘图钉
      await this.addEndMarkers(controller, points);
      // 事件小圆点（按初始过滤类别，类型色区分）
      await this.addEventMarkers(controller, this.eventFilter);

      this.loading = false;
      this.mapReady = true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'map setup failed, fallback: %{public}s', JSON.stringify(e));
      this.fallback = true;
      this.loading = false;
    }
  }

  /** 信息窗/详情内容：按 tag/位置反查键生成（端点绿/红，事件类型色）。
   *  未知键返回空标题对象，由调用方判空 */
  private detailForKey(key: string): PinDetail {
    if (key === 'start') {
      return { color: '#00C853', title: '行程起点', lines: [`出发时刻 ${TimeUtil.formatTime(this.report.startTime)}`] };
    }
    if (key === 'end') {
      return { color: '#F44336', title: '行程终点', lines: [`到达时刻 ${TimeUtil.formatTime(this.report.endTime)}`] };
    }
    const idx: number = parseInt(key, 10);
    const e: DrivingEvent | undefined = isNaN(idx) ? undefined : this.report.events[idx];
    if (e === undefined) {
      return { color: '#0A59F7', title: '', lines: [] };
    }
    const lines: string[] = [];
    lines.push(`时刻 ${TimeUtil.formatTime(e.time)}（开出的第 ${TimeUtil.formatDurationCn(Math.max(0, (e.time - this.report.startTime) / 1000))}）`);
    lines.push(`等级 Lv${e.level} ${e.levelName} · 车速 ${e.speedKmh !== undefined ? `${e.speedKmh} km/h` : '未记录'}`);
    if (e.excluded) {
      lines.push(`已豁免 · 不计分${e.excludeReason !== undefined ? `（${e.excludeReason}）` : ''}`);
    } else {
      lines.push(`扣 ${e.ded} 点`);
    }
    return { color: eventColor(e.name), title: e.name, lines: lines };
  }

  private async addEndMarkers(controller: map.MapComponentController, points: mapCommon.LatLng[]): Promise<void> {
    const startMark: map.Marker = await controller.addMarker({
      position: points[0],
      icon: $r('app.media.map_start_pin'),
      anchorU: 0.5,
      anchorV: 1.0,
      clickable: true,
      title: '行程起点',
      snippet: `出发时刻 ${TimeUtil.formatTime(this.report.startTime)}`,
    });
    startMark.setTag('start');
    this.rememberMarkerKey(startMark, 'start');
    const endMark: map.Marker = await controller.addMarker({
      position: points[points.length - 1],
      icon: $r('app.media.map_end_pin'),
      anchorU: 0.5,
      anchorV: 1.0,
      clickable: true,
      title: '行程终点',
      snippet: `到达时刻 ${TimeUtil.formatTime(this.report.endTime)}`,
    });
    endMark.setTag('end');
    this.rememberMarkerKey(endMark, 'end');
    this.overlays.push(startMark, endMark);
  }

  /** 记录 marker 位置 → 详情键，供点击回调按位置反查（见 detailKeyByPos 注释） */
  private rememberMarkerKey(m: map.Marker, key: string): void {
    const p: mapCommon.LatLng = m.getPosition();
    this.detailKeyByPos.set(`${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`, key);
  }

  /**
   * 按当前过滤类别添加事件小圆点：'全部' 时只标每类最严重的合计 MAX_EVENT_MARKERS 个
   * （圆点过多会重叠盖满轨迹）；指定类别时全量标注该类事件。
   * 圆点颜色按事件类型区分，tag 存事件在 report.events 中的下标供点击详情使用。
   */
  private async addEventMarkers(controller: map.MapComponentController, category: string): Promise<void> {
    const marked: DrivingEvent[] = this.report.events.filter((e: DrivingEvent): boolean => hasPos(e));
    if (marked.length === 0) {
      return;
    }
    let picked: DrivingEvent[];
    if (category === '全部') {
      picked = marked.slice().sort((a: DrivingEvent, b: DrivingEvent): number => b.level - a.level)
        .slice(0, MAX_EVENT_MARKERS);
    } else {
      picked = marked.filter((e: DrivingEvent): boolean => e.name === category);
    }
    for (const e of picked) {
      const idx: number = this.report.events.indexOf(e);
      const marker: map.Marker = await controller.addMarker({
        position: { latitude: e.lat as number, longitude: e.lng as number },
        icon: await this.dotIconOf(e.name),
        anchorU: 0.5,
        anchorV: 0.5,
        clickable: true,
        title: e.name,
        snippet: `${TimeUtil.formatDuration(Math.max(0, (e.time - this.report.startTime) / 1000))}` +
          `${e.excluded ? ' · 已豁免' : ` · Lv${e.level}`}`,
      });
      marker.setTag(idx);
      const posKey: string = this.posKey(marker.getPosition());
      if (!this.detailKeyByPos.has(posKey)) {
        // 与起点/终点坐标重合的事件点不抢占反查键（端点优先）；
        // 只有真正登记过的键才进 eventPosKeys，避免切过滤误删端点键
        this.detailKeyByPos.set(posKey, `${idx}`);
        this.eventPosKeys.push(posKey);
      }
      this.eventMarkers.push(marker);
      this.overlays.push(marker);
    }
  }

  /** marker → 详情键：优先 getTag，读不到时按位置反查（引擎回调实例可能不带 JS 端 tag） */
  private markerKeyOf(m: map.Marker): string {
    const tag: Object = m.getTag();
    if (typeof tag === 'string' || typeof tag === 'number') {
      return `${tag}`;
    }
    try {
      return this.detailKeyByPos.get(this.posKey(m.getPosition())) ?? '';
    } catch (e) {
      return '';
    }
  }

  private posKey(p: mapCommon.LatLng): string {
    return `${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`;
  }

  private boundsOf(points: mapCommon.LatLng[]): mapCommon.LatLngBounds {
    let minLat: number = 90;
    let maxLat: number = -90;
    let minLng: number = 180;
    let maxLng: number = -180;
    for (const p of points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return {
      southwest: { latitude: minLat, longitude: minLng },
      northeast: { latitude: maxLat, longitude: maxLng },
    };
  }

    build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.fallback) {
        this.fallbackView()
      } else {        MapComponent({
          mapOptions: {
            // 地图深浅色：AUTO 跟随系统深色开关；初始位置给中国区中心，
            // 轨迹加载成功后相机会被 animateCamera 拉到轨迹包围盒
            mapType: mapCommon.MapType.STANDARD,
            dayNightMode: mapCommon.DayNightMode.AUTO,
            position: {
              target: { latitude: 34.5, longitude: 108.9 },
              zoom: 4,
            },
            zoomControlsEnabled: false,
            compassControlsEnabled: true,
          },
          mapCallback: (err: BusinessError, controller: map.MapComponentController): void => {
            if (err) {
              hilog.warn(DOMAIN, TAG, 'map init failed: %{public}s', JSON.stringify(err));
              this.fallback = true;
              this.loading = false;
              return;
            }
            this.onMapReady(controller);
          },
        })
          .width('100%')
          .height('100%')
      }

      // 顶部返回栏（贴状态栏，点击返回报告）。
      // 布局与弹窗标题栏规范一致：返回在左、标题居中、徽标在右。
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([$r('app.color.font_primary')])
        }
        .width(44)
        .height(44)
        .padding(0)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(22)
        .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.93 })
        .accessibilityText('返回报告')
        .onClick(() => this.onClose())

        Blank()

        Text('行驶轨迹')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))

        Blank()

        Text(this.fallback ? '示意图模式' : `${(this.report.distanceM / 1000).toFixed(1)} km · 点位 ${this.report.gpsPath.length}`)
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(12)
          .constraintSize({ maxWidth: 200 })
          .id('map_badge')
      }
      .width('100%')
      .padding({
        left: 8,
        right: 12,
        top: this.sys.topInsetVp(this.getUIContext()) + 4,
      })
      .alignItems(VerticalAlign.Center)
      // 标题与空白处穿透到地图（贴顶的起点图钉仍可点中），返回按钮自身拦截
      .hitTestBehavior(HitTestMode.Transparent)

      // 事件过滤 chips：事件多时按类别查看，避免圆点铺满轨迹（真实地图加载成功后才显示）
      if (!this.fallback && !this.loading && this.eventCounts.size > 0) {
        Scroll() {
          Row({ space: 8 }) {
            this.filterChip('全部')
            ForEach(this.eventCategories(), (c: string) => {
              if ((this.eventCounts.get(c) ?? 0) > 0) {
                this.filterChip(c)
              }
            }, (c: string) => c)
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: this.sys.topInsetVp(this.getUIContext()) + 56 })
      }

      // 加载中提示
      if (this.loading && !this.fallback) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#0A59F7')
          Text('正在加载地图…')
            .fontSize(14)
            .fontColor($r('app.color.font_secondary'))
        }
        .padding({ left: 24, right: 24, top: 16, bottom: 16 })
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(16)
        .alignSelf(ItemAlign.Center)
      }

      // 标记详情卡（点击起终点/事件弹出）：整层 Transparent——空白处触摸穿透到地图，
      // 卡片自身拦截；点地图空白由 mapClick 回调收起
      if (this.pinDetail !== undefined) {
        Column() {
          Blank()

          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Circle()
                .width(12)
                .height(12)
                .fill(this.pinDetail.color)
                .accessibilityLevel('no')
              Text(this.pinDetail.title)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Button() {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([$r('app.color.font_tertiary')])
              }
              .width(28)
              .height(28)
              .padding(0)
              .backgroundColor('#00000000')
              .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.9 })
              .accessibilityText('关闭详情')
              .onClick(() => {
                this.pinDetail = undefined;
              })
            }
            .width('100%')

            ForEach(this.pinDetail.lines, (l: string) => {
              Text(l)
                .fontSize(13)
                .lineHeight(19)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            }, (l: string) => l)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
          .margin({ bottom: this.sys.bottomInsetVp(this.getUIContext()) + 16 })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 过滤 chip：选中态蓝底白字，未选中中性底；类别 chip 带对应色的圆点与图上标记呼应 */
  @Builder
  filterChip(label: string) {
    Row({ space: 6 }) {
      if (label !== '全部') {
        Circle()
          .width(8)
          .height(8)
          .fill(eventColor(label))
          .accessibilityLevel('no')
      }
      Text(label === '全部' ? '全部' : label)
        .fontSize(13)
        .fontWeight(this.eventFilter === label ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.eventFilter === label ? '#FFFFFF' : $r('app.color.font_primary'))
      if (label !== '全部') {
        Text(`${this.eventCounts.get(label) ?? 0}`)
          .fontSize(11)
          .fontColor(this.eventFilter === label ? '#CCFFFFFF' : $r('app.color.font_tertiary'))
      }
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(this.eventFilter === label ? '#0A59F7' : $r('app.color.chip_bg'))
    .borderRadius(18)
    .clickEffect({ level: ClickEffectLevel.HEAVY, scale: 0.94 })
    .onClick(() => {
      this.applyEventFilter(label);
    })
  }

  private isDark(): boolean {
    const ctx = GlobalContext.getInstance().getContext();
    return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /** 降级自绘：地图服务不可用时的轨迹示意图（与旧版报告内嵌画法一致） */
  @Builder
  fallbackView() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          Text('地图服务不可用，已切换为轨迹示意图')
            .fontSize(13)
            .fontColor($r('app.color.font_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
          Canvas(this.ctx)
            .width('100%')
            .aspectRatio(this.canvasW / this.canvasH)
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.canvasW = Number(newValue.width);
              this.canvasH = Number(newValue.height);
              this.drawFallback();
            })
            .onReady(() => this.drawFallback())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 120, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
  }

  private drawFallback(): void {
    const path: Array<[number, number]> = this.report.gpsPath;
    const c: CanvasRenderingContext2D = this.ctx;
    const isDark: boolean = this.isDark();
    const mapBg: string = isDark ? '#20242B' : '#F2F5FA';
    const mapGrid: string = isDark ? '#32373F' : '#E0E6EF';
    c.clearRect(0, 0, this.canvasW, this.canvasH);
    c.fillStyle = mapBg;
    c.fillRect(0, 0, this.canvasW, this.canvasH);
    c.strokeStyle = mapGrid;
    c.lineWidth = 1;
    for (let gx = 0; gx <= this.canvasW; gx += 40) {
      c.beginPath();
      c.moveTo(gx, 0);
      c.lineTo(gx, this.canvasH);
      c.stroke();
    }
    for (let gy = 0; gy <= this.canvasH; gy += 40) {
      c.beginPath();
      c.moveTo(0, gy);
      c.lineTo(this.canvasW, gy);
      c.stroke();
    }
    if (path.length < 2) {
      return;
    }
    let minLat: number = 90;
    let maxLat: number = -90;
    let minLng: number = 180;
    let maxLng: number = -180;
    for (const p of path) {
      if (p[1] < minLat) minLat = p[1];
      if (p[1] > maxLat) maxLat = p[1];
      if (p[0] < minLng) minLng = p[0];
      if (p[0] > maxLng) maxLng = p[0];
    }
    const spanLng: number = Math.max(maxLng - minLng, 1e-6);
    const spanLat: number = Math.max(maxLat - minLat, 1e-6);
    const scale: number = Math.min((this.canvasW - 48) / spanLng, (this.canvasH - 48) / spanLat);
    const ox: number = (this.canvasW - spanLng * scale) / 2;
    const oy: number = (this.canvasH - spanLat * scale) / 2;
    const px = (lng: number): number => ox + (lng - minLng) * scale;
    const py = (lat: number): number => oy + (maxLat - lat) * scale;

    c.beginPath();
    c.moveTo(px(path[0][0]), py(path[0][1]));
    for (let i = 1; i < path.length; i++) {
      c.lineTo(px(path[i][0]), py(path[i][1]));
    }
    c.lineJoin = 'round';
    c.lineCap = 'round';
    c.strokeStyle = isDark ? '#2E343D' : '#FFFFFF';
    c.lineWidth = 7;
    c.stroke();
    c.strokeStyle = '#0A59F7';
    c.lineWidth = 4;
    c.stroke();

    this.dot(px(path[0][0]), py(path[0][1]), '#00C853');
    this.dot(px(path[path.length - 1][0]), py(path[path.length - 1][1]), '#F44336');
    for (const e of this.report.events) {
      if (hasPos(e)) {
        this.dot(px(e.lng as number), py(e.lat as number), '#FF9800');
      }
    }
  }

  private dot(x: number, y: number, color: string): void {
    const c: CanvasRenderingContext2D = this.ctx;
    const isDark: boolean = this.isDark();
    c.beginPath();
    c.arc(x, y, 6, 0, Math.PI * 2);
    c.fillStyle = isDark ? '#2E343D' : '#FFFFFF';
    c.fill();
    c.beginPath();
    c.arc(x, y, 4, 0, Math.PI * 2);
    c.fillStyle = color;
    c.fill();
  }
}
