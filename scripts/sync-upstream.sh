#!/usr/bin/env bash
#
# Sync this fork with the PortSwigger upstream repository.
#
# Default behaviour: fetch upstream, merge upstream/main into the local branch,
# run the test suite, and report what changed. Nothing is pushed unless --push
# is given.
#
# See FORK.md for the full workflow, including conflict resolution.

set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/PortSwigger/mcp-server.git}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"

BRANCH="main"
UPSTREAM_BRANCH="main"
MODE="merge"
RUN_TESTS=1
DO_PUSH=0

usage() {
    cat <<'EOF'
Usage: scripts/sync-upstream.sh [options]

Options:
  -b, --branch <name>            Local branch to sync (default: main)
  -u, --upstream-branch <name>   Upstream branch to sync from (default: main)
      --rebase                   Rebase onto upstream instead of merging
      --skip-tests               Do not run ./gradlew test after syncing
      --push                     Push the synced branch to origin on success
  -h, --help                     Show this help

Environment overrides:
  UPSTREAM_REMOTE (default: upstream)
  UPSTREAM_URL    (default: https://github.com/PortSwigger/mcp-server.git)
  ORIGIN_REMOTE   (default: origin)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--branch) BRANCH="$2"; shift 2 ;;
        -u|--upstream-branch) UPSTREAM_BRANCH="$2"; shift 2 ;;
        --rebase) MODE="rebase"; shift ;;
        --skip-tests) RUN_TESTS=0; shift ;;
        --push) DO_PUSH=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"

# --- preflight ---------------------------------------------------------------

git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
    || die "local branch '$BRANCH' does not exist"

if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree is not clean. Commit or 'git stash' your changes first."
fi

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    info "adding remote '$UPSTREAM_REMOTE' -> $UPSTREAM_URL"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

# --- fetch -------------------------------------------------------------------

info "fetching $UPSTREAM_REMOTE"
git fetch --prune --tags "$UPSTREAM_REMOTE"

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git rev-parse --verify --quiet "$UPSTREAM_REF" >/dev/null \
    || die "'$UPSTREAM_REF' not found"

ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$ORIGINAL_BRANCH" != "$BRANCH" ]]; then
    info "checking out $BRANCH (was on $ORIGINAL_BRANCH)"
    git checkout "$BRANCH"
fi

BEFORE="$(git rev-parse HEAD)"

INCOMING="$(git rev-list --count "HEAD..$UPSTREAM_REF")"
if [[ "$INCOMING" -eq 0 ]]; then
    info "already up to date with $UPSTREAM_REF"
else
    info "$INCOMING new upstream commit(s):"
    git log --oneline --no-decorate "HEAD..$UPSTREAM_REF" | sed 's/^/    /'
fi

# --- integrate ---------------------------------------------------------------

if [[ "$INCOMING" -gt 0 ]]; then
    if [[ "$MODE" == "rebase" ]]; then
        info "rebasing $BRANCH onto $UPSTREAM_REF"
        if ! git rebase "$UPSTREAM_REF"; then
            cat >&2 <<EOF

Rebase stopped on conflicts. Resolve them, then:
    git add <files> && git rebase --continue
To abort and return to where you were:
    git rebase --abort
EOF
            exit 1
        fi
    else
        info "merging $UPSTREAM_REF into $BRANCH"
        if ! git merge --no-edit "$UPSTREAM_REF"; then
            cat >&2 <<EOF

Merge stopped on conflicts. Resolve them, then:
    git add <files> && git commit
To abort and return to where you were:
    git merge --abort
EOF
            exit 1
        fi
    fi
fi

AFTER="$(git rev-parse HEAD)"

# --- verify ------------------------------------------------------------------

if [[ "$RUN_TESTS" -eq 1 && "$BEFORE" != "$AFTER" ]]; then
    info "running ./gradlew test"
    ./gradlew --console=plain test \
        || die "tests failed after sync. Fix them before pushing (HEAD is now $AFTER, previous was $BEFORE)."
elif [[ "$RUN_TESTS" -eq 0 ]]; then
    warn "skipping tests (--skip-tests)"
fi

# --- report ------------------------------------------------------------------

if [[ "$BEFORE" != "$AFTER" ]]; then
    info "files changed by this sync:"
    git diff --stat "$BEFORE" "$AFTER" | sed 's/^/    /'
fi

info "fork-local changes relative to $UPSTREAM_REF:"
git diff --stat "$UPSTREAM_REF...HEAD" | sed 's/^/    /'

if [[ "$DO_PUSH" -eq 1 ]]; then
    if [[ "$MODE" == "rebase" ]]; then
        info "pushing $BRANCH to $ORIGIN_REMOTE (force-with-lease, rebase rewrote history)"
        git push --force-with-lease "$ORIGIN_REMOTE" "$BRANCH"
    else
        info "pushing $BRANCH to $ORIGIN_REMOTE"
        git push "$ORIGIN_REMOTE" "$BRANCH"
    fi
elif [[ "$BEFORE" != "$AFTER" ]]; then
    if [[ "$MODE" == "rebase" ]]; then
        info "done. Push with: git push --force-with-lease $ORIGIN_REMOTE $BRANCH"
    else
        info "done. Push with: git push $ORIGIN_REMOTE $BRANCH"
    fi
fi

if [[ "$ORIGINAL_BRANCH" != "$BRANCH" ]]; then
    warn "you are now on '$BRANCH' (started on '$ORIGINAL_BRANCH')"
fi
