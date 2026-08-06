---
description: C# Stack Context
---

Ad-hoc C#/.NET task helper. Use this for one-off tasks outside the TDD pipeline — debugging, build fixes, dependency updates, or exploratory work.

**Note:** During the TDD pipeline, engineering agents load stack context automatically from `agents/stacks/csharp.md` based on `plan.md`. You do NOT need to call this command for pipeline work.

Task: {ARGS}

1. Read `agents/stacks/csharp.md` for full C# platform conventions, patterns, and commands.
2. Read the constitution at `.claude/constitution.md` (if it exists).
3. If a feature spec exists for the current branch, read `plan.md` to understand architecture.
4. Read existing C# source files to match project patterns (naming, structure, style).
5. Execute the task following C# conventions from the stack agent:
   - Use modern C# features (records, pattern matching, file-scoped namespaces)
   - Enable nullable reference types
   - Follow .NET naming conventions
6. After making changes, verify:
   - `dotnet build` succeeds
   - `dotnet test` passes
   - `dotnet format --verify-no-changes` reports no issues
7. Report what was done and any issues encountered.
