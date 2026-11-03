# Changelog

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
