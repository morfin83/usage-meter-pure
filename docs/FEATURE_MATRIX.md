# Feature matrix

Status key: DONE = implemented and covered by a check in this repository; PARTIAL = implemented, not fully verified; PLANNED = not implemented; REJECTED = decided against.

| Feature | Status | Evidence |
|---|---|---|
| 5-hour and weekly Codex limits, percent remaining | DONE | live read 2026-11-01; `test_native_adapter.py` |
| Reset time per window, pending state after reset | DONE | `test_expired_reset_is_pending_and_never_replenishes` |
| Credit balance when the account reports it | DONE | `test_numeric_credit_balance_is_kept` |
| Automatic refresh (60 s) and manual refresh | PARTIAL | code path present; GUI not exercised in this session |
| CPU total and per logical core | PARTIAL | `--sample` output checked; per-core values shown |
| Memory usage | PARTIAL | code present; not compared with Activity Monitor |
| GPU load and core info | PARTIAL | driver-dependent; may show unavailable |
| Active network interface load | PARTIAL | code present |
| Collapsible panel and detail switches | PARTIAL | previously verified in older versions (VALIDATION.md) |
| Remembered settings | PARTIAL | `UserDefaults` keys in code |
| Czech and English | PARTIAL | `cs.json`/`en.json` present; not fully reviewed |
| Runs without Python on the user's Mac | DONE | native reader; no `python3` in the bundle |
| Clean install on macOS 13+ | PLANNED | needs a clean Mac or VM (NEOVĚŘENO) |
| Developer ID signing and notarization | DEFERRED | not required now; ad-hoc only (owner decision) |
| Token usage per conversation | REJECTED | the app shows account limits only; not token accounting |
