import Foundation

/// Snapshot of the timeline state for undo/redo
struct TimelineSnapshot: Equatable {
    let fragments: [TimelineFragment]
    let description: String
}

/// Manages undo/redo history for timeline operations
@Observable
class TimelineHistory {
    private var undoStack: [TimelineSnapshot] = []
    private var redoStack: [TimelineSnapshot] = []
    private let maxHistory = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var undoDescription: String? { undoStack.last?.description }
    var redoDescription: String? { redoStack.last?.description }

    /// Save current state before making a change
    func saveState(fragments: [TimelineFragment], description: String) {
        let snapshot = TimelineSnapshot(fragments: fragments, description: description)
        undoStack.append(snapshot)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    /// Undo: returns the previous state
    func undo(currentFragments: [TimelineFragment], currentDescription: String) -> [TimelineFragment]? {
        guard let previous = undoStack.popLast() else { return nil }
        let current = TimelineSnapshot(fragments: currentFragments, description: currentDescription)
        redoStack.append(current)
        return previous.fragments
    }

    /// Redo: returns the next state
    func redo(currentFragments: [TimelineFragment], currentDescription: String) -> [TimelineFragment]? {
        guard let next = redoStack.popLast() else { return nil }
        let current = TimelineSnapshot(fragments: currentFragments, description: currentDescription)
        undoStack.append(current)
        return next.fragments
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
