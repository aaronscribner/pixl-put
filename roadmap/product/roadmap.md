# DisplayMaid-Next — Release Roadmap

Time-ordered plan. Each row in [`features.md`](./features.md) maps to one of
the milestones below. Dates are intentionally absent — the gating signal for
each milestone is the listed exit criterion, not a calendar.

## v1.0 — Core Window Memory

**Theme**: Restore the windows the user already arranged. Get the
multi-instance case right (4 Brave windows, 3 VS Code workspaces). Earn
trust through correctness, not features.

**Spec**: [`001-core-window-memory/`](./001-core-window-memory/)

**Includes** (from [`features.md`](./features.md) v1 section): all ✅ rows,
plus the five shipping deep-identity providers (browsers, VS Code, Xcode,
terminals, JetBrains).

**Exit criteria** (also acts as the v1.0 acceptance gate):

- All seven SC-NNN measurable outcomes in spec 001 met on a 2024 MacBook
  Air reference machine.
- The full `quickstart.md` checklist passes manually on:
  - Laptop-only configuration.
  - Laptop + one external monitor.
  - Laptop + two external monitors.
- Zero off-device requests observed in 24-hour Little Snitch trace under
  default settings (Sparkle appcast traffic the only allowed exception).
- Notarized installer reproducibly builds from a clean checkout.
- Constitution Check in plan.md remains all-pass (no Complexity Tracking
  entries needed to ship).

**Non-goals for v1.0**: anything in the v1.x or v2+ tables of
[`features.md`](./features.md), including named-snapshot polish if it
threatens the exit criteria. Named snapshots are explicitly P3 within v1
and droppable.

## v1.x — Hardening and power-user

**Theme**: Convert the edge cases and P3 features of v1 into first-class
specs once real-world usage tells us which of them matter. Each row below
becomes its own spec under `specs/00N-*/` when promoted.

| Candidate spec | Trigger to promote |
|----------------|-------------------|
| `00N-relaunch-missing-apps` | User reports complain that "restore did nothing" when target apps are closed. Likely first v1.x spec. |
| `00N-app-rules` | More than two requests for "exclude this app from restore" or "force ordinal for bundle X." |
| `00N-snapshot-diff` | Users hesitant to enable auto-restore because they can't see what will change. |
| `00N-import-export` | First user asks to move snapshots between machines (will probably be the first v1.x ticket). |
| `00N-restore-hotkey` | Any user uses manual menu-bar restore more than five times a day. |
| `00N-scheduled-capture` | "I want a guaranteed daily snapshot independent of idle events." |

**Exit criteria for v1.x as a whole** (not per spec): the v1.0 SC-NNNs hold
without regression, and the product still passes the constitution check
without Complexity Tracking entries.

## v2 — Next architectural commitment

**Theme**: Decided after v1.x stabilizes. Likely candidates, with rough
shape of the architectural decision each would require:

- **Cross-Mac sync without a service.** Would require a constitution
  clarification on §IV (local-only) — a user-pointed iCloud Drive or
  shared folder is on-device per Mac but synced via a path the user
  controls. Not yet decided whether this counts as a deviation.
- **Stage Manager and Sidecar first-class support.** Spec 001 accepts
  "quirks acceptable for v1." If those quirks turn out to be the modal
  user experience, this becomes the v2 theme.
- **Per-user (Fast User Switching) snapshots.** Would scope all paths
  under `~/Library/.../{uid}/`. Self-contained change, but needs a v2
  migration story for v1 snapshot files.

The v2 theme is chosen by reviewing v1.x user reports and picking the
direction with the highest "this is why I'd switch back to DisplayMaid"
weight in feedback. No earlier commitment is wise — and none is needed,
because spec 001 alone justifies shipping v1.

## What this roadmap does not commit to

- A release date for any milestone.
- A specific date for promoting any v1.x candidate to a spec.
- Anything in the v2+ rows of [`features.md`](./features.md) marked ❌ —
  those are governance lines that require constitution amendments to
  cross, not roadmap items to schedule.
