# ADR-0003 — Single hardware target; open source, not commercial

**Status**: Accepted | **Date**: 2026-08-04 | **Amended**: 2026-10-08 (commercial code removed) | **Relates to**: [ADR-0002](0002-cross-space-relocation-via-process-assignment.md)

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
- The commercial machinery was first kept dormant. On 2026-10-01 a paid launch was briefly reconsidered and then dropped again on 2026-10-08, and the machinery was **deleted**: the license server (`server/`), the in-app licensing (`App/Core/Licensing/`, feature gates, trial, License pane and window), `SHIPIT.md`, and the pricing and buy pages of `marketing/`. The marketing site remains as the project's home page. Git history has the removed code.
- Sparkle packaging and signing remain useful — an open-source app can still ship updates.
- Constitution §IV (allowed external endpoints) is stricter: the license API was removed in constitution 1.2.0, and the appcast is the only remaining endpoint.

## Revisit Trigger

- The owner's display hardware changes, or `spans-displays` is set to `0`.
- Apple ships a public cross-Space window API, making generality cheap enough to reconsider.
