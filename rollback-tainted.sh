#!/usr/bin/env bash
# Roll back any local branch whose TIP commit introduced or removed a given
# fixed string. For each affected branch, walks back through history to the
# most recent ancestor that didn't touch the string's count, resets the local
# branch there, and force-pushes.
#
# Drop into any git clone:
#   cd /path/to/repo
#   /path/to/rollback-tainted.sh <search-string>
#
# Behavior:
#   - Uses `git log -S<string> --all` (pickaxe, fixed string) to find tainted
#     commits — commits whose diff changed the number of occurrences of the
#     string (i.e. commits that introduced or removed it). Doesn't match
#     commits that only mentioned the string in unchanged context lines.
#   - Only considers LOCAL branches that also exist on origin (rolling back a
#     local-only branch would create a remote branch, not undo anything).
#   - Skips a branch if its tip is NOT tainted, even when an ancestor is —
#     dropping a buried commit needs `git rebase -i`, not a reset, because
#     reset would also lose any legitimate work on top.
#   - Skips the currently checked-out branch (git refuses to force-update
#     HEAD's own ref).
#   - Requires interactive 'yes' after showing the plan.
#   - Uses --force-with-lease so a concurrent push to origin will reject.

set -uo pipefail

DRY_RUN=0
NEEDLE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help)
      cat <<HELP
Usage: $0 [--dry-run|-n] <search-string>

  --dry-run, -n   Show the plan but don't update refs or push.
HELP
      exit 0
      ;;
    *) NEEDLE="$arg" ;;
  esac
done

if [[ -z "$NEEDLE" ]]; then
  echo "Usage: $0 [--dry-run|-n] <search-string>" >&2
  exit 64
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: not in a git repository." >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "Error: no 'origin' remote configured." >&2
  exit 1
fi

echo "Fetching origin ..."
git fetch --prune origin >/dev/null 2>&1 || true

TAINTED_FILE=$(mktemp)
ACTIVITY_FILE=""
cleanup() { rm -f "$TAINTED_FILE" "${ACTIVITY_FILE:-}"; }
trap cleanup EXIT

# If origin is on GitHub and gh is installed, pull the repo's activity log so
# we can recover the EXACT pre-force-push SHA for each tainted branch (parent
# walking is wrong when the attacker amended a commit — see header notes).
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
OWNER_REPO=""
if command -v gh >/dev/null 2>&1; then
  # Match github.com[:/]owner/repo with optional .git suffix.
  OWNER_REPO=$(printf '%s' "$ORIGIN_URL" | sed -nE 's#.*github\.com[:/]+([^/]+/[^/]+)$#\1#p')
  OWNER_REPO="${OWNER_REPO%.git}"
fi
if [[ -n "$OWNER_REPO" ]]; then
  echo "Fetching GitHub activity log for $OWNER_REPO ..."
  ACTIVITY_FILE=$(mktemp)
  if ! gh api --paginate "/repos/$OWNER_REPO/activity" --jq '.[]?' > "$ACTIVITY_FILE" 2>/dev/null; then
    echo "  (activity API unavailable — will rely on local reflog only)"
    ACTIVITY_FILE=""
  fi
fi

echo "Searching all refs for commits that changed the count of: $NEEDLE"
git log -S"$NEEDLE" --all --format=%H 2>/dev/null > "$TAINTED_FILE"

TAINTED_COUNT=$(wc -l < "$TAINTED_FILE" | tr -d ' ')
if [[ "$TAINTED_COUNT" -eq 0 ]]; then
  echo "No commits in this repo introduced or removed '$NEEDLE'. Nothing to do."
  exit 0
fi

echo "Found $TAINTED_COUNT tainted commit(s) reachable from some ref."
echo

CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
REMOTE_BRANCHES=()
while IFS= read -r b; do
  # b looks like "origin/main", "origin/feature-x", or "origin/HEAD"
  [[ -z "$b" ]] && continue
  [[ "$b" == "origin/HEAD" ]] && continue
  REMOTE_BRANCHES+=("${b#origin/}")
done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin/)

is_tainted() { grep -qFx -- "$1" "$TAINTED_FILE"; }

# Find the SHA the branch was at BEFORE the force-push that put the current
# (tainted) tip there. This is NOT the parent of the tainted commit — for an
# amend-force-push the malicious commit and the legitimate one are siblings
# with the same parent. The correct source is GitHub's force-push audit log
# (.before of the activity entry where .after == current tip). Falls back to
# the local reflog of the remote-tracking ref.
find_pre_attack_sha() {
  local branch="$1"
  local current_tip="$2"
  local sha=""

  # Method 1: GitHub activity API.
  if [[ -n "$ACTIVITY_FILE" && -s "$ACTIVITY_FILE" ]]; then
    sha=$(jq -r --arg ref "refs/heads/$branch" --arg after "$current_tip" '
            select(.activity_type == "force_push" and .ref == $ref and .after == $after)
            | .before
          ' "$ACTIVITY_FILE" | head -n 1)
    if [[ -n "$sha" && "$sha" != "null" ]] && ! is_tainted "$sha"; then
      echo "$sha"
      return 0
    fi
  fi

  # Method 2: local reflog of the remote-tracking ref.
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == "$current_tip" ]] && continue
    if ! is_tainted "$entry"; then
      echo "$entry"
      return 0
    fi
  done < <(git log -g --format='%H' "refs/remotes/origin/$branch" 2>/dev/null)

  return 1
}

PLAN=()
SKIPPED_BURIED=()
SKIPPED_NO_GOOD_SHA=()
for branch in "${REMOTE_BRANCHES[@]}"; do
  remote_ref="refs/remotes/origin/$branch"
  tip=$(git rev-parse "$remote_ref")
  if is_tainted "$tip"; then
    if good=$(find_pre_attack_sha "$branch" "$tip"); then
      PLAN+=("$branch|$tip|$good")
    else
      SKIPPED_NO_GOOD_SHA+=("$branch: tip $tip is tainted, but no pre-attack SHA found in activity log or reflog")
    fi
  else
    # Check if any ancestor is tainted (buried).
    while IFS= read -r anc; do
      if is_tainted "$anc"; then
        SKIPPED_BURIED+=("$branch: tainted ancestor $anc is buried under clean tip $tip")
        break
      fi
    done < <(git rev-list "$remote_ref" 2>/dev/null)
  fi
done

if [[ ${#PLAN[@]} -eq 0 ]]; then
  echo "No remote branches have a tainted tip we can roll back. Nothing to do."
  if [[ ${#SKIPPED_BURIED[@]} -gt 0 ]]; then
    echo
    echo "Heads up — tainted commits are buried in these branches:"
    for s in "${SKIPPED_BURIED[@]}"; do echo "  $s"; done
    echo "Use \`git rebase -i\` to drop them; this script won't do it automatically."
  fi
  if [[ ${#SKIPPED_NO_GOOD_SHA[@]} -gt 0 ]]; then
    echo
    echo "Heads up — tainted tips with no recoverable pre-attack SHA:"
    for s in "${SKIPPED_NO_GOOD_SHA[@]}"; do echo "  $s"; done
    echo "Find the SHA manually (GitHub Activity tab or 'git reflog show refs/remotes/origin/<branch>')"
    echo "then run: git push --force-with-lease origin <sha>:refs/heads/<branch>"
  fi
  exit 0
fi

echo "Plan (${#PLAN[@]} branches):"
echo
for entry in "${PLAN[@]}"; do
  IFS='|' read -r branch tip clean <<<"$entry"
  local_note=""
  if git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    if [[ "$branch" == "$CURRENT_BRANCH" ]]; then
      local_note="  (local copy exists and is CHECKED OUT — origin will be rolled back; run 'git reset --hard origin/$branch' afterwards)"
    else
      local_note="  (local copy exists — will also be reset)"
    fi
  fi
  echo "  $branch$local_note"
  echo "    origin tip:   $tip"
  echo "    rollback to:  $clean"
  echo "    will remove from branch history:"
  git log --oneline "${clean}..${tip}" 2>/dev/null | sed 's/^/      /'
  echo
done

if [[ ${#SKIPPED_BURIED[@]} -gt 0 ]]; then
  echo "Not in plan (tainted commits buried under a clean tip — needs rebase, not reset):"
  for s in "${SKIPPED_BURIED[@]}"; do echo "  $s"; done
  echo
fi

echo "For each branch in plan, will run:"
echo "  git push --force-with-lease=refs/heads/<branch>:<tip> origin <clean>:refs/heads/<branch>"
echo "  (and update local ref if one exists and isn't checked out)"
echo

if (( DRY_RUN )); then
  echo "[dry-run] No refs updated and nothing pushed. Re-run without --dry-run to apply."
  exit 0
fi

read -r -p "Type 'yes' to proceed: " ANSWER
if [[ "$ANSWER" != "yes" ]]; then
  echo "Aborted. No changes pushed."
  exit 1
fi

for entry in "${PLAN[@]}"; do
  IFS='|' read -r branch tip clean <<<"$entry"
  echo
  echo "Rolling back $branch: $tip -> $clean"
  # Make sure the target SHA is in our local object DB (it may be a dangling
  # SHA on GitHub that we never fetched).
  if ! git cat-file -e "${clean}^{commit}" 2>/dev/null; then
    if ! git fetch origin "$clean" 2>/dev/null; then
      echo "  cannot fetch $clean from origin (GC'd?); skipping"
      continue
    fi
  fi
  if git push --force-with-lease="refs/heads/$branch:$tip" origin "$clean:refs/heads/$branch"; then
    echo "  origin updated"
  else
    echo "  push failed (branch protection? concurrent push? auth?)"
    continue
  fi
  # Sync local ref if it exists and isn't currently checked out.
  if git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    if [[ "$branch" == "$CURRENT_BRANCH" ]]; then
      echo "  local '$branch' is checked out — leaving it alone; run: git reset --hard origin/$branch"
    else
      git branch -f "$branch" "$clean" >/dev/null && echo "  local ref synced"
    fi
  fi
done

echo
echo "Done. Dropped commits still exist on GitHub as dangling SHAs."
