import Testing
@testable import SilenceCut

@Test func silenceDetectionSettingsDefaults() {
    let settings = SilenceDetectionSettings.normal
    #expect(settings.thresholdDB == -30.0)
    #expect(settings.minDurationSec == 0.3)
    #expect(settings.paddingMs == 100)
}

@Test func silenceDetectionSettingsPresets() {
    let aggressive = SilenceDetectionSettings.aggressive
    #expect(aggressive.thresholdDB == -25)
    #expect(aggressive.minDurationSec == 0.2)

    let conservative = SilenceDetectionSettings.conservative
    #expect(conservative.thresholdDB == -40)
    #expect(conservative.minDurationSec == 0.5)
}

@Test func timelineFragmentProperties() {
    let fragment = TimelineFragment(
        sourceStartTime: 10.0,
        sourceDuration: 5.0,
        type: .speech,
        isIncluded: true
    )

    #expect(fragment.sourceEndTime == 15.0)
    #expect(fragment.type == .speech)
    #expect(fragment.isIncluded)
}

@Test func timelineHistoryUndoRedo() {
    let history = TimelineHistory()

    let original = [TimelineFragment(sourceStartTime: 0, sourceDuration: 5, type: .speech)]
    let modified = [TimelineFragment(sourceStartTime: 0, sourceDuration: 3, type: .speech)]

    // Save state and check undo
    history.saveState(fragments: original, description: "Original")
    #expect(history.canUndo)
    #expect(!history.canRedo)

    // Undo
    let undone = history.undo(currentFragments: modified, currentDescription: "Modified")
    #expect(undone != nil)
    #expect(undone?.count == 1)
    #expect(undone?.first?.sourceDuration == 5.0)

    // Now can redo
    #expect(!history.canUndo)
    #expect(history.canRedo)

    // Redo
    let redone = history.redo(currentFragments: original, currentDescription: "Original")
    #expect(redone != nil)
    #expect(redone?.first?.sourceDuration == 3.0)
}

@Test func timelineEngineSplit() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 10, type: .speech)
    ]
    engine.loadFragments(fragments)

    engine.splitFragment(engine.fragments[0].id, at: 4.0)

    #expect(engine.fragments.count == 2)
    #expect(engine.fragments[0].sourceDuration == 4.0)
    #expect(engine.fragments[1].sourceDuration == 6.0)
    #expect(engine.fragments[1].sourceStartTime == 4.0)
}

@Test func timelineEngineToggle() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 5, type: .silence, isIncluded: false)
    ]
    engine.loadFragments(fragments)

    let id = engine.fragments[0].id
    engine.toggleFragment(id)
    #expect(engine.fragments[0].isIncluded == true)

    engine.toggleFragment(id)
    #expect(engine.fragments[0].isIncluded == false)
}

@Test func timelineEngineRemoveAllSilence() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 5, type: .speech, isIncluded: true),
        TimelineFragment(sourceStartTime: 5, sourceDuration: 2, type: .silence, isIncluded: true),
        TimelineFragment(sourceStartTime: 7, sourceDuration: 5, type: .speech, isIncluded: true),
        TimelineFragment(sourceStartTime: 12, sourceDuration: 1, type: .silence, isIncluded: true),
    ]
    engine.loadFragments(fragments)

    engine.removeAllSilence()

    let silenceFragments = engine.fragments.filter { $0.type == .silence }
    #expect(silenceFragments.allSatisfy { !$0.isIncluded })

    let speechFragments = engine.fragments.filter { $0.type == .speech }
    #expect(speechFragments.allSatisfy { $0.isIncluded })
}

@Test func timelineEngineUndo() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 5, type: .speech, isIncluded: true),
        TimelineFragment(sourceStartTime: 5, sourceDuration: 2, type: .silence, isIncluded: true),
    ]
    engine.loadFragments(fragments)

    engine.removeAllSilence()
    #expect(engine.fragments[1].isIncluded == false)

    engine.undo()
    #expect(engine.fragments[1].isIncluded == true)
}

@Test func exportSettingsDefaults() {
    let settings = ExportSettings()
    #expect(settings.preset == .high)
    #expect(settings.format == .mp4)
}

@Test func timelineEngineDeleteClearsSelection() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 5, type: .speech),
        TimelineFragment(sourceStartTime: 5, sourceDuration: 3, type: .silence),
    ]
    engine.loadFragments(fragments)

    let id = engine.fragments[1].id
    engine.selectedFragmentID = id
    #expect(engine.selectedFragmentID == id)

    engine.deleteFragment(id)
    #expect(engine.selectedFragmentID == nil)
    #expect(engine.fragments.count == 1)
}

@Test func timelineEngineTimeSaved() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 10, type: .speech, isIncluded: true),
        TimelineFragment(sourceStartTime: 10, sourceDuration: 3, type: .silence, isIncluded: true),
        TimelineFragment(sourceStartTime: 13, sourceDuration: 7, type: .speech, isIncluded: true),
    ]
    engine.loadFragments(fragments)

    #expect(engine.timeSaved == 0) // nothing removed yet

    engine.removeAllSilence()
    #expect(engine.timeSaved == 3.0)
    #expect(engine.totalDuration == 17.0)
}

@Test func timelineEnginePlayheadClamped() {
    let engine = TimelineEngine()
    let fragments = [
        TimelineFragment(sourceStartTime: 0, sourceDuration: 10, type: .speech, isIncluded: true),
    ]
    engine.loadFragments(fragments)

    // totalDuration = 10 (all included)
    engine.playheadPosition = 15.0
    #expect(engine.playheadPosition == 10.0)

    engine.playheadPosition = -5.0
    #expect(engine.playheadPosition == 0.0)
}
