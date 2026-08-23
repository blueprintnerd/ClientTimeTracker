# ClientTimeTracker

A macOS menu-bar app that bills a client's remote-support time.

## What it does

- Weekly bank of **10 hours**, showing live remaining time in the menu bar (`⏱ 9h 42m`).
- Only counts down while **both** are true:
  - A TeamViewer remote-control session is actually connected (not just the app open).
  - You (or the remote controller) have been active in the last **45 seconds** — checked via system-wide input idle time, which also registers input TeamViewer injects while controlling the machine.
- **Add 1 Hour ($1)** button in the menu adds an hour to the current week's bank and $1.00 to a running lifetime total.
- Every **Sunday**, the hour bank refreshes back to 10 hours (plus purchases reset to 0 for the new week) — but the lifetime dollar total is **not** cleared automatically, so pricing/billing stays consistent week to week.
- The lifetime total can only be reset via **Clear Lifetime Total…**, which requires a password.
- **Start Task Timer…** is a manual stopwatch for a single task: enter an estimated number of hours, and it starts counting up. This pauses the automatic TeamViewer/idle tracking while it runs. Press **Stop Task Timer** to end it:
  - If you finished within the estimate, the actual elapsed time (rounded to the nearest hour) is deducted from the weekly bank.
  - If you went over the estimate, **half of the total elapsed time** (rounded to the nearest hour) is deducted instead.

## Build & run (on macOS, Swift 5.9+ / Xcode 15+)

```bash
cd ClientTimeTracker
swift build -c release
./.build/release/ClientTimeTracker
```

The app has no Dock icon (menu-bar only) — look for the clock icon in the menu bar.

To have it launch automatically at login, add the built binary
(`.build/release/ClientTimeTracker`) as a Login Item in
System Settings → General → Login Items.

## Notes / caveats

- **TeamViewer session detection** works by checking for TeamViewer's
  `TeamViewer_Desktop` helper process, which macOS TeamViewer only runs for
  the duration of an active remote-control session (the main app/service
  process stays running even with no session connected). This is an
  unofficial heuristic — TeamViewer doesn't publish a session-status API —
  so if a future TeamViewer version changes its process architecture, this
  check may need updating.
- **Idle detection** uses `CGEventSource` to read system-wide seconds since
  the last input event. No special permission is required for this reading
  (only *simulating* or globally *observing* events needs Accessibility
  access, which this app does not do).
- All state (remaining time, purchased hours, lifetime total, last reset
  date) persists in `UserDefaults` between launches.
- The clear-total password is stored in the source only as a SHA-256 hash,
  never in plaintext.
