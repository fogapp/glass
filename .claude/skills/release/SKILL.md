---
name: release
description: Publish Glass's current main to the public GitHub repo (fogapp/glass) as a single commit, without the private git history.
disable-model-invocation: true
---

# Release: publish to public GitHub

Glass's private history lives on gitea.lan. This publishes main's tree to
`github.com/fogapp/glass` as one commit: `Initial public release` the first
time, `Sync YYYY-MM-DD` after that. Private commits, subjects and authors stay
private.

All of the mechanics live in `bin/publish-public`. Never run `commit-tree` or
`git push` to the public repo by hand: a raw push of `main` uploads the entire
history, and that can't be taken back.

## 0. Preconditions

- This clone names the public identity the commit is made under — never the
  owner's personal git identity:

  ```
  git config --get glass.publicAuthorName
  git config --get glass.publicAuthorEmail
  ```

  If either is empty, **stop** and ask the user to choose and set them. Don't
  pick values yourself. The script refuses without them.
- `~/.ssh/fog_ed25519` (fogapp's key) exists; the script pushes with it.
- `github.com/fogapp/glass` exists. If the script says it can't reach it, the
  user creates it (empty, no README/license) while logged in as fogapp:
  `gh repo create fogapp/glass --public` after
  `gh auth switch --hostname github.com --user fogapp`. Don't create it
  unasked.

## 1. Dry run

```
bin/publish-public
```

This changes nothing on GitHub. If it stops, report why and don't work around it:

- **Dirty tree, untracked files, or main differs from origin:** tell the user;
  don't commit or push to fix it unasked.
- **`public/main` has commits this script didn't make:** someone changed the
  public repo. They need bringing into `main` first, or the sync erases them.
- **Secret scan hit:** go to step 2 before anything else.
- **"binary files over … that aren't images, fonts or icons":** tell the user
  which file; don't publish it and don't delete it.
- **"nothing to publish":** public already matches main; say so and stop.

## 2. Read what's going public

The scan only recognises common credential formats, so read the change too:

```
git diff --stat public/main HEAD
git diff public/main HEAD -- <anything that looks sensitive>
```

(On the first publish there's no `public/main`; review `git ls-files`.)

Look for credentials the scan can't recognise (a real `glass_` or
`glass_ing_` token, an `AR_ENCRYPTION_*` value), and for anything that maps
the household or its machines:

- the production domain or any real hostname, and LAN or VPN addresses
  that are the home network's own (the Gitea host, a Tailscale address) —
  in the demo fleet (`lib/demo/`), spec and test fixtures, the conformance
  kit (`spec/fixtures/ingest/`) or comments;
- operational detail from the running fleet: measured memory or swap,
  dates of incidents, the names of private sibling apps' code or their
  audits, sealed apps by name;
- design proposals or write-ups under `docs/` (only
  `docs/ingest-protocol.md` belongs there), and references to them;
- new files never meant to be public.

Generic placeholders are known and fine: `*.example.net`, `*.example`,
`*.test`, `files.lan`, `192.168.1.x` and `10.x` example addresses, the
`100.64.0.0/10` examples in the origin tests, `dev@glass.test` with
`glass-dev-password`, and the fleet's app names (`hook`, `aio`, …) used as
example app names. A new address or name that reveals something more isn't
fine.

If anything is doubtful, stop and show the user the path and why, without
repeating a secret's value. Pass `--accept-findings` only once the user, or
your reading of the match, shows it's a false positive, and say which you
accepted.

## 3. Publish

```
bin/publish-public --push
```

Invoking `/release` is the user's go-ahead for this step, as long as step 2
was clean.

## 4. Report

Give the commit message and SHA the script printed, the file count from the
diff, and any accepted findings. Say it's published only if the script printed
`published "…" as <sha>`. If a secret reached GitHub, tell the user to rotate
it: a force-push doesn't undo the exposure.
