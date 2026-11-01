# Architecture

## Components (macos/UsageMeter.swift, one file)
- `AppDelegate` — status item, floating panel, timers, preferences (`UserDefaults`), quit handling.
- `SystemSampler` — CPU total and per logical core (`host_processor_info`), memory (`host_statistics64`), GPU (`IOAccelerator` `PerformanceStatistics`), active network interface.
- UI: `MeterRow`, `PastelBar`, `DragHeader`, `OverlayPanel`, `Palette`.
- `CodexUsage` — discovery of the Codex binary and the sanitized snapshot builder.
- `AppServerLink` — one `codex app-server --stdio --disable hooks` child process, JSON-RPC over pipes.
- Localisation: `macos/Resources/cs.json`, `en.json`.

## Data flow: account limits
1. Timer (every 60 s, and on demand) calls `fetchUsage()`. A guard prevents parallel refreshes.
2. Background queue: `CodexUsage.codexBinary()` searches `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`, then the ChatGPT/Codex app bundles.
3. `CodexUsage.read()` starts the app-server and sends `initialize`, `initialized`, `account/rateLimits/read`. Any server-initiated request is refused with an error. Timeout 12 s. Nothing else is sent.
4. `CodexUsage.snapshot()` whitelists fields, clamps percentages, rejects booleans as numbers, marks expired resets as pending (never as replenished), and drops account IDs, tokens and reset credits.
5. Main queue: `applyUsage()` updates the rows; an old value is marked as stale after 120 s or when a refresh fails.
6. `applicationWillTerminate` terminates the child process.

## Reference adapter
`scripts/usage_meter.py` implements the same logic in Python and is covered by `tests/test_usage_meter.py`. It is not bundled. Keep both in step when the protocol changes.

## Test hooks
`UsageMeter --usage-check <binary> [timeout]` and `UsageMeter --usage-find-codex` exist for `tests/test_native_adapter.py`. They do not change normal launch.

## Build
`scripts/build_macos.sh` compiles with `xcrun swiftc -target arm64-apple-macos13.0`, copies resources, writes `Info.plist`, cleans extended attributes and signs ad-hoc with bounded retries.
