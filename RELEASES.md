# Release history

Only facts that were checked are listed here. Checksums are SHA-256 of the distributed DMG.

## 0.6.1 build 10 — release candidate 3 (RC3, local build, not published)

- Changes since RC2: native Codex limits reader (no Python), Codex lookup from Finder launch, read-only tests, docs.
- Local DMG `Usage-Meter-Pure-0.6.1-RC3-build10-arm64.dmg`, SHA-256 `73a0e327b4aefda7a442dbc9b7d2284efac30ec1f9888801576b305266f538bb` (built and checked 2026-11-01; not published).
- Status: built and verified locally by the owner; no tag, no public release.

## 0.6.1 build 9 — release candidate 2 (RC2)

- Git tag in the private development repository: `v0.6.1-rc2`. This public repository has no tags or GitHub releases yet.
- Distribution file: `Usage-Meter-Pure-0.6.1-rc2-arm64.dmg`
- SHA-256: `4cdb79fed1121905ec5ddda7f799ab26d4531191851c81e388fa316fa0d4aa36` (recomputed on 2026-11-01 and matching)
- Signature: ad-hoc. Not notarized. Apple Developer ID is not used yet.
- Status: release candidate, not approved as the final 0.6.1 release.

## 0.6.0 build 8 — last published release

- Bundle identifier `cz.pure.usagemeter`, Apple Silicon (arm64).
- SHA-256: `51b1557b9598876d20037ce502a9f0d8644e870f3e5a3455cd6a47e4c55e0046`.
- Published on the Studio Pure Sound website as the production download.

## Merged to main (PR #1, fix/native-usage-adapter)

- The limits reader is native Swift. The `/usr/bin/env python3` dependency has been removed from the app.
- Codex is searched in `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`, because a Finder-launched app has a minimal `PATH`.
- Build no longer copies `usage_meter.py` into the bundle.
