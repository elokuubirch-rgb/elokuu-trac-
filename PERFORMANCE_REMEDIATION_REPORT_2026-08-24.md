# LifeFootprints 真机性能专项修复报告

日期：2026-08-24  
代码事实基线：`5ea8e01`  
性能基线：`PERFORMANCE_AUDIT_REPORT_2026-08-23.md`  
约束：performance-only；不得改变产品功能、业务语义、导航、布局、视觉样式、轨迹视觉参数或地图照片 UI

## 1. Current HEAD Re-Audit（修改前）

以下结论来自当前 `5ea8e01` 源码，而不是沿用旧行号。

| 指定问题 | 当前 HEAD 结论 |
| --- | --- |
| 1. WorkoutRoutePoint / Trajectory 读取入口 | `TrajectoryRepository.load()` 无范围 fetch 全部 `WorkoutRoutePoint`；`MapScreen.loadSnapshots()` 在 repository 失败时还有一次全表 fallback fetch。HealthKit 删除和 legacy backfill 也会扫描路线点。 |
| 2. 地图消费的数据层 | 地图不直接把 SwiftData Model 交给 MapKit。Raw Model 经 `TrajectoryRepository` → Trajectory Domain → Conflict Resolution → `FootprintSnapshot` → `RouteLine`，最终转成 MapKit geometry。普通 FootprintPoint 另有一次全量 Snapshot 构建。 |
| 3. Data revision | 没有持久数据 revision。只有 `reloadVersion`、`derivedVersion` 等进程内 UI token，不能判断 raw data 是否真正改变。 |
| 4. Persistent trajectory cache | 没有。`TrajectoryResolutionCache` 只在内存中保存一个 `TrajectoryResolution`，App 重启必 miss。 |
| 5. TrailIndex 时间查询 | 仍然存在 `segments.filter { a.t <= photoTime <= b.t }`，每张照片最坏扫描全部 segment。 |
| 6. 一条逻辑路线的 overlay | 仍然创建 casing / glow / core 三个独立 `MKPolyline` 和三个 overlay。 |
| 7. HealthKit 空增量 | 仍会进入 `importChanges`、执行 legacy backfill、保存 context、发送 `.dataImported`；Map 随后无条件 invalidate trajectory cache。 |
| 8. Legacy Route Migration | `backfillLegacyRouteBoundaries` 仍位于每次 `importChanges` 的同步热路径，并全量读取缺失 routeID 的历史点。 |
| 9. Stats 重算 | `onAppear`、`isActive=true`、`mapSnapshotReady`、`.dataImported` 都会触发 `scheduleClustersRebuild()`；没有 revision cache，也没有 single-flight。 |
| 10. Map full rebuild | `contentToken` 变化会调用 `rebuildAll`，移除全部非瓦片 overlay，清空 style 表，再同步 add 全部三层路线；没有 route diff 或 batch。 |

当前已经成立、无需重做的优化：

- 三个主页面常驻；Tab 切换不会重复执行 Map `onAppear` 或 Location `.task`。
- `updateUIView` 在 content token 未变化时已有低成本分支，旧审计中 88/89 次没有 MapKit 数据 mutation。
- 照片 annotation 在普通 marker token 变化时已经按 cluster ID 做增删差分。
- Trajectory、TrailIndex 和 PhotoCluster 主要计算已在后台执行；当前问题是工作量与最终主线程 presentation，而不是缺少 `Task.detached`。
- `TrajectoryResolutionCache` 的 `NSLock` 已证明不是瓶颈，本轮不优化。

## 2. 修改记录

### Commit 02 — suppress invalid trajectory invalidations

- 新增持久、分域的 `trajectory / photo / place / stats` revision；只有成功提交且真实可见数据改变时递增。
- 新增 `dataRevisionChanged` 精确通知；Map、Stats、Review、Settings 不再把 generic sync completion 当作数据变化。
- HealthKit anchored query 的空增量在保存新 anchor 与同步成功状态后立即返回：不创建 `ModelContext`、不执行 migration、不保存 SwiftData、不发数据变化通知。
- HealthKit summary-only 变化只改变 stats revision；route 增删或影响已有路线 presentation 的 activity type 变化才改变 trajectory revision。
- trajectory 内存缓存失效按 revision 去重。

阶段验证：

| 项目 | 结果 |
| --- | --- |
| Build | Passed |
| Xcode unit | 7/7 Passed（含 empty sync policy 与分域 revision 持久化） |
| Core logic | 139/139 Passed |
| 相关 UI | HealthKit 设置入口 1/1 Passed |
| `git diff --check` | Passed |
| 真机 HealthKit 空增量诊断 | Not measured（本阶段无已授权真机执行环境） |

### Commit 03 — remove legacy migration from sync hot path

- 从 `HealthKitService.importChanges` 移除 legacy 全表 backfill；正常 full/incremental sync 不再附带历史路线扫描。
- 新迁移在首个 `mapSnapshotReady` 之后以 utility 后台任务启动，首屏地图不等待迁移。
- 按 workout 独立事务处理，持久化 schema version 与 progress cursor；中断后由剩余 `routeID == nil` 数据恢复，完成后永久 no-op。
- migration 与 trajectory cold build 通过后台重任务 gate 互斥；并使同一进程的并发 trajectory build 在 gate 内复查内存缓存，复用已完成结果。
- 全部批次完成后只发布一次 trajectory revision，避免逐 workout 刷新地图。

阶段验证：Build Passed；Xcode unit 8/8 Passed（含 3 点/2 segment 迁移及二次 no-op）；Core 139/139 Passed；地图三缩放级 UI 回归 1/1 Passed；`git diff --check` Passed。

### Commit 04 — optimize trajectory persistence read path

- `TrajectoryRepository` 不再一次性 fetch 全部 `WorkoutRoutePoint`；改为按 timestamp、20,000 点一页读取，每页使用独立 `ModelContext`。
- 新的 streaming accumulator 直接从单页 SwiftData model 构造最终 `TrajectoryPoint` / session / route / segment，避免同时常驻 raw `@Model`、`TrajectorySample` 与 `TrajectoryPoint` 三份 623k 数组。
- activity type、trajectory/session/route/segment ID、断层规则、quality/confidence 与旧 `TrajectoryBuilder` 逐字段等价。
- repository 失败的地图 fallback 同样改为分页，不保留第二条全表 materialization 路径。
- HealthKit 删除按目标 workout 查询，移除删除路径的无条件 route-point 全表 fetch。

阶段证据：Build Passed；Xcode unit 10/10 Passed，其中 streaming accumulator 与旧 builder 等价测试 Passed，20,005 点跨页 repository 测试 Passed（1 条 trajectory、1 segment、20,005 点完整且末点 index=20,004）；Core 139/139 Passed；地图三缩放级 UI 回归 1/1 Passed；`git diff --check` Passed。623,384 点真机 after 数据：Not measured，待最终真机复测。

### Commit 05 — add revisioned persistent trajectory cache

- 新增可删除、可重建的 binary plist 派生缓存；schema、geometry presentation version 与持久 trajectory revision 必须完全一致才允许命中。
- 缓存包含 trajectory/session/segment/source/start/end、canonical geometry、quality/confidence、conflicts、suppression 与 resolver compared-pair metadata；raw SwiftData 仍是唯一事实来源。
- canonical point 只序列化一次，trajectory segment 与 resolved point 通过下标引用，避免缓存文件重复存储 623k 点几何。
- 同 revision 冷启动 persistent hit 直接恢复完整 `TrajectoryResolution`，跳过 SwiftData raw fetch、TrajectoryBuilder 与 ConflictResolver；构建期间 revision 改变则不写入陈旧缓存。

阶段证据：Build Passed；Xcode unit 12/12 Passed（含 exact-revision round-trip、revision mismatch miss、模拟重启后删除 raw 仍命中缓存）；Core 139/139 Passed；地图三缩放级 UI 回归 1/1 Passed；`git diff --check` Passed。

### Commit 06 — collapse three-stroke map overlay amplification

- 每条逻辑路线从 3 个 `MKPolyline` / overlay / renderer 降为 1 个；单个 `ProfessionalPolylineRenderer` 共享一份 map-point geometry，并按 MapKit `zoomScale` 以原始 point 线宽完成三次 stroke。
- casing / glow / core 的颜色、alpha、线宽、round cap、round join、overlay level 与路线间绘制顺序保持不变；轨迹开关仍只切 renderer alpha。
- 900 条逻辑路线的 presentation 对象由 2,700 个 polyline/overlay 降至 900 个，不减少任何路线或坐标。

阶段证据：Build Passed；Xcode unit 13/13 Passed（含 900 logical routes → 900 overlays 与三层原始 style 参数断言）；Core 139/139 Passed；同一 iPhone 17 Pro 模拟器、同一 seeded dataset 的 fit / near / far 三缩放级 UI 回归 1/1 Passed，并逐图核验路线完整性、线宽、casing、glow、core 与照片锚点无可感知变化；`git diff --check` Passed。

### Commit 07 — make map presentation incremental and batched

- `RouteLine` 改用跨更新稳定的 domain identity，geometry / frequency / latest-route style / theme 另存 presentation fingerprint；纯 diff 明确区分 added / removed / changed / unchanged。
- content revision 未变化时不触碰 MapKit；同 ID、同 fingerprint 的路线保持原 overlay 与 renderer，不 remove、不重新 add。
- 新 geometry 以自适应约 5ms 主线程预算分批创建和提交；首批从 8 条起，根据上一批耗时在 8...512 间调整，并在批次间 yield run loop。
- 为遵守“路线不得逐条出现、不得暂时缺失、加载顺序不得改变”，新 overlay 在 staging 期间统一 alpha=0，旧 presentation 持续可见；所有 batch 完成后才在一个无动画主线程事务中替换 changed/removed、恢复 route → live track → dots 的既有顺序并一次性显现。
- 新 revision 到达会取消未完成 staging 并仅清理隐藏的 pending overlay；已显示的旧 presentation 不受影响。

阶段验证：

| 项目 | 结果 |
| --- | --- |
| Build | Passed |
| Xcode unit | 16/16 Passed（含 no-change 零变更 diff、单路线 changed diff、自适应 batch budget） |
| Core logic | 139/139 Passed |
| 地图视觉 UI | 1/1 Passed；fit / near / far 逐图核验无可感知变化 |
| 20 次切换 UI | 1/1 Passed；Map↔Stats 20 轮、Map↔Settings 20 轮、Stats↔Settings 20 轮 |
| `git diff --check` | Passed |

20 次切换的 App 内部诊断（iPhone 17 Pro 模拟器；不把 XCTest 固定 idle 等待计入 App 性能）：

| 指标 | 调用 | 累计主线程 | 最大单次 | 结论 |
| --- | ---: | ---: | ---: | --- |
| `FootprintMapView.updateUIView` | 90 | 3.006 ms | 0.835 ms | 正常 |
| `MapKit.updateUIView.noMutation` | 89 | — | — | Tab 往返零 MapKit mutation |
| `MapKit.updateUIView.withMutation` | 1 | — | — | 仅首屏 |
| `MapKit.overlayBatch.mainThread` | 1 | 0.891 ms | 0.891 ms | seeded 首屏正常 |
| `MapKit.overlays.add` | 6 | — | — | 首屏 5 route + 1 dots |
| `MapKit.overlays.remove` | 0 | — | — | 无全量清空 |
| `MapKit.fullRebuild.calls` | 0 | — | — | 已移除 full rebuild 路径 |
| `MapScreen.onAppear / loadSnapshots / location task` | 各 1 | — | — | Tab 切换未重跑加载链 |
| `TrailIndex.build / photoMatching` | 各 1 | 0 ms | 1.857 / 6.294 ms | 后台且未随 Tab 重建 |

诊断同时记录 `MapScreen.init=86`、但 `onAppear=1`、`loadSnapshots=1`、location task=1：这是 SwiftUI value-view 的轻量重新初始化，不是地图页销毁/重建，也没有再次 fetch、trajectory build 或 MapKit presentation rebuild。623,384 点真机 batch 最大耗时与切页第一帧：Not measured，待最终真机复测。

### Commit 08 — add zoom-aware trajectory geometry

- canonical/raw trajectory 保持不变；每个已经按业务规则切开的 `RouteLine` 独立生成 zoom-aware render geometry，不跨 trajectory / session / route / segment 合并或连线。
- 使用 Douglas–Peucker 多级 geometry；每一级保留原始首尾点，并以 MapKit map-point 空间的最大垂距作为严格误差上限。
- renderer 按实时 `zoomScale` 选择满足 `mapPointError × zoomScale ≤ 0.25 screen point` 的最粗层级；没有满足条件的层级自动使用 raw geometry，所以街区/近距为完整或更精细路径。
- 一条逻辑路线仍只有一个 `ZoomAwareRouteOverlay`、一份 renderer 与原三次 casing/glow/core stroke；没有改变线宽、alpha、颜色、cap/join、overlay level、点击范围或照片锚点。
- LOD 在后台 derived-layer 构建阶段生成，不进入主线程 overlay batch；只有相对上一个常驻层级点数至少降低 35% 的层级才保留，跳过层级只会回退到更精细 geometry，并将常驻 LOD 数组控制为几何级数。
- 跨 world-wrap 的路线禁用简化并使用 raw geometry；persistent derived-cache geometry presentation version 从 1 升至 2，旧派生缓存安全失效，raw SwiftData 不受影响。

阶段证据：Build Passed；Xcode unit 18/18 Passed（含端点保持、独立误差复算、近距 raw、远距减点、屏幕误差 ≤0.25pt、常驻层级收益阈值）；Core 139/139 Passed；同一 seeded dataset 的 fit / near / far UI 回归 1/1 Passed，逐图对比 Commit 07 与修改前基线，路线完整性、远处曲线轮廓、三层 stroke、照片数量及锚点无可感知变化；`git diff --check` Passed。623,384 点真机 raw/render point count、LOD build 与 draw 耗时：Not measured，待最终真机复测。

## 3. Before / After

待真机和自动化验收后更新；无法测量的指标将明确标记 `Not measured`。
