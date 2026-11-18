#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Usage: .github/ci/retry.sh COMMAND [ARGUMENT]...
#
# Run a step that fetches from upstream Git hosts (dependencies/prepare.sh,
# kernel/mainline-6.18/scripts/prepare-source.sh) again when it fails: hosts
# such as git.savannah.gnu.org or gitlab.freedesktop.org answer 502/503 for a
# few minutes at a time. Five attempts, waiting 30 s, 1, 2 and 4 min between
# them; the scripts resume from what their Git cache already holds.
set -u
attempt=1
delay=30
while :; do
	"$@" && exit 0
	status=$?
	[ "$attempt" -lt 5 ] || {
		printf '%s\n' "retry.sh: $1 failed $attempt times; giving up" >&2
		exit "$status"
	}
	printf '%s\n' "::warning::$1 failed (attempt $attempt, status $status); retrying in ${delay}s" >&2
	sleep "$delay"
	attempt=$((attempt + 1))
	delay=$((delay * 2))
done
