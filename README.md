# 是不是老司机（ShiBuShiLaoSiJi）

一款基于 HarmonyOS 的驾驶舒适度检测应用：驾车时把手机平放在车内，通过加速度计与陀螺仪实时识别驾驶事件，行程结束后给出 0–100 分的驾驶舒适度评分，并生成包含行驶轨迹与事件时间线的完整报告。

![Platform](https://img.shields.io/badge/platform-HarmonyOS-blue) ![Language](https://img.shields.io/badge/language-ArkTS-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## ✨ 功能特性

- **驾驶事件识别**：基于加速度计 + 陀螺仪的实时检测，识别急加速、急减速、急转向、顿挫、摇摆等事件，并自动豁免路面颠簸带来的干扰。
- **零干扰检测**：检测过程中只记录事件、不显示分数，避免驾驶分心；行程结束后一次性出分。
- **三维综合评分**：按「事件密度 · 平稳巡航 · 操控」三个维度计算 0–100 分驾驶舒适度评分。
- **完整行程报告**：包含行驶轨迹、事件时间线与评分构成，支持一键生成海报并分享。
- **实况窗（Live View）**：检测中发布常驻实况窗，退后台/锁屏后仍可查看检测时长与事件计数，点击一键回到应用。
- **后台持续检测**：通过长时任务 + 后台定位保障检测在应用退后台后不中断。
- **姿态校准**：支持手机在车内不同摆放姿态下的重力方向校准。
- **历史记录**：本地持久化每次行程报告，可随时回顾对比。
- **个性化设置**：检测灵敏度、主题等可配置项。

## 🧩 工作原理

```
传感器采集（加速度计 / 陀螺仪）
        │
        ▼
姿态校准（OrientationCalibrator）
        │
        ▼
检测引擎（DetectionEngine）── 事件识别 + 路面颠簸豁免
        │
        ▼
评分引擎（ScoringEngine）── 事件密度 / 平稳巡航 / 操控 三维评分
        │
        ▼
行程报告（ReportRepository）── 轨迹 + 事件时间线 + 评分构成
        │                     └─ 海报生成与分享（PosterGenerator）
        ▼
实况窗 / 长时任务（后台持续展示与定位）
```

## 🛠 技术栈

- **语言 / UI**：ArkTS + ArkUI 声明式开发范式，应用层组件遵循 HDS 设计（`@kit.UIDesignKit`）
- **系统版本**：compatibleSdkVersion `6.1.0(23)`，targetSdkVersion `6.1.1(24)`
- **模块结构**：单模块（entry）工程，约 4000 行 ArkTS 代码

| 能力 | 使用的 Kit |
|------|-----------|
| 传感器（加速度计 / 陀螺仪）、振动反馈 | `@kit.SensorServiceKit` |
| 定位与轨迹（前台 + 后台） | `@kit.LocationKit` |
| 长时任务（后台持续检测） | `@kit.BackgroundTasksKit` |
| 实况窗 / 通知 | `@kit.NotificationKit` |
| 数据持久化（Preferences / RDB） | `@kit.ArkData` |
| 文件、图片、系统分享 | `@kit.CoreFileKit` `@kit.ImageKit` `@kit.ShareKit` |
| WantAgent / Ability 管理 | `@kit.AbilityKit` |

## 🗂 项目结构

```
├── AppScope/                       # 应用级配置
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/       # 应用入口 Ability
│       │   ├── pages/              # 页面：首页 / 检测页 / 历史 / 设置
│       │   ├── components/         # 组件：报告弹层 / 心情阶段
│       │   ├── model/              # 数据模型：事件 / 报告 / 检测配置
│       │   ├── service/            # 核心服务
│       │   │   ├── DetectionEngine.ets      # 检测引擎（事件识别 + 颠簸豁免）
│       │   │   ├── ScoringEngine.ets        # 评分引擎（三维评分）
│       │   │   ├── SensorManager.ets        # 传感器采集
│       │   │   ├── LocationTracker.ets      # 定位与轨迹
│       │   │   ├── OrientationCalibrator.ets# 姿态校准
│       │   │   ├── CalibrationRecorder.ets  # 校准记录
│       │   │   ├── ContinuousTaskService.ets# 长时任务
│       │   │   ├── NotificationHelper.ets   # 实况窗 / 通知
│       │   │   ├── ReportRepository.ets     # 报告持久化
│       │   │   ├── SettingsRepository.ets   # 设置持久化
│       │   │   ├── PosterGenerator.ets      # 报告海报生成
│       │   │   └── ...
│       │   └── util/               # 工具类
│       └── resources/              # 资源文件
├── build-profile.json5             # 工程构建配置
└── oh-package.json5                # 工程依赖配置
```

## 🔨 构建运行

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（需支持 HarmonyOS 6.1 SDK）。
2. 克隆本仓库并用 DevEco Studio 打开：

   ```bash
   git clone https://github.com/cxcboss/ShiBuShiLaoSiJi.git
   ```

3. 配置签名：`File > Project Structure > Signing Configs`，勾选 **Automatically generate signature**（仓库不含签名配置，也不会包含你的签名信息）。
4. 连接真机（传感器功能需真机支持），点击 **Run** 运行。

## 🔐 权限说明

| 权限 | 用途 |
|------|------|
| `ohos.permission.ACCELEROMETER` / `GYROSCOPE` | 采集加速度与角速度数据，识别驾驶事件 |
| `ohos.permission.LOCATION` / `APPROXIMATELY_LOCATION` | 获取行驶轨迹 |
| `ohos.permission.LOCATION_IN_BACKGROUND` | 退后台后继续记录轨迹 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 长时任务，保障后台持续检测 |
| `ohos.permission.VIBRATE` | 检测开始/结束等关键节点振动反馈 |

## 📄 相关文档

- [实况窗（Live View）服务接入申请材料](liveview_application.md) — 实况窗接入的场景设计与节点设计参考

## 📄 License

[MIT](LICENSE)
