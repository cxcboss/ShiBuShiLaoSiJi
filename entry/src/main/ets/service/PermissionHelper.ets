import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'PermissionHelper';

/** 定位授权申请结果 */
export interface LocationGrants {
  /** 至少获得大致定位（可开始检测） */
  allowed: boolean;
  /** 精确定位（APPROXIMATELY_LOCATION + LOCATION 同时授予） */
  precise: boolean;
  /** 后台定位（LOCATION_IN_BACKGROUND） */
  background: boolean;
}

const PERM_APPROX: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
const PERM_EXACT: Permissions = 'ohos.permission.LOCATION';
const PERM_BG: Permissions = 'ohos.permission.LOCATION_IN_BACKGROUND';

/**
 * 可由系统弹窗申请的定位权限。
 * LOCATION_IN_BACKGROUND 刻意不在此列：它只能由定位弹窗里的「始终允许」选项带出，
 * 一旦混进 requestPermissionsFromUser 的列表，整批请求会被系统判为无效——
 * 真机表现为 authResults 全为 2、3ms 内返回、完全不弹框，
 * 于是检测功能在权限其实已授予的情况下也永远起不来。
 */
const REQUESTABLE: Array<Permissions> = [PERM_APPROX, PERM_EXACT];
const ALL_LOCATION: Array<Permissions> = [PERM_APPROX, PERM_EXACT, PERM_BG];

/**
 * 定位权限辅助：官方契约要求 LOCATION 与 APPROXIMATELY_LOCATION 必须同时申请。
 * 授予与否一律以 checkAccessToken 的查询结果为真值——requestPermissionsFromUser
 * 对"曾被拒绝过"的申请不再弹框、直接返回，其返回值无法区分首次与永久拒绝。
 */
export class PermissionHelper {
  /** 查询本应用当前的定位授予状态（只读，不弹窗） */
  private static async grantedSet(): Promise<Set<string>> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId: number = info.appInfo.accessTokenId;
    const granted: Set<string> = new Set();
    for (const perm of ALL_LOCATION) {
      try {
        const status: abilityAccessCtrl.GrantStatus = await atManager.checkAccessToken(tokenId, perm);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          granted.add(perm);
        }
      } catch (e) {
        // 12100001：tokenID 非法。查不到状态时按未授予处理，不能假定已授权。
        hilog.warn(DOMAIN, TAG, 'checkAccessToken %{public}s failed: %{public}s', perm, JSON.stringify(e));
      }
    }
    hilog.info(DOMAIN, TAG, 'granted set: %{public}s', JSON.stringify(Array.from(granted)));
    return granted;
  }

  static async requestLocationGrants(context: common.UIAbilityContext): Promise<LocationGrants> {
    let granted: Set<string> = await PermissionHelper.grantedSet();

    if (!granted.has(PERM_APPROX)) {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      try {
        const res: PermissionRequestResult =
          await atManager.requestPermissionsFromUser(context, REQUESTABLE);
        hilog.info(DOMAIN, TAG, 'requestPermissionsFromUser authResults=%{public}s dialogShown=%{public}s',
          JSON.stringify(res.authResults), JSON.stringify(res.dialogShownResults ?? []));
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'requestPermissionsFromUser failed: %{public}s', JSON.stringify(e));
      }
      granted = await PermissionHelper.grantedSet();
    }

    if (!granted.has(PERM_APPROX)) {
      // 用户此前已拒绝过，系统不会再弹框；不引导到设置页就只能卸载重装，
      // 检测功能等于永久关闭。
      hilog.warn(DOMAIN, TAG, 'location still absent, guiding to system settings');
      granted = await PermissionHelper.grantViaSettings(context, granted);
    }

    const approx: boolean = granted.has(PERM_APPROX);
    const exact: boolean = granted.has(PERM_EXACT);
    const bg: boolean = granted.has(PERM_BG);
    hilog.info(DOMAIN, TAG, 'final grants: approx=%{public}s exact=%{public}s background=%{public}s',
      `${approx}`, `${exact}`, `${bg}`);
    return {
      allowed: approx || exact,
      precise: approx && exact,
      background: bg,
    };
  }

  /** 系统「前往设置」授权引导；用户取消则返回引导前的状态 */
  private static async grantViaSettings(context: common.UIAbilityContext,
    before: Set<string>): Promise<Set<string>> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      await atManager.requestPermissionOnSetting(context, REQUESTABLE);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'requestPermissionOnSetting failed: %{public}s', JSON.stringify(e));
    }
    const after: Set<string> = await PermissionHelper.grantedSet();
    return after.has(PERM_APPROX) ? after : before;
  }
}
