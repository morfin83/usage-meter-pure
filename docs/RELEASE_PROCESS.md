# Release process

Each step needs the owner's approval where marked. Nothing here publishes anything by itself.

1. **Branch and tests.** Work on a branch. `python3 -m unittest discover -s tests -v` must pass.
2. **Version.** Change `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/build_macos.sh`; keep them equal to the version in `README.md`, `RELEASES.md` and `INSTALLATION.md`.
3. **Build.** `sh scripts/build_macos.sh <empty folder outside the repo>`. The script deletes the target folder first.
4. **Verify.** `codesign --verify --deep --strict`, `plutil -p` on `Info.plist`, `lipo -archs`, `--usage-check` against a real Codex install (read-only).
5. **DMG.** Create with a drag-and-drop layout including an Applications link. The DMG script is not in this repository yet (see BACKLOG #6). Never commit it.
6. **Checksum.** `shasum -a 256` on the final DMG; record it in `RELEASES.md` and `INSTALLATION.md`. Recompute after every copy.
7. **Clean-machine test.** On macOS 13+ without developer tools. NEOVĚŘENO until done.
8. **Approval gate.** Owner approves the release (tag, GitHub release, public DMG, website update). Until then the state is "release candidate".
9. **Backup.** Save the DMG, checksum file, docs and the release notes to a folder outside the repository.
