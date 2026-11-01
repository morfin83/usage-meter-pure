# Decisions

Approved by the owner on 2026-11-01 unless noted.

- **D1 — Authoritative code:** the public repository `morfin83/usage-meter-pure` (`main`). The private `morfin83/pure` repository keeps history and web material and is not published.
- **D2 — Native limits reader instead of Python.** The app must not depend on a user-installed Python. Python stays only as a reference for tests. (Owner: "schvaluji vše".)
- **D3 — Read-only limits.** Only `account/rateLimits/read` is sent. No thread or turn is started, so no tokens are spent. Server-initiated requests are refused.
- **D4 — Ad-hoc signing.** No Developer ID or notarization until the owner asks; no claim that an ad-hoc build is notarized.
- **D5 — Work on branches.** No direct push to `main`; no release, tag or public DMG without explicit approval.
- **D6 — Release history file.** `RELEASES.md` at the root is the single history (per CLAUDE.md). `docs/RELEASE_HISTORY.md` from the proposed structure is intentionally not created, to avoid a duplicate.
- **D7 — Website excluded.** The public repository contains no website material. Studio Pure Sound website is a distribution channel only.
- **D8 — Scope of this work.** Fixes and documentation on a branch; no new features.
- **D9 — Claude data (approved 2026-11-01, variant A + C).** Limits: read the Claude app's `plan-usage-history.json` (`fh` = 5 h, `sd` = 7 days, used %). Tokens: sum Claude Code session logs in `~/.claude/projects` (per message id, last record wins). Not used: the usage API with the app's session cookie (would read another app's credentials), and `anthropic-ratelimit-*` headers (need an API key and spend tokens).
