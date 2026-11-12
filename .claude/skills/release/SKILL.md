---
name: release
description: Ship a new EJAJ version. Bumps the version in Resources/Info.plist, adds a CHANGELOG entry, packages and signs EJAJ.app, installs it over the running copy and commits. Use when the user wants a change "in the app", a new build, or a release.
---

# Release EJAJ

1. **Version.** Read the current one from `Resources/Info.plist`. Raise `CFBundleShortVersionString` (patch for fixes and small additions, minor for a new panel or feature) and add 1 to `CFBundleVersion`, which is a plain build counter (1.8.1 is build 17).

   ```bash
   /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.8.2' -c 'Set :CFBundleVersion 18' Resources/Info.plist
   ```

2. **Changelog.** Add an entry at the top of `CHANGELOG.md`: `## 1.8.2 (YYYY-MM-DD)`, then what changed for someone using the app, then a short line on how it was checked. Say what was not checked, too. Clicks in the running app usually can't be exercised from a session.

3. **Readme.** If the change is visible in the app, update the matching part of the tutorial in `README.md`. `scripts/package.sh` ships the README inside the zip.

4. **Package and install.**

   ```bash
   scripts/package.sh                                  # build/EJAJ.app and build/EJAJ-macOS.zip only
   scripts/package.sh --install /path/to/EJAJ.app     # also replace that copy and relaunch it
   ```

   Find the copy the user runs with `pgrep -fl 'EJAJ.app/Contents/MacOS/EJAJ'`. Install there and nowhere else. `--install` quits EJAJ, replaces the bundle and opens it again, so tell the user the app restarts. The script refuses a path whose bundle identifier is not `local.tadeas.ejaj`.

5. **Check** that it came back up: `pgrep -fl EJAJ.app` should list the installed path.

6. **Commit** the source change, the plist, the changelog and the readme together. The message title names the change and ends with the version in brackets, for example `Compare the calendar week with the average week (1.8.1)`. Commits are GPG-signed through the user's global git config. Don't turn signing off. If gpg asks for the YubiKey PIN, let the user enter it.

7. **Publish on GitHub.** Other people update from inside the app, and it only sees GitHub releases, so a version isn't out for them until it is published. Publishing pushes `main` and creates a public release, so ask the user first, every time.

   ```bash
   git push origin main
   scripts/publish.sh "Short title of the change"
   ```

   `scripts/publish.sh` refuses a dirty tree or an unpushed `main`, packages again from that clean HEAD, tags `v<version>` and attaches the zip, with that version's CHANGELOG entry as the notes. Check with `gh release view v<version>` that the zip is attached; GitHub adds its SHA-256 digest, which the app's updater checks.

The signature is ad hoc (`codesign --sign -`). The app is for this Mac and isn't notarized.
