import BackgroundTasks
import UIKit

/// Owns user-started work after it leaves the foreground.
///
/// Every run holds a short background assertion whose expiration handler
/// cancels the work and releases the assertion. iOS terminates a process that
/// lets an assertion expire without ending it, so the handler is not optional.
/// On iOS 26 devices a continued-processing task is additionally requested so
/// a long synchronization can outlive the short assertion; its launch handler
/// simply observes the same worker task. No continuations are involved, which
/// keeps the structured caller task and the system callbacks from ever
/// resuming or deallocating each other's storage.
@MainActor
final class VaultBridgeBackgroundExecution {
    static let shared = VaultBridgeBackgroundExecution()

    /// Small box so the expiration closure can end the assertion it belongs to
    /// exactly once, even if the run finishes at the same moment.
    private final class Assertion {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var ended = false

        func end() {
            guard !ended else { return }
            ended = true
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }

    private var workers: [String: Task<Bool, Never>] = [:]
    private var registeredIdentifier: String?

    func run(title: String, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        await execute(title: title, requestsContinuedProcessing: true, operation: operation)
    }

    func runAutomatic(title: String, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        await execute(title: title, requestsContinuedProcessing: false, operation: operation)
    }

    private func execute(
        title: String,
        requestsContinuedProcessing: Bool,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let worker = Task { @MainActor in await operation() }

        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: title) {
            // The system is about to suspend the process. Stop the work at
            // its next cancellation point and release the assertion so the
            // app is suspended, not killed. The durable journal and
            // repository state make the next run resume idempotently.
            worker.cancel()
            assertion.end()
        }

        #if !targetEnvironment(simulator)
        if requestsContinuedProcessing {
            requestContinuedProcessingIfAvailable(title: title, worker: worker)
        }
        #endif

        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        assertion.end()
        workers = workers.filter { $0.value != worker }
        return result
    }

    private func requestContinuedProcessingIfAvailable(title: String, worker: Task<Bool, Never>) {
        guard #available(iOS 26.0, *), let baseIdentifier = Bundle.main.bundleIdentifier else { return }
        let wildcard = "\(baseIdentifier).vaultbridge.sync.*"
        registerContinuedHandler(identifier: wildcard)
        guard registeredIdentifier == wildcard else { return }

        let identifier = "\(baseIdentifier).vaultbridge.sync.\(UUID().uuidString)"
        workers[identifier] = worker
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: "Saving, comparing, and uploading safely"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Continued processing is a bonus, never a requirement. The short
            // assertion above already covers the common case.
            workers.removeValue(forKey: identifier)
        }
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
        guard let worker = workers.removeValue(forKey: backgroundTask.identifier) else {
            backgroundTask.setTaskCompleted(success: false)
            return
        }

        backgroundTask.progress.totalUnitCount = 1
        backgroundTask.expirationHandler = { worker.cancel() }
        let success = await worker.value
        backgroundTask.progress.completedUnitCount = 1
        backgroundTask.setTaskCompleted(success: success)
    }
}
