import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the current session expires and a new one starts.
    /// `ViewManager` listens to this to rotate the active view span.
    static let last9SessionDidRollover = Notification.Name("last9.session.rollover")
}

// MARK: - SessionManager

/// Manages session lifecycle: start, persist, restore, rollover on timeout.
///
/// Two expiry triggers (matching Datadog iOS RUM defaults):
/// - **Inactivity timeout**: 15 minutes of no foreground activity
/// - **Max duration**: 4 hours regardless of activity
///
/// Session state is persisted to the caches directory via `SessionStore`.
/// Timeout is checked reactively on `willEnterForeground` — iOS suspends
/// background timers, so polling-based approaches don't work on mobile.
final class SessionManager {
    static let defaultMaxDuration: TimeInterval = 4 * 3600       // 4 hours
    static let defaultInactivityTimeout: TimeInterval = 15 * 60  // 15 minutes

    private let store: SessionStore
    private let tracer: Tracer
    private let maxDuration: TimeInterval
    private let inactivityTimeout: TimeInterval

    private var rolloverWorkItem: DispatchWorkItem?

    /// Guards against duplicate "Session End" spans for the same session.
    /// Reset when a new session starts or the session resumes from foreground.
    private var hasEmittedEnd = false

    #if canImport(UIKit)
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    #endif

    init(
        tracerProvider: TracerProvider,
        store: SessionStore = .shared,
        maxDuration: TimeInterval = defaultMaxDuration,
        inactivityTimeout: TimeInterval = defaultInactivityTimeout
    ) {
        self.store = store
        self.tracer = tracerProvider.get(
            instrumentationName: "session",
            instrumentationVersion: last9SDKVersion
        )
        self.maxDuration = maxDuration
        self.inactivityTimeout = inactivityTimeout
    }

    // MARK: - Public

    func start() {
        restoreOrCreateSession()
        installLifecycleObservers()
    }

    /// Emit a "Session End" span for the current session.
    /// Safe to call multiple times — only the first call per session emits.
    func end() {
        guard !hasEmittedEnd,
              let sessionId = store.currentSessionId,
              let startedAt = store.sessionStartedAt else { return }

        hasEmittedEnd = true

        let timeSpent = Int(Date().timeIntervalSince(startedAt) * 1000)
        let span = tracer.spanBuilder(spanName: "Session End")
            .setAttribute(key: "session.id", value: sessionId)
            .setAttribute(key: "session.time_spent", value: timeSpent)
            .startSpan()
        span.end()
    }

    func shutdown() {
        cancelRollover()
        #if canImport(UIKit)
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        #endif
    }

    // MARK: - Session Lifecycle

    private func restoreOrCreateSession() {
        guard let persisted = store.loadPersistedSession() else {
            createNewSession(previousId: nil)
            return
        }

        let now = Date().timeIntervalSince1970
        let elapsed = now - persisted.startedAt
        let inactiveFor = now - persisted.lastActivityAt

        let isExpiredByDuration = elapsed >= maxDuration
        let isExpiredByInactivity = inactiveFor >= inactivityTimeout

        if !isExpiredByDuration && !isExpiredByInactivity {
            // Restore valid session
            store.setCurrentSession(
                id: persisted.id,
                previousId: persisted.previousId,
                startedAt: Date(timeIntervalSince1970: persisted.startedAt)
            )
            let remainingDuration = maxDuration - elapsed
            scheduleRollover(after: min(remainingDuration, inactivityTimeout))
        } else {
            // Expired — start fresh with link to previous
            createNewSession(previousId: persisted.id)
        }
    }

    private func createNewSession(previousId: String?) {
        let now = Date()

        // Start the span first — its TraceId becomes the session.id,
        // matching the browser SDK convention expected by the dashboard.
        let span = tracer.spanBuilder(spanName: "Session Start").startSpan()
        let sessionId = span.context.traceId.hexString

        // Set session.id directly — SessionSpanProcessor.onStart already fired
        // before the store was updated, so we stamp it manually here.
        span.setAttribute(key: "session.id", value: AttributeValue.string(sessionId))
        if let previousId = previousId {
            span.setAttribute(key: "session.previous_id", value: AttributeValue.string(previousId))
        }
        span.end()

        // Update store after span ends so all subsequent spans (View, HTTP, etc.)
        // get session.id = traceId via SessionSpanProcessor.
        store.setCurrentSession(id: sessionId, previousId: previousId, startedAt: now)
        hasEmittedEnd = false

        scheduleRollover(after: min(maxDuration, inactivityTimeout))
    }

    private func rollover() {
        end()

        let previousId = store.currentSessionId
        store.clearSession()
        createNewSession(previousId: previousId)

        NotificationCenter.default.post(name: .last9SessionDidRollover, object: nil)
    }

    /// Re-checks session validity before rolling over.
    /// iOS equivalent of the browser SDK's `_checkAndMaybeRollover()`.
    ///
    /// When the rollover timer fires, user taps may have updated `lastActivityAt`
    /// since the timer was scheduled. If so, the session is still valid — reschedule.
    private func checkAndMaybeRollover() {
        guard let startedAt = store.sessionStartedAt,
              let lastActivity = store.sessionLastActivityAt else {
            createNewSession(previousId: nil)
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        let inactiveFor = now.timeIntervalSince(lastActivity)

        if elapsed >= maxDuration || inactiveFor >= inactivityTimeout {
            rollover()
        } else {
            store.updateLastActivity()
            let remainingDuration = maxDuration - elapsed
            scheduleRollover(after: min(remainingDuration, inactivityTimeout))
        }
    }

    // MARK: - Foreground Check

    private func handleForeground() {
        guard let startedAt = store.sessionStartedAt,
              let lastActivity = store.sessionLastActivityAt else {
            createNewSession(previousId: nil)
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        let inactiveFor = now.timeIntervalSince(lastActivity)

        if elapsed >= maxDuration || inactiveFor >= inactivityTimeout {
            rollover()
        } else {
            hasEmittedEnd = false
            store.updateLastActivity()
            let remainingDuration = maxDuration - elapsed
            scheduleRollover(after: min(remainingDuration, inactivityTimeout))
        }
    }

    // MARK: - Timer

    private func scheduleRollover(after interval: TimeInterval) {
        cancelRollover()
        let work = DispatchWorkItem { [weak self] in
            self?.checkAndMaybeRollover()
        }
        rolloverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func cancelRollover() {
        rolloverWorkItem?.cancel()
        rolloverWorkItem = nil
    }

    // MARK: - Lifecycle Observers

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleForeground()
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.store.updateLastActivity()
        }
        #endif
    }
}
