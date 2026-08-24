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

阶段证据：Build Passed；Xcode unit 10/10 Passed，其中 streaming accumulator 与旧 builder 等价测试 Passed，20,005 点跨页 repository 测试 Passed（1 条 trajectory、1 segment、20,005 点完整且末点 index=20,004）；Core 139/139 Passed；地图三缩放级 UI 回归 1/1 Passed；`git diff --check` Passed。623,384 点真机 after 数据：Not measured，最终验收时设备离线。

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

诊断同时记录 `MapScreen.init=86`、但 `onAppear=1`、`loadSnapshots=1`、location task=1：这是 SwiftUI value-view 的轻量重新初始化，不是地图页销毁/重建，也没有再次 fetch、trajectory build 或 MapKit presentation rebuild。623,384 点真机 batch 最大耗时与切页第一帧：Not measured，最终验收时设备离线。

### Commit 08 — add zoom-aware trajectory geometry

- canonical/raw trajectory 保持不变；每个已经按业务规则切开的 `RouteLine` 独立生成 zoom-aware render geometry，不跨 trajectory / session / route / segment 合并或连线。
- 使用 Douglas–Peucker 多级 geometry；每一级保留原始首尾点，并以 MapKit map-point 空间的最大垂距作为严格误差上限。
- renderer 按实时 `zoomScale` 选择满足 `mapPointError × zoomScale ≤ 0.25 screen point` 的最粗层级；没有满足条件的层级自动使用 raw geometry，所以街区/近距为完整或更精细路径。
- 一条逻辑路线仍只有一个 `ZoomAwareRouteOverlay`、一份 renderer 与原三次 casing/glow/core stroke；没有改变线宽、alpha、颜色、cap/join、overlay level、点击范围或照片锚点。
- LOD 在后台 derived-layer 构建阶段生成，不进入主线程 overlay batch；只有相对上一个常驻层级点数至少降低 35% 的层级才保留，跳过层级只会回退到更精细 geometry，并将常驻 LOD 数组控制为几何级数。
- 跨 world-wrap 的路线禁用简化并使用 raw geometry；persistent derived-cache geometry presentation version 从 1 升至 2，旧派生缓存安全失效，raw SwiftData 不受影响。

阶段证据：Build Passed；Xcode unit 18/18 Passed（含端点保持、独立误差复算、近距 raw、远距减点、屏幕误差 ≤0.25pt、常驻层级收益阈值）；Core 139/139 Passed；同一 seeded dataset 的 fit / near / far UI 回归 1/1 Passed，逐图对比 Commit 07 与修改前基线，路线完整性、远处曲线轮廓、三层 stroke、照片数量及锚点无可感知变化；`git diff --check` Passed。623,384 点真机 raw/render point count、LOD build 与 draw 耗时：Not measured，最终验收时设备离线。

### Commit 09 — index trail matching by time

- `TrailIndex.interpolateMatch` 不再对每张照片执行 `segments.filter`。构建 TrailIndex 时生成按 segment start 排序的不可变时间索引；查询用两次 binary search 定位 `[timestamp - 2h, timestamp]` 的必要窗口，再只检查窗口内的 end time，复杂度由每次 O(N) 改为 O(log N + K)。
- 2h 窗口与原有最大可插值跨度完全相同，因此不会排除任何原先合法候选；候选选择继续按最低端点 confidence 的最大值，confidence 相同时按原 `segments` 顺序，保持旧 `filter + max` tie-break。
- 原有 trajectoryID / sessionID / segmentID / source 边界、跨 gap 拒绝、首尾 clamp、坐标插值、confidence 与 timeDelta 未改变；空间 nearest-route grid fallback 未修改。
- DEBUG 汇总新增 temporal query 次数、时间窗候选、实际包含候选和避免扫描的候选数，不在 Release 路径增加采样闭包。

阶段证据：Build Passed；Xcode unit 20/20 Passed；其中 10,000 segment 回归查询仅进入 241 个必要时间窗候选、实际命中 1 个，并验证重叠来源仍选择相同高置信度 segment 及完整来源元数据；Core 139/139 Passed；fit / near / far 地图 UI 回归 1/1 Passed，照片锚点和轨迹视觉未变化；`git diff --check` Passed。623,384 点真机照片数量、候选总数与 matching 耗时：Not measured，最终验收时设备离线。

### Commit 10 — cache stats by data revision

- 密集区域结果以 `placeRevision + trajectoryRevision + pointSnapshotGeneration` 为 key。generation 只在一份新 point snapshot 完成物化时递增，用于区分启动期尚未加载与同持久 revision 已加载的状态；稳定数据下重复进入 Stats 直接复用。
- `StatsClusterRevisionCache` actor 同时保存同 key 的 in-flight task，后来的 consumer await 已有任务；旧 revision 晚完成时不能覆盖更新 revision 的 completed cache。
- 实际 `GeoMath.topClusters` 的输入、0.005° 默认 cell、topN=5、排序和输出数值不变；只把“页面激活即计算”改为“revision 未命中才计算”。Release 不安装诊断闭包。

三组各 20 次 Simulator 导航审计 Passed（测试本身 332.960s，包含 XCUI 固定等待，不能作为 App 首帧耗时）：`StatsCluster.rebuild.started/generation=1`（基线 41）、`screenReuse=40`、Map snapshot/fetch/TrailIndex 各 1、Map rebuild 1、overlay add 仅首次 6/remove 0、89 次 `updateUIView` 中 88 次 no-mutation。App 内诊断的 Map→Stats 首个 SwiftUI frame 最大 0.169ms，Stats→Map 最大 0.051ms；seeded Simulator Stats build 0.210ms。阶段证据：Build Passed；Xcode unit 21/21 Passed（含 20 个同 revision 并发 consumer 仅 build 1 次及完成缓存复用）；Core 139/139 Passed；fit / near / far UI 回归 1/1 Passed；`git diff --check` Passed。真实大数据库首帧与 Stats build：Not measured，最终验收时设备离线。

### Commit 11 — add large-data performance regression coverage

- 新增不依赖脆弱绝对时间阈值的大数据复杂度回归：100k / 300k / 623,384 行对应 5 / 15 / 32 个 20k page，单页 SwiftData model 峰值不超过 20k。
- 真实构造 100k Workout route values 进入 streaming accumulator，最终仍为同一 workout / route / segment，100k 点和首尾 global index 全部保留。
- 100k route presentation 的无变化 diff 为零 mutation；仅改变一条 fingerprint 时只报告该 route，overlay 数仍为逻辑路线数 N、`MKPolyline` 数为 0。
- 真实构造 100k 点 render geometry，近景仍为 100k raw、远景减点、首尾点一致且 screen error policy ≤0.25pt。
- 真实构造 30k segments，并对 10k photo timestamps 查询；每次实际命中 1 个 segment，总候选低于全表扫描的 1%，同时保持既有来源与边界语义测试。

阶段证据：Build Passed；大数据 tests 5/5 Passed（2.184s，记录但不作为门槛）；完整 Xcode unit 26/26 Passed；Core 139/139 Passed；完整 UI 2 Passed / 0 Failed / 1 Skipped，显式 20×3 导航审计另行 1/1 Passed；最终 fit / near / far 截图导出并逐图核验；`git diff --check` Passed。

## 3. Before / After

下表严格区分真实设备、Simulator 与结构性断言。当前 iPhone 15 Pro Max 在最终构建前从 `available (paired)` 变为 `unavailable`，所以没有把 Simulator 数字冒充 623,384 点真机 after。

| 指标 | Before | After |
| --- | ---: | ---: |
| WorkoutRoutePoint 规模 | 623,384（真机） | 同一 raw 数据：Not measured；合成规模覆盖 623,384 |
| WorkoutRoutePoint 冷路径 | 42,031.73 ms（真机全表 materialization） | 真机：Not measured；实现为 32×20k 分页，单页峰值 ≤20k |
| TrajectoryBuilder | 4,263.95 ms（真机） | persistent exact-revision hit 时 0 次；623k 真机 miss：Not measured |
| ConflictResolver | 2,131.17 ms（真机） | persistent exact-revision hit 时 0 次；623k 真机 miss：Not measured |
| Persistent cache cold launch | 无，重启必 miss | seeded Simulator hit=1；623k 真机：Not measured |
| MapKit 连续主线程阻塞 | ≥10,000 ms 后 `0x8BADF00D`（真机） | seeded Simulator batch 最大 1.039 ms；623k 真机：Not measured |
| Map presentation amplification | 逻辑路线 N → 3N overlays / polylines | N → N custom overlays / 0 `MKPolyline`；真实 N：Not measured |
| Raw route points | 623,384（真机） | raw/canonical 不删除不改写；真机计数：Not measured |
| Render points | 等于 raw，直接交给 MapKit | zoom-aware，误差 ≤0.25pt；623k 各 zoom 点数：Not measured |
| Stats 重复进入 | 41 次激活 → 41 次 generation（Simulator） | 41 次进入路径 → 1 次 generation、40 次 reuse（Simulator） |
| Empty Health sync rebuild | 空增量仍 post 1 次并使 cache 失效 | revision change=0、Map/TrailIndex/Stats rebuild=0（policy + notification tests） |
| 稳态 81 次 Tab selection | 88/89 `updateUIView` no mutation，但旧内容变化走 full rebuild | fetch/Map/TrailIndex 各 1；88/89 no mutation；overlay remove=0（Simulator） |
| Map→Stats 首帧代理最大值 | 13.31 ms（旧空数据 Simulator） | 0.169 ms（seeded Simulator） |
| Stats→Map 首帧代理最大值 | 10.20 ms（旧空数据 Simulator） | 0.051 ms（seeded Simulator） |
| Watchdog | 1 次已确认 `0x8BADF00D`（真机） | Simulator 0；真机 after：Not measured |

## 4. 数据流 Before / After

Before：

```text
App launch / generic .dataImported
→ full WorkoutRoutePoint @Model fetch (623k 同时常驻)
→ TrajectoryBuilder
→ ConflictResolver
→ TrailIndex (每张照片 filter 全 segments)
→ RouteLine × 3 MKPolyline
→ remove all + add all on main thread
→ watchdog
```

After：

```text
Committed domain revision
→ exact persistent TrajectoryResolution hit?
   ├─ yes: 跳过 raw fetch / Builder / Resolver
   └─ no: 20k paging → streaming accumulator → Resolver → atomic derived-cache save
→ immutable time-indexed TrailIndex
→ stable RouteLine ID + fingerprint
→ zoom-aware derived geometry（raw/canonical 不变）
→ route diff
→ hidden adaptive staging batches
→ atomic no-animation presentation commit
→ unchanged content: O(1) no-op
```

## 5. Cache / Revision 规则

| 变化 | Revision / cache 行为 |
| --- | --- |
| HealthKit anchored query 空增量 | 只保存 anchor/sync status；不创建 import context、不 save 数据、不 bump、不 post |
| Workout summary 变化、route 未变化 | stats revision；trajectory cache 保持有效 |
| Workout route 增删或影响路线 presentation 的 activity 变化 | trajectory + stats revision；trajectory derived cache 精确失效 |
| Footprint place/GPS/CSV 成功增删 | place/stats；含 trajectory source 时同时 bump trajectory |
| Photo/region 数据真实变化 | photo/place 相应 revision；不会无条件使 trajectory cache 失效 |
| App 重启且 schema + geometry version + trajectory revision 相同 | persistent hit，raw fetch / Builder / Resolver 全部跳过 |
| 构建期间 revision 改变 | 当前调用可返回已构建值，但禁止把陈旧结果写成新 revision cache |
| Stats 同 place/trajectory revision 与 snapshot generation | completed cache reuse；并发 consumer join 同一 in-flight task |
| geometry presentation version 改变 | 只使可重建派生缓存失效；raw SwiftData 不变 |

Legacy migration 以独立 schema version 与 progress cursor 管理，只在首份地图 snapshot 完成后运行；它不再属于 HealthKit sync 热路径，并与 trajectory cold build 通过 heavy-work gate 互斥。

## 6. MapKit 新策略与视觉不变量

- 一条逻辑路线对应一个 `ZoomAwareRouteOverlay` 和一个 renderer；renderer 内仍按原顺序绘制 casing、glow、core 三次 stroke。
- 颜色、alpha、线宽、round cap/join、overlay level、路线顺序、图层开关、照片锚点、点击范围均未改变。
- stable ID + fingerprint 只增删或替换 changed route；unchanged route 保留同一 overlay / renderer。
- 批次目标约 5ms，8...512 自适应；staging overlay 始终隐藏，旧路线保持可见，所有批次完成后一次性原子显现，所以没有逐条出现、暂时缺失或加载顺序变化。
- renderer 按 `mapPointError × zoomScale ≤ 0.25 screen point` 选择最粗安全层级；近景自动 raw，world-wrap 自动 raw，首尾点永远保留。

## 7. 对 12 个审计问题的最终回答

1. **一次菜单点击到下一页面第一帧多少 ms？** seeded Simulator 的 App 内提交代理：Map→Stats 最大 0.169ms，Stats→Map 最大 0.051ms。真实 623k 数据 P95：**Not measured**；Animation Hitches 才能给严格像素首帧。
2. **主线程最长连续阻塞多少 ms？** Before 真机 ≥10,000ms。After seeded Simulator 已记录的最大相关 MapKit batch 1.039ms，所有正常同步诊断任务均 <100ms；623k 真机最大连续阻塞：**Not measured**。
3. **哪三个函数累计耗时最高？** Before 真机为 route-point fetch 42.03s、Builder 4.26s、Resolver 2.13s，另有未完成的 MapKit ≥10s。After seeded Simulator 后台最高三个已记录区间为 PhotoCluster 8.883ms、persistent decode 6.737ms、photo matching 6.395ms；这不是 623k 真机排名。
4. **Tab 切换是否重新创建 MapScreen？** SwiftUI value `init` 会重算（86 次），但 `onAppear`、Map snapshot load、Location task 各只有 1 次；Map 页面与 `MKMapView` 没被销毁重建。
5. **是否重新 fetch SwiftData？** 稳态 81 次 Tab selection 不会；footprint/photo fetch 各 1 次首载。exact persistent trajectory hit 不读取 raw route points。
6. **是否重新构建 Trajectory？** 稳态切 Tab 为 0；同 revision persistent hit 为 0。只有 trajectory revision miss 才分页重建。
7. **是否重新构建 TrailIndex？** 稳态切 Tab 为 0，整轮 build 1 次；照片时间查询已从全扫改为 binary-search 时间窗候选。
8. **MapKit 是否 remove/add 全部 overlay？** 不会。审计中 add 仅首载 6、remove 0、full rebuild 0；单 route 变化的合成测试只报告该 route。
9. **`.dataImported` 一次业务操作触发几次？** 真实 commit 统一通过一次 domain revision change 发布；HealthKit 空增量为 0。跨独立事务仍各发布自己的 revision，消费者按 revision 去重。
10. **HealthKit 状态变化是否导致 Root/Map body 重算？** sync status 仍由 Settings 本地消费，不作为 Root/Map 数据 revision；可见路线未变化时不会触发 Map fetch/build/presentation mutation。
11. **没有数据变化时为什么仍发生地图重建？** 现在不会发生 MapKit 数据重建。navigation 可使 SwiftUI body / `updateUIView` 被调用，但 presentation token 未变时走 cheap no-op；88/89 次实测无 mutation。
12. **第一次出现性能回退的是哪个 commit / 哪组修改？** `b574b0e` 首次把完整 repository load 和每照片全 segment filter 接入地图；`9fcb98e` 的空 sync 通知放大频率；`7ea1a7d` 加入 Resolver；`f4dc41e` 的更多边界分段放大 3-layer overlay 数量。

## 8. 修改文件清单

| 文件 | 性能职责 |
| --- | --- |
| `.gitignore` | 忽略运行期诊断输出，不影响产品资源 |
| `LifeFootprints/LifeFootprintsApp.swift`、`TestHooks.swift` | DEBUG 诊断启用与可重复性能/视觉 seed |
| `CoreLogic/FootprintSnapshot.swift` | Sendable 值快照，允许后台 cache/aggregation 安全传递 |
| `CoreLogic/GeoMath.swift` | TrailIndex 时间索引、候选统计，保留 snap/interpolation 语义 |
| `CoreLogic/TrajectoryConflictResolver.swift`、`TrajectoryDomain.swift` | 完整 resolution 的持久 cache 编码所需派生 metadata |
| `Services/DataRevisionStore.swift` | 持久分域 revision 与精确通知 |
| `Services/DatabaseHeavyWorkGate.swift` | migration / trajectory cold work 协调与 single-flight 复查 |
| `Services/LegacyRouteMigration.swift` | 一次性、可恢复、后台 legacy route boundary migration |
| `Services/PersistentTrajectoryCache.swift` | exact-revision binary derived cache |
| `Services/WorkoutTrajectoryAccumulator.swift` | page → final TrajectoryPoint 流式累加 |
| `Services/TrajectoryRepository.swift` | 20k 分页、persistent hit、bounded fallback、分页 policy |
| `Services/HealthKitService.swift` | 空 change-set 早退、目标删除、migration 移出热路径、domain bump |
| `Services/HealthKitSyncCoordinator.swift`、`HealthKitSyncStatusStore.swift` | observer/sync/status 诊断与空同步状态分离 |
| `Services/FootprintStore.swift`、`PhotoStore.swift` | 只在成功可见数据 commit 后发布正确 domain revision |
| `Services/PhotoCluster.swift` | TrailIndex 候选/匹配诊断，不改变聚合与照片锚点 |
| `Services/StatsClusterRevisionCache.swift` | revision completed cache 与 in-flight single-flight |
| `Services/PerformanceDiagnostics.swift` | DEBUG-only signpost、调用次数、主线程与 JSON 聚合 |
| `Views/MainTabView.swift` | Tab/导航首帧诊断，页面仍保持常驻 |
| `Views/MapScreen.swift` | snapshot generation、persistent trajectory 消费、stable RouteLine/LOD |
| `Views/FootprintMapView.swift` | one-overlay renderer、diff、batch、atomic commit、zoom LOD、no-op |
| `Views/StatsScreen.swift` | Stats revision cache consumer；同 revision 不重算 |
| `Views/ReviewTabView.swift`、`SettingsScreen.swift` | 精确 revision/status 消费与导航诊断 |
| `LifeFootprintsTests/TrajectoryAndHealthTests.swift` | A–F 语义、cache、diff、LOD、TrailIndex、Stats tests |
| `LifeFootprintsTests/LargeDataPerformanceRegressionTests.swift` | 100k / 300k / 623k 复杂度回归 |
| `LifeFootprintsUITests/PerformanceAuditUITests.swift` | 20×3 导航审计与 fit/near/far 截图 |
| `PERFORMANCE_AUDIT_REPORT_2026-08-23.md` | 修改前根因与真实设备基线 |
| `PerformanceArtifacts/before-5ea8e01-images/`、`after-performance-remediation-images/` | 同 Simulator、同 seed 的地图视觉证据 |

## 9. 自动化与诊断结果

| 套件 | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Xcode unit（含大数据） | 26 | 0 | 0 |
| CoreLogic executable checks | 139 | 0 | 0 |
| 完整 UI 目标 | 2 | 0 | 1 |
| 显式 20×3 导航审计 | 1 | 0 | 0 |
| 大数据专项 | 5 | 0 | 0 |
| fit / near / far 视觉回归 | 1 | 0 | 0 |

默认 skipped 的唯一测试是带 `FP_RUN_PERF_AUDIT` 门槛的 20×3 长时审计；本轮已临时仅解除测试门槛完整执行，随后恢复源码并用 `git diff --exit-code` 确认零差异。

Instruments CLI：Time Profiler + POI 在 Simulator 实际启动并覆盖自动导航，但当前 `xctrace` 忽略 `--time-limit` 且 SIGINT 后无法完成模板封包，导出报 `Document Missing Template Error`，因此不把该 trace 算作有效通过；SwiftUI 与 Hitches instrument 明确不支持 Simulator。真机离线后无法补录，四项修复后 Instruments 结论均为 **Not measured**。App 内 `os_signpost` 与聚合 JSON 有效，20×3 调用次数和阶段耗时已写入本报告。

## 10. 地图 Before / After 视觉回归

- Before：`PerformanceArtifacts/before-5ea8e01-images/manifest.json`
- After：`PerformanceArtifacts/after-performance-remediation-images/manifest.json`
- 设备/数据：同一 iPhone 17 Pro Simulator、同一 deterministic visual seed、fit / near / far 三档。
- 逐图结论：路线数量与完整性一致；弯曲轮廓、首尾点、casing/glow/core、线宽/alpha、照片数量和锚点无可感知变化；没有逐条出现或临时缺线。

## 11. 真机最终验收状态

修改前真机证据来自 iPhone 15 Pro Max、iOS 26.0.1、真实本地数据库（104,865 FootprintPoint、623,384 WorkoutRoutePoint、1,154 WorkoutRecord）。本轮结束时同一设备先被 `devicectl` 报告为 `available (paired)`，随后在 Build 前变为 `unavailable`，Xcode destination 同步消失，故以下 after 均为 **Not measured**：

- 真实数据库三组各 20 次导航；
- 首个显示帧 P95；
- 623k cold miss / persistent hit 时间；
- raw/render point count 与 MapKit batch 最大值；
- Time Profiler / SwiftUI / Animation Hitches / POI 有效 trace；
- 修复后真机 fit / near / far 截图；
- 修复后真机 watchdog 次数。

## 12. 剩余风险

- 首次升级仍需执行一次 legacy schema migration；虽然已延后、可恢复并与 cold build 互斥，但真实 623k 完成时间未复测。
- 首次没有 persistent cache 或 trajectory revision 改变时仍需完整分页 build + resolve；内存峰值已受 page 限制，但低端设备和 1M+ 数据库未测。
- LOD 生成是后台 CPU 工作；100k 回归通过，623k 真机 LOD build/draw 与 MapKit 内部成本未测。
- MapKit 自身的 renderer/path cache 与极端 overlay 数仍是平台不可控成本；batch 防止连续主线程占用，但真机帧门槛尚需补验。
- SwiftUI root/body 仍会因 navigation value 变化重算；当前 cheap no-op 证明它不造成 MapKit mutation，未为减少 body 次数重写页面架构。
- 当前 Xcode CLI Instruments 与真机连接不稳定，严格像素首帧和 hitch chain 仍需在 Xcode Instruments GUI 中复跑。

## 13. 提交序列

```text
17db6ec perf: audit current trajectory cold path
e29dbc8 perf: suppress invalid trajectory invalidations
f81fbe2 perf: remove legacy migration from sync hot path
6d81098 perf: optimize trajectory persistence read path
05b1c1f perf: add revisioned persistent trajectory cache
84c8ee2 perf: collapse map overlay amplification
e2696ea perf: make map presentation incremental and batched
7377e29 perf: add zoom-aware trajectory geometry
0eb68b0 perf: index trail matching by time
3f1d546 perf: cache stats by data revision
Commit 11 test: add large-data performance regression coverage
```
