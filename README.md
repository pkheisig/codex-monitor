# Codex Monitor

`Codex Monitor` is a dependency-free native macOS menu-bar utility and CLI
for today's local Codex token usage in two exact Sol Advisor lanes:

- Advisor: `gpt-5.6-sol` with `high` reasoning
- Worker: `gpt-5.6-luna` with `max` reasoning

It reads local JSONL rollout logs only. It makes no network requests, sends no
data to a model, and does not modify Codex logs or plugin files.

## Build and install

Requirements are Apple Swift 6.3.3 and macOS 26.5.2 or compatible newer macOS.

```sh
swift test
swift build -c release
./scripts/install.sh
```

The installer creates:

- `/Applications/Codex Monitor.app`
- `~/.local/bin/codex-monitor`
- `~/Library/LaunchAgents/com.pkheisig.codex-monitor.plist`

The LaunchAgent starts the app at login and restarts it after an unsuccessful
exit. The Quit button exits successfully, so a normal Quit remains stopped.
The app is ad-hoc signed for local use and requests no special permissions.

## CLI

```sh
codex-monitor
codex-monitor --json
codex-monitor --watch
codex-monitor --date 2026-08-03
```

The default report is the current Europe/Berlin calendar day through now.
`--watch` refreshes every 30 seconds. `--date` reads a saved Berlin calendar-day
snapshot; it does not backfill or scan older rollout directories. The monitor
saves the current day as it runs, so the day picker can build history from that
point forward.

The menu app includes saved-day, model, and intelligence dropdowns plus
separate model-ranking and daily-trend views. The trend is built only from
daily snapshots saved while the monitor is running; it does not backfill old
rollouts. Ranking rows are one `model` + `intelligence` pair, and can be sorted
by total tokens or API-equivalent cost. The overview also shows a cache
breakdown with uncached input, cached input, cache writes, output, and the
corresponding API-equivalent cost for each priced model. The menu-bar display
can be switched between today's combined total tokens and API-equivalent cost.
JSON has a
stable top-level schema with `date`, `timezone`, `range`, `start_at`, `end_at`,
`generated_at`, `advisor`, `worker`, `combined`, `other`, `model_usage`, and
`attribution_note`. Lane totals contain `total_tokens`, `input_tokens`,
`cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`,
`reasoning_output_tokens`, `task_count`, and `api_equivalent_cost_usd`.
`other` deliberately has no invented price.

## Data and performance semantics

For today's report, the collector enumerates only the matching
`~/.codex/sessions/YYYY/MM/DD` directory and top-level archived rollout files
whose rollout date or modification date is today. It does not scan older
session directories or perform archive-wide content reads. Each refresh streams
eligible JSONL files in order and cheaply rejects lines that are not
`turn_context` or `event_msg` token-count records before using Foundation JSON
decoding. Large response/tool/world-state lines are never JSON-decoded.

The collector reads `turn_context.payload.model` and
`turn_context.payload.collaboration_mode.settings.reasoning_effort`, matching
only the two exact lane pairs. Other or incomplete attribution is shown under
`other` and excluded from the two lane cards and `combined`.

Token usage comes from cumulative `event_msg` token snapshots. Each nonnegative
delta is assigned to that event's Europe/Berlin day; a counter reset starts a
new positive delta. Missing optional fields are tolerated, and reasoning output
is diagnostic only because it is already included in output tokens. A rollout
counts once per lane when it contributes positive tokens to the day. A
cross-midnight rollout therefore follows event time rather than task start time.

## API-equivalent estimates

The displayed USD amount is an **API-equivalent estimate**, not Codex
subscription billing. It uses these per-million-token rates:

- Sol: $5.00 uncached input, $0.50 cached input, $6.25 cache writes, $30.00 output
- Luna: $0.20 uncached input, $0.02 cached input, $0.25 cache writes, $1.20 output

The estimate subtracts cached input and cache writes from input for the
uncached portion, clamps that portion at zero, and prices each category
separately. It excludes tool-call fees, priority/batch adjustments, and the
`>272K` long-context multiplier because local cumulative telemetry cannot
reconstruct that multiplier per request. Pricing references are the
[model comparison page](https://developers.openai.com/api/docs/models/compare),
[GPT-5.6 Luna documentation](https://developers.openai.com/api/docs/models/gpt-5.6-luna),
and [OpenAI's GPT-5.6 announcement](https://openai.com/index/gpt-5-6/).

## Uninstall

Remove the installed app, CLI, and LaunchAgent while retaining the source:

```sh
./scripts/uninstall.sh
```

Remove those installations and this source project as well:

```sh
./scripts/uninstall.sh --remove-source
```

The uninstall script unloads only the owned LaunchAgent label and removes only
this project's app, CLI, plist, and optional source path.
