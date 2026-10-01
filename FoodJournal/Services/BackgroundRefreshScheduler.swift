import Foundation
import BackgroundTasks

// MARK: - 后台刷新调度器

/// 注册并调度 BGAppRefreshTask（com.pigeon.foodjournal.garmin-refresh）：
/// 系统按自身策略唤醒（earliestBeginDate = 2 小时后，实际频率由系统决定），
/// handler 内执行一轮后台同步，无论成败都重排下一次；超时（约 30s）触发 expirationHandler 安全中止。
@MainActor
final class BackgroundRefreshScheduler {
    static let shared = BackgroundRefreshScheduler()

    /// BGTask 任务标识（须与 project.yml 的 BGTaskSchedulerPermittedIdentifiers 一致）
    nonisolated static let taskIdentifier = "com.pigeon.foodjournal.garmin-refresh"
    /// 期望的刷新间隔：2 小时
    nonisolated static let refreshInterval: TimeInterval = 2 * 3600

    private init() {}

    /// earliestBeginDate = now + 2h（抽出纯函数便于单测）
    nonisolated static func earliestBeginDate(from now: Date) -> Date {
        now.addingTimeInterval(refreshInterval)
    }

    /// App 完成启动前调用（FoodJournalApp.init）：注册 handler 并提交第一次请求
    func registerHandlerAndSchedule() {
        registerHandler()
        scheduleNext()
    }

    func registerHandler() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(refreshTask)
        }
    }

    /// 提交下一次后台刷新请求（重复提交按同标识覆盖，幂等）
    func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.earliestBeginDate(from: .now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// BGTask 非 Sendable，跨隔离域传递（expirationHandler / 后台 Task）需装箱
    private final class TaskBox: @unchecked Sendable {
        let task: BGAppRefreshTask
        init(task: BGAppRefreshTask) { self.task = task }
    }

    /// 系统唤醒时执行：后台同步 → 无论成败重排下一次；expirationHandler 超时中止并重排
    private func handle(_ task: BGAppRefreshTask) {
        let boxedTask = TaskBox(task: task)
        let syncTask = Task { @MainActor [weak self] in
            _ = await SyncCoordinator.shared.sync(trigger: .background)
            if !Task.isCancelled {
                boxedTask.task.setTaskCompleted(success: true)
            }
            self?.scheduleNext()
        }
        task.expirationHandler = { @Sendable in
            syncTask.cancel()
            boxedTask.task.setTaskCompleted(success: false)
            Task { @MainActor [weak self] in
                self?.scheduleNext()
            }
        }
    }
}
