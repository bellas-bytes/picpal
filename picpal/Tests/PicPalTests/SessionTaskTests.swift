import Testing
@testable import PicPal

// MARK: - SessionTaskTests

/// Unit tests for `SessionTask` and `SessionTaskScript`.
///
/// Tests verify:
/// 1. `m4Tasks` contains exactly eight tasks.
/// 2. All task IDs are distinct.
/// 3. No task has an empty title or empty instructions.
/// 4. The ID set is precisely {1, 2, 3, 4, 5, 6, 7, 8}.
struct SessionTaskTests {

    // MARK: - Test 1: count

    @Test("m4Tasks has exactly eight tasks")
    func m4Tasks_hasExactlyEightTasks() {
        #expect(SessionTaskScript.m4Tasks.count == 8)
    }

    // MARK: - Test 2: unique IDs

    @Test("m4Tasks has unique IDs")
    func m4Tasks_hasUniqueIDs() {
        let ids = SessionTaskScript.m4Tasks.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(uniqueIDs.count == ids.count)
    }

    // MARK: - Test 3: non-empty strings

    @Test("m4Tasks has no empty titles or instructions")
    func m4Tasks_noEmptyTitles() {
        for task in SessionTaskScript.m4Tasks {
            #expect(!task.title.isEmpty, "Task \(task.id) has an empty title")
            #expect(!task.instructions.isEmpty, "Task \(task.id) has empty instructions")
        }
    }

    // MARK: - Test 4: IDs are 1 through 8

    @Test("m4Tasks IDs are exactly the set {1, 2, 3, 4, 5, 6, 7, 8}")
    func m4Tasks_idsAreOneThrough8() {
        let expectedIDs = Set(1...8)
        let actualIDs = Set(SessionTaskScript.m4Tasks.map(\.id))
        #expect(actualIDs == expectedIDs)
    }
}
