# Session activity integration

The menu-bar UI consumes a small UI-facing snapshot through
`SessionActivityProviding` in
`Sources/UsageMenuBar/SessionActivityUI.swift`. Local discovery lives behind
`LocalSessionActivityProvider` and the shared domain model lives in
`SessionActivityModels.swift`.

The current app wiring is in `UsageMenuBarApp.swift`:

```swift
@StateObject private var sessionStore = SessionActivityStore(
    provider: LocalSessionActivityProvider()
)
```

`SessionActivityStore` runs the provider discovery off the main actor and
refreshes it every 20 seconds. Keep it separate from `QuotaStore`; quota
polling and Claude auth should not depend on session activity.

Required mapping fields:

- provider name
- project title
- session title
- explicit state: active, waiting, stale, unknown, or provider unavailable
- optional last-activity timestamp
- monitor status and optional snapshot timestamp

Until that adapter is connected, the UI deliberately shows `Unavailable` and
does not imply that no sessions exist.
