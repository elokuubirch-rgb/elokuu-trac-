import Foundation
import CoreLogic

func runTrackBatchBufferChecks() {
    func point(_ id: Int) -> FootprintDraft {
        FootprintDraft(latitude: 31, longitude: 121 + Double(id) / 100_000,
                       timestamp: Date(timeIntervalSince1970: Double(id)), source: "gps")
    }
    var queue = TrackBatchBuffer()
    queue.append(point(0), at: 100)
    queue.append(point(1), at: 150)
    check(queue.nextAttemptTime == 160, "写入队列-新点不能推迟首点60秒期限")
    check(queue.beginBatch(at: 159) == nil, "写入队列-未到期限不提前落库")
    let first = queue.beginBatch(at: 160)!
    check(first.drafts == [point(0), point(1)], "写入队列-到期按原顺序提交")
    queue.append(point(2), at: 161)
    queue.requestFlush()
    check(queue.beginBatch(at: 200) == nil && queue.nextAttemptTime == nil,
          "写入队列-并发flush不能启动第二批")
    queue.complete(batchID: UUID(), succeeded: true, at: 200)
    check(queue.inFlight == first, "写入队列-未知完成通知不能释放正在写入的批次")
    queue.complete(batchID: first.id, succeeded: false, at: 200)
    check(queue.pendingCount == 3 && queue.nextAttemptTime == 202,
          "写入队列-失败保留整批并自动安排2秒后重试")
    queue.requestFlush()
    check(queue.beginBatch(at: 201) == nil, "写入队列-强制保存也不绕过失败退避")
    let retry = queue.beginBatch(at: 202)!
    check(retry == first, "写入队列-先重试原批次而不是后来的新点")
    queue.complete(batchID: retry.id, succeeded: false, at: 202)
    check(queue.nextAttemptTime == 206, "写入队列-连续失败指数退避")
    let success = queue.beginBatch(at: 206)!
    queue.complete(batchID: success.id, succeeded: true, at: 207)
    let next = queue.beginBatch(at: 207)!
    check(next.drafts == [point(2)], "写入队列-写入中的flush在前批成功后继续执行")
    queue.complete(batchID: next.id, succeeded: false, at: 207)
    check(queue.nextAttemptTime == 209, "写入队列-成功后重试间隔恢复初始值")

    var bounded = TrackBatchBuffer(configuration: .init(batchSize: 2))
    for index in 0..<5 { bounded.append(point(index), at: 0) }
    bounded.requestFlush()
    var saved: [FootprintDraft] = []
    var sizes: [Int] = []
    while let batch = bounded.beginBatch(at: 0) {
        saved += batch.drafts
        sizes.append(batch.drafts.count)
        bounded.complete(batchID: batch.id, succeeded: true, at: 0)
    }
    check(sizes == [2, 2, 1] && saved == (0..<5).map(point),
          "写入队列-积压数据按有界事务分批且不丢点重复")
    check(bounded.nextAttemptTime == nil && bounded.pendingCount == 0,
          "写入队列-清空后不留下无效定时器")

    for succeeded in [false, true] {
        var reset = TrackBatchBuffer(configuration: .init(batchSize: 1))
        reset.append(point(0), at: 0)
        let active = reset.beginBatch(at: 0)!
        reset.append(point(1), at: 1)
        reset.beginReset()
        check(!reset.finishResetIfIdle(), "写入队列-清理必须等待已开始的事务 \(succeeded)")
        check(!reset.append(point(2), at: 2), "写入队列-清理期间拒绝追加 \(succeeded)")
        reset.complete(batchID: active.id, succeeded: succeeded, at: 3)
        check(reset.pendingCount == 0 && reset.nextAttemptTime == nil,
              "写入队列-清理后旧事务成功或失败都不能复活旧点 \(succeeded)")
        check(reset.finishResetIfIdle() && reset.append(point(3), at: 4),
              "写入队列-清理结束后允许全新采集 \(succeeded)")
        check(reset.beginBatch(at: 4)?.drafts == [point(3)],
              "写入队列-新一代批次不混入旧点 \(succeeded)")
    }
    var discard = TrackBatchBuffer(configuration: .init(batchSize: 1))
    discard.append(point(0), at: 0)
    let discarded = discard.beginBatch(at: 0)!
    discard.discardPending()
    discard.append(point(1), at: 1)
    discard.complete(batchID: discarded.id, succeeded: false, at: 2)
    check(discard.beginBatch(at: 2)?.drafts == [point(1)],
          "写入队列-非等待式丢弃同样隔离旧失败批次")

    var capped = TrackBatchBuffer(configuration: .init(batchSize: 1, retryMaximumDelay: 5))
    capped.append(point(0), at: 0)
    var time = 0.0
    var delays: [Double] = []
    for _ in 0..<6 {
        let batch = capped.beginBatch(at: time)!
        capped.complete(batchID: batch.id, succeeded: false, at: time)
        let deadline = capped.nextAttemptTime!
        delays.append(deadline - time)
        time = deadline
    }
    check(delays == [2, 4, 5, 5, 5, 5], "写入队列-持续失败退避有上限")
    capped.beginReset()
    check(capped.pendingCount == 0 && capped.nextAttemptTime == nil && capped.finishResetIfIdle(),
          "写入队列-清理取消已经安排的重试")
}
