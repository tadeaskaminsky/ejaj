# Changelog

## 1.9.1 (2026-11-06)

- The dashboard can fill the screen. Its content was capped at 1200 pt wide, and macOS took that as the window's maximum width, so a double-click on the title bar or a drag of the edge stopped at 1200 pt. The cards, the chart, the calendar and the Models table now stretch to whatever width the window has.
- The dashboard also opens filling the screen between the menu bar and the Dock, on the display whose menu bar you clicked. Before, it opened at 1000 x 760 in the middle. It opens through a zoom, so a double-click on the title bar shrinks it to the size it had when you last closed it (1000 x 760 the first time) rather than 20 pt off the full screen. A dashboard that is already open keeps its size, and a minimized one comes back as it was.
- Count from in the gear menu leaves out everything before a chosen day. It offers the first record and every day of use after 30 or more idle days. On this Mac All time started with a one-minute Codex session on 1 October 2025, then nothing until 28 April 2026, so the chart was mostly empty months. With 28 April picked, the totals, the chart, the calendar and the quick view's comparison start there.
- `scripts/build.sh` also runs `build/window-tests`, which puts the real dashboard into a window and fails if it caps the window's width again. It needs a logged-in session, not SSH.
- Checked: tests for the Count from days (30 idle days count, 29 don't, the October clock change, two tools on one day) and the rows left out before it. The window test fails with the 1200 pt cap put back. The real dashboard view in a window built like EJAJ's. Before the fix its maximum content width was 1200 and a zoom (what the double-click does) gave 1200 x 1044 on the 1800 x 1044 visible area. After it, the zoom fills all of it, and a render at that size shows the full-width layout. A probe with the same open logic fills the screen on the first open and after a close, double-clicks to 1000 x 760 or to a size set before closing, and leaves an open window's size alone. A review with separate correctness, tests and silent-failure passes, its two main findings (the 20 pt double-click and the missing test) checked by separate verifiers. The installed app's dashboard was measured after opening it, but a real double-click in it was not tried.

## 1.9.0 (2026-11-05)

- Each request is priced on its own, with what makes it dearer than the list price: fast mode (2x on Opus 5.5, Opus 5 and Opus 4.8, 2x on GPT-6 and GPT-5.6, 2.5x on gpt-5.5), Haiku 5.5 prompts over 100K tokens (5x), OpenAI prompts over 272K (2x input, 1.5x output), US-only inference (1.1x) and web searches ($10 per 1,000). On this Mac it mostly shows in Codex's priority tier, which ran through much of August and September: the API cost up to 4 November goes from $4,018 to $4,736.
- Codex logs the tier in a settings snapshot before each turn, and builds before 0.163 skip the first turn. A Codex log now starts in its first snapshot's tier, and a spawned subagent without snapshots runs in its parent's tier at spawn time. That is about $120 of the difference above.
- Sonnet 5.5 cache reads cost $0.10 per million tokens (0.05x input), down from the $0.20 EJAJ had.
- Codex sessions in `~/.codex/archived_sessions` count now (10.2M tokens here, from August and October). So do `~/.config/claude/projects`, `$CLAUDE_CONFIG_DIR` and `$CODEX_HOME` when they exist.
- pricing.json is checked more strictly: true, false and negative prices are rejected, unknown keys inside `longContext` too, and every broken entry is named instead of only the last one. `--snapshot` reads pricing.json like the app.
- The token and cost cards split into input, cache write, cache read and output, plus web searches when there were any.
- In euros, the dashboard and the quick view show the dollar amount and the ECB rate under the cost. The right-click line and the tooltip add the dollar amount in brackets.
- pricing.json takes `fast`, `longContext`, `usOnlyMultiplier` and `webSearch`. Edit prices writes them out for every bundled model.
- Checked: tests for every modifier, the collector tiers, Codex start tiers and subagents, the new pricing.json keys, the seeded file and the extra folders, with mutations of the new code caught by them. A snapshot of the real logs compared day by day with one from 1.8.1. Renders of the cards, the quick view and the calendar at 880 pt. Prices checked against Anthropic's and OpenAI's pricing pages. A review with separate correctness, tests and silent-failure passes, and its main finding (the Codex first-turn and subagent tier) checked against the logs. The running app was not clicked through.

## 1.8.1 (2026-11-04)

- The calendar day detail has a second banner for the selected day's Monday to Sunday week. It shows the week's cost, its level and the difference against the 12 weeks before it, plus the average full week. Weeks with no cost are left out.
- A week that is still running is compared with the same days of earlier weeks (Mon-Wed against Mon-Wed), so half a week isn't judged against full ones.
- Checked: tests for running, finished, future and empty weeks. A render at the 880 pt minimum width shows both banners on one line. Clicking other weeks in the running app was not tried.

## 1.8.0 (2026-11-04)

- Clicking a calendar day shows how its API cost compares with the same weekday over the previous 12 weeks, or with the previous 30 days when that weekday has no history yet. The banner gives a level (Way above, Above, Average, Below or Way below average), the difference in money and percent, the average and how many days it covers.
- Checked: tests for the weekday and 30-day averages. A render of today's banner.

## 1.7.0 (2026-10-31)

- Calendar panel: a month grid with every day's API cost, shaded by its share of the month's highest day. Clicking a day shows its totals per provider and its hour-by-hour chart. Hourly rows are now kept for every day.
- `-D CALENDAR_ONLY` builds a debug binary that shows only the calendar, for screenshots.
- `build.sh` fails loudly on compiler errors. Before, it could report a stale binary as built.

## 1.6.0 (2026-10-30)

- Sources formatted with swift-format (2 spaces, 120 columns).
- Model display names such as Opus 5.5 and GPT-5.6 Sol.
- Prices can be overridden in `~/Library/Application Support/EJAJ/pricing.json`, either as bare rates or as dated entries. The file is reloaded on every refresh and errors show in the dashboard.
- Gear menu: currency (EUR by default, converted at the ECB rate), appearance, Launch at login, Edit prices.
- Models table: Cache hit column and sortable Requests. The Today range shows an hour-by-hour chart.
- Codex tokens reported before the first `turn_context` now count for that session's model.

## 1.5.0 to 1.5.2 (2026-10-22)

- One-screen dashboard with provider and range pickers, totals, a per-day chart and the Models table.
- Archive button that runs `~/projects/token-archive/archive.py`.
- The Models table sorts by any column.

## 1.4.1 (2026-10-15)

- Reads Codex `.jsonl.zst` rollouts through a statically linked libzstd 1.5.7.
