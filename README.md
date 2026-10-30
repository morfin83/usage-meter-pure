# PURE

This repository contains the Studio Pure Sound web and the Usage Meter Pure macOS application, together with their shared build and release workflow.

## Web

- Production: <https://www.studiopuresound.cz/>
- Hosting: Cloudflare Pages
- Pages project: `studiopuresound`

The static web source is in `web/src/`, public build inputs are in `web/public/`, and the generator is `web/build.py`. The generated `web/dist/` directory is deliberately not committed.

```sh
python3 web/build.py
python3 -m unittest discover -s web/tests -v
```

## Usage Meter Pure

- Current version: 0.6.1 RC2 (release candidate, not yet published)
- Build: 9
- Last published release: 0.6.0, build 8
- Bundle identifier: `cz.pure.usagemeter`

The application source is `macos/UsageMeter.swift`; its resources and build helpers are in `macos/Resources/` and `scripts/`.

```sh
python3 -m unittest discover -s tests -v
sh scripts/build_macos.sh
```

`create_release.command` prepares the signed `.app` in the local release staging area. `create_release_dmg.command` packages the verified application as the standard drag-and-drop DMG. Release DMGs are not committed to Git; obtain the matching Git release asset or protected backup when reproducing a production web build.

## Release

Release history and integrity information live in [RELEASES.md](RELEASES.md). The 0.6.0 production release uses Usage Meter Pure build 8 and is deployed on Cloudflare Pages.

## Privacy

The web uses a minimal set of external mechanisms and currently has no marketing tracking. The production privacy page describes the active implementation.

## Licence

Usage Meter Pure is released under the MIT License. See [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
