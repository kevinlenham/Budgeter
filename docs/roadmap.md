# Roadmap

Execution plan for the design recorded in [design-decisions.md](design-decisions.md).

**Stack** — SwiftUI + Swift, GRDB over raw SQLite, Xcode installing straight to a free-provisioned device (DEC-034 defers TestFlight and the paid program). DEC-032 temporarily moved this to Expo/React Native for lack of a Mac; DEC-033 reverts that now a Mac is available. This is DEC-001/DEC-003 as originally written.

Sprints are ordered by **dependency and risk**, not by feature glamour. Two rules govern the ordering:

1. **The invariants come first.** Every rule in "The rules that must not be broken" is structural — a view, a constraint, a trigger, a funnel. Structure is cheap to build before there is data and expensive to retrofit after. Sprints 1–2 are almost entirely invisible to a user and are the most important work in the project.
2. **Reach daily-usable as early as possible.** Goal 1 is "a tool I personally use every day". That gates Sprint 3, and everything after Sprint 3 is built against real personal data rather than fixtures — which is also the only way the parked constants (DEC-020) ever get tuned.

Sprints are sized by outcome, not by calendar. Estimates assume part-time solo work.

---

## Sprint 0 — Project skeleton

**Estimate** ~1 session

**Goal** A SwiftUI app running on your actual iPhone, with a test suite that runs.

- New Xcode project, iOS app target, Swift strict concurrency on
- GRDB added via Swift Package Manager
- Signed with a free Apple ID (personal team), installed straight to your iPhone from Xcode over USB/wifi
- Swift Testing (or XCTest) for unit tests; a property-testing approach for `Money` (hand-rolled generators, or `SwiftCheck` if it still fits — check its maintenance status first)
- SwiftLint, SwiftFormat
- GitHub Actions running build, lint and tests on push — macOS runners this time, which cost more CI minutes than Ubuntu; keep the matrix small
- Apple Developer Program enrolment: **deferred** (DEC-034) — not needed for local-only use on your own phone

**Done when** a trivial failing test fails in CI, and the app builds and runs on your phone from Xcode over USB or wifi.

---

## Sprint 1 — Money and the schema core

**Estimate** 2–3 sessions. **The highest-value sprint in the plan.**

**Goal** The database enforces the invariants before any code exists that could violate them.

- `Money`: a Swift value type over integer minor units + currency code. No arithmetic operators on raw values — explicit `add`/`subtract`/`allocate` functions, currency mismatch throws (invariant 1)
- Property tests: associativity, no precision loss, currency mismatch rejected, `allocate` sums exactly to the input with no lost cents
- Migration 001 as raw SQL: `accounts`, `categories`, `transactions`, `splits`, plus the DEC-006 four columns (`id` UUIDv7, `created_at`, `updated_at`, `deleted_at`, `change_seq`) on every table
- CHECK constraints: `status IN ('draft','confirmed')`, `kind IN ('expense','transfer','income')` (DEC-035), transfer rows have NULL `category_id`, income rows have NULL `category_id` and no splits, split parents have NULL `category_id`
- Trigger: split totals must equal the parent amount (DEC-029)
- Unique index on `(account_id, source, dedupe_key)` — unconditional, covering soft-deleted rows (DEC-005)
- The **`spending` view** (DEC-010) — expenses only, `kind = 'expense'` (DEC-035) — and the **`postings` view** (DEC-028), which expands transfers into two signed rows and income into one positive row
- The **single upsert funnel** — the only write path for ingested data (DEC-005)
- Hand-written migration runner with a `user_version` check, tested against both an empty and a populated DB

**Done when** there is a test per rule in "The rules that must not be broken" that *fails* if the constraint is removed. Not a test that the happy path works — a test that the violation is rejected.

**Watch for**
- `PRAGMA foreign_keys = ON` is off by default in SQLite and must be set per connection — GRDB lets you set this per `DatabaseConfiguration`. Easy to forget, silently disables half the schema.
- Generate UUIDv7, not v4 — DEC-006 wants the timestamp ordering for index locality. No first-party Swift UUIDv7 yet; a small vetted implementation or package. Test the ordering property.
- Tests should run against in-memory SQLite (GRDB's `DatabaseQueue(path: ":memory:")`), not on device. That keeps this entire sprint on the fast loop even though it's now a native project.

---

## Sprint 2 — Periods and limits

**Estimate** 1–2 sessions. Pure logic, no UI, and all of it runs as plain `swift test` off-device.

**Goal** `generatePeriods(upTo)` and effective-dated limits, both correct at the edges.

- `periods` table, boundaries as local `YYYY-MM-DD` DATE strings (DEC-009)
- `generatePeriods(upTo)` — pure, idempotent, deterministic from `(anchor, cadence)`
- Effective-dated `category_limits` with validity ranges (DEC-008)
- Each period snapshots the limits in force at its start
- `booked_on` (local DATE) vs `occurred_at` (UTC instant) established in the model and never conflated
- Safe-to-spend: `remaining_limit / days_remaining_inclusive`
- `payDates(from:upTo:)` — the same shape as `generatePeriods`, pure and deterministic from `(pay_anchor, pay_cadence)`, feeding the DEC-036 notification queue. Built here because it is the same date arithmetic and the same 31st-of-the-month clamping; the notification binding that consumes it comes much later.

**Test cases that matter** monthly anchored on the 31st across February; an app unopened for two months generating eight weekly periods in one call; calling generate twice changes nothing; an 11pm 31 March transaction landing in March across the AEDT→AEST transition.

**Watch for** Foundation's `Date` is a genuine hazard for exactly this work — it is a UTC instant wearing a local-time costume, which is the precise confusion DEC-009 exists to prevent. Use `DateComponents`/a plain `YYYY-MM-DD` string for boundaries, and never let a `Date` object near `booked_on`.

**Done when** the boundary tests pass and periods are provably never regenerated.

---

## Sprint 3 — Manual entry, ledger, budget screen → **first usable build**

**Estimate** 3–4 sessions

**Goal** You put it on your phone and start using it.

- Onboarding: accounts, next payday (DEC-007), cadence, starter categories, and the pay schedule pre-filled from those answers (DEC-036) — stored, but no notification scheduled yet
- Add/edit transaction form, including `kind = 'income'` entry (DEC-035) — the same form, no category, so recording a payday is possible from the first usable build even though the reminder is not yet
- Ledger list grouped by day, reading the `spending` view, driven by GRDB `ValueObservation` into SwiftUI
- Budget screen: per-category "$340 of $500", days remaining, safe-to-spend
- Installed on your phone directly from Xcode (free-provisioned; re-run from Xcode roughly weekly to re-sign, per DEC-034)

**Done when** it is on your phone and you have logged a week of real transactions in it. **Do not start Sprint 4 before that is true** — every later sprint is tuned against real data.

**Note** DEC-001's original warning stands: SwiftUI's `List` degrades with large numbers of complex rows, and the ledger is exactly that shape. Do not pre-optimise — budget for wrapping a `UICollectionView` in `UIViewRepresentable` only if row counts actually reach the thousands.

---

## Sprint 4 — Categories, merchant memory, export, and payday reminders

**Estimate** 3 sessions

**Goal** Categorisation stops being tedious, the data becomes genuinely durable, and the app starts asking you for the one thing it can never observe.

- Category CRUD, limit editing, and the cadence-switch confirmation screen (DEC-008)
- `merchant_rules` — normalised merchant → category, written on every confirm or correction (DEC-030)
- Rules viewable and editable by the user
- **JSON/CSV export** via `FileManager` + a share sheet (`UIActivityViewController`). DEC-002 chose durability over sync and explicitly notes that durability *requires the export feature to actually be built, not assumed*. Until this ships, the no-sync decision is unbacked and you have one copy of the data and a hope.
- Round-trip test: export, then re-import your own export

- **Payday reminders** (DEC-036): pay schedule settings, permission requested at enable time (DEC-024), the rolling `UNUserNotificationCenter` queue topped up on launch, a "Log now" deep link to a blank income form, and "Remind me tomorrow"
- The in-app fallback card — "no pay logged since 14 March" — shown regardless of notification permission

**Done when** exporting and re-importing produces an identical dataset with zero duplicate rows — which also exercises the Sprint 1 funnel — and one real payday reminder has fired on your phone and been logged through.

**Watch for**
- No local team needed: `UNUserNotificationCenter` is unrelated to APNs and works under free provisioning. DEC-034's "Push Notifications require a paid team" does not apply here.
- iOS has no repeating trigger for a 14-day cycle, so fortnightly is a queue of one-shots, not a repeat. Cap is 64 pending per app; a year of fortnightly is 26.
- Under DEC-034 the profile expires after 7 days: the notification still fires but the app won't launch until re-signed. Expected, not a bug.

---

## Sprint 5 — Transfers and splits

**Estimate** 1–2 sessions. The schema already supports both; this is UI and query work.

- Transfer entry: one row, `from_account_id` / `to_account_id` (DEC-028)
- Per-account balances read `postings`, never `transactions`
- Split editor, with the sum-equals-parent trigger surfaced as a friendly error rather than a crash
- Verify transfers are absent from every aggregate and splits do not double-count

**Done when** a test asserts that adding a transfer moves no spending total by a cent.

---

## Sprint 6 — CSV import

**Estimate** 2–3 sessions

**Goal** Bulk history, and the first real exercise of the funnel against messy input.

- File pick via `UIDocumentPickerViewController` / `.fileImporter`
- Column-mapping wizard pre-filled from the header row (DEC-031)
- Saved named profiles — load-bearing, because they pin the layout that keeps row hashes stable
- Date-format and sign-convention handling (debits negative vs a separate column)
- Preamble-row tolerance
- Skip report: "12 imported, 3 previously deleted and skipped" (DEC-005)

**Done when** re-importing the same file imports nothing the second time, and deleting a row then re-importing does not resurrect it.

**Your job** supply two or three real CSV exports from actual Australian banks. This sprint cannot be built well against invented fixtures — the whole design exists because every bank's export is differently awkward.

---

## Sprint 7 — Wallet capture

**Estimate** 4–5 sessions. **Highest risk in the project** — not because of tooling now, but because Wallet capture's known failure modes (timeouts, declined-transaction firing, empty merchants) are inherent to the API, not the stack.

With a Mac, this is a normal native App Intents extension target — you compile and iterate locally in Xcode, no cloud build in the loop. The risk here is entirely in what the intent actually receives from your bank in practice, not in blind iteration.

- An App Intents extension target added to the Xcode project
- App Intent accepting amount, merchant, and card string
- Validation at the intent boundary: `amount == 0` returns a failure to Shortcuts and writes no draft (DEC-013)
- A bridge from the extension to the app's SQLite file — an App Group shared container, decided and tested early, because it gates everything else in this sprint
- Draft rows via the funnel, `dedupe_key` = hash of `(timestamp_bucket, amount, card)`, 2-minute bucket (DEC-018)
- `card_identifiers` mapping, learned on first sight (DEC-014)
- Pinned draft inbox at the top of the ledger, badge, and the "+ $28 unconfirmed" secondary line (DEC-011)
- One-tap confirm with a guessed category
- 14-day staleness prompt with Confirm all / Discard all (DEC-012)
- Setup guide, "Test it" button, and the permanent "Last capture received" diagnostic (DEC-015)

**Done when** a real tap at a real card terminal creates a draft on your phone and the diagnostic row updates.

**Your job** this sprint is unavoidably yours to drive: a physical iPhone, a real card in Wallet, and real purchases. There is no simulator for an NFC tap, and there would not be even with a Mac. Expect to spend a session just discovering what the trigger actually hands over for your specific bank — the doc's known failure modes are the documented ones, not necessarily all of yours.

**Suggested de-risking** before writing any Swift, build the Shortcuts automation against a plain HTTP request to a scratch endpoint and observe what your bank actually sends. That answers the riskiest unknown in the whole project for the cost of an afternoon, with no native code involved.

---

## Sprint 8 — Cross-source deduplication

**Estimate** 2–3 sessions. Pure logic again, back on the fast loop.

**Goal** Wallet captures, CSV rows, and manual entries stop being three copies of one coffee.

- Scored candidate matcher — **it never writes** (DEC-016)
- Structural rules from DEC-017; asymmetric amount tolerance for pending→posted (DEC-018)
- Per-field merge precedence, not winner-takes-all (DEC-019)
- All tunables in one `MatchingParameters` object with the documented starting guesses: `N = 3 days`, 2-minute bucket, single threshold (DEC-020)
- Merge proposals surfaced for consent; "not a match" is one tap

**Done when** the matcher has a test covering every scenario in DEC-018, and `MatchingParameters` is the only place any of those constants appears.

**Then leave it alone for a month.** DEC-020 parked those numbers deliberately because they are not derivable by reasoning. Tune them from the Sprint 9 debug screen against your own data.

---

## Sprint 9 — Security, observability, polish

**Estimate** 3–4 sessions.

- **Privacy overlay** on `willResignActive` (DEC-025), always, non-optional. Verify on a physical device that it renders before iOS takes the app-switcher screenshot — routine QA now, not a research risk.
- Face ID after N seconds backgrounded via `LocalAuthentication`, configurable, default 1 minute
- Local developer stats screen (DEC-023): capture success rate, ingestion mix, dedupe accept/reject, correction rate, draft queue age, DB size, schema version
- A `TelemetrySafe` type, with `Money` structurally unable to satisfy it (DEC-022)
- Analytics consent (DEC-024)
- **Widgets** with Lock Screen amounts hidden by default (DEC-025). A second native WidgetKit extension target, built and run locally like the rest of the app.

**Done when** the stats screen gives you the numbers needed to close out DEC-020.

---

## The v1 cut line

**Sprints 0–5 are v1.** That is already a good budgeting app: manual entry, budgets that respect real pay cycles, transfers, splits, categorisation memory, and exportable data. All of it is native Swift, built and run locally in Xcode — nothing blind about any of it now.

Sprints 6–9 are what make it *yours* and what make it a portfolio piece. Ship 0–5 to your own phone and live with it first, because everything after that is better designed once you have opinions formed by daily use rather than by planning.

Deliberately **not** in this plan: bank sync (CDR accreditation not held), multi-device sync (DEC-002), Core ML categorisation (DEC-030), the bundled starter merchant list (DEC-030), unallocated split remainders (DEC-029).

---

## How we work together

### What I do

Write the Swift, the SQL migrations, the views and triggers, and the tests. Draft each sprint on its own branch. Explain the reasoning wherever a decision wasn't already settled in the design doc — and flag it explicitly when implementation reveals a recorded decision was wrong, so it goes back into `design-decisions.md` as a new DEC rather than getting quietly worked around. DEC-032/DEC-033 is the template for that.

### What only you can do

- **Run the app.** I can write the code and reason about it, but I can't see your phone. Screenshots are worth a lot.
- **Apple Developer Program, TestFlight** — deferred per DEC-034; revisit only if you want it on a second device, want to hand a build to someone else, or hit a capability that needs it
- **Physical device work** — Face ID, widgets, the privacy overlay, and all of Sprint 7. NFC taps have no simulator on any platform.
- **Real data** — bank CSVs (Sprint 6), a real card in Wallet (Sprint 7), and a month of your own spending before DEC-020 can be closed
- **Product judgement** — anything where the design doc is silent and the answer is a taste question about your own app

### The loop that works best

1. Start a sprint: I read the relevant DECs and write a short implementation plan; you sanity-check it before I write code
2. I build in small commits, with tests alongside
3. You run the test suite (`cmd+U` or `xcodebuild test`) and paste failures verbatim — full output, not summarised. Swift compiler errors in particular carry information that gets lost in paraphrase.
4. You run the app and screenshot anything that looks wrong
5. The sprint ends when its "Done when" is true — not when it compiles

### Things that will save time

- Paste errors raw, including the noise
- When something feels wrong in use, say so early even if you can't articulate why — that is exactly the signal a design doc cannot contain
- Push back when I over-engineer. DEC-003 chose explicit SQL over an ORM partly on the grounds that one person maintains this; that constraint applies to the code I write too.
- Keep the fast loop fast. Anything testable outside the simulator should run as a plain unit test, not on device. Sprints 1, 2 and 8 should never need a device build.
