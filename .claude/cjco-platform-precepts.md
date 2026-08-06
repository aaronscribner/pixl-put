# CJCO Platform Precepts

This overlay supplements the project's own `.specify/memory/constitution.md`. It captures four CJCO-wide precepts that apply to every project using `@cerebral-juice-co/claude-agents`. The project constitution governs project-specific decisions; the precepts govern decisions about how the project relates to the CJCO platform.

When a precept and the project constitution conflict, the precept wins.

---

## Principle 1 — Platform Code Over Bespoke

Every project must reuse code from the CJCO platform packages instead of reimplementing equivalent functionality.

**Rule**: before writing a new abstraction, pattern, or utility, an agent MUST consult `mcp__platform-mcp__*`:

- `mcp__platform-mcp__list_patterns` — is there a documented pattern that fits?
- `mcp__platform-mcp__list_packages` — is there a package that already provides this?
- `mcp__platform-mcp__get_pattern` / `get_package_info` — read the docs before re-creating.
- `mcp__platform-mcp__search_code` / `find_implementations` — find canonical examples.

If a pattern or package exists for the need, use it. If a deliberate override is required, the project's own constitution must record the rationale before agents proceed.

The dotnet templates also enforce this at the code level (Roslyn analyzers + NetArchUnit tests). Treat those failures as non-negotiable.

---

## Principle 2 — `.llm/` Directory Adherence

Every project root contains a `.llm/` directory with template-specific instructions.

**Rule**: before writing, planning, breaking down tasks, generating checklists, or analyzing code, an agent MUST recursively read every file under `.llm/` and treat its instructions as authoritative project-specific guidance.

If `.llm/` is absent, the project is not properly initialized. The agent halts with a hard error directing the user to re-initialize from the dotnet template.

---

## Principle 3 — Template Checklist Is Mandatory

Every project's architecture-readiness checklist MUST include every item from the template's `.specify/checklists/<template>.md` file (where `<template>` is the value of `.solution-config/solution.json`'s `template` property).

**Rule**: when generating an architecture-readiness checklist for a spec, the template-provided items are mandatory and non-negotiable. Spec-specific items can be added on top, but no template item may be dropped or weakened.

If the template checklist file is missing, the agent halts; the project is not properly initialized.

---

## Principle 4 — Project Sub-Constitution

Every project has its own `.specify/memory/constitution.md` that supplements the CJCO-wide rules.

**Rule**: agents MUST read the project constitution before acting on the project's code. Project-specific caveats (domain language, naming choices, deprecated APIs, performance constraints, security notes) take precedence over generic CJCO defaults — except where they conflict with these four precepts, in which case the precepts win.

---

## Required Inputs (Hard-fail)

Before proceeding with any spec, plan, task, checklist, analysis, or implementation work, agents MUST verify all four inputs are present. If ANY is missing, halt with the corresponding error message — do not attempt to recover or proceed with partial inputs.

| Input | Path | On missing |
|---|---|---|
| Solution config | `.solution-config/solution.json` (must contain `template` property) | Halt: "Run the dotnet template that bootstraps `.solution-config/solution.json` before invoking CJCO agents." |
| Template instructions | `.llm/` directory at repo root | Halt: "`.llm/` directory missing; re-initialize from the dotnet template." |
| Project constitution | `.specify/memory/constitution.md` | Halt: "Project constitution missing; run `/constitution`." |
| Template checklist | `.specify/checklists/<template>.md` | Halt: "Template checklist missing; re-initialize from the dotnet template." |

These checks apply to every CJCO engineering and review agent (`architect`, `tdd-developer`, `software-developer`, `qa`, `code-reviewer`) and every CJCO slash command (`/cjco.cc.research`, `/cjco.cc.review`, `/cjco.cc.tdd-cycle`). Stack and product-research agents inherit context from their invoker and do not need to re-verify.

---

## Appendix: Agents Configuration (v3.0.0+)

The CJCO agent system (architect, code-reviewer) reads source bindings from this
project's constitution. Add the following to `.specify/memory/constitution.md`:

```yaml
agents:
  architecture:
    source: directory                       # directory | mcp
    c4_root: roadmap/architecture/c4        # required when source: directory
    # mcp: cjco-mcp                         # required when source: mcp
    roadmap_root: roadmap/architecture
    adr_root: roadmap/architecture/decisions
  platform:
    source: mcp                             # directory | mcp
    mcp: platform-mcp                       # required when source: mcp
    # platform_root: <path>                 # required when source: directory
    package_namespaces:
      - Cjco.Platform.*
      - Blocks.*
```

### Resolution rules

1. The architect reads `agents.architecture.source`. If missing, the architect
   halts with `BLOCKING: no architecture source configured`.
2. If `source: directory`, `c4_root` must exist on disk.
3. If `source: mcp`, the named MCP server must be reachable.
4. The same rules apply to `agents.platform`, consumed by the code-reviewer.

### Migration from older projects

Projects whose C4 lives as YAML/Markdown under `roadmap/architecture/c4/` should
set `source: directory`. Projects whose C4 is exposed via an MCP server (cjco-mcp,
refarchs-mcp, wk-lr-arch-mcp) should set `source: mcp` and the corresponding
`mcp:` value. The agent file format is identical between the two modes — only the
resolution layer differs.
