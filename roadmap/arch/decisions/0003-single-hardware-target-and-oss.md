# ADR-0003 — Single hardware target; open source, not commercial

**Status**: Accepted | **Date**: 2026-08-04 | **Supersedes**: the commercial framing in `SHIPIT.md` | **Relates to**: [ADR-0002](0002-cross-space-relocation-via-process-assignment.md)

## Context

PixPut was built to be sold: Ed25519-signed licenses, a Cloudflare Worker license API, Lemon Squeezy as merchant of record, Sparkle auto-update, an Astro marketing site, and a launch checklist in `SHIPIT.md`. Selling it implies supporting arbitrary Mac hardware and arbitrary Spaces configurations.

That generality is where the complexity concentrated, and it is not complexity the owner is being paid to carry:

- Window relocation across Spaces has no public API. The only viable mechanism (ADR-0002) is process-scoped and sticky, and on a real accumulated snapshot it misplaces more windows than it places (`satisfied=29`, `displaced=38`).
- Per-window relocation exists only through yabai, which requires SIP disabled — not something to ask arbitrary users to do.
- Space↔display resolution has two incompatible identifier namespaces. CGS keys its managed displays by a `"Display Identifier"` string (literally `"Main"` on the target hardware), while PixPut keys displays by `DisplayFingerprint` UUIDs. A fingerprint-keyed lookup misses and silently returns index `0`, flattening a snapshot's Space data — a regression that was designed and nearly implemented before being caught.
- Supporting "displays have separate Spaces" (the macOS default) requires resolving which managed display owns a given Space index. `PrivateCGS.spaceID(atIndex:displayUUID:)` currently guesses by iterating an unordered dictionary, which is a coin flip once more than one managed display exists.

## Decision

**PixPut is open source and unsold, and supports exactly one hardware configuration.**

The supported configuration:

| Property | Value |
|---|---|
| Display | Samsung Odyssey G9 dual-4K, PBP / dual-4K mode |
| As macOS sees it | Two logical displays, 3840×2160 each, at `x=0` and `x=-3840` |
| Physical reality | One panel — both logical displays report vendor `19501`, serial `810635603` |
| `com.apple.spaces spans-displays` | `1` — Spaces span the whole panel |
| CGS managed displays | Exactly **one**, `"Display Identifier" = "Main"` |

Generality across other hardware and other Spaces settings is an explicit **non-goal**, not a known gap.

## Consequences

- **A single managed display Space set is an invariant, not an assumption to be defended.** Every "which display owns this Space index" question is answered by the only set that exists. The ambiguous fallbacks become unreachable by construction.
- **Unsupported configurations must refuse loudly, never guess.** Where the code previously picked an arbitrary display, it now reports the configuration as unsupported and declines to act. A wrong guess silently scatters a user's windows; a refusal is legible.
- Space lookups must never be keyed on `DisplayFingerprint` UUIDs. CGS's managed-display set is the authority.
- The sticky, process-wide relocation side effect of ADR-0002 is acceptable — the person absorbing the tradeoff is the person who chose it.
- The commercial machinery (`server/`, licensing gates, Lemon Squeezy, `SHIPIT.md`, `marketing/`) is **retained and dormant, not deleted**. Selling is not the plan, but it is not ruled out, and the cost of keeping the code is close to zero while rebuilding it would not be. No work advances it; nothing depends on it. The licensing placeholder-key bypass keeps every feature enabled, which is the steady state rather than a development convenience.
- Sparkle packaging and signing remain useful — an open-source app can still ship updates.
- Constitution §IV (allowed external endpoints) becomes stricter for free: with no license API, the appcast is the only remaining endpoint.

## Revisit Trigger

- The owner's display hardware changes, or `spans-displays` is set to `0`.
- Apple ships a public cross-Space window API, making generality cheap enough to reconsider.
- Commercialisation comes back on the table — the machinery is dormant, not gone, so this ADR would be amended rather than reversed.
