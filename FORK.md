# Keeping this fork in sync with upstream

This repository is a fork of [PortSwigger/mcp-server](https://github.com/PortSwigger/mcp-server).

| Remote     | URL                                              | Role                                  |
| ---------- | ------------------------------------------------ | ------------------------------------- |
| `origin`   | `git@github.com:bgoodspeed/mcp-server.git`       | This fork — where our work lives      |
| `upstream` | `https://github.com/PortSwigger/mcp-server.git`  | PortSwigger's repo — read-only for us |

## One-time setup

If `git remote -v` does not list `upstream`:

```sh
git remote add upstream https://github.com/PortSwigger/mcp-server.git
git fetch upstream
```

## Routine sync

```sh
./scripts/sync-upstream.sh
```

That script:

1. refuses to run with a dirty working tree,
2. adds the `upstream` remote if it is missing, then fetches it,
3. lists the incoming upstream commits,
4. merges `upstream/main` into local `main`,
5. runs `./gradlew test`,
6. prints what the sync changed and what this fork still carries on top of upstream.

Nothing is pushed unless you ask for it:

```sh
./scripts/sync-upstream.sh --push
```

Useful flags:

| Flag                       | Effect                                                     |
| -------------------------- | ---------------------------------------------------------- |
| `-b, --branch <name>`      | Sync a branch other than `main`                             |
| `-u, --upstream-branch`    | Track an upstream branch other than `main`                  |
| `--rebase`                 | Rebase onto upstream instead of merging (rewrites history)  |
| `--skip-tests`             | Skip `./gradlew test`                                       |
| `--push`                   | Push to `origin` on success (force-with-lease under rebase) |

### Doing it by hand

```sh
git fetch upstream
git checkout main
git merge upstream/main      # or: git rebase upstream/main
./gradlew test
git push origin main
```

## Merge or rebase?

**Merge is the default and the right choice for `main`.** `main` is already
pushed to `origin` and has a merge commit (`c91ba5f`) in its history, so rebasing
it rewrites published history and forces everyone to re-clone or reset.

Use `--rebase` only on unpublished feature branches, to get a clean diff before
opening a PR upstream.

## What this fork changes

Check at any time with:

```sh
git diff --stat upstream/main...HEAD
```

As of the last sync, the fork-local changes are:

- `src/main/kotlin/net/portswigger/mcp/tools/Tools.kt` — extra tools: BCheck
  support, Bambda, request tagging/tag lookup, and tag search
- `src/test/kotlin/net/portswigger/mcp/tools/ToolsKtTest.kt` — tests for the above
- `INSTALL.md` — build/install notes

All of it is additive, which is why syncs have been cheap so far.

## Conflicts

`Tools.kt` is the one real conflict hot spot — both sides register tools in the
same file, and upstream refactors it regularly. When it conflicts:

- Keep upstream's structure and re-apply our tool registrations on top of it,
  rather than keeping our whole version of the file. Upstream changes to
  registration helpers, serialization, or the credential filter must survive.
- Re-run `./gradlew test` afterwards. `ToolsKtTest.kt` is the safety net for our
  additions; upstream's own tests cover theirs.

Two files change on nearly every upstream release and should almost always
resolve **in upstream's favour** unless we are shipping our own build:

- `gradle.properties` (`version=`)
- `BappManifest.bmf` / `BappDescription.html` (BApp Store metadata)

Recovery, at any point mid-conflict:

```sh
git merge --abort     # or: git rebase --abort
```

## Sending changes back upstream

Work from a branch cut off `upstream/main`, not off our `main` — that keeps
unrelated fork commits out of the PR:

```sh
git fetch upstream
git checkout -b my-feature upstream/main
# ... commits ...
git push origin my-feature
gh pr create --repo PortSwigger/mcp-server --base main --head bgoodspeed:my-feature
```

## Cadence

Upstream ships BApp releases every few weeks. Syncing at least that often keeps
`Tools.kt` conflicts small; letting the fork drift for months is what makes them
painful. CI (`.github/workflows/ci.yml`) runs tests and builds the extension JAR
on every push to `main`, so a sync that breaks the build is caught on push even
if you skipped the local test run.
