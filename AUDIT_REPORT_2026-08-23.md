# 一生足迹轨迹与 HealthKit 收尾审计报告

- 审计日期：2026-08-23（Asia/Shanghai）
- 审计对象：`LifeFootprints` iOS App、CoreLogic、SwiftData 轨迹仓库、HealthKit 同步、Xcode 测试目标
- 审计结论：代码实现与自动化验证已完成；未发现阻断发布的已知代码缺陷。真实 HealthKit 授权、Apple Watch 新路线到达和 iOS 后台调度仍需机主在真机上完成隐私授权型验收。

## 1. 本轮范围与处置结果

| 审计项 | 处置 | 结果 |
| --- | --- | --- |
| 关闭胜出来源后的图层回退 | 在解析点记录 `suppressedBySource`，地图派生层随图层开关重算 | 已完成并测试 |
| 大数据量轨迹冲突性能 | 先按开始时间排序，以时间窗口剪枝；增加线程安全解析缓存和数据变化失效 | 已完成并基准测试 |
| HealthKit 同步状态 UI | 增加自动同步开关、同步中/开关状态、上次成功、队列计数和错误显示 | 已完成并 UI 测试 |
| 手动与自动健康同步语义 | 手动同步不再隐式开启后台 Observer；只有自动开关开启时启用后台投递 | 已完成并编译验证 |
| `noRoute` 终态 | 至少 8 次空结果且 Workout 已结束 7 天才进入终态；手动同步可强制重查 | 已完成并测试 |
| imported / CSV 轨迹 | 连续且足够长的 CSV 序列进入 `.imported` 轨迹；稀疏旅行地点仍保留为普通点 | 已完成并测试 |
| 正式测试目标 | 新增 `LifeFootprintsTests`、`LifeFootprintsUITests` 和 shared scheme | 已完成 |
| README | 更新当前能力、架构、HealthKit 行为、测试命令和隐私说明 | 已完成 |
| 真机构建与启动 | iPhone 15 Pro Max 签名构建、安装、启动、进程存活检查 | 已完成 |

## 2. 设计与数据完整性审计

### 2.1 轨迹领域边界

原始记录不会因显示冲突被删除。数据经以下单向管线进入显示层：

`FootprintPoint / WorkoutRoutePoint` → `TrajectorySample` → `TrajectoryBuilder` → `TrajectoryConflictResolver` → `FootprintSnapshot` → 地图图层 / `TrailIndex`

- Core Location、HealthKit Workout Route、imported CSV 使用明确的 `TrajectorySource`。
- Workout、Route、Session、Segment 边界保留，跨 Workout 不插值、不连线。
- 抑制仅作用于显示，解析点保留原始点 ID、被谁抑制及来源。
- 关闭 HealthKit 或自动轨迹图层时，原先被该来源压制的备用路线恢复，避免地图出现空洞。

### 2.2 imported CSV 判定

只有同时满足下列默认条件的连续分区才解释为轨迹：

- 至少 3 个有效坐标点；
- 总时长至少 60 秒；
- 累计移动至少 100 米；
- 相邻时间间隔不超过 45 分钟；
- 相邻距离不超过 3 公里。

其他 CSV 行仍以普通足迹点参与地图和统计，不会被错误强制连线。该实现复用已有 SwiftData 字段，无数据迁移风险。

### 2.3 HealthKit 状态机

- 自动模式使用 Observer Query、Anchored Query 和 immediate background delivery。
- 关闭自动同步时停止进程内 Observer，并请求系统关闭 Workout / Workout Route 后台投递。
- 手动同步执行一次全量拉取和 pending / failed / noRoute 重查，但不会改变关闭状态下的自动同步开关。
- 空路线使用 5 分钟起步、最长 24 小时的指数退避；8 次确认且结束满 7 天后进入 `noRoute`。
- 同步开始、成功、错误和路线队列状态可在设置页观察；Observer 错误也写入可见状态。

### 2.4 缓存一致性

`TrajectoryResolutionCache` 使用 `NSLock` 保护读写。CSV、HealthKit、后台足迹导入及清空数据发出 `.dataImported` 后，地图先失效缓存再重建快照。缓存只保存可由原始 SwiftData 重建的派生结果，不影响数据持久性。

## 3. 验证证据

### 3.1 CoreLogic 回归

命令：

```bash
swift run --scratch-path /private/tmp/trace-spm-closeout FootprintTests
```

结果：`139 / 139` checks passed，`0` failed。

覆盖 CSV 解析、照片地图、回顾、定位过滤、后台策略、轨迹领域边界、Workout Route 元数据、TrailIndex、来源冲突、图层回退、imported 分类和 HealthKit 重试策略。

### 3.2 XCTest 与 XCUITest

环境：iPhone 17 Pro Simulator，iOS 26.5。

结果：`6 / 6` tests passed，`0` failed，`0` skipped。

- 5 个 XCTest：图层回退、noRoute 阈值、稀疏 CSV、缓存失效、时间剪枝性能。
- 1 个 XCUITest：从统计页进入设置，确认自动健康同步开关与手动同步按钮可滚动到达。

测试结果包：

```text
/private/tmp/trace-closeout-final/Logs/Test/Test-LifeFootprints-2026.08.23_15-55-54-+0800.xcresult
```

### 3.3 性能基准

场景：1,000 条时间上互不重叠的轨迹，每条 3 个点。

- 未剪枝的理论两两组合：499,500 对；
- 实际进入空间相似度判断：0 对；
- 10 次 XCTest wall-clock 测量：平均约 7.82 ms，范围约 7.67–8.13 ms；
- 测试结果已收集性能指标，但暂未设置项目历史 baseline，因此当前是可复测证据，不是 CI 回归门禁。

### 3.4 工程、静态分析与构建

- `project.pbxproj` plist 校验：通过；
- shared scheme XML 校验：通过；
- `xcodebuild analyze`（generic iOS Simulator）：通过，无输出诊断；
- iOS Simulator `build-for-testing`：通过；
- iPhone 15 Pro Max（Birch）Debug 签名构建：通过；
- 真机安装：通过，bundle ID `com.footprints.LifeFootprints`；
- 真机前台启动：通过；启动后进程仍存活，未发生立即崩溃。

真机冒烟使用 `FP_UI_TEST=1`、`FP_TAB=2`、`FP_SKIP_LOCATION=1`，明确关闭自动 HealthKit 和后台足迹，避免测试过程读取私人健康数据或启动后台定位。完成后如需使用这些能力，需在设置页重新开启。

## 4. 隐私与安全审计

- 轨迹、Workout 元数据、照片索引和同步状态均保存在本机 SwiftData / UserDefaults。
- 未发现新增网络上传、账号体系、广告 SDK 或远程日志路径。
- HealthKit 仅请求读取 Workout 与 Workout Route，不请求写入健康数据。
- UI 测试与真机冒烟不读取健康样本，不自动接受系统授权。
- 关闭应用内自动同步会同步停止 Observer 与后台投递请求。

## 5. 未自动完成的人工验收

以下项目受 Apple 隐私授权和系统调度约束，不能由命令行替用户完成，不能据此虚报为已通过：

1. 在 Birch 上打开设置，重新开启“自动同步苹果健康”。
2. 在系统弹窗中允许读取“锻炼”和“锻炼路线”。
3. 选取一条已有路线，确认设置页上次成功时间更新、路线队列变化、地图展示 Workout 边界。
4. 用 Apple Watch 新建一条室外锻炼路线，结束后观察前台增量到达。
5. 将 App 退到后台，等待系统调度一次 Observer delivery；其具体触发时点由 iOS 决定。
6. 分别关闭“运动路线”和“自动轨迹”图层，确认重叠来源正确回退。

## 6. 剩余风险与建议

| 等级 | 风险 | 建议 |
| --- | --- | --- |
| 低 | 旧 CSV 模型没有导入批次 ID，连续性判定只能按时空阈值分区 | 未来如需要精确保留外部文件会话，可增加可选 `importBatchID` 并做轻量迁移 |
| 低 | 性能用例尚未建立历史 baseline | CI 稳定后记录基准，并按目标设备设置回归阈值 |
| 外部验收 | HealthKit 后台到达依赖真机授权、Apple Watch 数据和 iOS 调度 | 按第 5 节完成一次人工验收并记录设备/系统版本 |

## 7. 最终判定

轨迹来源建模、冲突解析、图层回退、HealthKit 同步状态、CSV 轨迹语义、终态策略、性能优化、正式测试目标、文档和真机构建均已落地。自动化范围内全部通过；当前没有已知 P0/P1 缺陷。发布前唯一必要的外部确认是一次真实 HealthKit / Apple Watch 授权型端到端验收。
