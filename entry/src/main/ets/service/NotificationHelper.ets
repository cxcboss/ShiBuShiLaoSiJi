import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalContext } from '../util/GlobalContext';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotificationHelper';

/**
 * 状态栏通知：检测过程中常驻提示，点击可回到应用。
 */
export class NotificationHelper {
  private static instance: NotificationHelper = new NotificationHelper();
  private static readonly NOTIFY_ID: number = 1001;
  private published: boolean = false;
  /** 已发布的文案，仅在变化时重新 publish，避免无意义刷新 */
  private lastText: string = '';
  private agent: WantAgent | undefined = undefined;
  /** 本次运行内是否已请求过通知授权：requestEnableNotification 只主动弹一次 */
  private enableRequested: boolean = false;

  static getInstance(): NotificationHelper {
    return NotificationHelper.instance;
  }

  /**
   * 首次检测时引导开启通知授权：应用通知默认关闭，不申请则检测中常驻通知
   * 永远发不出来。仅弹一次系统授权框；用户拒绝或此前已永久拒绝时静默跳过，
   * 不阻塞检测流程。
   */
  private async ensureEnabled(): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      if (this.enableRequested) {
        return false;
      }
      this.enableRequested = true;
      const ctx = GlobalContext.getInstance().getContext();
      if (ctx === undefined) {
        return false;
      }
      await notificationManager.requestEnableNotification(ctx);
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      // 用户拒绝（1600004）或调用条件不满足时都会抛错，按未授权处理
      hilog.warn(DOMAIN, TAG, 'ensureEnabled failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** 发布或更新检测中通知（文案未变化时跳过） */
  async publishDetecting(text: string): Promise<void> {
    if (this.published && text === this.lastText) {
      return;
    }
    try {
      const enabled: boolean = await this.ensureEnabled();
      if (!enabled) {
        return;
      }
      if (this.agent === undefined) {
        this.agent = await this.buildWantAgent();
      }
      const request: notificationManager.NotificationRequest = {
        id: NotificationHelper.NOTIFY_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: this.agent,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: '老司机', text: text },
        },
      };
      await notificationManager.publish(request);
      this.published = true;
      this.lastText = text;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'publishDetecting failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 点击通知拉起 EntryAbility；构建失败时返回 undefined，通知仍可发布只是不可点击 */
  private async buildWantAgent(): Promise<WantAgent | undefined> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: ctx.abilityInfo.bundleName,
            abilityName: ctx.abilityInfo.name,
          },
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: NotificationHelper.NOTIFY_ID,
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getWantAgent failed: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  /** 取消检测中通知 */
  async cancel(): Promise<void> {
    if (!this.published) {
      return;
    }
    try {
      await notificationManager.cancel(NotificationHelper.NOTIFY_ID);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'cancel failed: %{public}s', JSON.stringify(e));
    } finally {
      this.published = false;
      this.lastText = '';
      this.agent = undefined;
    }
  }
}
