#!/usr/bin/env bash
# Rebuild the `test` branch as: main + test-extras + every open PR to main that passes validation.
#
# The test console syncs from `test`, so this is how a PR's templates (and their install wizards) reach the
# console before the PR merges. `test` is REBUILT from main on every run rather than accumulating merges:
# a closed PR drops off, an updated PR replaces its old version, and a merged PR is not carried twice
# (squash-merge on main + its branch commits on test).
#
# Safety: before force-pushing, any non-merge commit on the current `test` that is not reachable from the
# rebuild, from main, or from a PR head this script merged in an earlier run is treated as a hand push and
# the run REFUSES to overwrite it. Put commits that must stay on `test` on the `test-extras` branch.
#
# Env:
#   REPO      owner/name (default: $GITHUB_REPOSITORY)
#   DRY_RUN   1 = build and report, never push or label (default 0)
#   GH_TOKEN  token for gh (contents:write, pull-requests:write, actions:read)
set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:?set REPO or GITHUB_REPOSITORY}}"
DRY_RUN="${DRY_RUN:-0}"
TEST_BRANCH="test"
EXTRAS_BRANCH="test-extras"
CONFLICT_LABEL=not-on-test-branch
MERGE_PREFIX="sync-test: merge"
REQUIRED_WORKFLOWS=("Validate Helm Charts" "Validate Catalog Entries")

summary() { echo "$*"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main"
has_test=0; has_extras=0
git fetch --quiet origin "+refs/heads/$TEST_BRANCH:refs/remotes/origin/$TEST_BRANCH" 2>/dev/null && has_test=1
git fetch --quiet origin "+refs/heads/$EXTRAS_BRANCH:refs/remotes/origin/$EXTRAS_BRANCH" 2>/dev/null && has_extras=1

git checkout --quiet -B sync-test-rebuild origin/main

summary "## Rebuild of \`$TEST_BRANCH\`"
summary ""
summary "- base: \`main\` @ $(git rev-parse --short origin/main)"

if [ "$has_extras" = 1 ]; then
  # test-extras is maintainer-owned content that must always be on test; a conflict here is a real
  # problem to fix by hand, not something to skip silently.
  if ! git merge --quiet --no-ff --no-edit -m "$MERGE_PREFIX $EXTRAS_BRANCH" "origin/$EXTRAS_BRANCH"; then
    git merge --abort || true
    summary "- **FAILED:** \`$EXTRAS_BRANCH\` does not merge cleanly onto main. Rebase it onto main and re-run."
    exit 1
  fi
  summary "- \`$EXTRAS_BRANCH\` @ $(git rev-parse --short "origin/$EXTRAS_BRANCH")"
fi

# A PR qualifies when every required validation workflow's LATEST pull_request run on its CURRENT head
# commit concluded success. An older head that passed does not count, and a workflow that has not run yet
# keeps the PR off until it has.
passes_validation() {
  local sha="$1" wf conclusion
  for wf in "${REQUIRED_WORKFLOWS[@]}"; do
    conclusion=$(gh api "repos/$REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=100" \
      --jq "[.workflow_runs[] | select(.name == \"$wf\")] | sort_by(.created_at) | last | .conclusion // \"missing\"")
    [ "$conclusion" = "success" ] || { echo "$wf=$conclusion"; return 1; }
  done
  return 0
}

merged=(); skipped=(); conflicted=()
prs=$(gh pr list --repo "$REPO" --base main --state open --limit 200 \
  --json number,title,headRefOid,isDraft,isCrossRepository \
  --jq 'sort_by(.number) | .[] | [.number, .headRefOid, .isDraft, .isCrossRepository, .title] | @tsv')

while IFS=$'\t' read -r num sha draft cross title; do
  [ -z "$num" ] && continue
  if [ "$draft" = "true" ]; then skipped+=("#$num (draft)"); continue; fi
  if [ "$cross" = "true" ]; then skipped+=("#$num (fork)"); continue; fi
  if ! why=$(passes_validation "$sha"); then skipped+=("#$num (validation: $why)"); continue; fi

  git fetch --quiet origin "+refs/pull/$num/head:refs/remotes/pr/$num"
  if [ "$(git rev-parse "refs/remotes/pr/$num")" != "$sha" ]; then
    skipped+=("#$num (head moved during the run; the next run picks it up)"); continue
  fi
  if git merge --quiet --no-ff --no-edit -m "$MERGE_PREFIX #$num $sha" -m "$title" "$sha"; then
    merged+=("#$num")
  else
    git merge --abort || true
    conflicted+=("$num")
  fi
done <<< "$prs"

summary ""
summary "**On test (${#merged[@]}):** ${merged[*]+${merged[*]}}"
summary ""
summary "**Conflicts, left off (${#conflicted[@]}):** $( [ ${#conflicted[@]} -gt 0 ] && printf '#%s ' "${conflicted[@]}" || echo none)"
summary ""
summary "**Not eligible (${#skipped[@]}):**"
for s in ${skipped[@]+"${skipped[@]}"}; do summary "- $s"; done

# Guard: never overwrite commits that exist only on test.
if [ "$has_test" = 1 ]; then
  known=(sync-test-rebuild origin/main)
  [ "$has_extras" = 1 ] && known+=("origin/$EXTRAS_BRANCH")
  # PR heads merged by earlier runs: the second parent of each of our merge commits on test.
  while read -r m; do known+=("$m^2"); done < <(git log --merges --format=%H --grep="^$MERGE_PREFIX" "origin/$TEST_BRANCH")
  unknown=$(git rev-list --no-merges "origin/$TEST_BRANCH" --not "${known[@]}")
  if [ -n "$unknown" ]; then
    summary ""
    summary "### REFUSED: \`$TEST_BRANCH\` has commits found nowhere else"
    summary ""
    summary "Rebuilding would delete them. Move them to \`$EXTRAS_BRANCH\` (or a PR) and re-run:"
    summary ""
    while read -r c; do summary "- $(git log -1 --format='%h %an: %s' "$c")"; done <<< "$unknown"
    exit 1
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  summary ""
  summary "Dry run: would push $(git rev-parse --short HEAD) to \`$TEST_BRANCH\`."
  exit 0
fi

# Labels: mark conflicting PRs, clear the label from every other PR that has it.
gh label create "$CONFLICT_LABEL" --repo "$REPO" --color D93F0B --force \
  --description "Conflicts with main or another open PR, so it is not on the test branch" >/dev/null
for num in ${conflicted[@]+"${conflicted[@]}"}; do gh pr edit "$num" --repo "$REPO" --add-label "$CONFLICT_LABEL" >/dev/null; done
gh pr list --repo "$REPO" --state open --label "$CONFLICT_LABEL" --json number --jq '.[].number' | while read -r num; do
  [[ " ${conflicted[*]+${conflicted[*]}} " == *" $num "* ]] || gh pr edit "$num" --repo "$REPO" --remove-label "$CONFLICT_LABEL" >/dev/null
done

if [ "$has_test" = 1 ] && [ "$(git rev-parse "origin/$TEST_BRANCH^{tree}")" = "$(git rev-parse 'HEAD^{tree}')" ]; then
  summary ""
  summary "\`$TEST_BRANCH\` already has this content; nothing pushed."
  exit 0
fi

# --force-with-lease: if someone pushed to test while this ran, fail instead of overwriting their push.
lease="$TEST_BRANCH:$( [ "$has_test" = 1 ] && git rev-parse "origin/$TEST_BRANCH" || echo '')"
git push --force-with-lease="$lease" origin "HEAD:refs/heads/$TEST_BRANCH"
summary ""
summary "Pushed $(git rev-parse --short HEAD) to \`$TEST_BRANCH\`."
