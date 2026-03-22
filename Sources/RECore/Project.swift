import Foundation

/// Represents a saved editing project
public struct Project: Codable {
    public var name: String
    public var sourceURL: URL?
    public var sourceBookmarkData: Data?
    public var timeline: EditTimeline
    public var createdAt: Date
    public var modifiedAt: Date

    public init(name: String = "Untitled", sourceURL: URL? = nil, timeline: EditTimeline = EditTimeline()) {
        self.name = name
        self.sourceURL = sourceURL
        self.timeline = timeline
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    /// Create security-scoped bookmark for the source URL
    public mutating func createBookmark() throws {
        guard let url = sourceURL else { return }
        sourceBookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve security-scoped bookmark
    public mutating func resolveBookmark() throws -> URL? {
        guard let data = sourceBookmarkData else { return sourceURL }
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale { try createBookmark() }
        sourceURL = url
        return url
    }
}
