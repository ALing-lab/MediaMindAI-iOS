import SwiftUI

/// 1:1 复刻自 Android `TaskItemsScreen.kt`：任务内逐条操作状态筛选（全部/成功/失败/未执行）、失败项依赖闭包勾选（`FailedRetry`）与选中子集重试。
public struct TaskItemsView: View {
    public let run: TaskRun

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case failed = "失败"
        case done = "成功"
        case pending = "未执行"
        var id: String { rawValue }
    }

    @State private var store = PlanAndTaskStore.shared
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var selectedFailedIds: Set<String> = []
    @State private var retryHint: String?

    public init(run: TaskRun) {
        self.run = run
    }

    private var linkedPlan: ScrapePlan? {
        store.plans.first(where: { $0.id == run.planId })
    }

    public var body: some View {
        let allActions = linkedPlan?.actions.filter { $0.op != "unmatched" } ?? []
        let failedActions = allActions.filter { !$0.done && $0.error != nil }
        let failedSet = Set(failedActions.map(\.id))
        let filtered = allActions.filter { act in
            let statusOk: Bool
            switch filter {
            case .all: statusOk = true
            case .failed: statusOk = !act.done && act.error != nil
            case .done: statusOk = act.done
            case .pending: statusOk = !act.done && act.error == nil
            }
            guard statusOk else { return false }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return act.newName.lowercased().contains(q) || act.oldName.lowercased().contains(q)
        }
        let activeSelection = selectedFailedIds.intersection(failedSet)

        VStack(spacing: 0) {
            Picker("状态筛选", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .padding()

            if !failedActions.isEmpty, let plan = linkedPlan {
                HStack(spacing: 12) {
                    Button(activeSelection.count == failedSet.count ? "取消全选" : "全选失败项") {
                        let selectAll = activeSelection.count != failedSet.count
                        selectedFailedIds = FailedRetry.toggle(
                            selected: activeSelection,
                            ids: Array(failedSet),
                            on: selectAll,
                            failed: failedSet,
                            plan: plan
                        )
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Text("已选 \(activeSelection.count)/\(failedSet.count) 项失败")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if let retryHint {
                Text(retryHint)
                    .font(.caption)
                    .foregroundStyle(MMTheme.accent)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            if filtered.isEmpty {
                ContentUnavailableView("无匹配的操作项", systemImage: "checklist", description: Text("切换筛选条件或关键词查看其他记录。"))
            } else {
                List(filtered) { act in
                    let isFailed = !act.done && act.error != nil
                    let isChecked = activeSelection.contains(act.id)
                    HStack(alignment: .top, spacing: 10) {
                        if isFailed, let plan = linkedPlan {
                            Button {
                                selectedFailedIds = FailedRetry.toggle(
                                    selected: activeSelection,
                                    ids: [act.id],
                                    on: !isChecked,
                                    failed: failedSet,
                                    plan: plan
                                )
                            } label: {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isChecked ? MMTheme.accent : .secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("[\(act.op)] \(act.newName.isEmpty ? act.oldName : act.newName)")
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                Spacer()
                                if act.done {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(MMTheme.greenOk)
                                } else if act.error != nil {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(MMTheme.redErr)
                                } else {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                }
                            }
                            if !act.oldName.isEmpty && act.oldName != act.newName {
                                Text("原：\(act.oldName)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let err = act.error {
                                Text(err).font(.caption2).foregroundStyle(MMTheme.redErr)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .searchable(text: $query, prompt: "搜索文件名")
        .navigationTitle("任务操作明细")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedFailedIds.isEmpty {
                selectedFailedIds = failedSet
            }
        }
        .toolbar {
            if !failedActions.isEmpty, let plan = linkedPlan {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重试选中 (\(activeSelection.count))") {
                        retrySelected(plan: plan, selectedIds: activeSelection)
                    }
                    .disabled(activeSelection.isEmpty)
                }
            }
        }
    }

    private func retrySelected(plan: ScrapePlan, selectedIds: Set<String>) {
        guard !selectedIds.isEmpty else { return }
        guard let acct = AccountStore.shared.get(id: plan.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            retryHint = "找不到该任务所属云盘账号，无法重试"
            return
        }
        // 按原计划动作顺序固定排序，保证 TaskQueue 去重稳定；不提前抹除 error（由 ExecutionEngine 启动校验通过后再清理）
        let orderedSelected = plan.actions.map(\.id).filter { selectedIds.contains($0) }
        let idsToRun = FailedRetry.retryIds(selected: orderedSelected, plan: plan)
        let idSet = Set(idsToRun)
        var retryPlan = plan
        for i in retryPlan.actions.indices where idSet.contains(retryPlan.actions[i].id) {
            retryPlan.actions[i].selected = true
        }
        PlanAndTaskStore.shared.savePlan(retryPlan)
        ExecutionEngine.shared.enqueueOrStart(plan: retryPlan, drive: drive, actionIds: idsToRun)
        let extraDeps = max(0, idsToRun.count - selectedIds.count)
        retryHint = extraDeps > 0
            ? "已提交重试 \(selectedIds.count) 项（自动连带 \(extraDeps) 项前置目录依赖）"
            : "已将选中的 \(idsToRun.count) 项失败操作提交执行队列"
    }
}
