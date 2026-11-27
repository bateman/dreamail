#!/usr/bin/env bash
# Runs the whole CI workflow (a manual run: build, unit tests and all the UI
# shards) on REF, whose head is SHA, waits for it, and prints the run id on
# stdout. With --reuse, a manual run that already passed on SHA counts and
# nothing is started. Used by the Integrate dreamail-openpgp workflow for
# main (the baseline) and for its branch. Needs gh with GH_TOKEN and GH_REPO.
#
# Usage: .github/scripts/run-ci.sh [--reuse] REF SHA
# Exit status: 0 CI passed, 1 CI failed, 2 the run could not be started,
# found or followed to its end.
set -euo pipefail

reuse=false
if [ "${1:-}" = "--reuse" ]; then
  reuse=true
  shift
fi
ref=${1:?usage: run-ci.sh [--reuse] REF SHA}
sha=${2:?usage: run-ci.sh [--reuse] REF SHA}

runs() {
  gh run list --workflow ci.yml --event workflow_dispatch --commit "$sha" --limit 50 \
    --json databaseId,status,conclusion --jq "$1"
}

if [ "$reuse" = true ]; then
  passed=$(runs '[.[] | select(.status == "completed" and .conclusion == "success")][0].databaseId // empty')
  if [ -n "$passed" ]; then
    echo "A manual CI run already passed on $ref ($sha): run $passed." >&2
    echo "$passed"
    exit 0
  fi
fi

# The dispatch returns no run id: the new run is the one that was not there
# before (no clock comparison).
before=$(runs '[.[].databaseId] | map(tostring) | join(" ")')
gh workflow run ci.yml --ref "$ref" >&2 || exit 2
run=""
for _ in $(seq 1 60); do
  sleep 5
  run=$(runs "[.[].databaseId | tostring | select(. as \$id | \"$before\" | split(\" \") | index(\$id) | not)][0] // empty")
  if [ -n "$run" ]; then
    break
  fi
done
if [ -z "$run" ]; then
  echo "Could not find the CI run started on $ref ($sha)." >&2
  exit 2
fi

echo "CI on $ref: run $run." >&2
echo "$run"
if gh run watch "$run" --exit-status --interval 30 > /dev/null; then
  exit 0
fi
# A failed watch is a red run only if the run itself says so; an API error
# or a run still going is "could not follow it".
conclusion=$(gh run view "$run" --json conclusion --jq .conclusion || true)
case "$conclusion" in
  failure|timed_out|cancelled|action_required|startup_failure) exit 1 ;;
  *) echo "CI run $run: could not follow it to its end (conclusion '$conclusion')." >&2; exit 2 ;;
esac
