---
description: Kotlin Stack Context
---

Ad-hoc Kotlin/JVM task helper. Use this for one-off tasks outside the TDD pipeline — debugging, build fixes, dependency updates, or exploratory work.

**Note:** During the TDD pipeline, engineering agents load stack context automatically from `agents/stacks/kotlin.md` based on `plan.md`. You do NOT need to call this command for pipeline work.

Task: {ARGS}

1. Read `agents/stacks/kotlin.md` for full Kotlin platform conventions, patterns, and commands.
2. Read the constitution at `.claude/constitution.md` (if it exists).
3. If a feature spec exists for the current branch, read `plan.md` to understand architecture.
4. Read existing Kotlin source files to match project patterns (naming, structure, style).
5. Execute the task following Kotlin conventions from the stack agent:
   - Use Kotlin idioms (data classes, sealed classes, coroutines)
   - Prefer immutability
   - Follow kotlinlang.org coding conventions
6. After making changes, verify:
   - `./gradlew build` succeeds
   - `./gradlew test` passes
   - `./gradlew ktlintCheck` reports no new issues
7. Report what was done and any issues encountered.
