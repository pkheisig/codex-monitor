# Codex Monitor

`Codex Monitor` is a dependency-free native macOS utility, menu-bar extra, and CLI
for today's local Codex token usage in two exact model/reasoning lanes:

- Advisor: `gpt-5.6-sol` with `high` reasoning
- Worker: `gpt-5.6-luna` with `max` reasoning

It reads local JSONL rollout logs and, when the normal Codex OAuth file is
available, reads the authenticated Codex usage-limits endpoint used by
CodexBar. The access token stays local and is never persisted by this app;
the monitor stores only the returned quota snapshot. It sends no data to a
model and does not modify Codex logs or plugin files.

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
- `~/Library/LaunchAgents/com.pkheisig.codexmonitor.plist`

The LaunchAgent starts the app at login. The Quit button exits successfully,
so a normal Quit remains stopped until the next login or manual launch.
The app has its own clean menu-bar identity and is independent of Codex's
presentation settings. It is ad-hoc signed for local use and requests no
special permissions.

The panel includes the latest Codex subscription limits: weekly remaining,
pace deficit, reset and projected run-out timing, model-specific Spark limits,
and credits when the account endpoint provides them. A cached quota snapshot is
shown when a later refresh cannot reach the endpoint. The app bundle includes a
custom Codex Monitor icon.

## Account and privacy behavior

Codex Monitor is account-neutral. It reads the active user's local Codex
`auth.json` on each refresh, honors `CODEX_HOME` when set, and sends the
current user's access token only as an HTTPS Bearer request to the Codex usage
endpoint. It does not contain a token, cookie, account id, email address, or
rollout history in the repository or app bundle. A cached quota snapshot is
accepted only when its account id matches the currently active Codex session,
so switching accounts on the same Mac cannot reuse the previous account's
limits. Local quota and daily-history files stay under that user's
`~/Library/Application Support/SolUsageMonitor/` and are never uploaded.

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
`~/.codex/sessions/YYYY/MM/DD` directory and its two neighboring session-day
directories, allowing a rollout that crosses midnight to contribute its later
events. It then keeps only files whose rollout date or modification date is the
requested Berlin day. Top-level archived rollout files use the same date
filter. It does not scan the full sessions tree or perform archive-wide content
reads. Each refresh streams eligible JSONL files in order and cheaply rejects lines that are not
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
