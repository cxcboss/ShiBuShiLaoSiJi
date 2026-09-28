import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalContext } from '../util/GlobalContext';
import { DrivingReport } from '../model/DrivingReport';

const DOMAIN: number = 0x0000;
const TAG: string = 'ReportRepository';

const DB_NAME: string = 'drive_reports.db';
const TABLE: string = 'reports';
const KEY_ID: string = 'id';
const KEY_JSON: string = 'json';
const KEY_CREATE_TIME: string = 'createTime';
const MAX_KEEP: number = 50;

/**
 * 历史报告仓库：关系型数据库单表存储，每行一条报告的 JSON。
 */
export class ReportRepository {
  private static instance: ReportRepository = new ReportRepository();
  private store: relationalStore.RdbStore | undefined = undefined;
  /** 缓存 init 的 Promise，避免 save/loadAll 并发时重复建库建表 */
  private initPromise: Promise<void> | undefined = undefined;

  static getInstance(): ReportRepository {
    return ReportRepository.instance;
  }

  async init(): Promise<void> {
    if (this.store !== undefined) {
      return;
    }
    if (this.initPromise === undefined) {
      this.initPromise = this.doInit();
    }
    return this.initPromise;
  }

  private async doInit(): Promise<void> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        // 报告含 GPS 轨迹与车速等敏感位置数据，按数据安全定级至少 S2
        securityLevel: relationalStore.SecurityLevel.S2,
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
      const createSql: string =
        `CREATE TABLE IF NOT EXISTS ${TABLE} (` +
        `${KEY_ID} INTEGER PRIMARY KEY AUTOINCREMENT, ` +
        `${KEY_JSON} TEXT, ` +
        `${KEY_CREATE_TIME} INTEGER)`;
      await store.executeSql(createSql);
      this.store = store;
    } catch (e) {
      // 失败后清空，允许下次调用重试
      this.initPromise = undefined;
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 保存报告，返回新记录 id */
  async save(report: DrivingReport): Promise<number> {
    await this.init();
    if (this.store === undefined) {
      return -1;
    }
    try {
      const row: relationalStore.ValuesBucket = {
        json: JSON.stringify(report),
        createTime: report.startTime,
      };
      const rowId: number = await this.store.insert(TABLE, row);
      // 入库 JSON 在 insert 前序列化，其中 id 仍为旧值；此处仅回写内存对象，
      // 读取时 loadAll 统一以数据库自增 id 为准（HistoryPage ForEach 依赖唯一 id）
      report.id = rowId;
      await this.trim();
      return rowId;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', JSON.stringify(e));
      return -1;
    }
  }

  /** 加载全部历史（按创建时间倒序） */
  async loadAll(): Promise<DrivingReport[]> {
    await this.init();
    const result: DrivingReport[] = [];
    if (this.store === undefined) {
      return result;
    }
    let rs: relationalStore.ResultSet | undefined = undefined;
    try {
      const sql: string = `SELECT * FROM ${TABLE} ORDER BY ${KEY_CREATE_TIME} DESC`;
      rs = await this.store.querySql(sql);
      while (rs.goToNextRow()) {
        const dbId: number = rs.getLong(0);
        const json: string = rs.getString(1);
        try {
          const parsed = JSON.parse(json) as DrivingReport;
          // 用数据库自增 id，旧数据 JSON 里的 id 可能为 0（ForEach 键需唯一）
          parsed.id = dbId;
          result.push(parsed);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'loadAll skip corrupt row id=%{public}d: %{public}s',
            dbId, JSON.stringify(e));
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadAll failed: %{public}s', JSON.stringify(e));
    } finally {
      // ResultSet 必须显式关闭，否则泄漏；即使中途异常也要保证释放
      if (rs !== undefined) {
        try {
          rs.close();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'loadAll close failed: %{public}s', JSON.stringify(e));
        }
      }
    }
    return result;
  }

  /** 按 id 删除单条 */
  async removeById(id: number): Promise<void> {
    await this.init();
    if (this.store === undefined || id <= 0) {
      return;
    }
    try {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE);
      predicates.equalTo(KEY_ID, id);
      await this.store.delete(predicates);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'removeById failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清空全部历史 */
  async removeAll(): Promise<void> {
    await this.init();
    if (this.store === undefined) {
      return;
    }
    try {
      const sql: string = `DELETE FROM ${TABLE}`;
      await this.store.executeSql(sql);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'removeAll failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清理超量记录，保留最近 MAX_KEEP 条 */
  private async trim(): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    try {
      const sql: string = `DELETE FROM ${TABLE} WHERE ${KEY_ID} NOT IN ` +
        `(SELECT ${KEY_ID} FROM ${TABLE} ORDER BY ${KEY_CREATE_TIME} DESC LIMIT ${MAX_KEEP})`;
      await this.store.executeSql(sql);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'trim failed: %{public}s', JSON.stringify(e));
    }
  }
}
