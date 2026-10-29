# Krimp

PLAN.md is the spec. Read it in full before doing anything.

- Work one phase at a time. After each phase, post the report described in PLAN.md (including the app size table) and wait for my go-ahead.
- If something in PLAN.md is wrong, impossible, or clearly worse than an alternative, say so with your reasoning. Don't silently deviate.
- Commit at the end of every phase (conventional commits). Never push without asking.
- Hard rules:
  - App size budget: under 10 MB.
  - Everything is statically linked into the main executable. No helper binaries, no runtime CLI tools, no background processes.
  - No network access.
  - macOS 26+ only.
