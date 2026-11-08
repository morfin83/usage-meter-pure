# Release history

Only facts that were checked are listed here. Checksums are SHA-256 of the distributed DMG.

## 0.7.0 build 16 — installed locally, release pending approval

- Drawers for Codex and Claude Code, both can be open; the second goes to the free side, the main panel moves if needed.
- Width and side of the drawers in the "Šuflíky" menu; keyboard shortcuts ⌘W, ⌘M, ⌘1–⌘3, ⌘R, ⌘Q.
- Thread kind and model in the Codex drawer; Claude repair button on its line; faster Claude token scan (cached).
- Main panel without scrolling; drawers keep their scrolling.
- DMG: `Usage-Meter-Pure-0.7.0-build16-arm64.dmg`, SHA-256 `6a47be595d07a62cd7d10478a2026daff4dc64e515261636408d4edeedee6908`.
- Verified: 74 unit tests; drawers, placement and shortcuts on the running app.
- Not verified: clean macOS 13+ machine; the first Claude background refresh on another account.

## 0.6.2 build 15 — installed locally, release pending approval

- Claude line explains why there are no fresh data and offers the repair on the same line: "Připojit ↻" or "Obnovit ↻"; afterwards the data are read again.
- Fixed the stuck "loading" state: the Claude token scan (about 400 MB of logs, 7.6 s per refresh) now runs after the limits are shown and is cached for five minutes.
- DMG: `Usage-Meter-Pure-0.6.2-build16-arm64.dmg`, SHA-256 `6a47be595d07a62cd7d10478a2026daff4dc64e515261636408d4edeedee6908`.
- Verified: 71 unit tests; the repair states in an isolated copy; installed from the DMG, old version removed.
- Not verified: the repair "Připojit" on the real user settings (only in an isolated copy); clean macOS 13+ machine.

## 0.6.2 build 14 — installed locally, release pending approval

- Claude "Obnovit Claude ↻" now runs in the background: Claude Code starts in a pseudo-terminal in the app folder, no Terminal window and no Automation prompt. Enter answers the one-time browser-tools dialog; the run ends once the status line has written a fresh reading. Cost confirmation kept.
- Build 13 changes unchanged (Codex activity window, reset countdowns, Codex token totals).
- DMG: `Usage-Meter-Pure-0.6.2-build14-arm64.dmg`, SHA-256 `fc51ed36b03e76484c310c58a04515f719033551d42e9403661e3fe37b8a9889`.
- Verified: unit tests (61) pass; a real background refresh updated the status line within about 3 seconds and left no process; build, signature and DMG verified; installed from the DMG, old version removed.
- Not verified: clean macOS 13+ machine; the first refresh on a fresh account (the app folder must be trusted once).

## 0.6.2 build 13 — installed locally, release pending approval

- Codex activity window ("Aktivita"): state, session id, last steps, buttons to open Codex or run `codex resume` in Terminal.
- Reset countdown ("Obnova za …") on every limit row.
- Codex token totals from local logs (5 h and 7 days), computed after the limits are shown.
- Claude: manual "Obnovit Claude ↻" button with a cost confirmation (about 60,000 tokens); clearer status when data is stale; automatic refresh deliberately not added.
- Claude status line is connected automatically on first launch (unchanged); status notes wrap in the panel.
- DMG: `Usage-Meter-Pure-0.6.2-build13-arm64.dmg`, SHA-256 `8c848bb1f98fc5b74611b4f2168d5875bfa83bc682acdf9dd872c0e8b26c6581`.
- Verified: unit tests (59) pass; build and ad-hoc signature verified, also inside the DMG; installed from the DMG, old version removed, Spotlight finds only the new app; Claude status line path updated automatically.
- Not verified: clean macOS 13+ machine; an interactive Claude Code session that writes status-line data after the refresh button (first run needs a one-time trust of the app folder); Terminal automation permission flow.

## 0.6.1 build 12 — gauge bars (installed locally, replaced by build 13)

- Claude and Codex limits as bars with three zones (green to 50 %, orange to 85 %, red above) and an arrow at the current use.
- A click on a bar switches it to a 24-hour curve; another click switches back. The choice is kept across launches.
- Codex has a local 7-day history, so Codex has curves too; Codex refreshes every 30 s.
- DMG: `Usage-Meter-Pure-0.6.1-build13-arm64.dmg`, SHA-256 `8c848bb1f98fc5b74611b4f2168d5875bfa83bc682acdf9dd872c0e8b26c6581`.
- Verified: 48 Python tests; visual check of bars, arrow, toggle and persistence on the running app; the app installed from the DMG and the Claude status line re-pointed automatically.
- Not verified: clean macOS 13+ machine; a live Claude Code session showing status-line data.

## 0.6.1 build 11 — not published (replaced by build 12)

- Installed locally for testing and then replaced; no tag or public release.

- Finální kandidát 0.6.1, CFBundleVersion 11. Zatím nevydáno, bez tagu a bez veřejného DMG.
- Změny:
  - nativní čtečka limitů (bez Pythonu),
  - Codex se najde i při spuštění z Finderu,
  - skupina Claude v panelu: limity ze status line Claude Code, záloha ze souboru Claude desktop aplikace, součty tokenů z logů Claude Code,
  - automatické nastavení status line v `~/.claude/settings.json` (záloha, řetězení vlastní status line),
  - skript `scripts/make_dmg.sh`,
  - dokumentace.
- SHA-256: 764b00af7acaf9ef03db0003feae6d81e0761163b66dd9c10ba3b0c20f4b7779
- Podpis: ad-hoc. Bez notarizace.
- Ověřeno: 38 Python testů prošlo; sestavení a ad-hoc podpis lokálně.
- Neověřeno: čistý Mac s macOS 13+; živá session Claude Code se zobrazenou status line; první otevření přes Gatekeeper.

## 0.6.1 build 10 — release candidate 3 (RC3, published as a pre-release)

- Changes since RC2: native Codex limits reader (no Python), Codex lookup from Finder launch, read-only tests, docs.
- Git tag `v0.6.1-rc3` (GitHub pre-release): https://github.com/morfin83/usage-meter-pure/releases/tag/v0.6.1-rc3
- DMG `Usage-Meter-Pure-0.6.1-RC3-build10-arm64.dmg`, SHA-256 `73a0e327b4aefda7a442dbc9b7d2284efac30ec1f9888801576b305266f538bb` (checksum recomputed 2026-11-01).
- Signature: ad-hoc. Not notarized.
- Verified: the owner ran build 10 on 2026-11-01 and reports that it works.
- Not verified: clean macOS 13+ machine, Gatekeeper first-open path.

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
