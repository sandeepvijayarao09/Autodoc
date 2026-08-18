import Foundation

/// A reason a capture fired — stored on the event and shown in the UI.
struct CaptureTrigger: Sendable {
    var reason: String
    var time: Date
}

/// A point-in-time reading of user activity, gathered permission-free.
struct ActivitySnapshot: Sendable {
    var now: Date
    var idleSeconds: TimeInterval      // seconds since the last human input event
    var lastAppSwitch: Date?           // when the frontmost app last changed
}

/// Decides *when* to capture in activity mode — the Scribe-style "only on human
/// interaction" rule. Pure and deterministic so it can be unit-tested without
/// real HID events. Semantics:
///
///   • never faster than `minInterval` (rate-limit floor)
///   • an app switch is an immediate step (context changed)
///   • after typing/clicking, capture once activity *settles* for `debounce`
///     seconds (we log the result of the action, not every keystroke)
///   • during nonstop activity, force a capture every `maxActive` seconds
///   • when the user is idle, never capture
struct TriggerPolicy: Sendable {
    var minInterval: TimeInterval = 15
    var debounce: TimeInterval = 2
    var maxActive: TimeInterval = 60
    var activityWindow: TimeInterval = 2   // idle < this ⇒ "active right now"

    func decide(_ s: ActivitySnapshot,
                lastEmit: Date,
                firstInputSinceEmit: Date?) -> String? {
        if s.now.timeIntervalSince(lastEmit) < minInterval { return nil }

        if let switched = s.lastAppSwitch, switched > lastEmit { return "app-switch" }

        if let first = firstInputSinceEmit {
            let quietFor = s.idleSeconds                     // since last input
            let activeFor = s.now.timeIntervalSince(first)
            if quietFor >= debounce { return "input-settled" }
            if activeFor >= maxActive { return "sustained-activity" }
        }
        return nil
    }

    /// Whether this snapshot represents fresh input since the last capture.
    func isActive(_ s: ActivitySnapshot) -> Bool { s.idleSeconds < activityWindow }
}
