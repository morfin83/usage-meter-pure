# Known issues and technical debt

## Fixed on branch `fix/native-usage-adapter` (not yet released)
- **Python runtime dependency.** The app ran `/usr/bin/env python3`. On a Mac without Command Line Tools this fails, and the docs said no Python is needed. Fixed by the native reader.
- **Codex not found from Finder.** A Finder-launched app has a minimal `PATH`; `codex` under `/opt/homebrew/bin` was not found. Reproduced by the adapter with a launchd-like `PATH`. Fixed by extending the search path in both the Swift and the Python reference code.
- **Stale README.** The public README contained a section about the website. Replaced.
- **Missing release notes file.** `RELEASES.md` added.
- **CLAUDE.md referenced a DMG script not in this repository.** Line updated.

## Open
- **RC2 DMG on disk predates the adapter change.** Its `usage_meter.py` matches the old public source. A new RC needs a new build and checksum.
- **Unlabelled DMG** `Usage-Meter-Pure-0.6.1-RC-build9.dmg` (SHA-256 `62f14860…`) exists locally and matches no record. Not used.
- **Clean-install behaviour untested.** Gatekeeper, first open, drag to Applications: NEOVĚŘENO.
- **Codex is a moving target.** The app depends on `codex app-server` protocol details (`--disable hooks`, the `account/rateLimits/read` shape). Tested with codex-cli 0.165.0 only. A new Codex version must be re-checked against the JSON schema from `codex app-server generate-json-schema`.
- **Pending child cleanup on crash.** If the app is killed hard, the app-server child may outlive it until its stdin closes. Expected to exit on EOF; not verified.
- **Build script defaults.** `build_macos.sh` removes the target folder you give it; always pass an empty scratch folder.

## Claude panel (branch feat/claude-usage-sources)
- **Limits are stale unless the Claude app writes them.** The app writes its plan file only on its own schedule; the last write seen on 2026-11-01 was 31 Oct 22:32. The panel dims the rows and shows the age after 1 hour.
- **No reset times locally.** The Claude app keeps them in memory only.
- **Token totals include cache reads**, which dominate Claude Code volume (about 156 M in 5 h on the test Mac). They are not the same as the subscription limit.
