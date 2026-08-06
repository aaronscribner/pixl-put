---
description: Product Research Pipeline (Spec-Kit Integrated)
---

Execute the product research pipeline for the given topic. Research runs Market and UX researchers in parallel and synthesizes findings.

Topic: {ARGS}

0. **Pre-work — Project Precepts (REQUIRED)**. Before launching agents, perform the precept inputs check from [`.claude/project-precepts.md`](../../.claude/project-precepts.md):
   - Read `.claude/project-precepts.md`. Halt if absent.
   - Read `.claude/constitution.md`. Halt if absent.
   - Read `roadmap/product/constitution.md`. Halt if absent.

   Pass these inputs to every researcher launched in step 2; they govern scope, terminology, and the Apple frameworks / project extension points the synthesis should reference. Per project constitution §IV (no telemetry / no cloud sync), researchers must not recommend analytics, crash-reporting services, or backend integrations.

1. Read the constitution at `.claude/constitution.md` (if it exists) for project principles.

2. **Launch parallel research agents** using the Agent tool:

   **Agent 1: Market Researcher**
   - Read `agents/product/market-researcher.md` for full instructions
   - Research topic: {ARGS}
   - Produce: competitive landscape, industry trends, standards, risks, recommendations

   **Agent 2: UX Researcher**
   - Read `agents/product/ux-researcher.md` for full instructions
   - Research topic: {ARGS}
   - Produce: user needs, interaction patterns, accessibility, edge cases, recommendations

   Launch BOTH agents simultaneously using the Agent tool.

3. **Collect and synthesize** results from both researchers:
   - Merge findings into a unified research document
   - Identify agreements and conflicts between market and UX perspectives
   - Highlight areas where market opportunity aligns with user need
   - Flag areas where market pressure conflicts with UX best practices

4. **Produce research output** in this structure:
   ```markdown
   # Research: [Topic]

   ## Market Research
   [Market Researcher findings]

   ## UX Research
   [UX Researcher findings]

   ## Synthesis
   ### Aligned Opportunities
   - [Where market + UX agree]

   ### Tensions
   - [Where market pressure conflicts with UX]

   ### Recommendations
   - [Prioritized, actionable recommendations]

   ### Open Questions
   - [Items needing clarification before /specify]
   ```

5. If a spec directory already exists for this feature, write to `roadmap/product/<NNN>-<feature>/research.md`.
   Otherwise, output the research document for the user to use with `/specify`.

6. Report completion with a summary of key findings and recommended next steps.
