# Usage Meter Pure — project master

Status as of 2026-11-01. Authoritative source: the code in this repository plus the decisions in [DECISIONS.md](DECISIONS.md). Older documents are history only.

## What it is
Native macOS panel (Apple Silicon, macOS 13+) showing shared Codex account limits and local CPU, per-core CPU, memory, GPU and network load. MIT licence. Studio Pure Sound / MORfin83.

## Versions
- Last published: 0.6.0 build 8 (see [RELEASES.md](../RELEASES.md)).
- Release candidate: 0.6.1 RC2 build 9, ad-hoc signed, not notarized, not approved as final.
- Working branch: `fix/native-usage-adapter` (not merged, not pushed). `main` is unchanged.

## Verified (2026-11-01)
- Public `main` (`ea5e285`) equals the sources in the private repository.
- RC2 DMG SHA-256 recomputed: `4cdb79fe…aa36`, matches the record.
- Limits read live through `account/rateLimits/read` with codex-cli 0.165.0; no tokens spent.
- Unit tests and the Swift adapter tests pass; the app builds and is ad-hoc signed.

## Open
See [BACKLOG.md](BACKLOG.md) and [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Main points: clean-Mac and GUI verification not yet done; RC2 DMG on disk was built from an earlier source state; an unexplained second DMG exists locally.

## Backups
Before a milestone (release candidate, tag, public release), keep a copy of the docs and the release artefacts in a folder outside the repository, and record the checksums.
