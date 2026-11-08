#!/bin/bash
# ci_prune_artifacts.sh -- free the repository's Actions artifact storage before an upload. GitHub stops every upload once the
# quota is hit ("Artifact storage quota has been hit"), and it only recounts every 6-12 hours, so old artifacts are deleted here:
# every artifact from other runs, except the newest KEEP_PACKAGES Husk-* packages (the IPAs people download).
# Needs GH_TOKEN with actions:write and GITHUB_REPOSITORY / GITHUB_RUN_ID (set in Actions). Never fails the build.
set -uo pipefail
KEEP="${KEEP_PACKAGES:-2}"
REPO="${GITHUB_REPOSITORY:?}"; RUN="${GITHUB_RUN_ID:?}"
list="$(gh api --paginate "repos/$REPO/actions/artifacts?per_page=100" \
        --jq '.artifacts[] | select(.expired == false) | [.id, .name, (.workflow_run.id // 0), .created_at, .size_in_bytes] | @tsv' 2>/dev/null)" \
    || { echo "prune: could not list artifacts (token without actions:write?); nothing deleted"; exit 0; }
[ -n "$list" ] || { echo "prune: no artifacts"; exit 0; }
keep_ids="$(printf '%s\n' "$list" | awk -F'\t' '$2 ~ /^Husk-/' | sort -t$'\t' -k4,4r | head -n "$KEEP" | cut -f1)"
freed=0; n=0
while IFS=$'\t' read -r id name run created size; do
    [ "$run" = "$RUN" ] && continue
    if printf '%s\n' "$keep_ids" | grep -qx "$id"; then echo "prune: keeping $name ($created)"; continue; fi
    if gh api -X DELETE "repos/$REPO/actions/artifacts/$id" >/dev/null 2>&1; then
        n=$((n + 1)); freed=$((freed + size)); echo "prune: deleted $name ($created, $((size / 1048576)) MiB)"
    else echo "prune: could not delete $name"; fi
done <<< "$list"
echo "prune: $n artifacts deleted, $((freed / 1048576)) MiB freed (GitHub recounts the quota within hours; deleting still lets new uploads through sooner)"
exit 0
