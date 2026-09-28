import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ContinuousTaskService';

/**
 * 后台连续任务（location 模式）+ 屏幕常亮。
 * 检测开始后申请"定位导航"类长时任务，退后台/锁屏仍可持续采集传感器；
 * 被系统取消时降级为前台常亮模式，不阻断检测。
 * start/stop 通过 ops 串行化：防止快速"停止→再开始"时，旧的
 * stopBackgroundRunning 异步完成后误杀刚启动的新会话。
 */
export class ContinuousTaskService {
  private static instance: ContinuousTaskService = new ContinuousTaskService();
  private running: boolean = false;
  private degraded: boolean = false;
  private ops: Promise<void> = Promise.resolve();

  static getInstance(): ContinuousTaskService {
    return ContinuousTaskService.instance;
  }

  get isActive(): boolean {
    return this.running;
  }

  get isDegraded(): boolean {
    return this.degraded;
  }

  start(context: common.UIAbilityContext): Promise<void> {
    this.ops = this.ops.then(() => this.doStart(context));
    return this.ops;
  }

  stop(context: common.UIAbilityContext): Promise<void> {
    this.ops = this.ops.then(() => this.doStop(context));
    return this.ops;
  }

  private async doStart(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    this.degraded = false;
    await this.keepScreenOn(context, true);

    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name,
          },
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1000,
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context, ['location'], agent);
      hilog.info(DOMAIN, TAG, 'background running started');
    } catch (e) {
      this.degraded = true;
      hilog.warn(DOMAIN, TAG, 'startBackgroundRunning failed, degrade to foreground: %{public}s', JSON.stringify(e));
    }
    // 申请完成（无论成功或降级）后才置位，保证 stop 的守卫判断准确
    this.running = true;
  }

  private async doStop(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (!this.degraded) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(e));
      }
    }
    await this.keepScreenOn(context, false);
  }

  private async keepScreenOn(context: common.UIAbilityContext, on: boolean): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowKeepScreenOn(on);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setWindowKeepScreenOn failed: %{public}s', JSON.stringify(e));
    }
  }
}
