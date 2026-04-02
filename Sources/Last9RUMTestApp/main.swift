/// Last9RUM local smoke test — macOS CLI runner.
///
/// Usage:
///   export LAST9_OTLP_ENDPOINT=https://otlp-ext-aps1.last9.io/v1/otlp/organizations/<your-org-slug>/telemetry/client_monitoring
///   export LAST9_CLIENT_TOKEN=<your-token>
///   swift run Last9RUMTestApp

import Foundation
import Last9RUM

// MARK: - Credentials (env vars only — never hardcode)

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

// MARK: - Step 1: Direct connectivity check

print("▶  Step 1: verifying OTLP endpoint connectivity…")
let tracesURL = URL(string: "\(endpoint)/v1/traces")!
var probe = URLRequest(url: tracesURL)
probe.httpMethod = "POST"
probe.setValue("Bearer \(token)", forHTTPHeaderField: "X-LAST9-API-TOKEN")
probe.setValue(origin, forHTTPHeaderField: "X-LAST9-ORIGIN")
probe.setValue(UUID().uuidString, forHTTPHeaderField: "Client-ID")   // required by server
probe.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
probe.httpBody = Data()

let probeSemaphore = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: probe) { data, response, error in
    if let http = response as? HTTPURLResponse {
        print("   POST \(tracesURL.path) → HTTP \(http.statusCode)")
        if http.statusCode >= 400 {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            print("   Response: \(body.prefix(300))")
        }
    } else if let error = error {
        print("   ❌ Connection error: \(error.localizedDescription)")
    }
    probeSemaphore.signal()
}.resume()
probeSemaphore.wait()
print()

// MARK: - Step 2: Init SDK

print("▶  Step 2: Initializing Last9RUM…")
Last9RUM.initialize(
    endpoint: endpoint,
    clientToken: token,
    serviceName: "last9-rum-smoke-test",
    environment: "local",
    origin: origin,
    hangThreshold: 0
)
print("✓  Initialized  service=last9-rum-smoke-test  env=local\n")

// MARK: - Step 3: Emit spans

Last9RUM.identify(id: "test-user-1", name: "Smoke Test", email: "test@last9.io")
print("✓  identify: user.id=test-user-1")

Last9RUM.startView(name: "Home")
print("✓  startView: Home")

print("\n▶  Step 3: Making auto-traced network requests…")
let netGroup = DispatchGroup()
for urlString in [
    "https://httpbin.org/get?source=last9-rum-test",
    "https://httpbin.org/status/200",
] {
    netGroup.enter()
    URLSession.shared.dataTask(with: URL(string: urlString)!) { _, response, error in
        if let http = response as? HTTPURLResponse {
            print("   GET \(URL(string: urlString)!.path)  →  HTTP \(http.statusCode)  (auto-traced)")
        } else if let error = error {
            print("   GET error: \(error.localizedDescription)")
        }
        netGroup.leave()
    }.resume()
}
netGroup.wait()

let tracer = Last9RUM.tracer("checkout")
let span = tracer.spanBuilder(spanName: "order.place")
    .setAttribute(key: "order.id", value: "ORD-9999")
    .setAttribute(key: "order.total_usd", value: 49.99)
    .startSpan()
Thread.sleep(forTimeInterval: 0.05)
span.setAttribute(key: "order.status", value: "confirmed")
span.end()
print("✓  custom span: order.place")

Last9RUM.endView()
print("✓  endView: Home")

// MARK: - Step 4: Flush and wait for HTTP export to complete

print("\n▶  Step 4: Flushing and waiting for OTLP export (15s)…")
Last9RUM.shared?.flush()

// The exporter fires async HTTP — wait long enough for it to complete
Thread.sleep(forTimeInterval: 15)

print("""

✅  Done.  Search in Last9 Traces for:
    service.name = "last9-rum-smoke-test"
    environment  = "local"

Expected spans:
  • Session Start
  • View  (view.name=Home)
  • GET /get       (http.response.status_code=200)
  • GET /status/200
  • order.place    (order.id=ORD-9999)
""")
