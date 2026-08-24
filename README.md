# ClientTimeTracker

A macOS menu-bar app that tracks development hours against the rev5 "App
Development Services Agreement." It is a tracking aid; per **Section 8** of
that contract, the developer's **written time log is the authoritative
billing record** — this app produces that log (see *Export Time Log*).

## What it does

### Base hours (Section 5)
- Weekly cap of **10 hours**, shown live in the menu bar (`⏱ 6h 12m` = base
  left this week).
- Counts down only while **both**:
  - A TeamViewer session is confirmed active (see detection notes below).
  - You've been active in the last **45 seconds** (system-wide input idle).
- Every **Sunday** the base cap refreshes to 10 hours.

### Overage (Section 5, two-tier)
Overage only accrues **after** the 10-hour base is used up, **and** only if
you've marked it approved for the week via **Approve Overage This Week**
(the contract requires client pre-approval).
- Rates, per week: first **2 hrs $3/hr**, every hour after **$6/hr**.
- Caps: **4 hrs/week**, **12 hrs/period**, and a **16 total counted hrs/week**
  ceiling. Maximum overage payable across a period is **$54**.
- Billed in 30-minute increments, rounded up; the cheap tier resets each week.
- The menu shows overage used this week / this period and the running dollars
  owed. Settled once with the Day 30 payment.

### Task timer (Section 6 forgiveness)
- **Start Task Timer…** — enter an estimate, it counts up (pauses automatic
  tracking). On stop:
  - Within estimate → full elapsed time charged.
  - Over estimate → overage (elapsed − estimate) halved, rounded to nearest
    hour (30+ min up), that much **forgiven**; the rest charged (base first,
    then approved overage).
  - Examples: 2h est / 4h actual → 1h forgiven, 3h charged. 2h est / 3h
    actual → whole overage forgiven, 2h charged.

### Time log (Section 8) — the authoritative record
- Every automatic session and task-timer session is appended to
  `~/Library/Application Support/ClientTimeTracker/time_log.csv`
  (type, start/end ISO timestamps, duration, base vs overage seconds, note).
- **Export Time Log (CSV)…** saves a copy anywhere for sending to the client.
  This is the strongest answer to "you couldn't have worked that many hours."

### Proof-of-work screenshots (secondary; consent-gated per Section 8)
Screenshots are **off until the client consents in the app**, because §8
requires the other party's separate written consent before any tracking
software runs on their machine.
- **Screenshot Consent…** shows a plain disclosure (what's recorded, where
  it's stored, how to remove it) and records consent. Only then does macOS's
  **Screen Recording** permission get requested.
- Once consented: a full-screen shot roughly every **2 minutes**, only while
  a session is active **and** you're not idle. A **🔴** indicator and a menu
  line keep it disclosed.
- Safety brakes prevent runaway capture from a stale "session active"
  reading: capture stops after sustained idle, after **10h** continuous, at a
  **daily cap**, and old shots are **auto-pruned**.
- Stored locally only, never uploaded. **Open Screenshots Folder** to review.
- Note: §8 makes the *written log* authoritative — screenshots only
  corroborate it.

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
- State (base/overage counters, dollars owed, approval flag, reset dates)
  persists in `UserDefaults`, written on a ~15s batched interval rather than
  every second. **Note:** these values live in `UserDefaults`, so a
  determined owner of this Mac can edit them directly — which is exactly why
  §8 makes the exported **written log** the authoritative record, not this
  counter. The **Start New 30-Day Period** reset is password-gated as a soft
  deterrent, but it is not tamper-proof storage.
- The reset password is stored in source only as a SHA-256 hash, never
  in plaintext.

## Not signed / notarized

The DMG from CI is unsigned, so Gatekeeper will block a double-click. To
open it the first time: **right-click the app → Open**, then confirm; or run
`xattr -dr com.apple.quarantine /Applications/ClientTimeTracker.app`. Proper
distribution needs an Apple Developer ID signature + notarization, which
requires your paid Apple Developer account.
