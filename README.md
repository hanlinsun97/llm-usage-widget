# LLM Usage widget (macOS)

A desktop widget and menu-bar item that show how much of each LLM subscription
allowance is left. The accounts shown are set in `accounts.json`.

Each account is a card with two rings:
- **Inner ring:** weekly allowance left. The centre number (labelled `wk`) is
  that value.
- **Outer ring:** 5-hour allowance left. Its number sits in a badge at the end of
  the arc and turns orange below 20%.
- **Below the rings:** two labelled countdowns: `week` for the weekly reset and
  `hour` for the 5-hour reset. For example, `hour 33m` means the 5-hour allowance
  resets in 33 minutes.
  Hover over a countdown for its reset time. Token counts appear only in account
  details. The top-right refresh button refreshes all accounts.
- **Inner track:** slightly darker over the share of the week still left. If
  usage runs ahead of time, that darker part shows beyond the arc.

Click a card for details. The details show both windows, the token breakdown and
the source devices; for accounts set up for it, you can also switch the ChatGPT
app to that account. The menu bar shows one small weekly ring per account; click
it for a compact popover.

Preview: [desktop widget](docs/preview-desktop.pdf).

## How it works

```
your collector  ──▶  snapshot JSON  ──HTTP or file──▶  LLM Usage.app
(not included)       (format below)                     App.swift   fetch, refresh, menu bar
                                                         widget.html drawing (WebKit)
```

The app only reads. Every 60 seconds, when the popover opens, and after wake, it
loads `snapshotURL`. It caches the last good copy in
`~/Library/Application Support/LLMUsage/remote-snapshot.json`.

The collector is **not part of this repository**. The author runs one on an
always-on Mac every 5 minutes and serves the file over a private network; ↻
runs it on demand through `refreshCommand`.

## Accounts (`accounts.json`)

```json
[
  {"id": "codex",  "name": "Codex",  "label": "A", "icon": "codex", "chatgptProfile": "a", "codexHome": ".codex"},
  {"id": "claude", "name": "Claude", "menuLabel": "C", "icon": "claude"}
]
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Matches `rows[].id` in the snapshot. Must be unique. |
| `name` | yes | Shown on the card (`Codex`). |
| `label` | no | Tag after the name (`A`). Also used inside the menu-bar ring. |
| `menuLabel` | no | Text inside the menu-bar ring, 1–2 characters. Default: `label`, else the first letter of `name`. |
| `icon` | no | `codex` (a neutral terminal glyph), `claude` (✳), or omitted for no icon. |
| `iconFile` | no | Your own SVG, relative to `~/Library/Application Support/LLMUsage/` or absolute. It replaces `icon`. Only a plain `<svg>` under 20 KB is accepted: no scripts, event handlers or links. |
| `chatgptProfile`, `codexHome` | no | Enable "Use in app". It relaunches the ChatGPT app with that `CODEX_HOME` via `~/.local/bin/codex-app-profile <profile>`. Leave them out if you don't have that script. |

Behaviour:
- Cards follow the order of this list.
- An account with no row in the snapshot shows "No data".
- Snapshot rows whose id is not listed are ignored.
- The bundled `accounts.json` is used unless
  `~/Library/Application Support/LLMUsage/accounts.json` exists, so edit that
  copy to change accounts without rebuilding. Restart the app afterwards.
- An invalid file (bad JSON, duplicate ids, missing `id`/`name`) is skipped and
  the next one is tried.
- With no valid list, the widget shows the snapshot rows as they come, with
  their ids as names.

The layouts (2×2 and one row) are tuned for four accounts. Three or two also
work; more than four wrap to extra rows that the fixed window height does not
fit.

## Bring your own data source

To use the widget, provide a JSON file or URL in this format and point the app
at it.

### Snapshot format (schema version 1)

A complete example is in [docs/example-snapshot.json](docs/example-snapshot.json).

```json
{"schemaVersion": 1, "collectedAt": "ISO-8601",
 "rows": [{"id": "codex",
           "state": "ok | stale | signIn | unavailable",
           "measuredAt": "ISO-8601 | null",
           "weekly":   {"remaining": 0-100, "minutes": 10080, "resetsAt": "ISO-8601 | null"} | null,
           "fiveHour": {"remaining": 0-100, "minutes": 300,   "resetsAt": "ISO-8601 | null"} | null,
           "fiveHourAbsent": false,
           "tokenUsage": {"weekly": {"until": "ISO-8601", "complete": true,
                                     "usage": {"total_tokens": 0, "input_tokens": 0, "cached_input_tokens": 0,
                                               "output_tokens": 0, "reasoning_output_tokens": 0},
                                     "sources": [{"name": "Laptop", "state": "ok | stale | missing"}]},
                          "fiveHour": {"...": "same shape, optional"}}}]}
```

| Field | Rule |
|---|---|
| `schemaVersion`, `rows` | Required. `rows` must not be empty, otherwise the snapshot is rejected and the last good one is kept. |
| `remaining` | Percent of the allowance **left** (not used), 0–100. |
| `resetsAt` | When that window resets. `null` means the window has not started (for example, no usage since the last reset); the ring shows the value and no countdown. |
| `minutes` | Window length. Needed for the pace shading only. |
| `fiveHour: null` with `fiveHourAbsent: true` | The account has no 5-hour limit; only the weekly ring is drawn. |
| `state` | `ok` = fresh reading. `stale` = reusing an older reading (the card dims). `signIn` = credentials need attention. `unavailable` = no reading. With `signIn` or `unavailable`, set `weekly` and `fiveHour` to `null`. |
| `measuredAt` | When this row was read. Rows older than 15 minutes, or without it, are shown as stale. |
| `tokenUsage` | Optional. A total is shown only when its `until` equals the window's `resetsAt`, so counts from the previous window are never shown. `complete: false` shows the total as a lower bound (`≥`). |

The file must be under 128 KB; real snapshots are about 5 KB.

### Pointing the app at it

Local file, written by your own script:

```bash
defaults write com.hanlin.llmusage snapshotURL "file:///Users/you/llm-usage/snapshot.json"
```

HTTP, from another machine:

```bash
defaults write com.hanlin.llmusage snapshotURL "http://<host>:<port>/snapshot.json"
```

What ↻ runs before re-reading the snapshot, e.g. your collector. Without it, ↻
only re-reads. Exit status 0 means success; any other value shows "Refresh
command failed":

```bash
defaults write com.hanlin.llmusage refreshCommand "python3 ~/llm-usage/collect.py"
```

Restart the app after changing these settings. Until `snapshotURL` is set, the
footer says "Set snapshotURL — see README". Plain HTTP is allowed, so use it only
on a trusted network such as Tailscale.

### Where usage numbers can come from

None of this ships here; these are starting points. Check them yourself, because
the providers can change them.
- **Codex / ChatGPT:** the Codex CLI's app-server exposes
  `account/rateLimits/read`, which returns each window's used percentage and
  reset time. Use `100 - used` as `remaining`. Token counts can be summed from
  the Codex session logs under `$CODEX_HOME/sessions`.
- **Claude:** the Claude Code
  [status line](https://code.claude.com/docs/en/statusline) receives the 5-hour
  and 7-day rate-limit fields while a session is active.
  [OpenTelemetry metrics](https://code.claude.com/docs/en/monitoring-usage)
  (`claude_code.token.usage`) give token counts.
- **Other providers:** any service that reports a percentage left per time
  window fits the format. A prepaid balance (money, not a percentage) does not
  fit the two-ring card yet.

## Settings

Right-click the menu-bar icon or click ⚙. Options:
- desktop and popover layout (2×2 or one row);
- light, dark or system appearance;
- glass intensity: 100% is a solid off-white or dark background, lower values
  let the desktop show through.

Settings without a menu entry (`defaults write com.hanlin.llmusage …`):
`snapshotURL` and `refreshCommand`, described above.

## Build, test, install

```bash
zsh build.sh
```

```bash
node check-ui.cjs docs/example-snapshot.json   # logic tests; the snapshot is optional
```

```bash
swiftc -parse-as-library MenuBar.swift Accounts.swift tests/menu_bar_checks.swift -o /tmp/menu-checks -framework AppKit && /tmp/menu-checks accounts.json
```

```bash
python3 tests/preview_matrix.py
```

```bash
python3 install-local.py
```

- `build.sh` writes to `~/Library/Caches/LLMUsage.noindex/`, so Spotlight never
  lists build copies.
- `tests/preview_matrix.py` opens the real popover on screen, so run it when
  the computer is free. It checks clipping, that the centre text and the badge
  clear the rings, colours, and popover open/close/reopen.
- `install-local.py` copies the build to `~/Applications` and keeps the replaced
  version as one zip in `~/Library/Application Support/LLMUsage/backups/`.

Requirements: macOS 14+ on Apple silicon, the Xcode command-line tools, and
Node.js for `check-ui.cjs`.

## License

MIT; see [LICENSE](LICENSE). Codex, ChatGPT and Claude are trademarks of their
owners; this project is not affiliated with OpenAI or Anthropic and ships none
of their logos.
