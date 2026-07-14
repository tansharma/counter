<div align="center">

# ⏱ Counter

### A local-first token-usage dashboard for your AI assisted coding sessions

*How much have I burned in this 5-hour block? When does it reset? What am I spending it on, which models, which projects, and how has that changed over time?*

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-101418?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5-FF5C39?style=flat-square)
![Network](https://img.shields.io/badge/network-none-2EC4B6?style=flat-square)
![Data](https://img.shields.io/badge/data-read--only-2EC4B6?style=flat-square)

</div>

---

## What it is

**Counter** is a native, macOS-first (iOS-ready) SwiftUI app that reads session logs your agents write to disk and turns them into a usage dashboard.

It is **local** : no network calls, no API keys, no accounts. It never writes to any agent's
data, just reads it. Everything you configure (name, appearance, sources) lives in `UserDefaults`.


Originally, I just wanted to track my Claude Code usage; mapping out the 5-hour reset blocks and keeping tabs on how much time, money, and tokens I was burning through per model. But as I started flipping between different models for different projects, the tool kind of took on a life of its own. 

Now, it's evolved into a (still slightly restricted) multi agent dashboard that recognises usage from Claude Code, Codex, Gemini CLI and Opencode and even surfaces local model runs through those agents.

---

## Features

### At a glance
-	**Three tachometer gauges** - "Session Usage" and "This Week" show new tokens vs. cache-read as a composition ring, summed across every enabled source (no budget to compare against — Anthropic doesn't expose one locally, and one cache-heavy session made a fixed-budget number meaningless anyway), with a "Claude Block Reset" countdown alongside them. All three replace the old sweeping needle with tick marks that light up as they fill. "Claude Block Reset" is the one gauge that's **Claude Code only** — it's counting down Anthropic's own rate-limit window, which Codex/Gemini/OpenCode don't have.

- **The header card** - Grabs your display name and Claude plan tier straight from ~/.claude.json, alongside live lifetime totals (input + output + cache-creation, across every enabled source — cache-read tokens are tracked separately, see below) and estimated cost equivalents.

### Where it all goes
- **Usage-over-time bar chart** -  Has a quick 7 / 30 / 90-day range picker so you can spot trends.

- **Model breakdown** - Shows per-model tokens and estimated costs (local models get tagged with a neat little · local label).

-	**Per-project active time** - This tracks real focus time by looking at the gaps between events. It caps idle periods automatically so a coffee break won't mess up your stats.

-	**Agent breakdown card** - This only shows up once you actually start pulling data from more than one agent, keeping the UI clean.

-	**Vitals strip** - Streaks, session count, busiest day, cost saved by caching, and the raw cache-read token count (context re-sent from cache every turn — not counted in the lifetime total above it).

### Project drill-down
-	You can click any project to dive into a detailed view. It pulls  specific totals, project-filtered usage chart, model/agent breakdowns, and a scrollable session history.

### Menu-bar companion
-	A MenuBarExtra companion app where the icon itself is a miniature ring, split new-vs-cache-read just like the dashboard's Session Usage gauge.

-	The dropdown displays this session's new/cache-read tokens, a live reset countdown, today's total spend, and quick buttons to open the dashboard or quit. Plus, it stays live in the background even if you close the main window.

### Multi agent and local models
-	You can toggle sources on or off in Settings (if an agent isn't detected, it just displays as "not detected").

-	For sessions run against local endpoints (like Ollama via OpenCode, Qwen Code, or Codex), the tool costs them at $0 but tracks them against a cloud-equivalent reference rate. It surfaces all of this in a dedicated card so you can see exactly how much cloud spend you've avoided by running local.

### User Interface
-	Built around a "Tachometer" theme using ink (#101418) and cream (#F7F5F0) surfaces, a signal-orange (#FF5C39) accent, teal (#2EC4B6) for positives, and amber (#FFB020) for warnings.

-	Supports Light, Dark, and Auto modes (defaults to Auto). Every colour is driven by the theme layer—zero hardcoded colors in the views.

---

## Supported sources

| Agent | Reads from | Notes |
|---|---|---|
| **Claude Code** | `~/.claude/projects/*/*.jsonl`, `~/.claude.json` | Name, plan tier, four token counts per assistant line |
| **Codex** | `~/.codex/sessions`, `~/.codex/archived_sessions` | `input_tokens` includes the cached portion (normalised); `codex fork` replays are de-duplicated |
| **Gemini CLI** | `~/.gemini/tmp/<dir>/chats/session-*` | Cumulative token counters are turned into per-message deltas |
| **OpenCode** | `~/.local/share/opencode/storage/` | File-based storage only; the newer SQLite backend is not yet supported |
| **Local models** | *(via the agents above)* | Ollama writes no per-request token log, so local usage is picked up through agents pointed at its OpenAI-compatible endpoint |

---

## How it works

```
CounterCore/                 ← pure Swift package (macOS 14 / iOS 17, no UI imports)
  UsageEvent.swift           ← value types: UsageEvent (+ AgentSource), AccountInfo
  SessionLogParser.swift     ← Claude JSONL parsing + message-id dedupe
  CodexSessionParser.swift   ← Codex rollouts (cache normalisation, fork gate)
  GeminiSessionParser.swift  ← Gemini chats (cumulative-counter deltas, dir resolution)
  OpenCodeParser.swift       ← OpenCode session/message join
  AgentConfig.swift          ← per-agent root paths, detection, chart color, and parse
                               dispatch registry — adding a source is one entry here
  UsageCollector.swift       ← source roots, detection, merged parseAll
  UsageAnalytics.swift       ← totals, by-model/project/agent, daily series, 5h blocks,
                               active time, streaks, cache efficiency, session summaries
  Pricing.swift              ← offline per-model $/MTok table + local-model detection
Counter/                     ← thin SwiftUI app shell (macOS)
  CounterApp.swift           ← app entry, Window + MenuBarExtra + Settings scenes
  Theme.swift                ← Tachometer palette (light+dark), type scale
  DataStore.swift            ← @Observable: scans sources off-main, refreshes, account
  Views/                     ← Dashboard, ProjectDetail, MenuBar, Charts, Info, Settings
```

Design rules: all parsing and analytics are pure, deterministic functions over value types,
living in `CounterCore` and covered by fixture-based unit tests (never against your live
logs). The app target holds no parsing logic. The parser is tolerant: unknown line types are
skipped, malformed lines are skipped, streaming duplicates are deduped by message id, and one
bad line never aborts a file.

---

## Build & run

Requirements: macOS 14+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is generated and gitignored.

```bash
# regenerate the project from project.yml
xcodegen generate 
xcodebuild -scheme Counter -destination 'platform=macOS' build
# Run unit tests
swift test --package-path CounterCore
```

Then open `Counter.xcodeproj` and run, or launch the built `.app`.

> [!IMPORTANT]
> Counter is deliberately ***un-sandboxed** as it needs to read logs under your home directory (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.local/share/opencode`). It makes no network calls and only ever reads those files. 
>
> If you ever add an App Sandbox, you **must** add a folder-picker plus security-scoped bookmark flow at the same time.

---

## Caveats & assumptions

There are a number of caveats and assumptions you should bear in mind. Read these before trusting a number:

- There's no plan-limit number anywhere, on purpose.

  No agent actually exposes your real plan limits on disk (and if it does i havent found a way to read that), so rather than have you guess at a budget in Settings, "Session Usage" and "This Week" just show composition instead — new tokens vs. cache-read, as a ring with no denominator to argue about. 
  
- The 5-hour block is reconstructed. 

  A block opens at the very first event after a quiet gap, floors it to the top of the hour, and stretches for 5 hours. Because of that hour-flooring, the dashboard's countdown might run up to an hour earlier than the agent’s actual reset (which typically triggers off your exact first-message time).

- Costs reflect published API rates, not subscription billing.

  Pricing lives in a hardcoded offline table. The dashboard is strictly no-network by design. The OpenAI and Gemini rows, in particular, are best-effort guesses (feel free to add those or let me know and I'll add them).

- Two different token totals, on purpose.

  The lifetime total, model/project/agent breakdowns, and session history all count input + output + cache-creation tokens — not cache-reads, which get re-sent from cache on nearly every turn and would otherwise dwarf everything else (in practice, often 90%+ of the raw total). That cache-read count is shown on its own in the Vitals strip instead.

  "Session Usage" and "This Week" show the same split, just scoped to the current block/week instead of all time: the big number is new tokens, and cache-read gets its own labeled number in the legend underneath. Since a single long session can rack up tens of millions of raw cache-read tokens while contributing only a few hundred thousand genuinely new ones, these two gauges are drawn as a fully-filled ring divided by that ratio (not a fraction of some budget) — the composition is the point, not a total vs. a limit. Progress on all three tachometers (these two plus the reset countdown) is shown by the tick marks lighting up in sequence, not a sweeping needle.

- Local models use a reference rate. 
  
  Obviously, local usage costs $0. The "cloud value avoided" stat just prices those tokens at a Haiku-class rate to give you a rough estimate of what you're potentially saving. You may well be burning that on electrics, ram and cpu usage. 

- Per-agent quirks happen. A few things to keep in mind: 
  - Codex input_tokens includes the cached portion (which I subtract out before billing), and codex fork replays parent history (which is gated out so it doesn't double-count).
  - Gemini's token fields are cumulative per session, so I turn them into deltas. 
  - Finally, OpenCode’s SQLite backend isn't parsed yet, so DB-only installs will just show up as "not detected."

- Multiple enabled sources pool together — except Claude Block Reset. Every chart, total, and breakdown sums across every source you toggle on (a combined workspace view, not a per-agent breakdown), including Session Usage and This Week — except the Claude Block Reset countdown, which only ever counts Claude Code, since it's tracking Anthropic's own rate-limit window regardless of what else is enabled. Under the hood this is one `AgentScope` switch (`.allEnabled` vs. `.claudeOnly`) that every aggregate in `UsageAnalytics` takes as a parameter, so which gauges pool and which stay Claude-only is a one-line, explicit choice rather than something you have to infer from the code around each call site.

- Session cwd can drift. If you do a mid-run cd or rename a project folder, things can get messy. The app handles this by pinning each session to its dominant root, but it's a heuristic, not a guarantee.


---

## Roadmap

Potential deas, roughly in value order:

- **Live file tracking** - Shifting to a sub-second events driven refresh with the current 60s poll kept as a fallback.

- **Cost & Cache insights view** - A dedicated view showing cost over time stacked by model, cache hit-rate trends, cost-per-project, and a hero metric for "what caching saved me".

- **Full Sessions view** - Sortable list of every session with a timeline detail pane

- **Usage report export** - A way to export usage stats for 7/30/90 day periods.

- **iOS companion** -  A WidgetKit block-gauge and iPhone dashboard fed by an iCloud snapshot the Mac app generates.

- **Multi machine view**  Combining usage from more than one mac, completely de-duplicated using (sessionId & messageId).

- **Historical archive & trends** -  An opt-in, append-only daily rollup so charts survive when log files get pruned.

---

## Project layout & conventions

- **`CounterCore` is the key** 
  The app itself is a shell. All testable logic lives in the package ith fixture tests.

- **Don't modify .xcodeproj manually** 
  If you add or remove files, edit project.yml instead and run xcodegen generate. 
---

## Acknowledgements

- 5-hour block reconstruction follows the semantics popularised by
  [ccusage](https://github.com/ryoppippi/ccusage).
- The notion of showing per project session history is influend by [agentview](https://github.com/kenn-io/agentsview).

<div align="center">
<sub>Built with SwiftUI · Strictly read-only, never phones home..</sub>
</div>