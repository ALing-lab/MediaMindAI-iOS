import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 第 2 批（data/exec/ 1:1 逐行直译）独立单元测试套件：
/// 覆盖 NfoXml、ImageBytes、JournalReconciler（正向与 undo_prepared 逆向核实）与 TaskCancellation。
final class Batch2ExecTests: XCTestCase {

    private final class MockExecDrive: CloudDrive, @unchecked Sendable {
        let kind: ProviderKind = .webdav
        let accountId: String = "acc-exec"
        let rootId: String = "/"
        var listings: [String: [CloudEntry]] = [:]
        var renamed: [(String, String)] = []

        func list(folderId: String) async throws -> [CloudEntry] { listings[folderId] ?? [] }
        func rename(fileId: String, newName: String) async throws -> String {
            renamed.append((fileId, newName))
            return DrivePaths.join(parent: DrivePaths.parentOf(fileId), name: newName)
        }
        func mkdir(parentId: String, name: String) async throws -> String { DrivePaths.join(parent: parentId, name: name) }
        func move(fileId: String, destParentId: String) async throws -> String { fileId }
        func upload(parentId: String, name: String, data: Data) async throws -> String { DrivePaths.join(parent: parentId, name: name) }
        func trash(fileId: String) async throws -> String { fileId }
    }

    func testNfoXmlEscapingCdataSplittingAndImageBytes() {
        XCTAssertEqual(NfoXml.esc("A & B <C> \"D\" 'E'\u{0001}"), "A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;")
        let cd = NfoXml.cdata(name: "plot", value: "hello ]]> world\u{0007}")
        XCTAssertEqual(cd, "  <plot><![CDATA[hello ]]]]><![CDATA[> world]]></plot>")
        XCTAssertEqual(NfoXml.flat("  line1 \r\n  line2  "), "line1line2")

        XCTAssertEqual(ImageBytes.safeExt(url: "https://image.tmdb.org/t/p/w780/a.png?v=1"), "png")
        XCTAssertEqual(ImageBytes.safeExt(url: "https://example.com/file.exe"), "jpg")
        XCTAssertTrue(ImageBytes.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertFalse(ImageBytes.looksLikeImage(Data("<html>not img</html>".utf8)))
    }

    @MainActor
    func testJournalReconcilerForwardAndUndoPreparedDeadlockRecovery() async {
        let tmp = FileManager.default.temporaryDirectory
        let journal = OperationJournal(storageURL: tmp.appendingPathComponent("test_reconcile_\(UUID().uuidString).json"))

        // 1. 正向中断：目标已存在且原名消失 -> applied
        let r1 = journal.prepare(runId: "r1", actionId: "a1", op: "rename", kind: "file", fileId: "/m/old.mkv", parentId: "/m", destParentId: "/m", oldName: "old.mkv", newName: "new.mkv")
        journal.markUncertain(rowId: r1.id, error: "timeout")

        // 2. 撤销中断（undo_prepared）：原名已恢复且新名消失 -> reverted (.undone)
        let r2 = journal.prepare(runId: "r1", actionId: "a2", op: "rename", kind: "file", fileId: "/m/orig.mkv", parentId: "/m", destParentId: "/m", oldName: "orig.mkv", newName: "renamed.mkv")
        journal.markStatus(rowId: r2.id, status: .undoPrepared)

        let drive = MockExecDrive()
        drive.listings["/m"] = [
            CloudEntry(fileId: "/m/new.mkv", fileName: "new.mkv", isDir: false),
            CloudEntry(fileId: "/m/orig.mkv", fileName: "orig.mkv", isDir: false),
        ]

        let report = await JournalReconciler.reconcile(runId: "r1", drive: drive, journal: journal)
        XCTAssertEqual(report.confirmedApplied, 1)
        XCTAssertEqual(report.confirmedReverted, 1)
        XCTAssertEqual(report.stillUncertain, 0)
        XCTAssertEqual(journal.rows.first(where: { $0.id == r1.id })?.status, .applied)
        XCTAssertEqual(journal.rows.first(where: { $0.id == r2.id })?.status, .undone)
    }

    @MainActor
    func testTaskCancellationKeepAndUndoModes() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let cancelStore = TaskCancellation(storageURL: tmp.appendingPathComponent("test_cancel_\(UUID().uuidString).json"))
        let journal = OperationJournal(storageURL: tmp.appendingPathComponent("test_cj_\(UUID().uuidString).json"))
        let drive = MockExecDrive()

        let cKeep = try cancelStore.request(taskId: "t1", accountId: "acc-exec", undo: false)
        let doneKeep = await cancelStore.apply(control: cKeep, drive: drive, journal: journal)
        XCTAssertEqual(doneKeep.state, "completed")

        let row = journal.prepare(runId: "t2", actionId: "a1", op: "rename", kind: "file", fileId: "/m/a.mkv", parentId: "/m", destParentId: "/m", oldName: "a.mkv", newName: "b.mkv")
        journal.markApplied(rowId: row.id, createdId: "/m/b.mkv")
        let cUndo = try cancelStore.request(taskId: "t2", accountId: "acc-exec", undo: true)
        let doneUndo = await cancelStore.apply(control: cUndo, drive: drive, journal: journal)
        XCTAssertEqual(doneUndo.state, "completed")
        XCTAssertEqual(drive.renamed.first?.1, "a.mkv")
    }
}
