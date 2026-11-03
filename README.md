# EJAJ

A macOS menu-bar app that counts the tokens Claude Code and Codex use on this Mac and shows what they would cost at standard API prices. It reads the session logs both tools already write. Nothing is sent anywhere.

![Calendar panel with the day and week banners](docs/calendar.png)

The cost is what the same tokens would cost on the API. It is not a bill. If you pay for a subscription, think of it as how much use you got out of it.

Requires an Apple Silicon Mac with macOS 13 or later.

## Tutorial

### 1. Build and install

You need the Xcode command line tools (`xcode-select --install`). No Xcode project is involved.

```bash
git clone https://github.com/tadeaskaminsky/ejaj.git
cd ejaj
scripts/package.sh
```

That builds the app, runs the tests and leaves `build/EJAJ.app` plus `build/EJAJ-macOS.zip`. Move the app wherever you keep it, for example:

```bash
ditto build/EJAJ.app /Applications/EJAJ.app
open /Applications/EJAJ.app
```

The app is signed ad hoc, not notarized. That's fine on the Mac that built it. A copy from the zip on another Mac gets blocked the first time. Allow it with Open Anyway in System Settings > Privacy & Security.

### 2. The menu-bar icon

EJAJ has no Dock icon. It lives in the menu bar as a small waveform.

- **Click** it for the quick view: today's cost, tokens per tool and a verdict comparing today with the same weekday over the past 12 weeks. The quick view is in Slovak, on purpose.
- **Right-click** it for a line with today's cost and tokens, then Open EJAJ, Refresh data, Archive to GitHub, Launch at login and Quit.
- **Dashboard** in the quick view (or `⌘O`) opens the main window.

The data refreshes every 30 seconds. The first scan of a long history can take a few seconds, and after that only changed files are read again.

### 3. The dashboard

The two pickers at the top decide what everything below shows. **Platform** is All, Claude or Codex. **Range** is Today, 7, 30 or 90 days, or All time.

Under them you get the token and API cost totals and a chart per day (per hour for Today). The Tokens/Cost switch above the chart picks what the bars measure. If a model has no known price, the API cost card says how many tokens that leaves out.

The **Models** table lists every model with its tokens, requests, cache hit rate (the share of prompt tokens served from the cache) and API cost. Click a column header to sort, and click again to flip the order.

### 4. The calendar

The calendar shows one month. Each day has its API cost, and darker days cost more. A `*` means the day includes tokens of models without a price. Use `‹` and `›` to change the month.

Click a day to see its totals per tool, its hour-by-hour chart and two banners:

- **Day** compares the day with the same weekday over the 12 weeks before it, for example this Wednesday against the average Wednesday. When there are no earlier Wednesdays yet, it uses the 30 days before instead.
- **Week** compares the day's Monday to Sunday week with the 12 weeks before it. While a week is still running it is compared with the same days of earlier weeks. On a Wednesday that means Mon-Wed against Mon-Wed, so you don't see "way below average" every Monday morning. On the right is the average full week.

Both banners use the same scale. Way above average is 1.5x or more, Above is over 1.1x, Average is 0.9x to 1.1x, Below is 0.5x to 0.9x, and Way below is anything less. Days and weeks with no cost at all are left out of the averages. The Platform picker applies to the calendar too, so with Claude selected you compare Claude with Claude.

### 5. Settings

The gear icon in the dashboard has the settings.

- **Currency**: EUR (default, converted at the daily ECB rate) or USD.
- **Appearance**: Dark, Light or System.
- **Launch at login**: registers EJAJ as a login item. It shows up in System Settings under General > Login Items.
- **Edit prices (pricing.json)**: opens `~/Library/Application Support/EJAJ/pricing.json`, creating it with the bundled prices the first time.

Prices are in USD per million tokens, in this order: input, cache read, cache write, output, 1-hour cache write. A model can have one list of rates, or a list of dated entries that each apply from that day on:

```json
{
  "claude-opus-5-5": [4, 0.2, 5, 20, 8],
  "gpt-6.1-sol": [
    { "from": "2026-01-01", "rates": [2, 0.2, 2.5, 10, 4] },
    { "from": "2026-10-01", "rates": [2, 0.1, 2.5, 10, 4] }
  ]
}
```

Save the file and the next refresh picks it up. If an entry is broken, the dashboard names the model and that model keeps its bundled price. The other entries still apply.

### 6. Archive (optional)

The Archive button runs `~/projects/token-archive/archive.py`, a separate script that saves a snapshot of the counts and pushes it to a git repository. If that script doesn't exist, the button says so and nothing else happens.

### 7. Updating

Pull and package again. To replace the copy you run and restart it in one step:

```bash
git pull
scripts/package.sh --install /Applications/EJAJ.app
```

`--install` only replaces a bundle whose identifier is EJAJ's, so a wrong path fails without deleting anything.

## Where the numbers come from

- **Claude Code**: `~/.claude/projects/**/*.jsonl`
- **Codex**: `~/.codex/sessions/**/*.jsonl` and the compressed `.jsonl.zst` rollouts

EJAJ reads only the token counts, model names and timestamps from those files, never prompts or tool output. Repeated records are counted once. The last result is cached in `~/Library/Application Support/EJAJ/history.json` so the app opens with numbers straight away. Days are Europe/Bratislava days.

## Development

```
Sources/        main.swift (app, menus, icon), Models.swift (collector, pricing, averages), Views.swift (SwiftUI)
Tests/          Tests.swift, a plain executable of preconditions
Vendor/zstd/    static libzstd 1.5.7 (BSD licence in Vendor/zstd/LICENSE)
Resources/      Info.plist and AppIcon.icns
scripts/        build.sh, package.sh, render-calendar.sh
.claude/skills/ build-and-test, release, check-calendar-layout
```

- `scripts/build.sh` builds `build/EJAJ` and runs the tests.
- `scripts/render-calendar.sh` renders the calendar from your cached history to `build/calendar.png`, which is handy for checking that the banners fit.
- `build/EJAJ --snapshot out.json` writes what the collector found as JSON, without starting the app.

The version lives in `Resources/Info.plist`, and the history is in [CHANGELOG.md](CHANGELOG.md). If you work on this with Claude Code, the skills in `.claude/skills` cover building, releasing and checking the calendar layout.
