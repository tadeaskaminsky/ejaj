# Changelog

## 1.13.1 (2026-11-12)

- Patterns with Today chosen shows only today: one larger tile per hour, in two rows of twelve, with its cost written in, darker for more spent. The current hour is ringed and the hours still to come are outlined. Above the tiles are today's total so far and the busiest hour; under them the hovered or current hour's cost, tokens and requests. Before, Today drew the whole week grid with a single lit row. 7 days and more keep the week grid.
- Checked: captures from the real logs in dark at 880 pt and light at 1200 pt. The build and all tests pass. This is the first version installed through the Update button: it was published while 1.13.0 still ran here. Hovering the tiles wasn't tried.

## 1.13.0 (2026-11-12)

- EJAJ updates itself from its GitHub releases. It checks when it starts and every 6 hours, and when a newer version is out, an **Update** button appears next to Refresh. A click shows what changed. **Install and restart** downloads the release, checks it, replaces the app and opens it again, with settings and history kept. **Check for updates** in the gear menu checks right away.
- Before installing, the download must match the SHA-256 checksum GitHub lists for it, be EJAJ of the offered version and have an intact signature. Older versions are never offered. If the replacement fails after EJAJ has quit, the old version comes back and the dashboard says why the next time it opens. EJAJ has to sit in a folder you can write to, such as /Applications. A copy run straight from Downloads says so instead of updating.
- New installs can start from the zip of the latest GitHub release instead of building from source; the README's first step says how. `scripts/publish.sh` publishes a version: it requires a clean, pushed `main`, packages again from that commit and uses the version's CHANGELOG entry as the release notes.
- Checked: tests for release parsing (drafts, prereleases, other tags, missing zips, plain http only from this Mac, malformed checksums), version order, the checksum, and the swap script run on real folders: it waits for the old process, replaces the bundle, cleans up, and on a failed copy puts the old one back and leaves the note. An end-to-end run against a local server: a wrong checksum was refused, a good 1.12.1 replaced a 1.12.0 copy, opened, and then reported itself as the latest version, with nothing left in the temporary folder. The live GitHub API answered correctly. A review with correctness, security, tests and silent-failure passes. The security pass found no way in through the swap script, a crafted zip, a downgrade or the http exception. Its findings and the two confirmed Medium ones were fixed: a failed swap now leaves a note, and an old error line no longer outlives a later successful check. The Update button and its window weren't clicked in the running app.

## 1.12.0 (2026-11-12)

- The dashboard has five tabs instead of two, each answering one question. **Overview** has the totals, the chart per day and the Models table. **Calendar** has the calendar with the day details and the Claude week banner, moved out of Overview. **Projects** is the former Analytics tab. **Sessions** and **Patterns** are new. The Platform and Range pickers apply to every tab. Calendar moves by month, so there the Range picker gives way to the Tokens/Cost switch for the day's hourly chart.
- **Sessions** opens with **Running now**: every session that sent a request in the last 10 minutes, with what it cost today, and in total if it started on an earlier day. Under it are the range's record sessions (most expensive, most requests, most tokens), and then all sessions across projects in one table with a Project column and a search on titles and projects.
- **Patterns** has a weekday by hour heatmap of the cost in the chosen range and platform, with each weekday's total on the right and each hour's total underneath. Hovering a square shows its cost, the average for one such day, its tokens and its requests. On this Mac the dearest hour of the last 30 days is Wednesday 16:00.
- Overview has a third card, **Cache saved**. It weighs the cheaper cache reads and the dearer cache writes against paying the input price for every cached token, and shows the net saving, the share of the bill it cut and the bill without the cache. For the last 30 days here that is €14,235, 89 % off a bill of €15,985.
- A new look throughout. The header has the EJAJ mark, the tabs, and rounded Refresh, settings and Archive buttons, and Refresh spins while it reads. The pickers are pills that slide to the chosen option. The chart per day uses smooth lines over a fading fill, with a dashed line and ringed points on the hovered day. The hourly bars are rounded. Under the token and cost totals, a thin bar splits them between Claude and Codex. Calendar days shade by the square root of their cost so that cheap days still show. Today has a dark badge, the month's dearest day a flame, and future days a dashed outline, and a Today button brings you back. The Models table has a share-of-cost bar for each model.
- Checked: tests for the cache saving and write premium (5-minute and 1-hour writes at their own rates, fast mode, unpriced models), the weekday by hour grid (Monday first, two hours of one day counted as one day, rows without an hour skipped), running sessions (the 10-minute edge, newest first, a clock ahead) and range edges. Captures of every tab from the real logs in dark and light at 880 and 1200 pt. A review with correctness, tests and silent-failure passes. Its one main finding, confirmed by a separate verifier, was a cost per hour in Running now that divided today's cost by a session's whole span, so a session resumed after days looked almost free. Running now shows today's and total cost instead. Smaller fixes: the Tokens/Cost switch for the calendar, a singular "Monday", the whole settings button clickable, and the unpriced-model note on Cache saved. The four missing tests the review found were added. Hover, the search field and clicks weren't tried in the running app.

## 1.11.0 (2026-11-12)

- The dashboard has two tabs, **Overview** (everything it showed before) and **Analytics**. Analytics opens on a **Projects** panel: what each project cost in the chosen range and platform, with a bar, its number of sessions and its tokens. Click a project for its cost, tokens and sessions, with a sortable table of sessions (title, start, length, tokens, cost). Click a session for its cost and token breakdown, start, last request, requests, folder and models. The tab you were on is remembered.
- A session is a Claude Code conversation with its subagents, or a Codex thread with the threads it spawned. Its project is the git repository around its latest working folder. A Claude Code worktree counts as its repository. Claude's and Codex's scratch folders are grouped as Scratch, temporary folders as Temporary. Titles are the Claude Code name you set or else the generated one, and the Codex thread name from `session_index.jsonl`. A rename there alone is picked up on the next refresh. Codex threads without a name stay "Untitled": Codex's other title is the first prompt, and EJAJ doesn't store prompts.
- Sessions are saved in `history.json` with their project's name and folder, not the full working path. An older `history.json` still opens, and the tab fills in after the first refresh.
- On this Mac that is 397 sessions across about 20 projects. Their cost and tokens add up exactly to the dashboard's totals: 7.67 B tokens, 51,570 requests, $5,438.46.
- Checked: tests for the project rules (repository root, subfolders, worktrees, home, scratch and temporary folders), session grouping with a subagent file, a Codex subagent under its root thread, title precedence, renames, the project from the latest folder whatever the file order, range edges, platform filter, unpriced models and the cache round trip. Renders of the projects list, a project and a session at 880 pt from the real logs. A review with correctness, tests and silent-failure passes. Its confirmed findings were fixed: list costs left out unpriced models without a `*`, and four behaviours had no test (each shown by reverting the code). One finding wasn't fixed: a Claude Code record without a session id would count on the dashboard but in no session. None of the 55,887 records here lacks one. Clicks and hovering in the running app weren't tried.

## 1.10.1 (2026-11-10)

- Claude Fable 5.2 has a price, so its requests count in the API cost. Before, they showed tokens but no cost. It costs $8 per million input tokens, $40 output, $0.20 for cache reads and $10 or $16 for 5-minute or 1-hour cache writes. Fast mode doubles all of it ($16 / $80), and US-only inference adds 1.1x on top as for the other Claude models. On this Mac that is 72 requests on 9 November, about $16.56.
- Checked: prices against Anthropic's pricing page on 10 November. Tests for each price category, fast mode and fast plus US-only, and the name "Fable 5.2". Swapping the two cache-write prices fails the tests. A snapshot of the real logs with the 72 requests. A separate review with correctness, tests and silent-failure passes. Its one finding was that the first test only checked the total, so it couldn't catch prices in the wrong order. That is now fixed. The running app's Models table was not opened.

## 1.10.0 (2026-11-06)

- The calendar has a **Claude week** banner above the grid: how much of the Claude plan's weekly limit is left, when it resets and where the week is heading at its pace so far. Red means the pace hits the limit before the reset, with roughly when. Orange means a good part of the limit would go unused. The per-model weekly limits and the 5-hour limit are on the right. It reads the same numbers as `/usage` in Claude Code, every 5 minutes, and a click reads them again.
- The numbers come from `api.anthropic.com/api/oauth/usage` with Claude Code's login from the Keychain. EJAJ renews an expired login through `platform.claude.com/v1/oauth/token` as Claude Code does and writes it back to the same Keychain item, unless Claude Code stored a newer one in the meantime. Neither endpoint is documented. Without a Claude Code login the banner says how to sign in. A failed read keeps the last numbers with their time.
- `scripts/render-calendar.sh` takes `plan`, `signedout` or `live` as a third argument to render the banner with sample numbers, the sign-in note or the real numbers.
- Only an expired login is renewed, and only when EJAJ can save the result. A 401 on a login that hasn't expired retries only with a newer login Claude Code stored, and otherwise shows the error. A response EJAJ doesn't recognise, or a Keychain error, keeps the last numbers and shows what went wrong instead of hiding the banner or asking you to sign in. `security` gets 15 seconds before EJAJ gives up (a locked keychain waits on its dialog). Numbers older than 10 minutes, or from before the weekly reset, say so.
- Checked: tests for the usage response (null windows, one window only, unknown shapes, booleans, values outside 0 to 100, both date formats), the week projection, its 12-hour start and the runs-out time, the login merge (missing or empty refresh tokens, no refresh lifetime, other Keychain keys kept, broken responses) and the account name in `security` output. Mutations of the fixed lines were caught by them. Renders of the banner and of the sign-in note at 880 pt. A probe against this Mac's Keychain read the account and, with Claude Code signed out (empty token), gave the sign-in note. A review with correctness, security, reliability, tests and silent-failure passes, each of its eight main findings confirmed by a separate verifier and fixed. The worst was a miscounted account name that would have thrown away every renewed login. After signing in, the real endpoint returned weekly 77 %, Fable 68 % and 5-hour 38 %, the same as `/usage`. Its per-model limits come only in a `limits` list (`weekly_scoped`), which EJAJ now reads, with a test on that response. A live render shows them. A token renewal was not tried, because the new login doesn't expire until midnight.

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
