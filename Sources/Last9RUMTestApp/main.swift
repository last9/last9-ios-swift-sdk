/// Last9RUM comprehensive scenario test — macOS CLI runner.
///
/// Covers:
///   S1 — session.id / view.id / view.name on all spans
///   S2 — user.id after identify()
///   S3 — multiple views produce separate view spans
///   S4 — session rollover: inactivity timeout → new session.id + previous_id
///   S5 — session restore: re-init within timeout → same session.id
///   S6 — crash reporting: ObjC exception captured with stack trace
///
/// Usage:
///   export LAST9_OTLP_ENDPOINT=https://otlp-ext-aps1.last9.io/v1/otlp/organizations/<your-org-slug>/telemetry/client_monitoring
///   export LAST9_CLIENT_TOKEN=<your-token>
///   swift run Last9RUMTestApp
///
/// To run crash test only:
///   LAST9_CRASH_TEST=1 swift run Last9RUMTestApp

import Foundation
import Last9RUM

// MARK: - Credentials

let endpoint = ProcessInfo.processInfo.environment["LAST9_OTLP_ENDPOINT"] ?? ""
let token    = ProcessInfo.processInfo.environment["LAST9_CLIENT_TOKEN"]  ?? ""
let origin   = ProcessInfo.processInfo.environment["LAST9_ORIGIN"] ?? "ios://com.example.app"

guard !endpoint.isEmpty, !token.isEmpty else {
    print("""
    ❌  Set credentials before running:
      export LAST9_OTLP_ENDPOINT=https://otlp-ext-aps1.last9.io/v1/otlp/organizations/<your-org-slug>/telemetry/client_monitoring
      export LAST9_CLIENT_TOKEN=<your-token>
      swift run Last9RUMTestApp
    """)
    exit(1)
}

// MARK: - Helpers

func makeRequest(_ urlString: String, label: String) {
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: URL(string: urlString)!) { _, response, error in
        if let http = response as? HTTPURLResponse {
            print("   GET \(label)  →  HTTP \(http.statusCode)  (auto-traced)")
        } else if let e = error {
            print("   GET error: \(e.localizedDescription)")
        }
        sem.signal()
    }.resume()
    sem.wait()
}

func emitCustomSpan(name: String, attrs: [String: String]) {
    let tracer = Last9RUM.tracer("test")
    let builder = tracer.spanBuilder(spanName: name)
    for (k, v) in attrs { builder.setAttribute(key: k, value: v) }
    let s = builder.startSpan()
    Thread.sleep(forTimeInterval: 0.01)
    s.end()
}

// MARK: - Connectivity check

print("▶  Connectivity check…")
let tracesURL = URL(string: "\(endpoint)/v1/traces")!
var probe = URLRequest(url: tracesURL)
probe.httpMethod = "POST"
probe.setValue("Bearer \(token)", forHTTPHeaderField: "X-LAST9-API-TOKEN")
probe.setValue(origin, forHTTPHeaderField: "X-LAST9-ORIGIN")
probe.setValue(UUID().uuidString, forHTTPHeaderField: "Client-ID")
probe.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
probe.httpBody = Data()
let connSem = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: probe) { data, response, error in
    if let http = response as? HTTPURLResponse {
        print("   POST \(tracesURL.path) → HTTP \(http.statusCode)")
        if http.statusCode >= 400 {
            print("   Body: \((data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200))")
        }
    } else if let e = error { print("   ❌ \(e.localizedDescription)") }
    connSem.signal()
}.resume()
connSem.wait()
print()

// MARK: - S1/S2/S3: Init, identify, multiple views

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("S1/S2/S3 — session attributes, user.id, multiple views")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

// Init with SHORT inactivity timeout (8s) so S4 rollover test is fast
Last9RUM.initialize(
    endpoint: endpoint,
    clientToken: token,
    serviceName: "last9-rum-scenario-test",
    environment: "ci",
    origin: origin,
    sessionInactivityTimeout: 8,
    hangThreshold: 0
)

// S2: identify before first view
Last9RUM.identify(id: "scenario-user", name: "Scenario Runner", email: "ci@last9.io")
print("✓  identify: user.id=scenario-user")

// S1/S3: View 1 — Home
Last9RUM.startView(name: "Home")
print("✓  startView: Home")
makeRequest("https://httpbin.org/get?view=home", label: "/get?view=home")
emitCustomSpan(name: "home.load", attrs: ["content.type": "feed"])
Last9RUM.endView()
print("✓  endView: Home")

// S3: View 2 — Profile (separate view span)
Last9RUM.startView(name: "Profile")
print("✓  startView: Profile")
makeRequest("https://httpbin.org/get?view=profile", label: "/get?view=profile")
emitCustomSpan(name: "profile.load", attrs: ["user.id": "scenario-user"])
Last9RUM.endView()
print("✓  endView: Profile")

// S3: View 3 — Checkout (SwiftUI-equivalent — trackView calls startView/endView)
Last9RUM.startView(name: "Checkout")
print("✓  startView: Checkout  (SwiftUI .trackView equivalent)")
makeRequest("https://httpbin.org/get?view=checkout", label: "/get?view=checkout")
emitCustomSpan(name: "order.place", attrs: ["order.id": "ORD-S3", "order.total": "99.00"])
Last9RUM.endView()
print("✓  endView: Checkout\n")

// MARK: - S4: Session rollover

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("S4 — session rollover (waiting 10s for 8s inactivity timeout…)")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
Thread.sleep(forTimeInterval: 10)  // exceed 8s inactivity timeout

// After timeout, new activity should trigger a new session
Last9RUM.startView(name: "PostRollover")
print("✓  startView: PostRollover  (expect NEW session.id + session.previous_id)")
makeRequest("https://httpbin.org/get?view=postrollover", label: "/get?view=postrollover")
emitCustomSpan(name: "post.rollover.span", attrs: ["rollover": "true"])
Last9RUM.endView()
print("✓  endView: PostRollover\n")

// MARK: - S5: Flush first run before persistence test

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("Flushing S1–S4 spans (15s)…")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
Last9RUM.shared?.flush()
Thread.sleep(forTimeInterval: 15)
print("✓  Flush complete\n")

print("""
✅  S1–S4 done.  Verify in Last9:
    service.name = "last9-rum-scenario-test"
    environment  = "ci"

  S1: All spans have session.id, view.id, view.name
  S2: Home/Profile/Checkout spans have user.id=scenario-user
  S3: 3 separate View spans — Home, Profile, Checkout
  S4: PostRollover view has NEW session.id + session.previous_id set

Note: S5 (session restore) — run this test again within 15 min.
      The new run should reuse the SAME session.id as PostRollover.
""")

// MARK: - S6: Crash reporting (ObjC exception)

if ProcessInfo.processInfo.environment["LAST9_CRASH_TEST"] == "1" {
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("S6 — crash reporting (ObjC exception)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    // Fresh SDK init for crash test (separate service name for easy filtering)
    Last9RUM.initialize(
        endpoint: endpoint,
        clientToken: token,
        serviceName: "last9-rum-crash-test",
        environment: "ci",
        origin: origin,
        hangThreshold: 0
    )

    Last9RUM.identify(id: "crash-test-user", name: "Crash Tester", email: "ci@last9.io")
    Last9RUM.startView(name: "CrashView")
    emitCustomSpan(name: "pre.crash.span", attrs: ["crash.imminent": "true"])

    print("✓  SDK initialized, user identified, CrashView started")
    print("   Raising NSException in 1s…")
    Thread.sleep(forTimeInterval: 1)

    // Raise an ObjC uncaught exception — captured by NSSetUncaughtExceptionHandler
    NSException(
        name: NSExceptionName("Last9RUMTestCrash"),
        reason: "Intentional crash for S6 verification — exception.type, exception.message, exception.stacktrace expected in Last9 logs",
        userInfo: ["test.scenario": "S6", "triggered_by": "Last9RUMTestApp"]
    ).raise()

    // Handler calls flush internally; extra sleep ensures exporter drains
    Thread.sleep(forTimeInterval: 5)

    print("""

    ✅  S6 crash emitted.  Verify in Last9 Logs:
        service.name  = "last9-rum-crash-test"
        exception.type       = "Last9RUMTestCrash"
        exception.message    = "Intentional crash for S6 verification…"
        exception.stacktrace = (stack frames present)
        session.id, view.id, view.name, user.id should all be stamped
    """)
}
