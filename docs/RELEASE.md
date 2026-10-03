# Cutting a release

```sh
# edit VERSION, commit
scripts/release.sh             # DMG (+ notarized if possible), Sparkle signature, appcast, cask
```

`VERSION` is the single source of truth and `release.sh` bumps nothing. It builds through
`make-dmg.sh` → `make-app.sh`, so what a stranger downloads is what `./install.sh` runs here. It
runs `notarize.sh` when a Developer ID and the notary profile both exist, and otherwise ships the
ad-hoc DMG under a loud banner. Then it signs the DMG with Sparkle's `sign_update`, puts the entry
for this version at the top of `packaging/appcast.xml` (replacing one from an earlier run), and
writes `version` and `sha256` into `packaging/homebrew/Casks/agent-island.rb`.

It does not publish. That is, in this order — the appcast last, or Sparkle offers a 404:

1. `git tag v<VERSION> && git push --tags`, and attach `dist/AgentIsland-<VERSION>.dmg` to the
   GitHub release of that tag (the URL in the appcast and cask is built from it).
2. Copy the cask into the `Tiwari1999/homebrew-tap` repo as `Casks/agent-island.rb` and push.
3. Upload `packaging/appcast.xml` to `https://agentisland.in/appcast.xml`, then commit it here.

Building blocks, still usable alone: `scripts/make-dmg.sh` (unsigned DMG), `scripts/notarize.sh`.

## Sparkle key (once, before the first release)

Updates are only accepted when signed by the private half of the key whose public half is
inside the app. Lose it and every installed copy is stranded on its version.

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys      # private key -> login keychain
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p   # prints the public key
```

Put the public key in `packaging/sparkle-public-ed-key` (its only home) and commit it. Back up the
private key with `generate_keys -x <file>` somewhere that is not this repo. `release.sh` signs from
the keychain by default, or from `SPARKLE_PRIVATE_KEY_FILE=<file>` / `SPARKLE_PRIVATE_KEY=<secret>`
(piped on stdin, never on the command line). It refuses to run while the placeholder is there.
Until then builds still work: their updater is simply off, and Settings says so.

## Today: unsigned

There is no Apple Developer Program membership, so the build is ad-hoc signed. Two consequences,
both of which the DMG's "Read me first" already tells the user about:

- **Gatekeeper refuses a double-click.** The first launch has to be right-click → Open → Open.
- **The Accessibility grant is dropped on every rebuild.** macOS keys that permission to the code
  signature, and an ad-hoc signature changes with the binary. Only the ⌘V fallback for idle Warp
  sessions needs it, so most people never see this.

Do not paper over either with `xattr -d com.apple.quarantine` instructions. Teaching strangers to
strip quarantine off downloaded binaries is a bad habit to hand out, and it is the notarization
that is missing, not the user's judgement.

## The day the Apple account exists

1. **Membership** — developer.apple.com, $99/yr. An individual account is enough; `io.github.…`
   does not need an organisation.
2. **Certificate** — Certificates → + → *Developer ID Application*. Download, double-click to
   install into the login keychain. `security find-identity -v -p codesigning` should now list it,
   and `make-app.sh` picks it up with no change.
3. **App-specific password** — appleid.apple.com → Sign-In and Security → App-Specific Passwords.
   Not the Apple ID password.
4. **Store the credentials once:**
   ```sh
   xcrun notarytool store-credentials agentisland \
     --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
   ```
5. **Build:** `scripts/release.sh` now takes the notarized path on its own (it runs
   `scripts/notarize.sh`, which can also be run alone). It rebuilds the DMG (so the Developer ID signature is inside
   it, not just around it), submits, waits, staples, and validates.
6. **Check it as a stranger would**, ideally on another Mac:
   ```sh
   spctl -a -t open --context context:primary-signature -vv dist/AgentIsland-<VERSION>.dmg
   ```

`notarize.sh` refuses with instructions rather than half-doing the job — a half-notarized DMG
fails on the user's machine instead of on yours.

## Homebrew cask

`packaging/homebrew/Casks/agent-island.rb` is the template for the tap; `release.sh` fills it.
`brew uninstall` runs the bundled `uninstall-hooks.py` before removing the app (brew also does on
`reinstall`, after which the app's welcome re-adds the hooks), and `--zap` clears preferences.
Until notarization, brew users get the same right-click → Open on first launch as DMG users.

## Auto-update

Sparkle 2, linked as SPM's binary xcframework (no Xcode needed), embedded by `make-app.sh` in
`Contents/Frameworks` and signed inside-out. `Updater.swift` starts it only when the bundle holds a
real public key. It checks `SUFeedURL` (`https://agentisland.in/appcast.xml`) on its own daily
timer, in-process and never on the refresh path, and always asks before installing. Settings has
the off switch; the menu-bar icon's right-click menu has *Check for Updates…*.
