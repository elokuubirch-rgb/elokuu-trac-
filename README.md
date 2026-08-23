# 一生足迹（LifeFootprints / Tracé）

一款本地优先的 iOS 足迹与照片回顾应用。它把照片 GPS、低功耗定位、连续 CSV 轨迹，以及 Apple Watch / iPhone 的锻炼路线统一到一张地图中，同时保留每条数据的来源和会话边界。

> This is not a map of the city. This is a map of me.

## 当前能力

- 照片位置：读取相册 GPS，按地图缩放级别聚合，并支持按地点回顾照片。
- 自动足迹：使用系统访问监测和重大位置变化低功耗留点，不提供持续高精度手动录制。
- 锻炼路线：从 HealthKit 增量同步 Apple Watch / iPhone Workout Route，保留 Workout、Route 和真实时间断层。
- CSV：自动识别列和时间格式；连续、足够密集的点识别为 imported 轨迹，稀疏旅行地点仍显示为普通足迹点。
- 来源冲突：同时段、同路线的 HealthKit / Core Location / imported 数据按质量和优先级择优显示；关闭胜出来源图层时，被抑制的原始路线自动恢复。
- 地图与回顾：照片点、普通足迹、自动轨迹和锻炼路线分层显示，支持时间筛选、主题、统计和照片回顾。
- 数据操作：CSV 导入、CSV 备份导出、重新扫描相册、清空本地数据。

## Apple 健康同步

设置页提供“自动同步苹果健康”开关、立即同步入口、最近成功时间、待重试/失败/无路线计数和错误状态。

- 首次开启需要在真机上授权读取锻炼与锻炼路线。
- 自动同步使用 HealthKit observer query 和 anchored query；锻炼新增或变化后执行增量拉取。
- 暂时查不到路线时采用指数退避。锻炼结束至少 7 天且累计确认 8 次后才标记为“无路线”；手动同步仍可重新检查。
- 模拟器不能完成真实 HealthKit 路线与后台投递验收，相关行为必须在有 Apple Health 数据的真机上确认。

## 技术结构

```text
├── LifeFootprints.xcodeproj
├── LifeFootprints/
│   ├── CoreLogic/       # 无 iOS UI 依赖的领域逻辑
│   ├── Models/          # SwiftData 模型与主题
│   ├── Services/        # HealthKit、定位、相册、导入导出、轨迹仓库
│   ├── Views/           # 地图、回顾、统计、设置与导入界面
│   └── LifeFootprintsApp.swift
├── LifeFootprintsTests/ # XCTest 逻辑、策略、缓存与性能测试
├── LifeFootprintsUITests/ # XCUITest 设置页冒烟测试
├── Tests/main.swift     # 可在 macOS 运行的 CoreLogic 回归套件
└── Package.swift
```

轨迹数据流为：原始点 → `TrajectorySample` → `TrajectoryBuilder` 会话/分段 → `TrajectoryConflictResolver` 冲突解析 → 地图图层与 `TrailIndex`。SwiftData 保存原始记录，显示层抑制不会删除原始点。

## 环境与运行

- Xcode 16 或更新版本
- iOS 17.0 或更新版本
- HealthKit 路线同步需要已配对、已开启开发者模式的真机

打开 `LifeFootprints.xcodeproj`，选择 `LifeFootprints` shared scheme 和目标设备后运行。首次使用按需授权照片、定位和健康数据。

## 测试

运行跨平台核心逻辑回归：

```bash
swift run --scratch-path /tmp/life-footprints-spm FootprintTests
```

运行 iOS XCTest 与 XCUITest：

```bash
xcodebuild \
  -project LifeFootprints.xcodeproj \
  -scheme LifeFootprints \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

测试范围包括 CSV 解析、地图聚合、轨迹建模与边界、来源冲突和图层回退、HealthKit 重试策略、imported 轨迹识别、缓存失效、时间窗口性能剪枝，以及设置页同步控件可达性。

## 隐私

足迹、照片索引、锻炼路线和同步状态只保存在本机 SwiftData / UserDefaults 中。应用无账号、无自建服务器上传、无广告。系统权限可随时在 iOS 设置中关闭；关闭应用内自动健康同步时，也会关闭对应的 HealthKit 后台投递。

## 审计

本轮轨迹与 HealthKit 收尾的实现、验证证据、已知边界和人工验收步骤见 [`AUDIT_REPORT_2026-08-23.md`](AUDIT_REPORT_2026-08-23.md)。
