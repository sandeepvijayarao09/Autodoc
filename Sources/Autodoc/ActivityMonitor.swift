import Foundation
import AppKit
import CoreGraphics

/// Produces capture triggers. In `.activity` mode it watches human interaction
/// (permission-free) and fires per `TriggerPolicy`; in `.interval` mode it just
/// ticks on a timer. Either way it yields into an `AsyncStream<CaptureTrigger>`
/// the capture engine consumes.
@MainActor
final class ActivityMonitor {
    private var continuation: AsyncStream<CaptureTrigger>.Continuation?
    private var appObserver: NSObjectProtocol?
    private var tickTask: Task<Void, Never>?

    private var appSwitchTime: Date?
    private var lastEmit = Date.distantPast
    private var firstInput: Date?

    /// Build the trigger stream for the given config and start producing.
    func makeStream(config: Config) -> AsyncStream<CaptureTrigger> {
        let (stream, cont) = AsyncStream.makeStream(of: CaptureTrigger.self)
        continuation = cont

        switch config.captureMode {
        case .interval:
            let interval = Double(max(1, config.intervalSeconds))
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.continuation?.yield(CaptureTrigger(reason: "interval", time: Date()))
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }

        case .activity:
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.appSwitchTime = Date() }
            }
            let policy = TriggerPolicy(
                minInterval: Double(config.minIntervalSeconds),
                debounce: Double(config.debounceSeconds),
                maxActive: Double(config.maxActiveSeconds))
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick(policy)
                    try? await Task.sleep(nanoseconds: 500_000_000)   // 0.5 s poll
                }
            }
        }
        return stream
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        appObserver = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Activity polling

    private func tick(_ policy: TriggerPolicy) {
        let snap = snapshot()
        if policy.isActive(snap), firstInput == nil { firstInput = snap.now }
        if let reason = policy.decide(snap, lastEmit: lastEmit, firstInputSinceEmit: firstInput) {
            continuation?.yield(CaptureTrigger(reason: reason, time: snap.now))
            lastEmit = snap.now
            firstInput = nil
        }
    }

    private func snapshot() -> ActivitySnapshot {
        ActivitySnapshot(
            now: Date(),
            idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                 eventType: .null),
            lastAppSwitch: appSwitchTime)
    }
}
