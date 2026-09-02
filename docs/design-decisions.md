# Design Decisions

Local-first iOS budgeting app. Market: Australia (AUD, AEST/AEDT). iOS only.

Each record is: **Decision → Options considered → Choice → Reasoning → Consequences.**
Rejected options are kept deliberately — the rejections carry as much of the reasoning as the choices.

Status: settled in design session, pre-implementation. The repo was empty at the time of writing, so nothing here is constrained by existing code.

---

## Context

**Goals, in priority order**

1. A tool I personally use every day
2. A portfolio piece demonstrating engineering judgement
3. Possibly a real product later

**Locked before the session**

- Budgeting model: per-category spending caps. Not envelope, not zero-based.
- Cadence: weekly, fortnightly, or monthly. Exactly those three.
- Local-first: the device is the source of truth; fully functional offline.
- iOS only. No Android, now or planned.
- Bank sync deferred — Australia's CDR regime requires accreditation not held. Sandbox only, and not before everything else works.

**Invariants — to be enforced structurally, by types and constraints, not convention**

1. Money is an integer of minor units plus a currency code. Never a `Double`. A `Money` value type with explicit arithmetic, property-tested.
2. Transfers between own accounts are never spending. Excluded from every aggregate.
3. Soft-delete everything.
4. Ingestion is idempotent. Re-running an import or sync is a no-op.
5. ~~Splits don't double-count. A transaction with splits has no category of its own.~~ **Struck by DEC-038** — splits are not a v1 feature.
6. No financial data in telemetry. No amounts, merchant names, category names, account names. Counts and buckets only.

---

## Three reframings that shaped everything below

Recorded because they changed the answers, and because future-me will otherwise re-derive them.

**A unique index is not idempotency.** Idempotency is an upsert. A unique index on `(account_id, external_id)` does not make re-import a no-op — it makes re-import *fail*. The no-op comes from `INSERT ... ON CONFLICT DO NOTHING` or lookup-then-skip, both application logic. The constraint is a **detector** that converts a silent bug into a loud one. Valuable, but not the mechanism. This deflated the apparent conflict between invariant 4 and CloudKit.

**Uniqueness does not survive sync as a constraint.** A `UNIQUE` index is per-device. Two devices importing the same CSV offline both insert cleanly, each satisfying its own local constraint, and sync then produces two rows. Under any sync design, uniqueness is a *convergence* problem, solved by deterministic identity (e.g. UUIDv5 over the dedupe key), not by a constraint.

**There are two dedupe problems, not one.** Same-source idempotency is exact and deterministic — solved by DEC-005. Cross-source identity is fuzzy and unsolvable in general — handled by DEC-016 through DEC-019. Conflating them is what made deduplication look like the hardest problem in the app. The exact half is mechanical.

---

# 1. Stack and persistence

## DEC-001 — UI framework and language

**Options considered**
- SwiftUI + Swift
- UIKit + Swift
- React Native or another cross-platform runtime

**Choice** — SwiftUI + Swift.

**Reasoning** — iOS-only removes the entire case for a cross-platform runtime. App Intents, required for Wallet capture, is a Swift-native framework that would otherwise need bridging. There is no counterweight.

**Consequences** — SwiftUI's `List` degrades with large numbers of complex rows, and the transaction ledger is exactly that shape. Budget for wrapping a `UICollectionView` in `UIViewRepresentable` on the ledger screen if row counts reach the thousands. Do not pre-optimise.

---

## DEC-002 — Sync versus durability

**Options considered**
- Durability only, no sync
- Multi-device sync in v1 (iPhone + iPad)
- Durability now, but a sync-compatible schema now

**Choice** — Durability only. No sync in v1.

**Reasoning** — These are different products. Sync means the same data live on several devices. Durability means the data survives device loss. Every stated goal is satisfied by durability, and durability on iOS is nearly free: the SQLite file in Application Support is included in encrypted device backup automatically, plus an explicit JSON/CSV export. Sync is a distributed-systems project that generates the app's hardest bug class and fights several invariants.

The third option is the trap: adding CloudKit later requires an all-optional, add-only schema *today*, so it pays the full cost immediately and receives none of the benefit.

**Consequences** — Single-device only until deliberately revisited. Durability requires the export feature to actually be built, not assumed. A later sync design will be *server-backed*, not CloudKit — see DEC-003.

---

## DEC-003 — Persistence layer

**Options considered**
- (a) SwiftData + CloudKit sync
- (b) SwiftData, local only
- (c) GRDB / raw SQLite + a bespoke sync layer
- (c′) GRDB / raw SQLite, local only, no sync layer

**Choice** — (c′). GRDB, local only.

**Reasoning**

1. *The invariants are SQL invariants.* Transfer exclusion, splits not double-counting, soft-delete everywhere, idempotent ingestion — these are CHECK constraints, unique indexes, triggers and views. GRDB provides all of them. CloudKit removes them: no `@Attribute(.unique)`, all properties optional or defaulted, all relationships optional, and violations fail sync *silently*.
2. *The schema will be rewritten repeatedly.* Drafts, splits, dedupe state and the period model were all unresolved at the start of this session. CloudKit's add-only, lightweight-migration-only constraint is the worst possible fit for a greenfield schema, and it is permanent once shipped.
3. *Boring, per the stated criterion.* GRDB is a decade-old, stable, thoroughly documented wrapper over the most widely deployed database in existence. SwiftData is younger and still shifts annually. One person maintains this.
4. *Portfolio signal.* A reasoned refusal of free sync is a stronger judgement story than accepting the default.
5. *Doors stay open.* Both a future `CKSyncEngine` layer and a future server are natural from GRDB and painful from SwiftData + CloudKit.

Note that (c′) is materially cheaper than the (c) originally proposed: deleting "my own sync layer" removes the expensive part, leaving roughly (b)'s workload with strictly better tools.

Reinforcing fact discovered during the session: the eventual plan is a server-backed account system with login. That means the future sync backend is a server under our control — capable of real uniqueness, real conflict resolution and real migrations, all of which CloudKit refuses. The capability option (a) was buying was the *wrong* sync.

**Consequences** — Migrations are hand-written, reviewed and tested. Aggregate queries are SQL, which suits the reporting shape. No free multi-device sync. GRDB observation drives SwiftUI rather than `@Query`.

---

## DEC-004 — Two-store workaround

**Options considered**
- A local store with constraints plus a CloudKit store, replicated between them
- Reject

**Choice** — Reject outright.

**Reasoning** — Two sources of truth plus a bespoke bidirectional replication layer maintained forever, and CloudKit's conflict semantics are still inherited on the far side. It is strictly more work than a single `CKSyncEngine` mapping layer, which is the honest version of the same idea. A workaround costing more than the thing it works around.

**Consequences** — If sync is ever built, it is GRDB + `CKSyncEngine` with deterministic record names, or a server. Never two stores.

---

## DEC-005 — Idempotency, and its collision with soft-delete

**Options considered**
- Unconditional unique index, with skipped rows reported to the user
- Partial index, `WHERE deleted_at IS NULL`
- Unconditional index, silent no-op
- No DB constraint; rely on the upsert funnel alone

**Choice** — Unconditional unique index on `(account_id, source, dedupe_key)`, plus a skip report in the import summary.

**Reasoning** — Every ingested row carries a non-null `dedupe_key`, defined per source:

| Source | `dedupe_key` |
|---|---|
| Bank sync / CSV | Provider `external_id`, or a hash of the raw row |
| Wallet capture | Hash of `(timestamp_bucket, amount, card)` — see DEC-018 |
| Manual entry | A fresh UUID |

Manual entries get a UUID precisely so they *never* collide: manual entry is a deliberate act, and two identical manual entries are two real purchases.

The index covers *all* rows including soft-deleted ones. A soft-deleted row therefore keeps occupying its identity slot, so re-importing a file whose rows the user deleted is a genuine no-op and the deletion sticks. A partial index would resurrect deliberately-deleted rows — a real bug the user would hit and not understand. Reporting the skips ("12 imported, 3 previously deleted and skipped") makes the invariant visible instead of mysterious.

All ingestion goes through **one upsert funnel function**. There is no other write path for ingested data. That is what makes invariant 4 structural rather than conventional: the funnel implements it, the index detects violations.

**Consequences** — A CSV whose export format changes will produce different row hashes and re-import as duplicates. Mitigated by DEC-031 (saved column-mapping profiles pin the layout). The skip report needs UI. Covers only exact same-source idempotency; cross-source matching is DEC-016.

---

## DEC-006 — Sync-readiness insurance

**Options considered**
- Four cheap columns only
- UUID primary keys only
- Nothing — a pure local design
- Design an operation log now

**Choice** — Four columns on every table, and nothing more.

- `id` — UUIDv7 primary key. Globally unique, no cross-device collisions, still sorts by creation time for index locality.
- `created_at`, `updated_at` — UTC instants.
- `deleted_at` — the soft-delete marker from invariant 3, which doubles as the tombstone any sync needs.
- `change_seq` — monotonically increasing local counter, so a future sync client can ask "what changed since N" without a full table scan.

**Reasoning** — `updated_at` and a change cursor are the two things that cannot be honestly backfilled: retrofitting them means every pre-existing row lies about when it changed. Costs about a day and commits to no particular sync design. An operation log is a large architectural commitment made before the requirements exist.

**Consequences** — Slightly larger rows and a small write-path obligation to maintain `change_seq`. No conflict resolution, vector clocks or op log until a real sync design exists.

---

# 2. Budget periods

## DEC-007 — Anchor date, and the governing principle

**Options considered**
- Ask for the next payday; anchor changes take effect forward only
- Ask for payday; anchor changes regenerate all periods
- Use the first-launch date
- A fixed epoch, not user-configurable

**Choice** — Ask for the next payday during onboarding. Anchor and cadence are changeable, and changes take effect from the next period boundary. Already-generated periods are never touched.

**Governing principle** — *Periods are immutable, append-only records. Cadence and anchor changes are effective-dated forward and never regenerate history.* A period containing transactions is a historical fact, not a derived view.

**Reasoning** — The entire reason fortnightly cadence exists in Australia is fortnightly pay, so the anchor is a real-world fact the user knows and can supply in one date picker. First launch is arbitrary and every fortnightly user would have to correct it anyway. Regenerating history silently changes which period past transactions belong to, retroactively altering budget results the user already saw — the classic month-four bug.

**Consequences** — One extra onboarding step. Monthly periods anchored on the 31st clamp to the last day of shorter months, and clamping never mutates a stored row.

---

## DEC-008 — Cadence switch, and what happens to limits

**Options considered**
- Wait for the next boundary; prompt with scaled default limits
- Switch immediately, truncating the current period
- Wait for the boundary, auto-scale limits silently
- Wait for the boundary, reset all limits

**Choice** — The switch takes effect at the next period boundary. On confirmation, show every category with a scaled-and-rounded suggested limit the user can edit.

**Reasoning** — Waiting for the boundary means partial periods never exist, and "spent this period" never jumps for invisible reasons. A $200 limit is meaningless without its cadence, so a switch must do *something* with limits: silent scaling produces numbers no human chose ($92.31) with no visible origin; resetting throws away the user's setup and most people will abandon the switch. Prompting with a sensible pre-fill is the only option that is both correct and kind.

**Schema consequence** — Limits are **effective-dated rows**, and each period **snapshots the limit in force at its start**. A past period must display the limit that applied *then*, not today's. Without this, editing a limit silently rewrites history.

**Consequences** — A limits table with validity ranges rather than a single current value. A confirmation screen listing every category. UI must communicate "your new cadence starts 14 March".

---

## DEC-009 — Period generation and boundary storage

**Options considered**
- Lazy generation + local DATE boundaries
- Lazy generation + timestamp boundaries
- Eager background generation + DATE boundaries

**Choice** — Lazy generation; boundaries stored as local DATE values.

**Reasoning** — `generatePeriods(upTo: date)` is a pure function that fills any gap between the last generated period and today. Called on launch and before any period query. Idempotent, deterministic from `(anchor, cadence)`, trivially unit-testable. An app unopened for two months generates eight weekly periods instantly on the next launch. Eager generation means `BGTaskScheduler`, which iOS runs when it chooses and is a well-known source of "why didn't this fire".

Boundary storage matters more than the originally-asked question about unequal month lengths. Stored as timestamps, Australian DST transitions silently shift boundaries by an hour, and transactions near midnight land in the wrong period twice a year. Stored as `YYYY-MM-DD` local dates, the problem cannot occur.

**Consequences** — Transactions need **two** time fields: `booked_on` (local DATE, decides period membership, what the user sees and edits) and `occurred_at` (UTC instant, for intra-day ordering and dedupe windows). Conflating them puts an 11pm 31 March purchase into April.

Unequal month lengths then handle themselves: days-remaining is plain date arithmetic in the user's calendar, inclusive of today, and safe-to-spend is `remaining_limit / days_remaining_inclusive`.

---

# 3. Apple Wallet capture

Known failure modes, all documented and all designed around: it times out when the card issuer is slow; it fires even on **declined** transactions; it sometimes delivers an empty merchant and an amount of 0.0; and it covers only NFC taps, not in-app or browser payments.

## DEC-010 — Draft storage, and the canonical aggregate view

**Options considered**
- Same table with a status column, plus one canonical `spending` view
- A separate drafts table
- Same table, no view, filtering at each query

**Choice** — Same table, `status` with `CHECK (status IN ('draft','confirmed'))`, plus a single `spending` view.

**Reasoning** — A separate table looks safer, but promotion becomes a cross-table move so the row's ID changes, breaking any edit made while it was a draft — and cross-source dedupe, the hottest correctness path in the app, would need a UNION on every check. Same-table promotion is a status flip.

The safety lost is recovered structurally and then some. **One SQL view, `spending`, is the only thing any aggregate is ever permitted to read.** It encapsulates:

- `status = 'confirmed'`
- `deleted_at IS NULL`
- transfers excluded (invariant 2)
- split parents excluded, split children included (invariant 5)

Invariants 2, 3 and 5 plus draft handling are therefore enforced in one definition rather than at every callsite. "Impossible to get wrong at a callsite" becomes true by construction.

**Consequences** — Nothing computes spending from the raw `transactions` table, ever. This is the single most important rule in the schema and should be stated in the repo's contributor docs.

---

## DEC-011 — Review UX

**Options considered**
- Pinned inbox + badge + pending-delta line
- The same, but drafts counted in the main total
- A separate inbox tab with a badge
- A per-capture notification, no inbox

**Choice** — Drafts appear as a pinned section at the top of the main ledger. App icon badge shows the count. Budget displays "$340 of $500" with a secondary "+ $28 unconfirmed". No per-capture notification; an optional daily digest when drafts exist.

**Reasoning** — Drafts are unverified — a declined transaction produces one too — so they must not count toward the authoritative number. But that means the budget silently *understates* spending until review, which is arguably worse than overstating: the app says you're fine when you aren't. Showing both numbers resolves it honestly.

A separate tab is an out-of-sight queue, and an unreviewed queue kills this feature. A per-capture notification is one alert per coffee, and Wallet already put the transaction on the lock screen seconds earlier; it would be disabled within a week.

One-tap confirm: each draft row shows merchant, amount and a guessed category (DEC-030) with a single ✓. Tapping ✓ accepts the guess; tapping the row opens edit.

---

## DEC-012 — Unreviewed drafts

**Options considered**
- Never auto-confirm; surface staleness with bulk actions
- Auto-discard after 30 days
- Auto-confirm after 7 days
- Accumulate forever

**Choice** — Never auto-confirm. Drafts never count toward spending. After 14 days, surface "3 captures from over 2 weeks ago" with Confirm all / Discard all.

**Reasoning** — The entire justification for draft status is that capture fires on declined transactions and sometimes delivers garbage. Auto-confirming writes known-unreliable data into budget totals, and when the totals later look wrong the user has no way to find which row lied. Accumulating forever produces a 200-item queue, which is abandoned by definition. Staleness is treated as a prompt, not a policy: the app never guesses on the user's behalf.

---

## DEC-013 — Degenerate captures

**Options considered**
- Reject amount 0 at the intent boundary; keep empty-merchant captures
- Create drafts for everything and flag them in the UI
- Reject both amount 0 and empty merchant

**Choice** — Validate at the App Intent boundary before any DB write. `amount == 0` returns a failure to Shortcuts, so the user sees something went wrong, and no draft is created. An empty merchant with a valid amount creates a draft showing "Unknown merchant" that cannot be confirmed until filled in. Both increment a bucketed failure counter.

**Reasoning** — The two failures are not equivalent. Amount 0 carries no information at all — there is nothing to confirm or correct, and it is pure noise in a queue whose reviewability is the whole point. An empty merchant with a real amount still carries the amount, which is most of the value, and the user can usually reconstruct the merchant from the time of day.

**Declined transactions are undetectable at this layer** — the intent receives no status. This is recorded explicitly so that a future optimisation pass does not "simplify away" the draft confirmation step. Confirmation is mandatory *because* declines cannot be detected.

---

## DEC-014 — Card to account mapping

**Options considered**
- A mapping table, learned on first sight
- Map cards during Shortcuts setup
- A single designated capture account

**Choice** — A `card_identifiers` table mapping the raw card string to `account_id`. The first time an unknown string arrives, the draft is created with a null account and the inbox asks "which account is this card?" once. Every later capture from that card auto-attributes.

**Reasoning** — The intent receives a card string like "Visa •••• 1234", which is neither stable nor guaranteed unique, so it cannot be a foreign key. But the mapping is load-bearing twice over: without it, captures cannot be attributed to an account, which breaks per-account balances *and* breaks DEC-017 matching, which keys on `(amount, account, date)`. Learning on first sight adds no steps to a setup flow already at risk of being too long, and handles card renames as simply a new mapping. A single designated account is silently wrong the moment there are two cards.

---

## DEC-015 — Positioning and survivability of the Shortcuts automation

**Options considered (positioning)**
- Build it as an earned power-user feature
- Offer it in onboarding as skippable
- Build it for personal use only, hidden
- Don't build it; ship a quick-add widget instead

**Choice** — Build it, but never in first-run. Surface it after the user has manually logged roughly ten transactions: *"tired of typing? there's a faster way."*

**Reasoning** — Its value differs wildly across the three goals. For goal 1 it is enormously valuable: set up once, frictionless capture forever. For goal 3 it is a funnel catastrophe — "open Shortcuts, create an automation, choose Wallet, pick your card, add an action, find my app's intent, map three parameters". Putting it in first-run makes the most confusing screen in the app the wall a new user hits before ever seeing the app work. Deferring it until the user has felt the manual-entry friction means they have a reason to tolerate the setup cost.

**Options considered (survivability)**
- Guided setup + Test button + last-capture diagnostic
- Guided setup only
- Guide + Test button, no ongoing diagnostic

**Choice** — All three: a screenshot-by-screenshot guide; a "Test it" button confirming the intent actually fired end-to-end; and a permanent settings row reading "Last capture received: 2 hours ago", optionally warning after 14 days of silence.

**Reasoning** — Setup friction is a one-time cost. **Silent breakage is the failure that actually kills this feature** — an iOS update, a user edit, or a card removed and re-added stops the automation, and the user doesn't notice for three weeks, by which point they have lost trust in the app's numbers and cannot reconstruct what is missing. Trust cost compounds; setup cost does not.

---

# 4. Deduplication

## DEC-016 — What the matcher does when it finds something

**Options considered**
- Propose only, with a `merged_into_id` pointer
- Auto-merge above a high threshold, propose below
- Propose only, with a full observation/evidence model
- No matcher; the user resolves duplicates manually

**Choice** — The matcher is a pure function returning scored candidates and **never writes**. Proposals land in the existing draft inbox as "these look like the same purchase" with one-tap accept or reject. Accepting soft-deletes the losing row and sets `merged_into_id`; unmerge is clearing a pointer and an undelete.

**Reasoning** — The error costs are wildly asymmetric. A false merge destroys data the user entered and *feels* unrecoverable even when it technically isn't — the fastest way to lose trust in a finance app. A missed merge is a visible, self-correcting annoyance: two rows appear and the user deletes one. Given that asymmetry, the matcher should take the weakest possible action.

An observation/evidence model (one canonical transaction with N source observations) is the genuinely correct model and handles amount-changing updates elegantly, but it is a large amount of machinery for one maintainer and complicates every query. The pointer is cheap and reversible, which is what matters.

**Consequences** — No new UI surface; proposals reuse the DEC-011 inbox. Rejected proposals must be remembered so the same pair is not proposed repeatedly.

---

## DEC-017 — Structural matching rules

**Options considered**
- Different-source only, same-sign only, 1:1
- Different-source only, opposite signs allowed
- Same-source matching permitted at a higher bar

**Choice** — Only propose matches between rows from **different sources**; only between rows of the **same sign**; each row participates in **at most one** proposal.

**Reasoning** — This largely dissolves the two-identical-coffees problem without touching any threshold. The distinguishing signal is not amount or time, it is **source**:

- Two manual entries of $4.50 at the same café are two deliberate acts by the user, who meant both. Merging them overrules the human.
- Two bank rows with different `external_id`s are two transactions according to the bank, which is authoritative about its own ledger.
- The only case where one real purchase legitimately appears twice is arrival via two *different* sources.

The same-sign rule structurally prevents a $30 refund being proposed as a duplicate of a $30 purchase.

**Consequences** — Residual risk: one Wallet capture plus one manual entry of two genuinely different coffees produces a false proposal. Cost is one "not a match" tap — acceptable given DEC-016 means nothing is mutated without consent.

---

## DEC-018 — Pending→posted, refunds, declined-then-retried

**Options considered**
- Upsert on `external_id`; sign-aware refunds; 2-minute Wallet bucket
- Treat pending and posted as separate rows to be matched
- No timestamp bucketing on Wallet captures

**Choice** — All three of these stop being dedupe problems under the right framing:

- **Pending → posted with a changed amount** (restaurant tip $50→$62, fuel pre-auth $1→$73): if bank sync keeps `external_id` stable across the transition, this is an **upsert on an existing row**, not a match. The amount simply updates. It is only fuzzy when the pending observation came from Wallet and the posted one from the bank — and there the amount tolerance must be **asymmetric** (posted ≥ pending).
- **Refunds and partial refunds**: not duplicates at all. First-class opposite-sign transactions that reduce category spending, optionally linked to an original.
- **Declined-then-retried**: Wallet fires twice with identical amount and card seconds apart. Because the Wallet `dedupe_key` is a hash of `(timestamp_bucket, amount, card)`, a **2-minute bucket** collapses it via the DEC-005 unique index, with no fuzzy matching involved.

**Reasoning** — Routing large, common, mechanical cases through a fuzzy matcher is how a fuzzy matcher gets blamed for problems it never should have seen.

**Consequences** — Depends on the bank keeping `external_id` stable across pending→posted; some providers do not, and this must be verified against the real CDR sandbox before relying on it. The 2-minute bucket will also collapse a genuine second identical purchase within two minutes — rare, and re-addable manually. The bucket size is a tunable constant (DEC-020).

---

## DEC-019 — Field precedence on merge

**Options considered**
- Per-field source precedence, with user edits always winning
- The winning row keeps all fields; the loser is discarded
- A merge screen where the user picks per field

**Choice** — Per-field precedence, held in one table so it is readable and changeable:

| Field | Precedence |
|---|---|
| `occurred_at` | Wallet > manual > bank |
| `amount` | bank > wallet > manual |
| `merchant` | manual > bank > wallet |

Category, and any field the user explicitly edited, always survive regardless of source.

**Reasoning** — This is where merges actually go wrong, and it was not in the original decision tree. The sources have complementary strengths: Wallet capture has an excellent timestamp (it fired at the moment of the tap) and a frequently useless merchant string; bank sync has an authoritative merchant and amount but a date that can be off by days, and a merchant string often mangled into `SQ *COFFEE SUPPLY C SYDNEY`; manual entry has whatever the user bothered to type, but represents their actual intent. "Keep the winner's fields" discards the better value for some field no matter which row wins. A per-field merge screen is never wrong but turns a one-tap action into a form, killing the inbox flow.

---

## DEC-020 — PARKED: the date window and confidence threshold

**Status — deliberately unresolved. Requires a prototype and real data.**

`N` (the date window) and the confidence threshold are not derivable by reasoning. `N` depends on how the specific Australian bank posts dates — some post same-day, some the next business day, some backdate to the transaction date, and weekends compound all of it. The threshold depends on how long the user personally takes to log a purchase manually. Any number chosen now would be invented.

**What was decided** — the structure that makes tuning cheap:

- All weights, `N`, the Wallet timestamp bucket size and the threshold live in **one `MatchingParameters` struct**, with documented starting guesses (`N = 3 days`, single threshold, 2-minute bucket).
- A **debug screen** runs the matcher over real data and shows every candidate with its score breakdown, so tuning means reading a list rather than rewriting code.
- **Revisit after roughly a month of real use.** Do not tune before there is data.

A single threshold, not two: above it, propose; below it, ignore. Fewer knobs.

---

# 5. Metrics and telemetry

## DEC-021 — Where telemetry goes

**Options considered**
- No remote telemetry in v1; build the seam anyway
- TelemetryDeck from day one
- MetricKit to a self-hosted endpoint
- Firebase Analytics

**Choice** — No remote telemetry in v1. Write the full type-safe event API now with a local-only sink writing to a SQLite table.

**Reasoning** — App Store Connect provides downloads, D1/D7/D28 retention, crash-free rate, hang rate and launch time for free with zero code, which covers most of the engineering-health bucket outright. What it does **not** provide is the headline product metric: ASC retention measures app *opens*, not "still logging transactions in week 4", and the gap between those is exactly the thing worth knowing. It also gives nothing on ingestion mix, categorisation correction rate, or capture success rate.

But v1 has approximately one user, and a finance app phoning home is a trust cost paid whether or not the payload is innocent. Building the seam means adding a remote sink later is a single conformance — by which point there are real users to justify it.

**If remote telemetry is later added**, TelemetryDeck is the recommendation: privacy-first, Swift-native, no user identifiers, EU-hosted, cheap, well understood in the indie iOS world. Firebase was rejected — Google in a finance app undercuts the main differentiator and complicates the App Store privacy label.

---

## DEC-022 — Making invariant 6 structural

**Options considered**
- A `TelemetrySafe` conformance allowlist + closed event enum
- The same, plus a build-phase payload scanner
- A closed event enum with fully-typed per-event payload structs

**Choice** — Allowlist by conformance.

- Event names come from a **closed enum**, never a free-form string.
- Payload values must conform to a `TelemetrySafe` protocol.
- `Int`, `Bool`, bucket enums and closed-set enums conform.
- `Money`, `String`, `Decimal`, `Date`, `Category` and `Account` do **not** and **cannot** — conformance is declared inside the telemetry module, so no other file can add it.
- `Money` → bucket conversion is an explicit, named, deliberate function call.
- One test fails if any new type gains conformance without review.

**Reasoning** — The instinct is a denylist: scrub known-bad fields, review payloads. That fails the moment someone adds a field. The type system only helps if the payload *refuses* the dangerous types. `track(.transactionAdded, ["amount": money])` must fail to compile, not fail review.

Per-event payload structs are stricter still and self-documenting, but the boilerplate per event means fewer events get added in practice.

---

## DEC-023 — Local developer stats screen

**Options considered**
- Ship it, hidden behind a settings gesture
- Debug builds only
- Also ship a user-facing "insights" version

**Choice** — Ship it in release builds, reachable by tapping the version number five times.

**Contents** — capture success rate and last-capture timestamp; ingestion mix by source; dedupe proposals shown / accepted / rejected; categorisation correction rate; draft queue age distribution; DB file size and row counts; current schema migration version.

**Reasoning** — With no remote telemetry, this *is* the observability story, and it is nearly free because every number is a SQL query over data already present. Debug-only makes it useless the moment the problem is on someone else's phone. "Last capture received" doubles as the DEC-015 Wallet automation health check.

---

## DEC-024 — Analytics consent

**Options considered**
- Opt-in, asked late, with a "see what's sent" screen
- Opt-in, asked late, plain copy only
- Never add remote analytics

**Choice** — In v1 there is no consent dialog at all, because nothing leaves the device — the strongest possible framing. When remote telemetry is eventually added: **off by default, genuinely**; **never asked at first run** — from settings, or after weeks of use; copy that names the exclusions **concretely** — *"never amounts, merchants, categories or account names — only counts, like 'a transaction was added'"*; plus a screen showing the **actual recent payloads**.

**Reasoning** — The standard vague "help us improve" prompt at first launch reads, in a finance app, as "we are about to look at your money", and it is asked at the exact moment the user has least reason to trust you. Naming what is *not* sent is more reassuring than vaguely describing what is. And the payload screen converts a promise into something checkable, which is worth substantially more than a stated claim.

---

# 6. Security

## DEC-025 — App lock and pre-unlock visibility

**Options considered**
- Privacy overlay + configurable timeout + widget amount toggle
- Overlay + immediate lock, no timeout setting
- Overlay + timeout, widgets always show amounts

**Choice**
- **Privacy overlay on `willResignActive`, always, non-optional.**
- Face ID required after N seconds backgrounded, user-configurable: Immediately / 1 min / 5 min / Off. Default 1 minute.
- Lock Screen widgets hide amounts by default, with a setting to show them. Home Screen widgets show amounts.

**Reasoning** — The part usually got wrong is not the timeout. iOS screenshots the app when it backgrounds, to render the app-switcher card; without an explicit privacy overlay the entire budget is legible in the app switcher with no Face ID involved, and no timeout setting affects that. The second overlooked leak is widgets: a Lock Screen widget reading "$140 left this week" is visible to anyone who picks up the phone, because rendering before unlock is the entire point of a Lock Screen widget.

Immediate lock with no setting is strictest but means Face ID on every app switch, which is genuinely irritating for an app opened ten times a day.

---

## DEC-026 — Encryption at rest

**Options considered**
- OS file protection only; SQLCipher explicitly rejected
- Tighten to `.completeUnlessOpen`
- Add SQLCipher

**Choice** — Keep the default `NSFileProtectionCompleteUntilFirstUserAuthentication`. **SQLCipher is explicitly rejected**, and the rejection is recorded here on purpose.

**Reasoning** — Ask what attacker SQLCipher stops that the OS does not:

| Threat | Already covered by |
|---|---|
| Device stolen while locked | OS full-disk encryption |
| Device unlocked in an attacker's hands | Nothing — SQLCipher's key is in the keychain and the app decrypts happily |
| Malicious app on the device | The sandbox |
| Backup extraction | Encrypted backups |

It costs GRDB ergonomics, key management, and a new class of "database won't open" bugs, in exchange for defending against essentially nobody. For a portfolio piece, a documented, reasoned rejection of an unnecessary security layer demonstrates better judgement than adding it.

`.completeUnlessOpen` was rejected because it breaks widget and background reads while the device is locked.

---

## DEC-027 — Threat model

**Options considered**
- Document all five, including the ones the OS handles
- Document only actively-mitigated threats
- Skip the written threat model

**Choice** — Document all five honestly.

| # | Threat | Mitigation | Whose job |
|---|---|---|---|
| 1 | Someone picks up the unlocked phone and opens the app | Face ID lock + app-switcher overlay (DEC-025) | **Ours — the only one we defend against** |
| 2 | Device stolen while locked | OS full-disk encryption | iOS; we contribute nothing |
| 3 | iCloud account compromise | Advanced Data Protection | Apple; outside our control |
| 4 | Developer compromised or curious | Structurally impossible — data never leaves the device | Architecture (DEC-002, DEC-021) |
| 5 | Malicious app on device | App sandbox | iOS |

**Reasoning** — A threat model that honestly says "I defend against exactly one of these, and here is why the other four don't need me" is stronger engineering judgement than a longer list of countermeasures. It also stops future-me adding security theatre to threats already covered — see DEC-026, which is precisely that temptation resisted.

Threat 4 is the actual privacy story worth advertising.

---

# 7. Domain modelling

These four were not on the original decision tree. They surfaced during the session as things that would otherwise have been silently assumed.

## DEC-028 — Transfer representation

**Options considered**
- A single row plus a `postings` expansion view
- Two linked rows sharing a `transfer_group_id`
- A single row with a kind flag and no expansion view

**Choice** — One row: `kind = 'transfer'`, `from_account_id`, `to_account_id`, with `category_id` forced NULL by CHECK. A `postings` view expands each transfer row into two signed rows so per-account balances remain a simple sum.

**Reasoning** — The `spending` view (DEC-010) handles the *exclusion* half of invariant 2, but representation determines whether a half-recorded transfer is even possible. Two linked rows is the ledger-correct model and makes balances a plain `SUM`, but nothing at the schema level prevents an orphaned half, and soft-deleting one half silently breaks the pair. A single row cannot be half-recorded by construction, and the expansion view recovers the ledger ergonomics.

**Consequences** — A second view to maintain. Balance queries read `postings`, never `transactions`.

---

## DEC-029 — Split representation

**Options considered**
- CHECK for null parent category + trigger for sum integrity
- CHECK plus application-level sum validation
- Allow an unallocated remainder

**Choice**
- `CHECK`: a parent with splits has `category_id IS NULL`.
- `AFTER INSERT/UPDATE/DELETE` trigger on splits: raise if the split total ≠ the parent amount.
- The `spending` view reads split rows when present and the parent otherwise.

**Reasoning** — Invariant 5's "no category of its own" half is a straightforward CHECK. The half not previously specified is whether splits must sum to the parent, and SQLite cannot express a cross-row CHECK — so it is a trigger, application code, or nothing. "Nothing" means a $100 transaction can carry $80 of splits and category totals quietly disagree with account balances forever: exactly the month-four silent corruption feared in DEC-003, merely relocated. Application-level validation gives friendlier errors but is convention again, which the brief explicitly forbids.

An unallocated remainder (splits ≤ parent) is genuinely useful — split only the part you care about — but it means the sum invariant does not exist and the remainder must be handled in every aggregate. Rejected for v1; revisit only with a concrete need.

---

## DEC-030 — Category guessing

**Options considered**
- A merchant→category memory learned from the user
- The same, plus a bundled starter merchant list
- An on-device Core ML classifier

**Choice** — A `merchant_rules` table mapping normalised merchant string → category, written every time the user confirms or corrects a category.

**Reasoning** — DEC-011's one-tap confirm is worthless if the guess is usually wrong, and the categorisation correction rate metric is meaningless without knowing what it measures. The memory table is deterministic, explainable, needs no model and no bundled data, works from about the third transaction onward, and the user can view and edit the rules. Core ML generalises across unseen merchants but is a large amount of work, unexplainable when wrong, and the opposite of boring.

A bundled Australian starter list (Woolworths, Coles, Ampol) would solve cold-start, but it is a data set to curate and it rots. Deferred.

---

## DEC-031 — CSV import

**Options considered**
- A mapping UI saved as a reusable named profile
- Auto-detect with a confirmation screen
- Hardcoded templates for the big four banks

**Choice** — The first import walks the user through "which column is the date / amount / description", pre-filled with a best guess from the header row, then saves the result as a **named profile**. Subsequent imports are one tap.

**Reasoning** — Every Australian bank exports a different shape: different column names, different date formats, debits as negative numbers versus a separate column, sometimes a preamble before the header. Per-bank templates are fastest for banks covered and useless for the rest, and break silently whenever a bank changes its export. Auto-detect gives the best first run but its failures are confusing rather than instructive, and nothing pins the layout for future imports.

**Interaction with DEC-005** — CSVs frequently have no stable external ID, so `dedupe_key` must be a hash of the raw row. A bank changing its export format therefore silently changes every key and turns re-import into full duplication. **The saved profile pins the column layout, which is what keeps those hashes stable.** This is the load-bearing reason to prefer profiles over auto-detect.

---

# 8. Revisions

## DEC-032 — Revisiting DEC-001 under a hardware constraint

**Context** — DEC-001 chose SwiftUI + Swift, reasoning that "iOS-only removes the entire case for a cross-platform runtime". That reasoning was sound but incomplete: it did not have the development machine as an input. The development machine is Windows, with no Mac available and none planned. SwiftUI requires Xcode, which requires macOS. The original decision is unbuildable as recorded.

**Options considered**
- (a) Swift, built on cloud macOS CI (GitHub Actions), TestFlight to device
- (b) Expo / React Native + TypeScript, raw SQLite, EAS Build
- (c) Defer the project until a Mac exists

**Choice** — (b). Expo + TypeScript, raw SQLite via `expo-sqlite`, EAS Build for cloud compilation, TestFlight for device install.

**Reasoning**

1. *The feedback loop is the whole argument.* Both (a) and (b) compile in the cloud, so neither escapes a slow build. The difference is what sits behind that wait. Under (a), every button, every layout tweak and every colour change is a 5–15 minute round trip with no simulator, no previews and no breakpoints — print debugging for the entire app. Under (b), the hot-reload loop runs on the physical iPhone over wifi and the slow cloud build is confined to the one genuinely native surface (Wallet capture, and later widgets). (a) puts the slow loop on 95% of the work; (b) puts it on 5%.
2. *The persistence design is untouched.* DEC-003's load-bearing claim is that the invariants are SQL invariants. `expo-sqlite` opens the same SQLite, runs the same DDL, and enforces the same CHECK constraints, triggers, views and unique indexes. Migrations remain hand-written and reviewed. The `spending` view, the `postings` view, the split-sum trigger and the upsert funnel port unchanged. Nothing in DEC-005, DEC-010, DEC-028 or DEC-029 is affected.
3. *"Boring" survives.* DEC-003 rejected an ORM in favour of explicit SQL, on the grounds that one person maintains this. The same reasoning selects raw `expo-sqlite` over Drizzle or WatermelonDB. The stack changed; the philosophy did not.
4. *(c) is not a real option.* "Not soon" makes deferral indistinguishable from cancellation.

**What is surrendered — recorded honestly**

- **App Intents must be written blind.** The Wallet capture intent is still Swift, now as an Expo config plugin wrapping a native target, developed against a cloud-build loop with no local compiler. Sprint 7 gets materially harder.
- **Widgets get harder for the same reason.** WidgetKit is Swift-only and needs its own native extension target. DEC-025's widget decisions stand, but their cost rises.
- **The privacy overlay is less crisp.** SwiftUI's `willResignActive` becomes React Native's `AppState` `inactive` transition. Achievable, but it is a mitigation against an OS screenshot with a narrow timing window, and it must be verified on device rather than assumed.
- **The portfolio signal changes shape.** It is no longer "I know SwiftUI". It is now "I know React Native, and I revised a recorded architectural decision when a constraint invalidated its premise, without losing the invariants it was protecting." That is not obviously worse.

**What is gained**

- A development loop that exists at all on the available hardware
- `FlashList` outperforms SwiftUI's `List` on exactly the long-complex-row ledger screen DEC-001 flagged as a risk. That consequence can be struck.

**Consequences** — DEC-001 is superseded, not deleted; it remains the correct decision for anyone holding a Mac. `Money` is a branded TypeScript type over integer minor units, property-tested with `fast-check` — invariant 1 is unchanged in substance. GRDB `ValueObservation` has no direct equivalent; the reactivity mechanism over SQLite is a new open item. An Apple Developer Program membership (USD $99/yr) becomes non-optional, because without a Mac a free-provisioned build cannot be re-signed every 7 days and TestFlight is the only durable route onto the device.

---

## DEC-033 — Reverting DEC-032 now that a Mac exists

**Context** — DEC-032 superseded DEC-001 on a single hardware fact: no Mac was available. That fact has changed — the development machine is now a Mac. DEC-032 said explicitly, at the time: *"DEC-001 is superseded, not deleted; it remains the correct decision for anyone holding a Mac."* This decision exercises that clause.

**Options considered**
- (a) Revert to DEC-001/DEC-003 as originally written: SwiftUI, Swift, GRDB, no Expo layer
- (b) Stay on the Expo/React Native path from DEC-032, even with a Mac available

**Choice** — (a). Revert. SwiftUI + Swift + GRDB, local only. Xcode replaces Expo/EAS/TestFlight-via-cloud-build as the toolchain.

**Reasoning**

1. *The constraint that motivated DEC-032 is gone.* DEC-032's entire argument was the feedback-loop cost of building native UI with no local compiler. With a Mac, that cost doesn't exist — Xcode Previews and the simulator restore the fast loop DEC-032 was compensating for.
2. *DEC-001's original reasoning was never wrong, only inapplicable.* iOS-only still removes the entire case for a cross-platform runtime, and App Intents (Wallet capture, Sprint 7) and WidgetKit (Sprint 9) are still Swift-native frameworks. DEC-032 itself flagged both as harder, blinder, and cloud-build-only under RN — a cost paid for a constraint that no longer applies.
3. *Nothing in the schema or invariants moves.* DEC-032 already established that DEC-003's SQL invariants are toolchain-independent; GRDB is simply the tool DEC-003 always preferred over `expo-sqlite`, now unblocked.
4. *Deployability is at least as good, not worse.* Native SwiftUI is the standard, best-supported path to the App Store — no Expo/EAS account dependency, no RN bridge layer to maintain long-term. This matters more now that goal 3 ("possibly a real product later") is back in view.

**Consequences** — Every RN-specific item in the roadmap and open items below reverts: `expo-sqlite` → GRDB, `FlashList` → `UICollectionView`-wrapped `List` (per DEC-001's original consequence, only if row counts warrant it), `AppState` → `willResignActive`, the Expo config-plugin App Intents wrapper → a normal native App Intents extension target, TanStack Query → GRDB `ValueObservation`. The reactivity and privacy-overlay open items DEC-032 introduced are closed by this reversion, not resolved by prototyping — they were only open because of the RN constraint. `Money` becomes a Swift value type again (invariant 1 unchanged in substance, per DEC-001). Whether the Apple Developer Program enrollment stays mandatory is revisited separately — see DEC-034.

---

## DEC-034 — Deferring the Apple Developer Program

**Options considered**
- Enroll now (as DEC-032 assumed), sign with a paid team, distribute via TestFlight
- Defer enrollment. Sign with a free Apple ID (personal team), install directly from Xcode to one's own phone

**Choice** — Defer. Free Apple ID, direct Xcode install, no TestFlight, for as long as the app stays single-device and personal.

**Reasoning** — Goal 1 ("a tool I use every day") only requires the app running on the owner's own phone, which free provisioning does at no cost. DEC-032 assumed paid enrollment was non-optional because *that plan* routed distribution through TestFlight (itself a consequence of having no local compiler at all under React Native). With native Xcode now in place, that reason no longer applies — Xcode can install straight to a paired device without any account tier. The features that do require a paid team — CloudKit/iCloud, Push Notifications, Sign in with Apple — are all things DEC-002 and DEC-021 already rejected for this app. App Groups and WidgetKit, both needed later (Sprint 7, Sprint 9), work under free provisioning.

**Consequences** — Free-provisioned apps carry a 7-day provisioning-profile expiry: after that window the app refuses to launch until reinstalled from Xcode, which means the phone needs to meet the Mac (USB or same wifi network) roughly weekly. Acceptable friction for a single-owner, single-device app; revisit if the app is ever handed to a second person, put on a second device, or needs a capability that turns out to require a paid team.

---

# 9. Income and payday

## DEC-035 — Income representation

**Context** — Nothing in this document modelled income. `spending` (DEC-010) and `postings` (DEC-028) were both written assuming expenses and transfers are all there is. DEC-036 requires the user to record what they were paid, so income needs a representation before that feature has anywhere to write.

**Options considered**
- `kind = 'income'` on the transactions table, `category_id` forced NULL by CHECK, excluded from `spending`, expanded as one positive posting in `postings`
- A normal transaction with an inverted sign in a reserved "Income" category
- A separate `income` table
- A transfer (DEC-028) from a phantom external "Employer" account

**Choice** — `kind = 'income'`, alongside `'expense'` and `'transfer'`. `category_id IS NULL` by CHECK, no splits, excluded from `spending`, one positive posting in `postings`.

**Reasoning**

A reserved category is the tempting cheap answer and it is the one that breaks. The `spending` view is the entire enforcement mechanism for invariant 2 and rule 1; making its correctness depend on a *row* the user can rename, delete, merge or reuse turns a constraint back into a convention, which the brief forbids. Category management is user territory (DEC-030) and always will be.

Sign inversion inside `transactions` is worse than it looks. Once one row's amount means the opposite of another's, every aggregate must know which sign it is holding, and a single mis-signed row corrupts category totals and account balances simultaneously — with nothing structural to catch it. Sign belongs where DEC-028 already put it: in `postings`, which exists precisely to be the signed expansion.

A separate table fails for the same reason DEC-010 rejected a separate drafts table, and harder. Sprint 6 imports bank CSVs, and a bank CSV contains salary credits, so income is *ingested* data — it must flow through the single upsert funnel (rule 3) and be visible to the cross-source matcher (DEC-016). A second table means a second write path and a UNION on every dedupe check.

The phantom-employer transfer is the ledger-purist answer, and it is genuinely elegant: DEC-028's expansion already balances. It is rejected because DEC-028's transfer semantics are explicitly "between own accounts" — an employer account is not the user's, would appear in account pickers, and would accumulate an ever-more-negative balance that means nothing to anybody. Fabricating accounts to preserve double-entry purity in a single-user budgeting app is cost without a payer.

**Consequences**

- The `kind` CHECK becomes `IN ('expense','transfer','income')`, in **migration 001** — Sprint 1, before any data exists. This is the sprint-ordering principle applied literally: a third `kind` is free now and a data migration later.
- `CHECK`: income rows have `category_id IS NULL` and may not have splits. The DEC-029 split trigger is unaffected.
- `spending` gains a fourth clause: `kind = 'expense'`. Stated positively — **spending is expenses only**, not "everything that isn't a transfer".
- `postings` gains an income case: one positive posting on `account_id`.
- Amounts stay unsigned in `transactions`. Sign is a `postings` concern, as it already was for transfers.
- **The budget screen does not change.** The budgeting model is per-category caps, not envelope and not zero-based (locked before the design session), so income funds nothing and allocates nothing. It moves a balance and records a fact.
- Income participates in dedupe like any other row, which means a manually entered payday and an imported salary credit can and will collide. That is the DEC-016–019 matcher's job, and it now has income rows in scope — see open items.

---

## DEC-036 — Payday reminders

**Context** — The app is structurally blind to income. Bank sync is deferred indefinitely (CDR accreditation not held), and Wallet capture (DEC-010–015) sees card spending only; a salary credit never touches it. Nothing in the system can observe that the user was paid. If income is to be recorded at all, the user must be asked, and the app must choose a moment to ask.

**Options considered**
- A local notification on a **separate** pay schedule, tapping through to a blank income form
- The same, but derived from DEC-007's budget anchor with no separate schedule
- No notification at all — a persistent "log your pay" card in the ledger once a payday has passed
- Auto-create the income row on payday from a stored expected amount

**Choice** — A local notification on a pay schedule stored independently of the budget anchor: `pay_anchor` (local DATE), `pay_cadence` (weekly/fortnightly/monthly), and a reminder time-of-day. Off until enabled. Tapping opens a blank income entry form; nothing is written until the user saves. The in-app card is kept as the fallback, not as the mechanism.

**Reasoning**

*Why a separate schedule.* Pay rhythm and budget rhythm are the same thing by default and not by definition. DEC-007/DEC-008 make cadence a changeable, forward-dated budgeting decision — and a user switching from fortnightly to monthly budgeting has not changed jobs. One field serving both purposes guarantees that one of the two is wrong the instant they diverge, and the wrongness is silent in both directions: a reminder that fires on the wrong day, or a budget period retimed by a payroll change. Onboarding pre-fills `pay_anchor`/`pay_cadence` from the DEC-007 answers, so the cost is a confirm step on an already-filled form, not a second interrogation.

*Why a notification is justified here when DEC-011 rejected one.* DEC-011 refused per-capture alerts because they are frequent, redundant with the lock-screen alert Wallet itself just posted, and would be switched off within a week. A payday reminder inverts all three: at most 52 a year and typically 26, duplicated by nothing, and fired at the one moment the app genuinely cannot observe for itself. The rationing principle is upheld, not overturned — this is the app's *only* scheduled notification, and the daily draft digest (DEC-011) remains the only other one in the design.

*Why the app must not fill in the amount.* Pay varies — hours, overtime, leave loading, a tax threshold change — so a stored "expected amount" writes a number nobody checked into account balances, and when the balance later looks wrong there is no way to find the row that lied. That is DEC-012's argument verbatim, and it applies here with less excuse: capture drafts at least come from a real card tap, whereas a projected salary comes from nothing at all. The app never guesses on the user's behalf.

*Mechanism.* `UNUserNotificationCenter` local notifications. **This requires no paid Apple Developer Program membership and no entitlement.** DEC-034 lists Push Notifications among the paid-team features this app does not need; that refers to APNs, and local scheduling is unrelated. Recorded explicitly because the two are conflated constantly and DEC-034 would otherwise read as blocking this feature.

iOS offers a repeating `UNCalendarNotificationTrigger` that can express "every Thursday" and "the 15th of every month", but **there is no way to express a 14-day cycle** — the one cadence most Australian salaries actually use. Fortnightly must therefore be a rolling queue of discrete one-shot triggers, topped up whenever the app launches. iOS caps pending notifications at 64 per app; a year of fortnightly pay is 26, so scheduling roughly a year ahead fits comfortably.

All three cadences use that same rolling queue, rather than repeating triggers for two of them and a queue for the third. One code path is worth more than the saved scheduling calls: monthly-on-the-31st then reuses the DEC-007 clamping rule instead of trusting calendar matching to do something defensible in February, and the queue is refilled lazily on launch for exactly the DEC-009 reason — `BGTaskScheduler` runs when iOS chooses, and "why didn't this fire" is not a debugging session worth having twice.

Pay dates are stored as local DATEs plus a time-of-day, never as instants (rule 6). Which dates the queue *should* contain, given an anchor, a cadence and today, is a pure function and belongs in the testable core alongside `generatePeriods`.

*Content and privacy.* DEC-025's concern is what is legible before unlock. The notification carries no amount by construction — it exists to ask for one — but it does disclose pay timing, so the body names no employer, no account and no figure: "Payday — log what you were paid". Whether previews are shown on a locked screen is an iOS-level user setting the app cannot control, which is exactly why the content must be safe unconditionally rather than conditionally.

*Drift.* Australian payroll pays early ahead of weekends and public holidays, so a one- or two-day miss is normal, not a bug. The notification carries a **"Remind me tomorrow"** action that reschedules a single one-shot; it never moves `pay_anchor`. Changing the anchor stays an explicit settings action, forward-dated, per DEC-007's governing principle.

**Consequences**

- New settings: pay anchor, pay cadence, reminder time, enabled flag. Disabled by default and offered during onboarding, pre-filled from the DEC-007 answers.
- Notification permission is requested at the moment the user enables the reminder, never at first launch — DEC-024's consent precedent.
- Denied or later revoked permission must degrade rather than break: the ledger card ("no pay logged since 14 March") shows regardless of notification state, and is the only thing standing between a permission prompt the user declined and a feature that silently does nothing.
- **Free provisioning interacts badly, and this is not a reason to change either decision.** Pending notifications are held by the system and still fire, but under DEC-034's 7-day profile expiry the app itself refuses to launch, so the notification arrives and tapping it does nothing until the phone next meets the Mac. Recorded so it is diagnosed once rather than twice.
- Scheduling behaviour is device-only — the simulator proves nothing useful and full verification needs a real payday. The pure date-queue function must therefore be a plain unit test off-device, leaving only the thin `UNUserNotificationCenter` binding unverified.
- The reminder tells the user *that* payday arrived. It never checks *how much* — reconciling actual pay against expected pay is a different feature and is not in v1.

---

## DEC-037 — Refund representation

**Context** — DEC-018 and DEC-035 conflict, and migration 001 cannot satisfy both. DEC-018 says refunds are "first-class opposite-sign transactions that reduce category spending". DEC-035, written later, says "amounts stay unsigned in `transactions`" and that sign is a `postings` concern. The `kind` CHECK and the amount CHECK are both written in Sprint 1, so the conflict had to be resolved before any data existed.

**Options considered**
- A fourth `kind = 'refund'`, amounts unsigned, `spending` subtracts refunds
- Opposite-sign expense rows — DEC-018 taken literally, dropping the `amount_minor >= 0` CHECK
- Defer to Sprint 6, when refunds first arrive by CSV

**Choice** — `kind = 'refund'`, alongside `'expense'`, `'transfer'` and `'income'`. Amounts stay unsigned. The `spending` view adds expenses and subtracts refunds.

**Reasoning**

DEC-035 already argued this case and its argument is not specific to income: "once one row's amount means the opposite of another's, every aggregate must know which sign it is holding, and a single mis-signed row corrupts category totals and account balances simultaneously — with nothing structural to catch it." A refund is precisely such a row. Sign belongs in the expansion views, where DEC-028 put it.

The sprint-ordering principle then decides the timing, exactly as DEC-035 applied it: a fourth `kind` is free in migration 001 and a data migration later.

Unlike income and transfers, **a refund does carry a `category_id`** — it must, because reducing the right category's spending is the entire point of the row.

**Consequences**
- `kind` CHECK is `IN ('expense','refund','transfer','income')`.
- `category_id` is permitted for `'expense'` and `'refund'`, and forced NULL for `'transfer'` and `'income'`.
- `spending` signs by kind: expenses positive, refunds negative. The rows in `transactions` remain unsigned.
- `postings` gives a refund one positive posting on its account.
- Rule 9 restated: **spending is expenses and refunds only** — income and transfers never appear.
- Linking a refund to its original purchase (DEC-018's "optionally linked") is not modelled in v1.

---

## DEC-038 — Splits removed from v1

**Context** — Two separate problems surfaced when implementing DEC-029.

*Structural.* DEC-029's enforcement mechanism is unimplementable as written. An `AFTER INSERT` trigger that raises when the split total ≠ the parent amount rejects the first row of every multi-way split: inserting $70 of a $70/$30 split on a $100 parent sees $70 ≠ $100 and aborts. There is no partial state in which the invariant holds, so the check must be deferred to end-of-transaction — which SQLite can express only through a trigger-maintained "balanced parents" table plus a `DEFERRABLE INITIALLY DEFERRED` foreign key. That is the most intricate SQL in the schema, for a feature not yet justified by use.

*Product.* Splitting is manual work the user must remember to do on every mixed purchase. One $100 Woolworths charge covering $70 of groceries and $30 of a gift can instead be corrected by editing the row's category, or by deleting it and entering two transactions — the account balance nets identically and the category totals come out right.

**Options considered**
- Remove splits from v1
- Build them now with the deferred-FK mechanism
- Keep DEC-029's trigger behind a guard flag the write path sets during batch inserts
- Validate split sums in the upsert funnel instead

**Choice** — Remove splits from v1 entirely. Invariant 5 is struck, not parked. DEC-029 is superseded.

**Reasoning**

The two rejected enforcement mechanisms both fail on the brief's own terms. A guard flag is convention wearing a trigger's clothes — forget to clear it and enforcement silently stops, which is the failure class DEC-003 exists to prevent. Funnel-level validation was already considered and rejected by DEC-029 itself for being convention.

That leaves the deferred-FK mechanism, which does work and is genuinely structural, against a feature whose value is thin. The only case where "just enter two transactions" is materially worse is Sprint 6, when a bank CSV delivers one $100 row that the user has already recorded as two — a dedupe problem, not a budgeting one.

**The asymmetry that makes this cheap is the deciding factor.** Refunds (DEC-037) had to be settled now because the `kind` CHECK constrains every row, so changing it later is a data migration. Splits are not like that: adding a `splits` table later is purely additive — a new table, its triggers, and dropping and recreating the `spending` view. A view holds no data, so recreating one costs nothing. Deferring the decision is therefore nearly free, while building it now costs the hardest work in Sprint 1.

**Consequences**
- Invariant 5 ("splits don't double-count") is removed from the invariant list. It cannot be violated by a schema that has no splits.
- `spending` loses its split-parent/split-child clause and reads `transactions` directly — meaningfully simpler, which matters for the one definition every aggregate depends on.
- Sprint 5 becomes transfers-only.
- **The Sprint 6 matcher must tolerate one bank row legitimately facing several manual rows.** DEC-017's "each row participates in at most one proposal" rule already prevents a wrong auto-merge here, and DEC-016 means nothing is mutated without consent.
- DEC-005's unconditional index covering soft-deleted rows means a bank row the user deleted and replaced with two manual rows will not resurrect on re-import. The manual correction survives.
- Revisit only if real use produces mixed purchases often enough to be annoying.

---

# Open items

| Item | Status | Resolution path |
|---|---|---|
| Matcher `N` and confidence threshold (DEC-020) | Parked, deliberately | Tune after ~1 month of real data via the debug screen |
| Bank `external_id` stability across pending→posted (DEC-018) | Unverified assumption | Verify against the CDR sandbox before relying on it |
| Bundled starter merchant list (DEC-030) | Deferred | Revisit if cold-start categorisation proves painful |
| Unallocated split remainder (DEC-029) | Rejected for v1 | Revisit only with a concrete need |
| `Money` value type design | Locked by invariant 1, not grilled | Integer minor units + currency code, explicit arithmetic, property-tested |
| SQLite→UI reactivity mechanism (DEC-032) | Closed by DEC-033 | GRDB `ValueObservation` drives SwiftUI directly, as DEC-003 always intended. No longer open. |
| Privacy overlay fidelity (DEC-032) | Closed by DEC-033 | Native `willResignActive` (DEC-025), not `AppState`. Still verify on a physical device in Sprint 9 as routine QA, not as a research risk. |
| Income vs. imported salary credit dedupe (DEC-035) | Open | Sprint 6 brings salary lines in by CSV; confirm the DEC-016 matcher scores income rows sensibly before trusting it |
| Pay-date drift around weekends and public holidays (DEC-036) | Accepted, unmodelled | The snooze action absorbs 1–2 days; revisit only if a quarter of real paydays shows systematic drift |

---

# The rules that must not be broken

Extracted for quick reference, because these are the ones that produce silent corruption when violated.

1. **Nothing computes spending from the `transactions` table.** Everything reads the `spending` view. (DEC-010)
2. **Nothing computes balances from the `transactions` table.** Everything reads the `postings` view. (DEC-028)
3. **All ingestion goes through the single upsert funnel.** There is no other write path for ingested data. (DEC-005)
4. **The matcher never writes.** It returns scored candidates; only a user action mutates. (DEC-016)
5. **Periods are never regenerated.** Cadence and anchor changes are forward-dated. (DEC-007)
6. **Period boundaries are local DATEs, never instants.** (DEC-009)
7. **Drafts never count toward the authoritative spending number, and are never auto-confirmed.** (DEC-012)
8. **`Money` cannot conform to `TelemetrySafe`.** (DEC-022)
9. **Income and transfers are never spending and never carry a category.** `spending` reads `kind IN ('expense','refund')` only, expenses positive and refunds negative. (DEC-035, DEC-037)
10. **Amounts in `transactions` are never negative.** Sign exists only in the `spending` and `postings` views. (DEC-035, DEC-037)
