import Foundation
import AVFoundation

/// Central engine managing timeline state and fragment operations
@Observable
class TimelineEngine {
    private(set) var fragments: [TimelineFragment] = []
    private let history = TimelineHistory()

    var playheadPosition: Double = 0 {
        didSet {
            let maxDur = totalDuration > 0 ? totalDuration : _sourceDuration
            playheadPosition = max(0, min(playheadPosition, maxDur))
        }
    }

    var pixelsPerSecond: Double = 100
    var selectedFragmentID: UUID?

    /// Source video URL (temp copy)
    private(set) var sourceURL: URL?
    private var _sourceDuration: Double = 0

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    var totalDuration: Double {
        fragments.filter { $0.isIncluded }.reduce(0) { $0 + $1.sourceDuration }
    }

    var sourceDuration: Double { _sourceDuration }

    var timeSaved: Double {
        fragments.filter { $0.type == .silence && !$0.isIncluded }
            .reduce(0) { $0 + $1.sourceDuration }
    }

    var silenceCount: Int {
        fragments.filter { $0.type == .silence }.count
    }

    // MARK: - Source

    func setSource(url: URL, duration: Double) {
        sourceURL = url
        _sourceDuration = duration
    }

    // MARK: - Load

    func loadFragments(_ newFragments: [TimelineFragment]) {
        history.clear()
        fragments = newFragments
        selectedFragmentID = nil
    }

    // MARK: - Operations

    func toggleFragment(_ id: UUID) {
        guard let index = fragments.firstIndex(where: { $0.id == id }) else { return }
        saveUndoState(description: "Toggle fragment")
        var updated = fragments[index]
        updated.isIncluded.toggle()
        fragments[index] = updated
    }

    func removeAllSilence() {
        saveUndoState(description: "Remove all silence")
        for i in fragments.indices where fragments[i].type == .silence {
            var updated = fragments[i]
            updated.isIncluded = false
            fragments[i] = updated
        }
    }

    func restoreAllSilence() {
        saveUndoState(description: "Restore all silence")
        for i in fragments.indices where fragments[i].type == .silence {
            var updated = fragments[i]
            updated.isIncluded = true
            fragments[i] = updated
        }
    }

    func deleteFragment(_ id: UUID) {
        guard fragments.contains(where: { $0.id == id }) else { return }
        saveUndoState(description: "Delete fragment")
        if selectedFragmentID == id { selectedFragmentID = nil }
        fragments.removeAll { $0.id == id }
    }

    func splitFragment(_ id: UUID, at offset: Double) {
        guard let index = fragments.firstIndex(where: { $0.id == id }) else { return }
        let fragment = fragments[index]
        guard offset > 0 && offset < fragment.sourceDuration else { return }
        saveUndoState(description: "Split fragment")
        let first = TimelineFragment(sourceStartTime: fragment.sourceStartTime, sourceDuration: offset,
                                      type: fragment.type, isIncluded: fragment.isIncluded)
        let second = TimelineFragment(sourceStartTime: fragment.sourceStartTime + offset,
                                       sourceDuration: fragment.sourceDuration - offset,
                                       type: fragment.type, isIncluded: fragment.isIncluded)
        fragments.replaceSubrange(index...index, with: [first, second])
    }

    func trimFragment(_ id: UUID, newStartTime: Double? = nil, newDuration: Double? = nil) {
        guard let index = fragments.firstIndex(where: { $0.id == id }) else { return }
        var updated = fragments[index]
        if let s = newStartTime { updated.sourceStartTime = max(0, s) }
        if let d = newDuration { updated.sourceDuration = max(0.01, d) }
        fragments[index] = updated
    }

    func adjustFragmentEdges(_ id: UUID, leftDelta: Double = 0, rightDelta: Double = 0) {
        guard let index = fragments.firstIndex(where: { $0.id == id }) else { return }
        let f = fragments[index]
        var updated = f
        updated.sourceStartTime = max(0, f.sourceStartTime - leftDelta)
        updated.sourceDuration = max(0.01, (f.sourceEndTime + rightDelta) - updated.sourceStartTime)
        fragments[index] = updated
    }

    // MARK: - Undo / Redo

    func undo() {
        if let prev = history.undo(currentFragments: fragments, currentDescription: "Current") {
            fragments = prev
        }
    }

    func redo() {
        if let next = history.redo(currentFragments: fragments, currentDescription: "Current") {
            fragments = next
        }
    }

    private func saveUndoState(description: String) {
        history.saveState(fragments: fragments, description: description)
    }
}
