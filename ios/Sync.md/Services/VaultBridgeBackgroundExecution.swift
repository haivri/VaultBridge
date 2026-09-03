import BackgroundTasks
import UIKit

/// Owns user-started work after it leaves the foreground. iOS 26 continued
/// processing is preferred; older systems receive the maximum short execution
/// assertion available and rely on the durable sync journal for resume.
@MainActor
final class VaultBridgeBackgroundExecution {
    static let shared = VaultBridgeBackgroundExecution()

    private struct Pending {
        let operation: @MainActor () async -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var pending: [String: Pending] = [:]
    private var registeredIdentifier: String?

    func run(title: String, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        #if targetEnvironment(simulator)
        // BackgroundTasks cannot launch continued-processing jobs reliably in
        // Simulator. Exercise the same structured operation under the ordinary
        // background assertion used by older devices.
        return await runWithShortAssertion(title: title, operation: operation)
        #else
        if #available(iOS 26.0, *), let baseIdentifier = Bundle.main.bundleIdentifier {
            let wildcard = "\(baseIdentifier).vaultbridge.sync.*"
            registerContinuedHandler(identifier: wildcard)
            let identifier = "\(baseIdentifier).vaultbridge.sync.\(UUID().uuidString)"

            return await withCheckedContinuation { continuation in
                pending[identifier] = Pending(operation: operation, continuation: continuation)
                let request = BGContinuedProcessingTaskRequest(
                    identifier: identifier,
                    title: title,
                    subtitle: "Saving locally, comparing, and safely synchronizing"
                )
                request.strategy = .fail
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    pending.removeValue(forKey: identifier)
                    Task { @MainActor in
                        continuation.resume(returning: await runWithShortAssertion(title: title, operation: operation))
                    }
                }
            }
        }
        return await runWithShortAssertion(title: title, operation: operation)
        #endif
    }

    func runAutomatic(title: String, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        await runWithShortAssertion(title: title, operation: operation)
    }

    @available(iOS 26.0, *)
    private func registerContinuedHandler(identifier: String) {
        guard registeredIdentifier != identifier else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                await self?.handle(continuedTask)
            }
        }
        if registered { registeredIdentifier = identifier }
    }

    @available(iOS 26.0, *)
    private func handle(_ backgroundTask: BGContinuedProcessingTask) async {
        guard let item = pending.removeValue(forKey: backgroundTask.identifier) else {
            backgroundTask.setTaskCompleted(success: false)
            return
        }

        backgroundTask.progress.totalUnitCount = 7
        backgroundTask.progress.completedUnitCount = 1
        let worker = Task { @MainActor in await item.operation() }
        backgroundTask.expirationHandler = { worker.cancel() }
        let success = await worker.value
        backgroundTask.progress.completedUnitCount = success ? 7 : 1
        backgroundTask.setTaskCompleted(success: success)
        item.continuation.resume(returning: success)
    }

    private func runWithShortAssertion(
        title: String,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        // Run in the caller's structured task. Capturing a child Task from the
        // expiration closure can outlive XCTest/app task-local storage and has
        // triggered Swift concurrency deallocation traps. iOS will suspend the
        // process after expiration; the durable journal makes the next run
        // idempotently resume from repository state.
        let identifier = UIApplication.shared.beginBackgroundTask(withName: title, expirationHandler: nil)
        defer {
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        }
        return await operation()
    }
}
