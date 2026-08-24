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

## 3. Before / After

待真机和自动化验收后更新；无法测量的指标将明确标记 `Not measured`。
