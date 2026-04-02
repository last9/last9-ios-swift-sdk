# Last9 RUM SDK for iOS

Real User Monitoring for iOS, built on OpenTelemetry. Drop it in, initialize once, and every network call, screen view, crash, hang, and user interaction is automatically traced and sent to [Last9](https://last9.io).

```swift
.package(url: "https://github.com/last9/last9-ios-swift-sdk", from: "0.1.2"),
```

## Setup

### 1. Create a Client Monitoring token

1. Open [Last9 → Settings → Ingestion Tokens](https://app.last9.io/control-plane/ingestion-tokens)
2. Click **Create Token** → choose type **Client**
3. Set the **allowed origin** to `ios://com.yourcompany.yourapp` (your app's bundle ID, e.g. `ios://com.acme.myapp`)
4. Copy the **token** and the **OTLP endpoint URL** shown after creation

The origin acts as a scope guard — the token is rejected if the `X-LAST9-ORIGIN` header doesn't match.

### 2. Initialize the SDK

Call this once — in `AppDelegate` or your SwiftUI `App.init()`:

```swift
import Last9RUM

Last9RUM.initialize(
    endpoint: "https://otlp-ext-aps1.last9.io/v1/otlp/organizations/<org-slug>/telemetry/client_monitoring",
    clientToken: "<your-client-token>",
    serviceName: "my-ios-app"
)
```

That's it. Every `URLSession` request is now traced automatically.

## What you get out of the box

Every `URLSession` request — latency, status code, URL, W3C `traceparent` injected for backend correlation. UIKit screens tracked via `UIViewController` swizzle. App launch time (cold and warm). Per-view frame rate, CPU, and memory. Tap tracking. Main thread hangs. Watchdog terminations. Signal crashes and ObjC exceptions — all with stack traces.

Sessions are auto-managed: 15 minutes of inactivity or 4 hours max, persisted across restarts.

## SwiftUI

UIKit is automatic. For SwiftUI, use the modifier:

```swift
ContentView()
    .trackView(name: "Home")
```

## Users

```swift
Last9RUM.identify(id: "u_123", name: "Alice", email: "alice@example.com")
Last9RUM.clearUser()
```

## Custom spans

```swift
let tracer = Last9RUM.tracer("checkout")
let span = tracer.spanBuilder(spanName: "order.place")
    .setAttribute(key: "order.total", value: 49.99)
    .startSpan()
span.end()
```

## Configuration

```swift
Last9RUM.initialize(
    endpoint: "...",
    clientToken: "...",
    serviceName: "my-ios-app",
    sessionInactivityTimeout: 10 * 60,  // default: 15 min
    enableAutoViewTracking: false,       // default: true
    hangThreshold: 3.0                   // default: 2s, 0 to disable
)
```

## Security

Client tokens are write-only and scoped to your app's bundle ID. Safe to ship in the binary.

## Requirements

iOS 13+, Xcode 15+, Swift 5.9+

## License

Apache 2.0
