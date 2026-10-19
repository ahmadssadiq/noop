#if os(iOS)
import CallKit
import Foundation
import UIKit

/// Wrist alert for incoming calls: buzzes the strap for as long as a call rings, like an Apple Watch,
/// and stops once it is answered, declined or ends. iOS counterpart of Android's `CallAlertController`
/// (#66), which instead stops after 4 buzzes. Same privacy line: NOOP only learns THAT a call is ringing,
/// never who is calling or from which app.
///
/// Detection is `CXCallObserver`, which sees every CallKit call on the phone: regular phone calls,
/// FaceTime, and VoIP apps that ring through CallKit (WhatsApp audio and video, Messenger, Teams, …).
/// It needs no permission or entitlement.
///
/// The limit is iOS itself: call changes are only delivered while NOOP is running. In the background
/// the app runs only when the strap wakes it with a Bluetooth frame, so `poll()` re-checks the call list
/// on inbound frames. With Continuous HRV capture on, the strap sends a frame every second and alerts
/// arrive within about a second; without it, frames are sparse and an alert can be missed. Nothing can
/// help once the app has been force-quit from the app switcher: iOS does not relaunch it.
@MainActor
final class CallBuzzMonitor: NSObject, CXCallObserverDelegate {
    static let enabledKey = "notif.calls.enabled"

    /// One burst (3 pulses) plays for about 2 s on the strap (strap log: "Sequence fired" → "SEQ done"),
    /// so a new burst every 3 s keeps the wrist buzzing with a short pause between bursts.
    static let repeatInterval: TimeInterval = 3
    /// Self-heal ceiling (Android `MAX_RING_WINDOW_MS`): a cycle never runs longer than this even if
    /// the call's end is never observed. Longer than any normal ring before voicemail.
    static let maxRingWindow: TimeInterval = 90

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private let observer = CXCallObserver()
    /// Fires one buzz; returns false when the strap can't be reached (not connected).
    private let buzz: () -> Bool
    private let log: (String) -> Void

    private var cycleCallID: UUID?
    private var cycleStartedAt: Date?
    private var buzzCount = 0
    private var lastBuzzAt: Date?
    private var repeatWork: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastPollAt = Date.distantPast

    init(buzz: @escaping () -> Bool, log: @escaping (String) -> Void) {
        self.buzz = buzz
        self.log = log
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        // Delivered on the main queue (see `setDelegate`), so this is already main-actor isolated.
        MainActor.assumeIsolated { evaluate() }
    }

    /// Re-check the call list, throttled to once a second. Called on every inbound strap frame, which
    /// is what catches a call that started while the app was suspended.
    func poll() {
        let now = Date()
        guard now.timeIntervalSince(lastPollAt) >= 1 else { return }
        lastPollAt = now
        evaluate()
    }

    func evaluate() {
        guard Self.isEnabled, let call = ringingCall() else {
            stopCycle()
            return
        }
        if call.uuid != cycleCallID {
            startCycle(for: call.uuid)
        } else {
            tick()
        }
    }

    /// An incoming call that is still ringing: not placed by us, not answered, not ended.
    private func ringingCall() -> CXCall? {
        observer.calls.first { !$0.isOutgoing && !$0.hasConnected && !$0.hasEnded }
    }

    private func startCycle(for id: UUID) {
        stopCycle()
        cycleCallID = id
        cycleStartedAt = Date()
        // Ask for background time so the repeat buzzes still fire if iOS would otherwise suspend us
        // mid-ring (iOS grants roughly 30 s; after that the strap's frames keep driving `poll()`).
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CallBuzz") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        log("Call alert: incoming call ringing")
        tick()
    }

    private func tick() {
        repeatWork?.cancel()
        repeatWork = nil
        let now = Date()
        let expired = cycleStartedAt.map { now.timeIntervalSince($0) >= Self.maxRingWindow } ?? true
        // Past the ceiling: stop buzzing. `cycleCallID` is kept so the same call can't restart the cycle.
        guard !expired else {
            endBackgroundTask()
            return
        }
        let due = lastBuzzAt.map { now.timeIntervalSince($0) >= Self.repeatInterval - 0.25 } ?? true
        if due {
            if buzz() {
                buzzCount += 1
                lastBuzzAt = now
                if buzzCount == 1 { log("Call alert: buzzing") }
            } else if lastBuzzAt == nil {
                log("Call alert: strap not connected, will retry")
            }
        }
        let wait = lastBuzzAt.map { max(0.25, Self.repeatInterval - now.timeIntervalSince($0)) } ?? 1
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        repeatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func stopCycle() {
        guard cycleCallID != nil else { return }
        log("Call alert: stopped after \(buzzCount) buzz\(buzzCount == 1 ? "" : "es")")
        repeatWork?.cancel()
        repeatWork = nil
        cycleCallID = nil
        cycleStartedAt = nil
        buzzCount = 0
        lastBuzzAt = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif
