# PixPut — Agent-Facing Constitution

> This file is the source bindings the agent system reads on every invocation.
> The load-bearing product principles live in [`../roadmap/product/constitution.md`](../roadmap/product/constitution.md); this file only wires paths and namespaces.
> Cross-cutting agent rules live in [`./project-precepts.md`](./project-precepts.md).

## Code Review Checklist (delta from project constitution)

The project constitution at [`../roadmap/product/constitution.md`](../roadmap/product/constitution.md) sets the load-bearing principles. Reviewers MUST verify, on every PR:

- [ ] No title-only window identity (project constitution §II)
- [ ] All persistence under `~/Library/Application Support/` (§IV); no telemetry, no cloud sync
- [ ] Private CoreGraphics symbols isolated to `PrivateCGS.swift` with fallback (§VI)
- [ ] Capture / restore idempotence preserved (§III); restore checks current frame within 1px tolerance
- [ ] Performance budgets met or Complexity Tracking entry exists for regressions >20% (§VII)
- [ ] AX calls serialized on the dedicated dispatch queue (no AX deadlocks)
- [ ] Swift idioms followed (async/await over completion handlers; value types over reference types where appropriate)
- [ ] SwiftLint clean; no new warnings treated as errors
- [ ] Tests cover the changed behavior; manual `quickstart.md` step added if the change is AX-driven

---

## agents: configuration

```yaml
agents:
  architecture:
    source: directory
    c4_root: roadmap/arch/c4
    roadmap_root: roadmap/arch
    adr_root: roadmap/arch/decisions
  # No `platform:` block — this project has no CJCO platform dependency.
  # The code-reviewer's platform-pattern consultation pass is a no-op for PixPut
  # (see .claude/project-precepts.md Principle 3).
  package_namespaces:
    - PixPut.*
```

**Version**: 1.0.0 | **Ratified**: 2026-05-26
