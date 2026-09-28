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

  static getInstance(): NotificationHelper {
    return NotificationHelper.instance;
  }

  /** 发布或更新检测中通知（文案未变化时跳过） */
  async publishDetecting(text: string): Promise<void> {
    if (this.published && text === this.lastText) {
      return;
    }
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
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
