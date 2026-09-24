import Foundation

/// Preserve revisits and nearby samples. Only the same source, measured instant,
/// exact coordinate and recorded boundaries identify a repeated measurement.
public struct ImportPointIdentity: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let source: String
    public let trajectoryID: String?
    public let sessionID: String?
    public let segmentID: String?

    public init(_ draft: FootprintDraft) {
        latitude = draft.latitude
        longitude = draft.longitude
        timestamp = draft.timestamp
        source = draft.source
        trajectoryID = draft.trajectoryID
        sessionID = draft.sessionID
        segmentID = draft.segmentID
    }
}
