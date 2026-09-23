# Cutting a release

```sh
scripts/make-dmg.sh            # dist/AgentIsland-<VERSION>.dmg — works today, unsigned
scripts/notarize.sh            # the same thing, signed and stapled — needs an Apple account
```

`VERSION` is the single source of truth. Bump it, tag the commit `v<VERSION>`, attach the DMG to
the GitHub release. `scripts/make-app.sh` assembles the bundle for both the DMG and `./install.sh`,
so what a stranger downloads is what runs on the developer's own machine.

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
5. **Build:** `scripts/notarize.sh`. It rebuilds the DMG (so the Developer ID signature is inside
   it, not just around it), submits, waits, staples, and validates.
6. **Check it as a stranger would**, ideally on another Mac:
   ```sh
   spctl -a -t open --context context:primary-signature -vv dist/AgentIsland-<VERSION>.dmg
   ```

`notarize.sh` refuses with instructions rather than half-doing the job — a half-notarized DMG
fails on the user's machine instead of on yours.

## Homebrew cask

Worth doing only after notarization: a cask that installs an unsigned app hands the right-click
dance to every `brew install` user, which is worse than no cask. Once notarized, the cask is a
formula pointing at the GitHub release asset and its SHA.

## Auto-update

Deliberately not wired yet. Sparkle needs a signing key and a hosted appcast, and an auto-updater
that ships unsigned builds is a way to distribute anything to everyone who installed once. It
belongs immediately after notarization, not before.
