# Pitch Outline — The Agentic GTM Engine

*Draft narrative for review. Not PMI-specific — pitched as a reusable pattern
for running GTM on big accounts / territories. PMI appears only as the worked
example ("in production: 88 accounts").*

*Deck format: single self-contained HTML, GSAP animations, keyboard/click
navigation, NO voice for v1 (browser-TTS hooks can be added later, as in the
reference deck). ~12-15 slides.*

---

## Slide 1 — Title

**The Agentic GTM Engine**
*From scattered data to account intelligence — a multi-agent system for
running GTM on large accounts and territories.*

Visual: vault-at-center diagram, agents orbiting.

---

## Slide 2 — The problem

Covering big accounts today:

- Data lives in 5+ systems: CRM, data warehouse, calendar, email, spreadsheets
- Every account review / EBR / QBR prep is a scramble — days of manual gathering
- Intelligence is tribal knowledge: when the SE is off, the knowledge is off
- The team sees none of it

Visual: chaos diagram — 5 systems, arrows everywhere, no center.
Kicker: "Every enterprise SE team runs on this."

---

## Slide 3 — The core idea: vault-first

One governed knowledge base — **the vault** — that every agent reads and one
agent writes.

- Plain markdown files with structured frontmatter (YAML)
- Readable by humans, parseable by machines, syncable to search
- Every analysis, report, and answer traces back to it

Visual: vault at center, calm. One line in: "single source of truth".
Kicker: "Agents don't guess. They read."

---

## Slide 4 — The agent roster

Six agents, each with one job:

| Agent | Job | Status |
|---|---|---|
| **Curator** | Keeps the vault fresh — parallel refresh of every account | ✅ in production |
| **Implementation** | Develops features with human-in-the-loop gates (LangGraph) | ✅ in production |
| **Q&A** | The team's read-only interface — asks the vault from Slack | 🔄 built, daemon pending |
| **Analyst** | Finds patterns across accounts, builds project specs | 💡 ideation |
| **Researcher** | External intelligence gathering | 💡 ideation |
| **PS Agent** | Post-sales consumption signals | 💡 ideation |

Visual: roster cards, status badges. Honest about what's real.

---

## Slide 5 — How it's built: anatomy

The stack, one line each:

- **Execution harness** — headless agent sessions (cortex exec), one-shot workers
- **The vault** — markdown + frontmatter, synced to Cortex Search
- **Shared context layer** — AGENTS.md hierarchy: every session loads the
  right rules + retrieval core; per-agent files, one shared core
- **Orchestration** — parallel worker pool today (ThreadPool), LangGraph where
  cycles and gates are needed (feature development)
- **Slack** — the human surface: reports out, approvals in, questions answered
- **Data sources** — CRM (Salesforce), data warehouse (Snowflake), calendar

Visual: layered architecture diagram.

---

## Slide 6 — Three ways to interact (permissions per interface)

| Interface | Who | Power |
|---|---|---|
| **Headless / scheduled** | The system | Writes the vault, fires reports |
| **Slack** | The team | **Read-only** — questions answered from the vault; never triggers writes |
| **In-session** | The operator | Full toolkit — every skill, script, and query |

Kicker: "Same agents. Different doors. The doors decide the permissions."

---

## Slide 7 — The development standard: eval-gated

You can't unit-test an agent's judgment. So changes are gated by **behavioral
evaluation**:

1. Capture a baseline — golden questions run through real agent sessions
2. Make the change (refactor, new context, new skill)
3. Re-run the eval — sources must match, facts must match, no regressions
4. Live smoke test, then merge

Visual: baseline → change → gates → merge pipeline.
Kicker: "We test retrieval behavior itself — not mocks."

---

## Slide 8 — What's real today

Production numbers, honestly stated (worked example: the PMI deployment):

- **88 accounts** refreshed in parallel, overnight (6-7 workers, ~8h)
- Account intelligence + performance + use-case pipeline, fully automated
- Weekly pipeline report to Slack, read by the team
- Feature development via agent with Slack approval gates — real PRs, real merges
- Retrieval eval harness: 15 golden questions + 12 resolution checks, run
  against every structural change
- Shared context layer refactor, gated by that eval (in flight)

Visual: the actual Slack report screenshot (sanitized).
Kicker: "Not a demo. Running in production every week."

---

## Slide 9 — Roadmap: what's left

High-level, GitHub-issue-tracked (20 issues: 6 closed, 14 open):

**Critical — RAG 2.0** *(#20)*
- Today only known-entity lookups work: one file, one answer
- Open questions ("what blockers came up across the portfolio?") and graph
  questions ("who connects this stalled UC to other accounts?") need:
  working embeddings (Cortex Search — currently broken + unvalidated) ·
  multi-hop traversal over the relationship graph · Type 2/3 golden questions
  in the eval so the gap is measured, not just felt
- Everything consumer-facing (Q&A daemon, Analyst, cloud deployment) waits on this

**Near term**
- Analyst agent — cross-account patterns, project specs (ideation → build)
- Researcher agent — external intelligence
- Slack Q&A daemon scheduled + hardened (launchd)

**Platform**
- Multi-agent orchestration — LangGraph across all agents (today: per-agent)
- Tool MCP server — query tools as MCP; read-only toolset for Slack-facing
  sessions, full toolset for the operator
- Cloud deployment path — vault synced to Cortex Search → Cortex Agent for
  team-wide Q&A beyond the operator's laptop

**Quality**
- Tier-2 LLM-as-judge evaluation for open-ended answers *(#19)*

Visual: RAG 2.0 as the headline block, then three columns, issue numbers as badges.

---

## Slide 10 — The architecture principles

1. **Vault-first** — agents read before they reason; Snowhouse is the last resort
2. **Permissions per interface** — Slack reads, the operator writes
3. **Eval-gated change** — no structural change without behavioral comparison
4. **Local-first, cloud-ready** — everything runs on the SE's machine today;
  the vault sync is the bridge to scale

Kicker: "The methodology is the product."

---

## Slide 11 — Closing

**We built the GTM agent — and the way to change it safely.**

The repo: agents, toolbox, shared context, eval harness, the vault schema —
everything openable, inspectable, improvable.

Call to action: apply the pattern to your territory.

---

## Open questions for review

1. Title: "The Agentic GTM Engine" — or keep brainstorming? ("Account
   Intelligence Engine", "The SE Control Plane"...?)
2. Slide 8 numbers: comfortable stating them publicly (if deck goes to GitHub
   Pages)? Alternative: keep numbers in a "worked example" footnote.
3. Screenshots: the Slack report needs sanitizing (account names)? Or use a
   mock version?
4. Where it lives: `docs/pitch/` in this repo → later a dedicated `gh-pages`
   repo for the shareable URL (like the reference deck).
5. Voice: hooks added but disabled for v1 (per decision) — confirm.
