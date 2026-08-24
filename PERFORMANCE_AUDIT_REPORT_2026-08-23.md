# LifeFootprints 菜单与地图性能审计报告

日期：2026-08-23

审计基线：`5ea8e01`（`feat: complete trajectory and health sync audit`）
范围：只增加 `DEBUG` 诊断、signpost 和审计测试；未修改产品功能、业务规则或 UI 视觉

## 1. 结论

当前性能回退不是 `TrajectoryResolutionCache` 的 `NSLock`，也不是 Tab 每次销毁并重建整张地图。真实根因是：冷启动或缓存失效后，App 对 62 万级 HealthKit 路线点执行全表读取和完整轨迹管线，完成后又在主线程把大量逻辑路线展开成三层 `MKPolyline` 并逐条提交给 MapKit。真机在 `MKMapView.addOverlay` 中连续占用主线程超过系统允许的 10 秒，被 `0x8BADF00D` scene-update watchdog 终止。

造成“整个 App 都变重”的三个放大器是：

1. `HealthKitService.importChanges` 即使没有实际数据变化也会发送一次 `.dataImported`，使轨迹缓存失效并请求地图全量重载。
2. 统计页每次重新激活都启动一次完整聚合任务；41 次统计页激活产生了 41 次 `StatsCluster` 重建。
3. `TrailIndex.interpolateMatch` 对每张照片扫描全部轨迹 segment，复杂度接近 `照片数 × segment 数`；watchdog 日志确认它和 MapKit 图层提交并发运行。

最早明确引入本轮回退结构的提交是 `b574b0e`（`feat: add boundary-aware trail index`）：它在地图已经读取展示数据后，又调用 `TrajectoryRepository.load()` 全量读取并构建领域轨迹，同时把照片时间插值从二分查找改成对全部 `segments.filter`。`9fcb98e` 加入自动 HealthKit 同步和无条件通知后扩大了触发频率；`7ea1a7d` 再把冲突解析接入地图冷路径，增加了真机约 2.13 秒计算。这个判断来自提交历史和真机调用栈；本轮没有修改历史提交，也没有用私有真机数据逐提交重放。

## 2. 审计方法与限制

增加了仅在 `DEBUG` 且 `FP_PERF_DIAGNOSTICS=1` 时启用的诊断：

- `os_signpost` 事件和区间：Tab、页面生命周期、SwiftData、轨迹构建、冲突解析、TrailIndex、照片聚合、MapKit、HealthKit、`.dataImported`。
- 进程内聚合：调用次数、总耗时、最大耗时、主线程调用和 Overlay/Annotation/Polyline 数量。
- 显式审计 UI 测试：三个导航序列各 20 次；默认测试流程中跳过，只有 `FP_RUN_PERF_AUDIT=1` 才执行。
- 真机：iPhone 15 Pro Max，iOS 26.0.1，使用真实本地数据库。
- 模拟器：iPhone 17 Pro；数据为空，仅用于验证生命周期、无数据变化时的无效重算和 20 次导航自动化。

Instruments CLI 已实际尝试 Time Profiler、SwiftUI、Animation Hitches 和 Logging/signpost 四条路径。Time Profiler 与 Logging 超过 `--time-limit` 后仍不退出，产出的 52 KB 包缺少模板；SwiftUI 与 Animation Hitches 明确返回模拟器不支持，虽生成可导出包，但目录显示时长为 0、没有进程和采样轨道；真机路径还曾错误报告等待已连接设备启动。因此本报告不伪造 Instruments trace 结论。真机 watchdog 崩溃报告提供了完整主线程栈，App 内 signpost 聚合提供了阶段耗时。建议在 Xcode Instruments GUI 可稳定连接真机后复跑同一场景，作为修复后的验收对照。

## 3. 数据规模与真机冷路径

| 数据/阶段 | 数量或耗时 | 线程 | 结论 |
| --- | ---: | --- | --- |
| 领域轨迹 FootprintPoint | 104,865 行 | 后台 | 大数据集 |
| WorkoutRoutePoint | 623,384 行 | 后台 | 最大数据源 |
| WorkoutRecord | 1,154 行 | 后台 | 数量正常 |
| `SwiftData.workoutRoutePoint.fetch` | 42,031.73 ms | 后台 | P0，最慢完成区间 |
| `SwiftData.footprint.fetch` | 1,354.80–6,321.52 ms | 后台 | 冷缓存波动大 |
| `FootprintSnapshot.build` | 456.72–4,047.33 ms | 后台 | 大量模型转值类型 |
| `TrajectoryBuilder` | 4,263.95 ms | 后台 | P0 |
| `TrajectoryConflictResolver` | 2,131.17 ms | 后台 | P0，但不是唯一瓶颈 |
| `ResolvedSnapshot.build` | 206.70 ms | 后台 | 次要 |
| `TrajectoryResolutionCache.lock.get` | 0.0035–0.0224 ms | 后台 | 正常，不是根因 |
| `TrajectoryResolutionCache.lock.set` | 0.0041 ms | 后台 | 正常，不是根因 |
| `MKMapView.addOverlay` | 至少连续 10,000 ms | 主线程 | P0，watchdog 终止点 |

另一次真机退出 watchdog 显示主线程在 `HealthKitService.backfillLegacyRouteBoundaries` 的 SwiftData/Core Data 对象哈希中停留，后台同时正在 `TrajectoryRepository.load()` 为路线点分配对象。这说明自动同步的旧数据回填与地图全量读取会争用数据库、CPU 和内存。

## 4. 三组 20 次导航测试

完整 XCUITest 结果：1 个审计测试通过，0 失败，用时 346.679 秒。下表是 XCTest 从点击开始到可访问性状态/目标导航栏就绪的墙钟时间，包含测试框架同步和页面动画，不能等同于“屏幕像素首帧”。

| 场景 | 转换 | 次数 | 平均 | P95 | 最大 |
| --- | --- | ---: | ---: | ---: | ---: |
| 地图→统计→地图 | 地图→统计 | 20 | 2,545.32 ms | 2,575.78 ms | 2,580.22 ms |
| 地图→统计→地图 | 统计→地图 | 20 | 1,451.36 ms | 1,470.22 ms | 1,476.89 ms |
| 地图→设置→地图 | 地图→统计 | 20 | 1,436.82 ms | 1,455.85 ms | 1,457.86 ms |
| 地图→设置→地图 | 统计→设置 | 20 | 2,347.24 ms | 2,339.08 ms | 3,171.20 ms |
| 地图→设置→地图 | 设置→统计 | 20 | 2,236.06 ms | 2,258.03 ms | 2,258.10 ms |
| 地图→设置→地图 | 统计→地图 | 20 | 1,435.67 ms | 1,455.77 ms | 1,461.55 ms |
| 地图→设置→地图 | 整体往返 | 20 | 7,455.83 ms | 7,469.11 ms | 8,286.03 ms |
| 统计→设置→统计 | 统计→设置 | 20 | 2,299.18 ms | 2,331.85 ms | 2,336.48 ms |
| 统计→设置→统计 | 设置→统计 | 20 | 2,233.56 ms | 2,250.04 ms | 2,253.63 ms |

App 内“Tab 状态改变到下一次主队列提交”代理值，在空数据模拟器中为：地图→统计平均 5.92 ms、最大 13.31 ms；统计→地图平均 6.86 ms、最大 10.20 ms。它证明稳定状态下 Tab 自身并不慢，但不代表 Core Animation 已真正显示下一帧。真实数据设备没有完成稳态 20 次测试：地图内容提交前即被 watchdog 杀死。

## 5. 调用次数与合理性

模拟器自动场景共发生 81 次 Tab 选择变化。

| 操作 | 调用 | 次数 | 主线程耗时 | 是否合理 |
| --- | --- | ---: | ---: | --- |
| 81 次 Tab 切换 | `MapScreen.init`（SwiftUI 值重建） | 86 | 未单独计时 | 可接受，但说明根 View 失效范围较大 |
| 81 次 Tab 切换 | `MapScreen.body` | 89 | 未单独计时 | 偏多；当前 body 本身不是 P0 |
| 全部场景 | `MapScreen.onAppear` | 1 | — | 正常，状态页未被反复挂载 |
| 全部场景 | `MapScreen.task.locationStart` | 1 | — | 正常，没有随 Tab 重跑 |
| 全部场景 | SwiftData 足迹/Workout/路线读取 | 各 1 | 0 ms 主线程 | 正常：不是每次 Tab 都读取 |
| 全部场景 | `TrajectoryBuilder` / Resolver / TrailIndex | 各 1 | 0 ms 主线程 | Tab 生命周期正常；真实数据冷路径仍极重 |
| 41 次统计页激活 | `StatsCluster.generation` | 41 | 0 ms 主线程 | 异常：每次激活都创建全量任务 |
| 全部场景 | `FootprintMapView.updateUIView` | 89 | 合计 6.30 ms，最大 2.60 ms | 调用偏多，但空数据成本低 |
| 89 次 Map 更新 | 没有 MapKit 数据变更 | 88 | 包含于上项 | 正常：token 防护有效 |
| 初始数据装载 | `MapKit.fullRebuild` | 2 | 空数据无法代表真机 | 内容 token 会触发全量替换 |
| 真机内容提交 | `MKMapView.addOverlay` → 三层 Polyline | 未完成 | ≥10,000 ms 连续阻塞 | 严重异常，直接 watchdog |
| 20 次场景 | HealthKit sync / `.dataImported` | 0 | 0 ms | 正常；测试期间没有伪触发 |

## 6. 对 12 个问题的直接回答

1. **一次菜单点击到下一页面第一帧多少 ms？** 空数据模拟器的“下一主队列提交”代理为地图→统计平均 5.92 ms、统计→地图平均 6.86 ms；XCTest 的页面就绪时间为 1.44–2.55 秒。真实大数据设备在地图图层提交时没有下一帧，至少 10 秒后被杀死。只有成功的 Animation Hitches trace 才能给出严格像素首帧，本轮 CLI trace 无效。
2. **主线程最长连续阻塞多少 ms？** 已证明至少 10,000 ms，位置是 `MKMapView.addOverlay` → `FootprintMapView.addProfessionalLine` → `rebuildLinesOnly` → `rebuildAll` → `updateUIView`。
3. **哪三个函数累计耗时最高？** 已完成的真机诊断区间依次是 `SwiftData.workoutRoutePoint.fetch` 42.03 秒、`TrajectoryBuilder` 4.26 秒、`TrajectoryConflictResolver` 2.13 秒。另有未能正常结束计时的 MapKit 主线程提交，已持续至少 10 秒，严重性高于后两项。
4. **Tab 切换是否重新创建 MapScreen？** SwiftUI 的 `MapScreen` 值会重新初始化（86 次），但状态化页面生命周期没有重新创建：`onAppear` 和 Location `.task` 都只有 1 次。不能把值类型 `init` 次数误判成地图实例被销毁。
5. **是否重新 fetch SwiftData？** 单纯 Tab 切换不会；整轮 81 次切换只有初始加载各 1 次。冷启动、缓存失效或 `.dataImported` 后会重新全表 fetch。
6. **是否重新构建 Trajectory？** 单纯 Tab 切换不会；初始/失效加载会。当前缓存仅进程内存保存，冷启动必 miss。
7. **是否重新构建 TrailIndex？** 单纯 Tab 切换不会；地图加载阶段构建 1 次。统计聚合则每次统计页激活重建，当前观测为 41 次。
8. **MapKit 是否每次 remove/add 全部 overlay？** Tab 无数据变化时不会：88/89 次 `updateUIView` 无 MapKit 数据变更。`contentToken` 变化时会调用 `rebuildAll`，移除全部非瓦片 overlay，并为每条历史/Workout 路线创建 casing、glow、core 三层 polyline；真机在这一步 watchdog。
9. **`.dataImported` 一次业务操作触发几次？** `HealthKitService.importChanges` 每次成功保存后发送 1 次，但发送是无条件的，即使 `workouts`、删除集合和新增路线均为空。一次通知会被 Map、Stats、Review 接收，Settings 挂载时也接收；Map 有 900 ms 防抖，只能合并时间窗口内的通知，不能消除无变化重建。其他导入服务也会各自发送，因此跨服务业务批次可能超过 1 次。
10. **HealthKit 状态变化是否导致 Root/Map body 重算？** 没有直接证据。状态通知由 Settings 本地接收，未作为高层 `EnvironmentObject` 注入根视图；真机状态变化期间 Map/Main body 有重算，但同时存在导航和加载，不能建立因果。真正会明确驱动地图全量加载的是 `.dataImported`，不是 `healthKitSyncStatusChanged`。
11. **没有数据变化时为什么仍发生地图重建？** 需区分 SwiftUI 重算和地图数据重建。Tab 改变使高层 `@Observable navigation.selectedTab` 失效，三个常驻子页面的值和 body 会重算，`updateUIView` 也会被调用；token 未变时 MapKit 不增删内容。真正“无业务数据变化却全量地图重建”的路径是 HealthKit 空增量仍保存并发送 `.dataImported`，它失效轨迹缓存并调度 `loadSnapshots`，随后改变内容 token。
12. **第一次出现性能回退的是哪个 commit / 哪组修改？** 最早明确的结构性回退是 `b574b0e`：Map 加载新增一次完整 `TrajectoryRepository.load()`，并引入每张照片 `segments.filter`。`9fcb98e` 用自动同步和无条件 `.dataImported` 放大重载频率；`7ea1a7d` 把冲突解析加入冷路径。`f4dc41e` 的边界保留会增加路线分段和三层 overlay 数量，是 MapKit 主线程峰值的前置放大因素，但不是最早的重复全量读取点。

## 7. 根因优先级与下一阶段建议

本轮没有实施以下优化，仅给出下一阶段的修复顺序：

1. **P0：轨迹数据读取与缓存。** 避免一次性 materialize 623,384 个 SwiftData 模型；按 workout/时间窗分批或直接读取所需字段；给 canonical/resolution 建立带数据 revision 的持久缓存，冷启动不重做全管线。
2. **P0：MapKit 提交。** 不能在一次 `updateUIView` 中逐条提交所有三层 polyline；需要分批、差分或合并渲染，并设主线程帧预算。功能和视觉语义可以保持不变。
3. **P0：通知语义。** 只有保存确实改变可见数据时才发 `.dataImported`；同一同步批次合并成单一 revision 通知。
4. **P0：HealthKit 旧数据回填。** 从每次 sync 入口移出，改成一次性、可恢复、分批迁移，避免与地图读取并发争用。
5. **P1：TrailIndex 时间索引。** 替换每张照片对全部 segment 的线性 `filter`，按时间和轨迹边界建立索引。
6. **P1：统计页任务。** 缓存按数据 revision 的统计结果；取消或合并重复激活产生的后台聚合任务。
7. **P2：SwiftUI 失效范围。** 拆分高层 navigation observation，减少隐藏页面 body 和 `updateUIView` 调用；这不是当前 watchdog 的首要原因。

修复验收门槛建议：真机真实数据库能完成三个场景各 20 次；菜单点击到首个显示帧 P95 < 100 ms；主线程单段 < 16.7 ms（不得出现 >100 ms hitch）；无数据变化时 SwiftData/Trajectory/TrailIndex/MapKit 全量重建次数均为 0；一次 HealthKit 业务批次最多一次有效地图 revision。

## 8. 回归验证

- Xcode 单元测试：5/5 通过。
- 正常 UI 测试：1/1 通过；性能审计 UI 测试按设计默认跳过。
- 显式 20 次性能审计 UI 测试：1/1 通过，0 失败，346.679 秒。
- SwiftPM 核心逻辑：139/139 checks 通过。
- `git diff --check`：通过，无空白错误。
