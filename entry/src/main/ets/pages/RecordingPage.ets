import { common } from '@kit.AbilityKit';
import { ShowDialogSuccessResponse } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SensorManager, Vec3 } from '../service/SensorManager';
import { OrientationCalibrator, VehicleAccel } from '../service/OrientationCalibrator';
import { DetectionEngine, EngineSnapshot } from '../service/DetectionEngine';
import { CalibrationRecorder } from '../service/CalibrationRecorder';
import { ScoringEngine, ScoreResult } from '../service/ScoringEngine';
import { LocationTracker, GpsPoint } from '../service/LocationTracker';
import { ContinuousTaskService } from '../service/ContinuousTaskService';
import { VibrationHelper } from '../service/VibrationHelper';
import { NotificationHelper } from '../service/NotificationHelper';
import { SettingsRepository } from '../service/SettingsRepository';
import { ReportRepository } from '../service/ReportRepository';
import { PermissionHelper, LocationGrants } from '../service/PermissionHelper';
import { DrivingReport } from '../model/DrivingReport';
import { DrivingEvent } from '../model/DrivingEvent';
import {
  levelOf, moodOf, randomSlogan, reactionOf, sensitivityLabel, Mood, Reaction, Sensitivity
} from '../model/DetectionConfig';
import { TimeUtil } from '../util/TimeUtil';
import { GlobalContext } from '../util/GlobalContext';
import { TAB_BAR_CLEARANCE_VP, ThemeState } from '../util/ThemeState';
import { MoodStage } from '../components/MoodStage';

const TICK_MS: number = 200;
/** 启动点击后的准备倒计时：留时间把手机放稳，否则放置过程本身会被记成驾驶事件 */
const COUNTDOWN_SEC: number = 5;
const COUNTDOWN_MS: number = 1000;
/** 检测中展示的最近"乘客内心戏"条数 */
const REACTION_LIMIT: number = 4;
/** 合并同类反应时向前扫描的事件数：手持走路实测 1 秒一条，只取 4 条会全是同一句话 */
const REACTION_SCAN: number = 12;
/**
 * 运动强度包络的释放系数（每 tick 0.2s 乘一次）：快攻慢放。
 * 手一停，4s 均值会立刻跌破手持门限，不做包络表情就会在 🤳 与 🙂 之间反复跳。
 * 0.95 是用实测手晃数据回放扫参定的：手持状态占比从 52%/67% 提到 52%/78%，
 * 而平稳巡航、烂路、激烈驾驶三种合成场景的表情分布不受影响。
 */
const MOTION_DECAY: number = 0.95;

/**
 * 检测中实时反馈的一条乘客反应（由事件翻译而来，不含专业数值）。
 * 同时也是 reactionRow 的参数类型：必须按对象传参（按引用），
 * 且与 ForEach 元素同型，否则 @Builder 传参会触发 ArkTS 结构化类型限制。
 */
interface LiveReaction {
  key: string;
  emoji: string;
  text: string;
  muted: boolean;
  /** 同一句反应重复出现的次数，>1 时在行尾显示 ×N */
  count: number;
}

@ComponentV2
export struct RecordingPage {
  /** 切回本页签时自增，重新读取设置（灵敏度等） */
  @Param refreshTick: number = 0;
  /** 报告生成后回调给根容器展示（传报告对象） */
  @Param onShowReport: (report: DrivingReport) => void = () => {
  };

  @Local running: boolean = false;
  /** 启动流程进行中（权限弹窗、倒计时），用于阻断重复点击 */
  @Local starting: boolean = false;
  /** 5s 准备倒计时进行中 */
  @Local counting: boolean = false;
  /** 倒计时剩余秒数 */
  @Local countdownLeft: number = 0;
  /** 系统环境可观察状态（底部导航条高度），用于避让悬浮页签 */
  @Local sys: ThemeState = ThemeState.getInstance();
  @Local durationSec: number = 0;
  @Local distanceM: number = 0;
  /** 检测中的实时情绪（表情 + 一句话），由引擎快照的运动强度与车速推导 */
  @Local mood: Mood = moodOf(0, 0, false, 0);
  /** 最近若干条事件的趣味文案 */
  @Local reactions: LiveReaction[] = [];
  /** 新事件计数，驱动表情弹跳 */
  @Local pulseKey: number = 0;
  /** 真正惊动乘客的次数（豁免事件不计） */
  @Local alertCount: number = 0;
  @Local sensitivity: Sensitivity = 'moderate';
  @Local degraded: boolean = false;
  @Local bumpActive: boolean = false;
  @Local exemptReason: string = '已自动豁免';
  /** 近 60s 垂向颠簸次数：路况统计，不参与评分 */
  @Local roadBumpCount: number = 0;

  private scroller: Scroller = new Scroller();
  private engine: DetectionEngine = new DetectionEngine();
  private ctx: common.UIAbilityContext | undefined = undefined;
  private timer: number = -1;
  private autoStopTimer: number = -1;
  private startTs: number = 0;
  /** 最近一条事件的时间戳，用于判断是否有新事件（事件数达上限后不再增长） */
  private lastEventTs: number = 0;
  /** 运动强度包络（快攻慢放），只参与情绪推导，不显示数值 */
  private motionHeld: number = 0;
  /** 页面已销毁：倒计时 await 期间被回收时，据此放弃后续启动，避免残留传感器订阅 */
  private destroyed: boolean = false;
  /** 倒计时被用户取消 */
  private countdownAbort: boolean = false;

  aboutToAppear(): void {
    this.ctx = GlobalContext.getInstance().getContext();
    this.loadSensitivity();
    if (GlobalContext.getInstance().getAutoStart()) {
      this.start();
    }
  }

  /** 切回检测页签时刷新灵敏度等设置 */
  @Monitor('refreshTick')
  onRefreshTick(): void {
    if (this.refreshTick > 0) {
      this.loadSensitivity();
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    const wasRunning: boolean = this.running;
    this.haltAll();
    // 页面销毁时若仍在检测，落盘保留本次行程，避免整段数据静默丢失。
    // 此时不再弹报告（组件即将卸载），仅持久化。
    if (wasRunning) {
      this.persistReport(false);
    }
  }

  /** showToast 可能抛异常，统一收敛以免产生未处理异常 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(0x0000, 'RecordingPage', 'showToast failed: %{public}s', JSON.stringify(e));
    }
  }

  async loadSensitivity(): Promise<void> {
    const s: Sensitivity = await SettingsRepository.getInstance().getSensitivity();
    this.sensitivity = s;
  }

  start(): void {
    if (this.running || this.starting) {
      hilog.info(0x0000, 'RecordingPage', 'start() ignored: running=%{public}s starting=%{public}s',
        `${this.running}`, `${this.starting}`);
      return;
    }
    hilog.info(0x0000, 'RecordingPage', 'start() called, ctx=%{public}s', this.ctx !== undefined ? 'defined' : 'undefined');
    this.prepareAndStart();
  }

  private async prepareAndStart(): Promise<void> {
    hilog.info(0x0000, 'RecordingPage', 'prepareAndStart() entered');
    // 整个启动流程（含权限弹窗与倒计时）期间置位，阻断重复点击。
    // 否则权限弹窗期间二次点击会并发跑第二遍：engine.reset 清空状态，
    // 且下面的 setInterval 句柄被覆盖，旧 timer 永远无法 clear（200ms 定时器泄漏）。
    this.starting = true;
    this.countdownAbort = false;
    try {
      this.sensitivity = await SettingsRepository.getInstance().getSensitivity();
      if (this.destroyed) {
        return;
      }
      // 权限申请必须在倒计时之前：系统弹窗一压住倒计时，5 秒准备就作废了
      if (!await this.ensureLocationGrants()) {
        return;
      }
      if (!await this.runCountdown()) {
        hilog.info(0x0000, 'RecordingPage', 'countdown unfinished, start aborted');
        return;
      }
      this.beginDetection();
    } finally {
      this.starting = false;
    }
  }

  /** 定位权限按需申请：精确+后台定位是评分与轨迹的基础，未获授权不应开始 */
  private async ensureLocationGrants(): Promise<boolean> {
    if (this.ctx === undefined) {
      hilog.warn(0x0000, 'RecordingPage', 'ctx is undefined, skipping permission request');
      return true;
    }
    hilog.info(0x0000, 'RecordingPage', 'calling PermissionHelper.requestLocationGrants');
    const grants: LocationGrants = await PermissionHelper.requestLocationGrants(this.ctx);
    hilog.info(0x0000, 'RecordingPage', 'grants result: allowed=%{public}s, precise=%{public}s, background=%{public}s',
      `${grants.allowed}`, `${grants.precise}`, `${grants.background}`);
    if (!grants.allowed) {
      hilog.warn(0x0000, 'RecordingPage', 'location not allowed, aborting start');
      this.toast('需要定位权限才能开始检测，请在设置中开启后重试');
      return false;
    }
    if (!grants.precise || !grants.background) {
      hilog.warn(0x0000, 'RecordingPage', 'incomplete location grants');
      this.toast('未获完整定位权限，评分与轨迹可能受影响');
    }
    return true;
  }

  /**
   * 5 秒准备倒计时：点完按钮后有足够时间把手机放到车内摆稳。
   * 返回 false 表示没走完（用户取消或页面已销毁），调用方必须放弃启动，
   * 否则会留下无人退订的传感器订阅。
   */
  private async runCountdown(): Promise<boolean> {
    this.counting = true;
    try {
      for (let i = COUNTDOWN_SEC; i >= 1; i--) {
        this.countdownLeft = i;
        await this.sleep(COUNTDOWN_MS);
        if (this.countdownAbort || this.destroyed) {
          return false;
        }
      }
      return true;
    } finally {
      this.counting = false;
      this.countdownLeft = 0;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private cancelCountdown(): void {
    this.countdownAbort = true;
  }

  /** 倒计时走完，正式开始采集 */
  private beginDetection(): void {
    const recorder: CalibrationRecorder = CalibrationRecorder.getInstance();
    recorder.start(this.sensitivity);
    this.engine.reset(this.sensitivity);
    OrientationCalibrator.getInstance().reset();
    this.reactions = [];
    this.alertCount = 0;
    this.durationSec = 0;
    this.distanceM = 0;
    this.lastEventTs = 0;
    this.pulseKey = 0;
    this.motionHeld = 0;
    this.mood = moodOf(0, 0, false, 0);
    this.bumpActive = false;
    this.roadBumpCount = 0;
    this.startTs = Date.now();

    this.engine.setOnEvent((e: DrivingEvent): void => {
      recorder.event(e.time, e.name, e.level, e.excluded, e.speedKmh ?? 0, e.vertRatio ?? 0);
      // 被豁免的事件（路况/低速）不算惊动乘客；仅严重且计分的事件震动提醒（内部 60s 节流）
      if (!e.excluded) {
        this.alertCount++;
        if (e.level >= 6) {
          VibrationHelper.getInstance().vibrate();
        }
      }
    });

    SensorManager.getInstance().startAccel((v: Vec3): void => {
      recorder.gravity(v);
      OrientationCalibrator.getInstance().update({ x: v.x, y: v.y, z: v.z });
    });
    SensorManager.getInstance().startLinear((v: Vec3): void => {
      const cal: OrientationCalibrator = OrientationCalibrator.getInstance();
      const proj: VehicleAccel = cal.horizontalize(v.x, v.y, v.z);
      recorder.linear(v);
      recorder.projected(v.ts, proj.lateral, proj.longitudinal, proj.vertical);
      this.engine.feed(proj.lateral, proj.longitudinal, proj.vertical);
    });

    LocationTracker.getInstance().setOnUpdate((pt: GpsPoint): void => {
      const spd: number = pt.speedKmh;
      this.engine.setSpeed(spd);
      this.engine.setPosition(pt.lat, pt.lng);
      // 车体前向轴由"GPS 速度导数 × 同窗水平加速度"在线学习，手机怎么放都不影响纵轴含义
      OrientationCalibrator.getInstance().onSpeed(spd, pt.ts);
      recorder.gps(pt.ts, pt.lat, pt.lng, spd, pt.direction ?? -1, pt.accuracy ?? -1);
    });
    if (!LocationTracker.getInstance().start()) {
      this.toast('定位不可用，本次检测仅依据传感器');
    }

    if (this.ctx !== undefined) {
      ContinuousTaskService.getInstance().start(this.ctx);
      NotificationHelper.getInstance().publishDetecting('正在检测驾驶行为，结束后生成综合评分报告');
    }

    this.running = true;
    this.timer = setInterval(() => this.tick(), TICK_MS);
    // 自动停止的时长从倒计时之后起算，调试参数含义才是"检测 N 毫秒"
    const autoStopMs: number = GlobalContext.getInstance().getAutoStopMs();
    if (autoStopMs > 0) {
      this.autoStopTimer = setTimeout(() => {
        this.autoStopTimer = -1;
        if (this.running) {
          this.stop();
        }
      }, autoStopMs);
    }
  }

  private tick(): void {
    const snap: EngineSnapshot = this.engine.getSnapshot();
    const raw: number = snap.motionRms;
    this.motionHeld = raw > this.motionHeld ? raw : this.motionHeld * MOTION_DECAY;
    const mood: Mood = moodOf(this.motionHeld, snap.speedKmh, snap.speedKnown, snap.peakLevel);
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.mood = mood;
      this.distanceM = LocationTracker.getInstance().getDistance();
      this.durationSec = Math.floor((Date.now() - this.startTs) / 1000);
      this.bumpActive = snap.bumpActive;
      this.exemptReason = snap.exemptReason;
      this.roadBumpCount = snap.roadBumpCount;
    });
    this.degraded = ContinuousTaskService.getInstance().isDegraded;

    // 以"最新事件时间戳"而非"事件总数"判断是否有新事件：
    // events 达 MAX_EVENTS 上限后长度不再增长，用长度比较会让列表永久冻结。
    const evs: DrivingEvent[] = this.engine.getEvents();
    const newestTs: number = evs.length > 0 ? evs[0].time : 0;
    if (newestTs > this.lastEventTs) {
      this.lastEventTs = newestTs;
      const list: LiveReaction[] = [];
      for (let i = 0; i < evs.length && i < REACTION_SCAN && list.length < REACTION_LIMIT; i++) {
        const e: DrivingEvent = evs[i];
        const r: Reaction = reactionOf(e.name, e.level, e.excluded);
        // 同一句内心戏只占一行：手持实测 43s 能产生 39 条事件，
        // 逐条直出会刷成四行一模一样的"虚惊一场，不扣分"
        const dup: LiveReaction | undefined = list.find((x: LiveReaction) => x.text === r.text);
        if (dup !== undefined) {
          dup.count++;
          continue;
        }
        list.push({ key: `${e.time}-${e.name}`, emoji: r.emoji, text: r.text, muted: e.excluded, count: 1 });
      }
      this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseOut }, () => {
        this.reactions = list;
        this.pulseKey++;
      });
    }
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.haltAll();
    this.persistReport(true);
  }

  private haltAll(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.autoStopTimer !== -1) {
      clearTimeout(this.autoStopTimer);
      this.autoStopTimer = -1;
    }
    SensorManager.getInstance().stopAll();
    OrientationCalibrator.getInstance().reset();
    LocationTracker.getInstance().stop();
    if (this.ctx !== undefined) {
      ContinuousTaskService.getInstance().stop(this.ctx);
      NotificationHelper.getInstance().cancel();
    }
    this.engine.stop();
    this.running = false;
    this.reactions = [];
  }

  /**
   * 结算本次行程并落盘。show=true 时回调根容器弹出报告；
   * 页面销毁路径只落盘不弹窗（组件即将卸载）。
   * 必须在 haltAll() 之后调用：engine.stop()/LocationTracker.stop() 只停采集，
   * 不清空事件、里程与轨迹，结算数据仍然可读。
   */
  private async persistReport(show: boolean): Promise<void> {
    try {
      const distanceM: number = LocationTracker.getInstance().getDistance();
      const durationSec: number = Math.floor((Date.now() - this.startTs) / 1000);
      const result: ScoreResult = ScoringEngine.getInstance()
        .compute(this.engine.getEvents(), distanceM, durationSec, this.engine.getRmsH());
      const final: number = result.finalScore;
      // 标定数据带上最终分，离线才能把"原始样本 → 事件 → 分数"整条链复算一遍
      CalibrationRecorder.getInstance().stop(durationSec, distanceM, final);
      const lv = levelOf(final);
      const now: number = Date.now();
      const report: DrivingReport = {
        id: 0,
        baseScore: result.breakdown.evScore,
        finalScore: final,
        breakdown: result.breakdown,
        level: lv.label,
        levelDesc: lv.desc,
        slogan: randomSlogan(final),
        sensitivity: this.sensitivity,
        durationSec: durationSec,
        distanceM: distanceM,
        startTime: this.startTs,
        endTime: now,
        date: TimeUtil.formatDate(this.startTs),
        events: result.events,
        gpsPath: LocationTracker.getInstance().getPath().map((p: GpsPoint): [number, number] => [p.lng, p.lat]),
      };
      const id: number = await ReportRepository.getInstance().save(report);
      report.id = id;
      this.durationSec = 0;
      this.distanceM = 0;
      if (id < 0) {
        hilog.error(0x0000, 'RecordingPage', 'report persist failed, id=%{public}d', id);
        this.toast('本次报告保存失败');
      }
      if (show) {
        this.onShowReport(report);
      }
    } catch (e) {
      hilog.error(0x0000, 'RecordingPage', 'persistReport failed: %{public}s', JSON.stringify(e));
      this.toast('结算失败，本次报告未能生成');
    }
  }

  build() {
    Column() {
      if (this.counting) {
        this.countdownView()
      } else if (!this.running) {
        this.idleView()
      } else {
        this.runningView()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 5 秒准备期：环形进度 + 剩余秒数，给用户把手机放稳的时间 */
  @Builder
  countdownView() {
    Column({ space: 24 }) {
      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: COUNTDOWN_SEC - this.countdownLeft, total: COUNTDOWN_SEC, type: ProgressType.Ring })
          .width(168)
          .height(168)
          .color('#0A59F7')
          .backgroundColor($r('app.color.card_bg_light'))
          .style({ strokeWidth: 10 })
          // 读屏会把这个环念成 "3.000000"，中间的秒数 Text 已经报过数了，环只作装饰
          .accessibilityLevel('no')
        Text(`${this.countdownLeft}`)
          .fontSize(64)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0A59F7')
      }

      Text('请将手机平放在车内')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
      Text('结束就开始记录\n这几秒让手机待在车里')
        .fontSize(15)
        .fontColor($r('app.color.font_tertiary'))
        .textAlign(TextAlign.Center)
        .lineHeight(22)

      Text('取消')
        .fontSize(16)
        .fontColor('#0A59F7')
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .onClick(() => this.cancelCountdown())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
  }

  @Builder
  idleView() {
    Column() {
      // 内容区
      Column({ space: 16 }) {
        Text('🚗')
          .fontSize(56)
        Text('准备好出发了吗？')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.Center)
        Text('把手机平放固定好\n开起来它替你看，下车给你算个分')
          .fontSize(16)
          .fontColor($r('app.color.font_tertiary'))
          .textAlign(TextAlign.Center)
          .lineHeight(24)
        Row({ space: 8 }) {
          Text('当前灵敏度')
            .fontSize(13)
            .fontColor($r('app.color.font_tertiary'))
          Text(sensitivityLabel(this.sensitivity))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#0A59F7')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('#0D0A59F7')
            .borderRadius(8)
            .onClick(() => this.changeSensitivity())
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // 底部按钮区域
      Column({ space: 10 }) {
        Button(this.starting ? '正在准备…' : '开始检测')
          .width('100%')
          .height(48)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('#0A59F7')
          .borderRadius(24)
          .enabled(!this.starting)
          .onClick(() => this.start())
        Text('检测需要访问加速度计和定位权限')
          .fontSize(11)
          .fontColor($r('app.color.font_quaternary'))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .padding({
        left: 24, right: 24,
        bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()),
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 灵敏度快捷修改：官方对话框三选一 */
  private changeSensitivity(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '检测灵敏度',
      message: '灵敏度越高，越容易触发记录事件。',
      buttons: [
        { text: '轻度', color: '#0A59F7' },
        { text: '中度', color: '#0A59F7' },
        { text: '重度', color: '#0A59F7' },
      ],
    }).then(async (res: ShowDialogSuccessResponse) => {
      const opts: Sensitivity[] = ['mild', 'moderate', 'severe'];
      if (res.index >= 0 && res.index < opts.length) {
        this.sensitivity = opts[res.index];
        await SettingsRepository.getInstance().setSensitivity(this.sensitivity);
      }
    }).catch(() => {
    });
  }

  /** 路况/低速豁免的趣味说明：只说"这不是你的问题"，不解释传感器 */
  private roadLine(): string {
    const base: string = this.exemptReason === '低速工况'
      ? '低速挪车不算车技'
      : '那几下是路面的锅，不计分';
    return this.roadBumpCount > 0 ? `${base} · 颠了 ${this.roadBumpCount} 次` : base;
  }

  /** 陪伴进度：时长与里程是行程事实，不是专业数值 */
  private companionLine(): string {
    const parts: string[] = [`已同行 ${TimeUtil.formatDuration(this.durationSec)}`];
    if (this.distanceM >= 100) {
      parts.push(`${(this.distanceM / 1000).toFixed(1)} 公里`);
    }
    if (this.alertCount > 0) {
      parts.push(`惊动乘客 ${this.alertCount} 次`);
    }
    return parts.join(' · ');
  }

  @Builder
  runningView() {
    Column() {
      // 可滚动内容（带弹性）
      Scroll(this.scroller) {
        Column({ space: 18 }) {
          // 乘客状态：表情 + 一句话，检测过程中不出现任何专业数值
          MoodStage({
            emoji: this.mood.emoji,
            title: this.mood.title,
            hint: this.mood.hint,
            color: this.mood.color,
            pulseKey: this.pulseKey,
          })

          Text(this.companionLine())
            .fontSize(16)
            .fontColor($r('app.color.font_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)

          // 路况/低速豁免：用安抚的口吻，不用"豁免 N 次"这类术语
          if (this.bumpActive) {
            Row({ space: 6 }) {
              Text('🛡️')
                .fontSize(15)
              Text(this.roadLine())
                .fontSize(15)
                .fontColor('#FF9800')
            }
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor('#1AFF9800')
            .borderRadius(10)
          }

          // 乘客内心戏：事件按趣味文案滚动展示，等级/扣分数值留给报告
          Column({ space: 8 }) {
            Text(this.reactions.length > 0 ? '乘客内心戏' : '目前为止')
              .fontSize(14)
              .fontColor($r('app.color.font_quaternary'))
              .width('100%')
            if (this.reactions.length > 0) {
              ForEach(this.reactions, (r: LiveReaction) => {
                this.reactionRow(r)
              }, (r: LiveReaction) => r.key)
            } else {
              this.reactionRow({ key: 'idle', emoji: '🍵', text: '乘客还很放松', muted: false, count: 1 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 后台降级
          if (this.degraded) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
                .fontSize(16)
                .fontColor(['#FF9800'])
                .accessibilityLevel('no')
              Text('后台检测受限，已切换为前台模式')
                .fontSize(13)
                .fontColor('#FF9800')
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#1AFF9800')
            .borderRadius(8)
          }

          Text('具体数字结束后在报告里看')
            .fontSize(14)
            .fontColor($r('app.color.font_quaternary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)

      // 结束检测（固定底部，始终可见）
      Button('结束检测')
        .width('100%')
        .height(48)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .backgroundColor('#F44336')
        .borderRadius(24)
        .margin({
          left: 20, right: 20, top: 8,
          bottom: TAB_BAR_CLEARANCE_VP + this.sys.bottomInsetVp(this.getUIContext()),
        })
        .onClick(() => this.stop())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  reactionRow($$: LiveReaction) {
    Row({ space: 10 }) {
      Text($$.emoji)
        .fontSize(22)
      Text($$.text)
        .fontSize(17)
        .fontColor($$.muted ? $r('app.color.font_tertiary') : $r('app.color.font_primary'))
        .layoutWeight(1)
      if ($$.count > 1) {
        Text(`×${$$.count}`)
          .fontSize(15)
          .fontColor($r('app.color.font_quaternary'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.chip_bg'))
    .borderRadius(12)
    .transition(TransitionEffect.translate({ y: 12 })
      .combine(TransitionEffect.OPACITY)
      .animation({ duration: 280, curve: Curve.EaseOut }))
  }
}
