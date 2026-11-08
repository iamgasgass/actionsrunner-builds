#!/bin/bash
# ci_prune_handover.sh -- delete the Actions cache entries earlier runs used to pass files between jobs (husk-handover-<run>,
# husk-packages-<run>), keeping this run's. They would otherwise sit in the 10 GB cache, pushing out the runtime and image
# caches that save an hour a build. Needs GH_TOKEN with actions:write. Never fails the build.
set -uo pipefail
REPO="${GITHUB_REPOSITORY:?}"; RUN="${GITHUB_RUN_ID:?}"
keys="$(gh api --paginate "repos/$REPO/actions/caches?per_page=100" --jq '.actions_caches[] | .key' 2>/dev/null)" \
    || { echo "prune: could not list caches; nothing deleted"; exit 0; }
n=0
while read -r k; do
    case "$k" in
        husk-handover-"$RUN"|husk-packages-"$RUN") continue ;;
        husk-handover-*|husk-packages-*)
            gh api -X DELETE "repos/$REPO/actions/caches?key=$k" >/dev/null 2>&1 && { n=$((n + 1)); echo "prune: deleted cache $k"; } ;;
    esac
done <<< "$keys"
echo "prune: $n old hand-over cache entries deleted"
exit 0
