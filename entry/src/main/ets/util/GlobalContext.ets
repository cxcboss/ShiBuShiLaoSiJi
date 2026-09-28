import { common } from '@kit.AbilityKit';

/**
 * 全局上下文持有者：EntryAbility 启动时写入 UIAbilityContext，
 * 供各服务（存储/定位/后台任务）获取上下文。
 */
export class GlobalContext {
  private static instance: GlobalContext = new GlobalContext();
  private abilityContext: common.UIAbilityContext | undefined = undefined;
  private autoStart: boolean = false;
  private autoStopMs: number = 0;

  static getInstance(): GlobalContext {
    return GlobalContext.instance;
  }

  setContext(context: common.UIAbilityContext): void {
    this.abilityContext = context;
  }

  /**
   * 取 UIAbilityContext。
   * 此前直接 `as common.UIAbilityContext` 把 undefined 也断言成非空，
   * 一旦在 onCreate 之前被调用只会在调用点抛出难以定位的空引用；
   * 改为显式校验，失败信息直接指出根因。
   */
  getContext(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | undefined = this.abilityContext;
    if (ctx === undefined) {
      throw new Error('GlobalContext.context 未初始化：setContext 必须在 EntryAbility.onCreate 中调用');
    }
    return ctx;
  }

  setAutoStart(v: boolean): void {
    this.autoStart = v;
  }

  getAutoStart(): boolean {
    return this.autoStart;
  }

  setAutoStopMs(v: number): void {
    this.autoStopMs = v;
  }

  getAutoStopMs(): number {
    return this.autoStopMs;
  }
}
