# Backlog (priority order)

| # | Priority | Task | Status |
|---|---|---|---|
| 1 | P0 | Native limits reader without Python; codex discovery from a Finder launch | DONE, merged to main (PR #1) |
| 2 | P0 | Verify the built app in a GUI session: launch, limits row, refresh, quit | TODO |
| 3 | P0 | Clean-Mac test on macOS 13+ (VM or spare Mac), without developer tools; first-open Gatekeeper path | BLOCKED (no clean machine) |
| 4 | P1 | Explain or retire the unlabelled DMG `Usage-Meter-Pure-0.6.1-RC-build9.dmg` (hash 62f14860…) | TODO, owner input |
| 5 | P1 | New release candidate from current source | DONE locally as RC3 build 10 (not published); publication needs approval |
| 6 | P1 | DMG builder in the repo | DONE: `scripts/make_dmg.sh` (refuses to overwrite, writes `.sha256`); `create_release.command` not added |
| 7 | P2 | `observedAt` timestamp | CLOSED: the reader makes a live request and reads the answer immediately, so the time is the read time. The API returns no answer timestamp. |
| 8 | P2 | Add a Swift-side unit test target instead of the compiled test hooks (needs XCTest from full Xcode) | IDEA |
| 9 | P2 | Review Czech and English strings in `macos/Resources` | DONE for key coverage (46 keys in both files, no gaps); English wording not reviewed by a native speaker |
| 10 | P2 | Public release tag and GitHub release for 0.6.1 | NEEDS APPROVAL |
