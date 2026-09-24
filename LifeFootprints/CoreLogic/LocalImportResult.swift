import Foundation

public struct LocalImportResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case completed, failed, cancelled }
    public var added = 0
    public var updated = 0
    public var duplicates = 0
    public var invalid = 0
    public var status: Status
    public init(status: Status = .completed) { self.status = status }
}
