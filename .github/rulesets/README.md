# Rulesets

Version-controlled so branch protection is reviewable in a diff rather than remembered from a
settings page. GitHub does not read these automatically — import them once.

## Apply

Settings → Rules → Rulesets → **New ruleset → Import a ruleset**, and pick the JSON.

Or, authenticated as a repo admin:

```sh
gh api -X POST repos/Tiwari1999/Agent-Island/rulesets --input .github/rulesets/protect-main.json
gh api -X POST repos/Tiwari1999/Agent-Island/rulesets --input .github/rulesets/protect-release-tags.json
```

To fix the existing "Protect" ruleset in place instead of adding a second one:

```sh
gh api -X PUT repos/Tiwari1999/Agent-Island/rulesets/24241800 --input .github/rulesets/protect-main.json
```

## What they do, and what they deliberately do not

`protect-main` blocks force-pushes and deletion of the default branch. `protect-release-tags`
does the same for `v*`, so a published tag cannot be moved under a DMG someone already
downloaded.

Both cost nothing day to day: normal pushes and merges are unaffected.

Four rules are left out on purpose:

- **Require a pull request.** One maintainer cannot approve their own PR, so this means either
  never merging or bypassing every time — protection that is always waived teaches you to
  ignore it.
- **Require status checks.** There is no CI. `tests/selftest.py` reads live process state and
  needs the app running, so most of its 806 checks cannot pass on a runner as written. The
  parts that could — `--check-prompts`, `--check-proc`, and the hook contract tests, which are
  pure subprocess work — would make a real gate. That is the prerequisite, not the rule.
- **Require signed commits.** Nothing in this repo's history is signed; turning it on blocks the
  next push rather than improving anything already here.
- **Require linear history.** Merging reviewed PRs produces merge commits, which is how #3 and
  #4 landed. This would have refused them.
