# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo is **single-context**: one `CONTEXT.md` and one `docs/adr/` at the root.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the glossary of domain terms
- **`docs/adr/`** — read ADRs that touch the area you're about to work in

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

Separately from the domain docs, `docs/GhostMeet.md` and `docs/GhostMeet-Prompts.md` are the product spec and are already authoritative — read them for architecture and prompt behaviour.

## File structure

```
/
├── CONTEXT.md                  ← glossary (not created yet)
├── docs/
│   ├── GhostMeet.md            ← product spec
│   ├── GhostMeet-Prompts.md    ← LLM mode prompts
│   ├── adr/                    ← architecture decisions (not created yet)
│   └── agents/                 ← this file and its siblings
└── GhostMeet/                  ← Xcode project (SRCROOT)
    └── GhostMeet/              ← Swift sources
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

The spec already fixes several terms that must not drift: **You** / **Them** for the two audio channels, **Turn** for a transcript entry, and the mode names (**Assist**, **Say**, **Follow-up**, **Recap**, **Ask**, **Solve on screen**).

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
