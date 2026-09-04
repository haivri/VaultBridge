import Foundation
import os

/// Aggregate, privacy-safe timing for one repository inspection pass — the
/// "Checking for local changes" phase. Carries durations and counts only,
/// never vault paths, file names, or remote URLs, so every field is safe to
/// log and to attach to os_signpost events for Instruments.
nonisolated struct GitInspectionMetrics: Sendable {
    var openSeconds: TimeInterval = 0
    var configSeconds: TimeInterval = 0
    var statusListSeconds: TimeInterval = 0
    var entryFilterSeconds: TimeInterval = 0
    var syncStateSeconds: TimeInterval = 0
    var totalSeconds: TimeInterval = 0
    var rawStatusEntryCount = 0
    var reportedEntryCount = 0
    var lfsCleanSkippedCount = 0
    var spuriousRenameSkippedCount = 0
    var evictedSkippedCount = 0
    var spellingMismatchCount = 0

    var summary: String {
        func ms(_ value: TimeInterval) -> String { String(format: "%.1f ms", value * 1000) }
        return "total \(ms(totalSeconds)) · open \(ms(openSeconds)) · config \(ms(configSeconds))"
            + " · status-list \(ms(statusListSeconds)) · entry-filter \(ms(entryFilterSeconds))"
            + " · sync-state \(ms(syncStateSeconds))"
            + " · entries \(reportedEntryCount) of \(rawStatusEntryCount) raw"
            + " (skipped: \(lfsCleanSkippedCount) lfs-clean, \(spuriousRenameSkippedCount) spurious-rename, \(evictedSkippedCount) evicted; \(spellingMismatchCount) spelling-mismatch)"
    }
}

/// Mutable box handed into the synchronous libgit2 phases so they can record
/// timings without changing their return types.
nonisolated final class GitInspectionMetricsBox: @unchecked Sendable {
    var metrics = GitInspectionMetrics()
}

/// Emits os_signpost intervals (visible in Instruments' Time Profiler /
/// os_signpost tracks alongside File Activity) and, for slow inspections, one
/// aggregate line in the in-app debug log.
nonisolated enum GitInspectionProfiler {
    /// Small repositories stay quiet; only inspections slow enough to matter
    /// produce a debug-log line. Signposts are always emitted. Mutable so the
    /// profiling harness can capture every run.
    nonisolated(unsafe) static var debugLogThresholdSeconds: TimeInterval = 0.05

    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "org.vaultbridge.VaultBridge",
        category: "GitInspection"
    )

    static func measure<T>(_ name: StaticString, into slot: inout TimeInterval, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            slot += TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            signposter.endInterval(name, state)
        }
        return try body()
    }

    static func record(_ metrics: GitInspectionMetrics) async {
        signposter.emitEvent(
            "inspectionCounts",
            "raw:\(metrics.rawStatusEntryCount, privacy: .public) reported:\(metrics.reportedEntryCount, privacy: .public) lfsClean:\(metrics.lfsCleanSkippedCount, privacy: .public) spuriousRename:\(metrics.spuriousRenameSkippedCount, privacy: .public)"
        )
        guard metrics.totalSeconds >= debugLogThresholdSeconds else { return }
        let summary = metrics.summary
        await MainActor.run {
            DebugLogger.shared.info("inspect", "Repository inspection timing", detail: summary)
        }
    }
}
