---
name: build-and-test
description: Build EJAJ and run its collector tests after any change to Sources/ or Tests/. Use before committing, before packaging, or when a test fails and you need to see which precondition broke.
---

# Build and test EJAJ

```bash
scripts/build.sh
```

This compiles `build/EJAJ`, `build/collector-tests` and `build/window-tests` with `swiftc -O` for arm64 macOS 13+, then runs both tests. `window-tests` (from `Tests/WindowTests.swift`) puts the real dashboard into a window, so it needs a logged-in session with a window server and fails over SSH. It prints compiler errors only (warnings are filtered) and ends with `built build/EJAJ`. Anything else is a failure: `BUILD FAILED: ...` or `TESTS FAILED`.

There is no Xcode project and no Swift package. The app is four files in `Sources/` plus the static libzstd in `Vendor/zstd/`, linked through `EJAJ-Bridging.h`. Add new Swift files to the `compile` lines in `scripts/build.sh`, and to `scripts/render-calendar.sh` if the calendar code needs them.

## When a test fails

`Tests/Tests.swift` is a plain executable of `precondition` calls. Under `-O` a failed precondition traps with exit code 133 and prints nothing, and any `PASS:` lines still sitting in the stdout buffer are lost too. To see which line broke, build the tests without optimisation:

```bash
swiftc -Onone -target arm64-apple-macos13.0 -module-cache-path build/module-cache \
  -import-objc-header Vendor/zstd/EJAJ-Bridging.h \
  Sources/Models.swift Sources/Plan.swift Tests/Tests.swift Vendor/zstd/libzstd.a -o build/tests-debug && build/tests-debug
```

It reports `Tests.swift:<line>: Precondition failed`. Check the expectation before you touch the code: a threshold such as a 0.8 ratio counting as "Below average" is easy to get wrong in the test itself.

## Rules for tests

- The collector and the calendar math live in `Sources/Models.swift` and must stay testable without SwiftUI. Put new logic there as plain functions over plain values (see `dayAverage` and `weekAverage`, which take `[String: Double]` keyed by `yyyy-MM-dd`), and keep colours and text layout in `Views.swift`.
- The plan limits (`Sources/Plan.swift`) follow the same split: parsing the usage response, the week projection and the credentials merge are plain functions with tests. The Keychain and network calls (`ClaudeKeychain`, `ClaudePlan`) aren't tested and must never print or log a token.
- Dates are Europe/Bratislava days. Use `dayFormatter` and `bratislava`, never `Calendar.current`.
- Each test group ends with a `print("PASS: ...")` line. Add one for new groups so the output shows they ran.
- Formatting follows `.swift-format` (2 spaces, 120 columns).
