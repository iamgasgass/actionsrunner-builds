#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Kept for compatibility with upstream WindowsiOS: works on every supported device now.
exec "$(cd "$(dirname "$0")" && pwd)/launch_on_device.sh" "$@"
