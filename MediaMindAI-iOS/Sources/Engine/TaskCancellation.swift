import Foundation
import Observation

/// 1:1 复刻自 Android `TaskCancellation.kt`（94 行）：
/// 持久化任务取消控制记录（支持「保留已完成结果」或「撤销已完成操作」两种模式），防止取消途中崩溃丢失意图。
public struct TaskControl: Identifiable, Codable, Hashable, Sendable {
    public let taskId: String
    public let accountId: String
    public var mode: String // "keep" | "undo"
    public var state: String // "requested" | "undoing" | "conflict" | "needs_backup_choice" | "needs_asset_choice" | "completed"
    public var missingBackupIds: [String]
    public var acceptedSubstitutions: [String]
    public var unverifiedAssetIds: [String]
    public var acceptedUnverifiedAssetIds: [String]
    public var updatedAt: Date

    public var id: String { taskId }

    public init(
        taskId: String,
        accountId: String,
        mode: String,
        state: String = "requested",
        missingBackupIds: [String] = [],
        acceptedSubstitutions: [String] = [],
        unverifiedAssetIds: [String] = [],
        acceptedUnverifiedAssetIds: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.taskId = taskId
        self.accountId = accountId
        self.mode = mode
        self.state = state
        self.missingBackupIds = missingBackupIds
        self.acceptedSubstitutions = acceptedSubstitutions
        self.unverifiedAssetIds = unverifiedAssetIds
        self.acceptedUnverifiedAssetIds = acceptedUnverifiedAssetIds
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case taskId, accountId, mode, state, missingBackupIds, acceptedSubstitutions, unverifiedAssetIds, acceptedUnverifiedAssetIds, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        accountId = try c.decode(String.self, forKey: .accountId)
        mode = try c.decode(String.self, forKey: .mode)
        state = try c.decode(String.self, forKey: .state)
        missingBackupIds = (try? c.decodeIfPresent([String].self, forKey: .missingBackupIds)) ?? []
        acceptedSubstitutions = (try? c.decodeIfPresent([String].self, forKey: .acceptedSubstitutions)) ?? []
        unverifiedAssetIds = (try? c.decodeIfPresent([String].self, forKey: .unverifiedAssetIds)) ?? []
        acceptedUnverifiedAssetIds = (try? c.decodeIfPresent([String].self, forKey: .acceptedUnverifiedAssetIds)) ?? []
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

@MainActor
@Observable
public final class TaskCancellation: @unchecked Sendable {
    public static let shared = TaskCancellation()

    public private(set) var controls: [String: TaskControl] = [:]
    private let fileUrl: URL
    @ObservationIgnored private var applyingTasks: Set<String> = []

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileUrl = storageURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = dir.appendingPathComponent("MediaMindAI", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileUrl = folder.appendingPathComponent("task_controls.json")
        }
        if let d = try? Data(contentsOf: fileUrl), let decoded = try? JSONDecoder().decode([String: TaskControl].self, from: d) {
            self.controls = decoded
        }
    }

    public func request(taskId: String, accountId: String, undo: Bool, acceptedSubstitutions: [String] = [], acceptedUnverifiedAssetIds: [String] = []) throws -> TaskControl {
        if let existing = controls[taskId],
           existing.state != "conflict" && existing.state != "needs_backup_choice" && existing.state != "needs_asset_choice" && existing.state != "completed" {
            throw DriveError.invalidInput("取消请求已保存，请等待处理")
        }
        let ctrl = TaskControl(
            taskId: taskId,
            accountId: accountId,
            mode: undo ? "undo" : "keep",
            state: "requested",
            acceptedSubstitutions: Array(Set(controls[taskId]?.acceptedSubstitutions ?? []).union(acceptedSubstitutions)).sorted(),
            acceptedUnverifiedAssetIds: Array(Set(controls[taskId]?.acceptedUnverifiedAssetIds ?? []).union(acceptedUnverifiedAssetIds)).sorted()
        )
        controls[taskId] = ctrl
        persist()
        if ExecutionEngine.shared.currentRun?.id == taskId {
            ExecutionEngine.shared.stop()
        }
        return ctrl
    }

    public func pendingControls() -> [TaskControl] {
        controls.values.filter { $0.state == "requested" || $0.state == "undoing" }
    }

    /// 仅收口「保留已完成项」控制记录（无需云盘实例，避免保留区被 requested 状态永久锁定）。
    public func applyKeep(control: TaskControl) async -> TaskControl {
        var next = control
        if ExecutionEngine.shared.currentRun?.id == control.taskId {
            await ExecutionEngine.shared.stopAndWait()
        }
        next.state = "completed"
        next.updatedAt = Date()
        controls[control.taskId] = next
        persist()
        syncTaskRunStatus(taskId: control.taskId, status: "stopped", message: "任务已停止（保留已完成项）")
        return next
    }

    public func apply(
        control: TaskControl,
        drive: any CloudDrive,
        substitutionActions: [String: PlanAction] = [:],
        journal: OperationJournal = .shared
    ) async -> TaskControl {
        guard applyingTasks.insert(control.taskId).inserted else { return controls[control.taskId] ?? control }
        defer { applyingTasks.remove(control.taskId) }
        var next = control
        if !control.accountId.isEmpty && drive.accountId != control.accountId {
            next.state = "conflict"
            next.updatedAt = Date()
            controls[control.taskId] = next
            persist()
            syncTaskRunStatus(taskId: control.taskId, status: "stopped", message: "撤销暂停：任务账号与当前网盘不匹配")
            return next
        }
        if control.mode == "undo", ExecutionEngine.shared.isRollingBack
            || (ExecutionEngine.shared.isRunning && ExecutionEngine.shared.currentRun?.id != control.taskId) {
            next.state = "conflict"
            next.updatedAt = Date()
            controls[control.taskId] = next
            persist()
            return next
        }
        // 确保在途正向云盘写入任务已彻底退出，再进入保留/撤销收口，杜绝并发写/撤销竞态
        if ExecutionEngine.shared.currentRun?.id == control.taskId {
            await ExecutionEngine.shared.stopAndWait()
        }
        if control.mode == "keep" {
            next.state = "completed"
            next.updatedAt = Date()
            controls[control.taskId] = next
            persist()
            syncTaskRunStatus(taskId: control.taskId, status: "stopped", message: "任务已停止（保留已完成项）")
            return next
        }
        next.state = "undoing"
        controls[control.taskId] = next
        persist()

        let summary = await ExecutionEngine.shared.rollback(
            runId: control.taskId, drive: drive,
            substitutionActions: substitutionActions,
            acceptedSubstitutions: Set(control.acceptedSubstitutions),
            acceptedUnverifiedAssets: Set(control.acceptedUnverifiedAssetIds),
            journal: journal
        )
        next.missingBackupIds = summary.missingBackups.map(\.actionId)
        next.unverifiedAssetIds = summary.unverifiedAssets.map(\.id)
        let message: String
        if !summary.missingBackups.isEmpty {
            next.state = "needs_backup_choice"
            message = "撤销暂停：缺失备份，请在任务中心选择补齐方式"
        } else if !summary.unverifiedAssets.isEmpty {
            next.state = "needs_asset_choice"
            message = "撤销暂停：素材缺少校验信息，请确认是否转存后继续"
        } else if summary.failed > 0 {
            next.state = "conflict"
            message = "撤销暂停：\(summary.errors.joined(separator: "；"))"
        } else {
            next.state = "completed"
            message = "任务已停止并撤销已完成操作"
        }
        syncTaskRunStatus(taskId: control.taskId, status: "stopped", message: message)
        next.updatedAt = Date()
        controls[control.taskId] = next
        persist()
        return next
    }

    private func syncTaskRunStatus(taskId: String, status: String, message: String) {
        if var run = PlanAndTaskStore.shared.tasks.first(where: { $0.id == taskId }) {
            run.status = status
            run.message = message
            if run.finishedAt == nil { run.finishedAt = Date() }
            PlanAndTaskStore.shared.saveTask(run)
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(controls) {
            try? d.write(to: fileUrl, options: .atomic)
        }
    }
}
