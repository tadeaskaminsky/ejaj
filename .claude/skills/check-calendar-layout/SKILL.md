---
name: check-calendar-layout
description: Render EJAJ's calendar panel to a PNG and look at it. Use after changing CalendarPanel, its day or week banners, or anything they display, to confirm that text fits and nothing is cut off, without clicking through the running app.
---

# Check the calendar layout

```bash
scripts/render-calendar.sh build/calendar.png        # 880 pt wide, the dashboard's minimum
scripts/render-calendar.sh build/calendar-wide.png 1200
scripts/render-calendar.sh build/calendar-plan.png 880 plan       # Claude week banner, sample numbers
scripts/render-calendar.sh build/calendar-out.png 880 signedout   # its sign-in note
scripts/render-calendar.sh build/calendar-live.png 880 live       # real numbers via Claude Code's login
```

The script compiles `scripts/render-calendar.swift` together with `Sources/Models.swift`, `Sources/Plan.swift`, `Sources/Update.swift` and `Sources/Views.swift`. It loads the cached history from `~/Library/Application Support/EJAJ/history.json`, the same file the app writes, and renders `CalendarPanel` with SwiftUI's `ImageRenderer` at 2x. Open the PNG with the Read tool and look at it.

What it shows and what it can't:

- The selected day is always today, because `selected` is view state that starts at today. To check another day, temporarily change the initial value of `selected` (or `month`) in `CalendarPanel`, render, and put it back before committing.
- The numbers are real data from this Mac, so they change between runs. Don't commit renders that contain them unless the user wants that.
- Hover states and clicks don't exist in a render. Say so when you report a visual check.

Check at 880 pt first. The banners use `lineLimit(1)`, so overflow shows up as "..." at the end of a line, not as wrapping. When a line is too long, shorten the wording before you shrink the font. `AverageBanner` gives the coloured detail text priority over the grey average on the right.
