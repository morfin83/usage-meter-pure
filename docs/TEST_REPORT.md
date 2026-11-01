# Test report

Date: 2026-11-01. Branch: `fix/native-usage-adapter`.

## Commands and results
- `python3 -m unittest discover -s tests -v` — 21 tests: 10 for the Python reference, 11 for the native Swift reader (compiled with `xcrun swiftc`, driven through test hooks against fake app-servers). **OK.**
- `sh scripts/build_macos.sh <empty scratch folder>` — **OK**; `codesign --verify --deep --strict` passes; the bundle has no `.py` file.
- Real read-only check with the built binary: `UsageMeter --usage-check /opt/homebrew/bin/codex` — **OK**, returned 5-hour and weekly windows and a credit balance of 0. No tokens spent.
- `UsageMeter --usage-find-codex` — **OK**, returned `/opt/homebrew/bin/codex`.
- `UsageMeter --sample` — **OK**, returned CPU values.

## Covered by tests
Handshake and single usage read; server requests refused; timeout bounded; server errors and invalid results do not leak payload; closed pipe is an error; clamping of percentages; boolean values rejected as numbers; expired resets are pending; private fields dropped; numeric credit balances only; PATH discovery.

## Checked on the RC2 DMG (before the change)
Checksum recomputed and matched; bundle identifier and version correct; arm64; ad-hoc signature valid; bundled `usage_meter.py` identical to the then-current public source.

## Not verified (NEOVĚŘENO)
- Launch and interaction of the GUI app (panel, refresh, quit): not done in this session.
- Clean macOS 13+ machine without developer tools; first-open Gatekeeper path; drag-to-Applications install.
- Localisation review; visual layout at all sizes.
- Behaviour with other Codex versions.
