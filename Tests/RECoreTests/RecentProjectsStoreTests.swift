import Testing
import Foundation
@testable import RECore

/// Каждому тесту своё хранилище — иначе они видят чужие записи
private func freshDefaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: "recent.\(UUID().uuidString)")!
    RecentProjectsStore.defaults = suite
    return suite
}

private func project(_ name: String, at path: String, modified: Date = Date()) -> RecentProject {
    RecentProject(
        name: name,
        url: URL(fileURLWithPath: path),
        modifiedAt: modified,
        durationSeconds: 42,
        clipCount: 3,
        sourceCount: 1
    )
}

@Test func emptyStoreReturnsNothing() {
    _ = freshDefaults()
    #expect(RecentProjectsStore.all().isEmpty)
}

@Test func recordedProjectComesBackWithMetadata() {
    _ = freshDefaults()
    RecentProjectsStore.record(project("Ролик", at: "/tmp/a.silencecut"))

    let all = RecentProjectsStore.all()
    #expect(all.count == 1)
    #expect(all[0].name == "Ролик")
    #expect(all[0].clipCount == 3)
    #expect(abs(all[0].durationSeconds - 42) < 0.001)
}

@Test func newestProjectSortsFirst() {
    _ = freshDefaults()
    let old = Date(timeIntervalSince1970: 1000)
    let recent = Date(timeIntervalSince1970: 2000)
    RecentProjectsStore.record(project("Старый", at: "/tmp/old.silencecut", modified: old))
    RecentProjectsStore.record(project("Новый", at: "/tmp/new.silencecut", modified: recent))

    #expect(RecentProjectsStore.all().map(\.name) == ["Новый", "Старый"])
}

@Test func recordingSamePathUpdatesInsteadOfDuplicating() {
    _ = freshDefaults()
    RecentProjectsStore.record(project("Первое имя", at: "/tmp/a.silencecut"))
    RecentProjectsStore.record(project("Второе имя", at: "/tmp/a.silencecut"))

    let all = RecentProjectsStore.all()
    #expect(all.count == 1)
    #expect(all[0].name == "Второе имя")
}

@Test func pathsAreComparedAfterStandardization() {
    _ = freshDefaults()
    RecentProjectsStore.record(project("Прямой", at: "/tmp/dir/a.silencecut"))
    RecentProjectsStore.record(project("Кружной", at: "/tmp/dir/./a.silencecut"))

    #expect(RecentProjectsStore.all().count == 1)
}

@Test func listIsCappedAtLimit() {
    _ = freshDefaults()
    for index in 0..<(RecentProjectsStore.limit + 10) {
        RecentProjectsStore.record(project(
            "П\(index)",
            at: "/tmp/\(index).silencecut",
            modified: Date(timeIntervalSince1970: Double(index))
        ))
    }
    let all = RecentProjectsStore.all()
    #expect(all.count == RecentProjectsStore.limit)
    // Выпадают самые старые
    #expect(all.first?.name == "П\(RecentProjectsStore.limit + 9)")
}

@Test func removeDropsOnlyThatProject() {
    _ = freshDefaults()
    RecentProjectsStore.record(project("A", at: "/tmp/a.silencecut"))
    RecentProjectsStore.record(project("B", at: "/tmp/b.silencecut"))

    RecentProjectsStore.remove(url: URL(fileURLWithPath: "/tmp/a.silencecut"))

    #expect(RecentProjectsStore.all().map(\.name) == ["B"])
}

@Test func clearEmptiesTheList() {
    _ = freshDefaults()
    RecentProjectsStore.record(project("A", at: "/tmp/a.silencecut"))
    RecentProjectsStore.clear()
    #expect(RecentProjectsStore.all().isEmpty)
}

@Test func missingFileIsReportedButKept() {
    _ = freshDefaults()
    RecentProjectsStore.record(project("Уехал", at: "/tmp/точно-нет-\(UUID()).silencecut"))

    let all = RecentProjectsStore.all()
    #expect(all.count == 1)
    #expect(all[0].fileExists == false)
}
