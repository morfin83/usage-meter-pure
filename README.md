# Usage Meter Pure

A small native macOS menu-bar and desktop panel (Apple Silicon, macOS 13+) that shows the shared Codex account limits (5-hour and weekly windows, reset times) next to local CPU, per-core CPU, memory, GPU and network load.

- Bundle identifier: `cz.pure.usagemeter`
- Current version: 0.6.1 build 10 (RC3, published as a pre-release: [v0.6.1-rc3](https://github.com/morfin83/usage-meter-pure/releases/tag/v0.6.1-rc3))
- Last published release: 0.6.0 build 8 (see [RELEASES.md](RELEASES.md))
- Languages: Czech and English
- Licence: MIT ([LICENSE](LICENSE)); third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## How the limits are read

The app asks the locally installed Codex app-server for account limits with a single read-only request, `account/rateLimits/read`. It starts no conversations and spends no model tokens. The request is made by the native Swift code in `macos/UsageMeter.swift`; no Python runtime is needed on the user's Mac.

The limits are shared account limits, not the tokens of a single conversation. Credit balances are shown only when the account reports them.

## Repository layout

- `macos/UsageMeter.swift` — the application (AppKit, IOKit, SystemConfiguration), including the native limits reader.
- `macos/Resources/` — application icon, Czech and English strings.
- `scripts/build_macos.sh` — builds and ad-hoc signs the `.app` into a folder you choose.
- `scripts/make_app_icon.sh` — regenerates the icon.
- `scripts/usage_meter.py` — reference implementation of the limits reader, kept for tests. It is not part of the app bundle.
- `tests/` — unit tests for the reader and for the compiled Swift adapter.
- `docs/` — project documentation (status, architecture, backlog, decisions, release process).

## Build and test

```sh
python3 -m unittest discover -s tests -v
sh scripts/build_macos.sh /path/to/an/empty/output/folder
sh scripts/make_dmg.sh "/path/to/Usage Meter Pure.app" /path/to/output-folder Usage-Meter-Pure-0.6.1-build10
```

The tests compile the Swift code with `xcrun swiftc`, so Command Line Tools are needed on the build machine only. End users need none of them.

## Privacy

The app sends nothing over the network itself. It reads the account limits through the local Codex app-server. See [INSTALLATION.md](INSTALLATION.md) for installation and Gatekeeper notes.

## Reporting bugs

Please use the [issue tracker](https://github.com/morfin83/usage-meter-pure/issues) and the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md).
