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
- **Start Task Timer…** is a manual stopwatch for a single task: enter an estimated number of hours, and it starts counting up. This pauses the automatic TeamViewer/idle tracking while it runs. Press **Stop Task Timer** to end it, per the contract's estimate-overrun rule:
  - If you finished within the estimate, the actual elapsed time is deducted from the weekly bank in full.
  - If you went over, the overage (elapsed − estimate) is halved and rounded to the nearest hour (30+ min rounds up) — that rounded amount is forgiven, and the remainder of the elapsed time is deducted from the weekly cap.
    - Example: 2h estimate, 4h actual → 2h overage → 1h forgiven → 3h deducted.
    - Example: 2h estimate, 3h actual → 1h overage → rounds up to 1h forgiven → 2h deducted (i.e. just the estimate).

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

- **TeamViewer session detection is unverified and fails closed.**
  TeamViewer publishes no session-status API, so `TeamViewerDetector`
  combines several signals: whether any TeamViewer process is running, and
  whether the most recent session marker in TeamViewer's own logfile
  (`AddParticipant` = start, `SessionTerminate` = end) is a start or an end.
  It resolves to one of three states:
  - `active` — bills time.
  - `inactive` — does not bill.
  - `unknown` — signals missing or contradictory. **Does not bill.**

  The fail-closed default is deliberate: under-counting can be corrected by
  hand, but billing a client for hours nobody worked cannot. If detection
  is unreliable on your setup, use the **Task Timer** instead, which is
  explicit and auditable.

  **This detection has not been tested against a live TeamViewer session.**
  Use **TeamViewer Diagnostics…** in the menu (once with a session
  connected, once without) to confirm it works before relying on it for
  billing.

- **For invoice reconciliation**, TeamViewer writes
  `~/Library/Logs/TeamViewer/Connections_incoming.txt` — one row per
  *completed* incoming session, with start and end timestamps in UTC. It's
  written when a session ends, so it can't drive the live counter, but it's
  the best auditable record if a bill is ever disputed. The diagnostics
  panel shows whether this file was found. Note it only covers **incoming**
  connections — if you connect *out* to the client's machine, the record
  lives on their Mac, not yours.
- **Idle detection** uses `CGEventSource` to read system-wide seconds since
  the last input event. No special permission is required for this reading
  (only *simulating* or globally *observing* events needs Accessibility
  access, which this app does not do).
- All state (remaining time, purchased hours, lifetime total, last reset
  date) persists in `UserDefaults` between launches.
- The clear-total password is stored in the source only as a SHA-256 hash,
  never in plaintext.
