#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Fetch and unpack the prebuilt inputs of the Andarium IPA build.
#
# Usage: .github/ci/fetch-prebuilt.sh OUTPUT_DIR [SOURCE]...
#
# Each SOURCE is one archive (or one directory) and becomes OUTPUT_DIR/NNN.
# Sources may be separated by spaces, commas or new lines. A SOURCE is:
#
#   https://host/path/file.tar.zst          any URL curl can fetch
#   https://a/x.tar.001+https://a/x.tar.002 the parts of one split archive,
#                                           concatenated in the order given
#   gh-release:OWNER/REPO@TAG/ASSET         a release asset (GH_TOKEN or
#                                           PREBUILT_TOKEN for a private
#                                           repository); ASSET may be a glob
#   gh-release:OWNER/REPO@TAG               every asset of that release
#   path/in/the/checkout                    a local archive or directory
#
# Assets and local files named like the parts of a split archive
# (NAME.001, NAME.002 ... or NAME.part-aa, NAME.partab ...) are joined
# before unpacking. Archives may be tar (plain, gzip, bzip2, xz, zstd),
# zip or 7z; a directory is used as it is. What each unpacked tree holds
# is decided afterwards by .github/ci/place-prebuilt.py.
set -euf

fail()
{
	printf '%s\n' "fetch-prebuilt.sh: $*" >&2
	exit 1
}
note()
{
	printf '%s\n' "fetch-prebuilt.sh: $*" >&2
}

[ "$#" -ge 1 ] || fail "usage: fetch-prebuilt.sh OUTPUT_DIR [SOURCE]..."
OUT=$1
shift
mkdir -p -- "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
DOWNLOADS="$OUT/.downloads"
mkdir -p -- "$DOWNLOADS"
COUNT=0

if [ -n "${PREBUILT_TOKEN:-}" ]; then
	GH_TOKEN=$PREBUILT_TOKEN
	export GH_TOKEN
fi

next_slot()
{
	COUNT=$((COUNT + 1))
	SLOT=$(printf '%s/%03d' "$OUT" "$COUNT")
	mkdir -p -- "$SLOT"
}

download()
{
	# download URL DESTINATION
	note "downloading $1"
	curl --fail --location --silent --show-error --retry 5 --retry-delay 10 \
		--retry-all-errors --connect-timeout 30 -o "$2" -- "$1" ||
		fail "cannot download $1"
}

# unpack FILE: unpack one archive into a new slot, then delete the archive.
unpack()
{
	file=$1
	next_slot
	magic=$(od -An -tx1 -N6 -- "$file" | tr -d ' \n')
	tarmagic=$(dd if="$file" bs=1 skip=257 count=5 2>/dev/null || true)
	note "unpacking $(basename -- "$file") ($(du -h -- "$file" | cut -f1)) into $SLOT"
	case $magic in
	28b52ffd*)
		zstd -dc --long=31 -- "$file" | tar -xf - -C "$SLOT" ;;
	504b0304* | 504b0506*)
		ditto -x -k -- "$file" "$SLOT" 2>/dev/null || unzip -q -o -- "$file" -d "$SLOT" ;;
	377abcaf271c)
		if command -v 7zz >/dev/null 2>&1; then
			7zz x -y -o"$SLOT" -- "$file" >/dev/null
		else
			tar -xf "$file" -C "$SLOT"
		fi
		;;
	1f8b* | 425a68* | fd377a585a00*)
		tar -xf "$file" -C "$SLOT" ;;
	*)
		if [ "$tarmagic" = ustar ]; then
			tar -xf "$file" -C "$SLOT"
		else
			# Not an archive: keep the file itself, place-prebuilt.py may
			# still recognise it (e.g. a compressed system.img).
			note "$(basename -- "$file") is not an archive; kept as a file"
			mv -- "$file" "$SLOT/"
			return
		fi
		;;
	esac
	rm -f -- "$file"
}

# join_parts DESTINATION PART...: concatenate the parts, deleting each one.
join_parts()
{
	destination=$1
	shift
	: >"$destination"
	for part in "$@"; do
		cat -- "$part" >>"$destination"
		rm -f -- "$part"
	done
}

# part_base NAME: print the archive name of a split part, or nothing.
part_base()
{
	printf '%s\n' "$1" | sed -n -E \
		-e 's/^(.+)\.[0-9]{3}$/\1/p' \
		-e 's/^(.+)\.part[-_]?[a-z0-9]{1,3}$/\1/p'
}

# unpack_files FILE...: unpack each file, joining split parts first.
unpack_files()
{
	group_list="$DOWNLOADS/.groups"
	: >"$group_list"
	for file in "$@"; do
		base=$(part_base "$(basename -- "$file")")
		if [ -n "$base" ]; then
			printf '%s\t%s\n' "$base" "$file" >>"$group_list"
		else
			unpack "$file"
		fi
	done
	for base in $(cut -f1 "$group_list" | LC_ALL=C sort -u); do
		# shellcheck disable=SC2046
		set -- $(awk -F '\t' -v b="$base" '$1 == b { print $2 }' "$group_list" | LC_ALL=C sort)
		note "joining $# parts of $base"
		join_parts "$DOWNLOADS/$base" "$@"
		unpack "$DOWNLOADS/$base"
	done
	rm -f -- "$group_list"
}

fetch_one()
{
	source=$1
	case $source in
	gh-release:*)
		spec=${source#gh-release:}
		repo=${spec%%@*}
		rest=${spec#*@}
		[ "$repo" != "$spec" ] || fail "gh-release needs OWNER/REPO@TAG[/ASSET]: $source"
		tag=${rest%%/*}
		pattern=
		[ "$tag" = "$rest" ] || pattern=${rest#*/}
		directory="$DOWNLOADS/gh-$COUNT-$$"
		mkdir -p -- "$directory"
		note "downloading release $repo@$tag ${pattern:-(all assets)}"
		if [ -n "$pattern" ]; then
			gh release download "$tag" --repo "$repo" --dir "$directory" --pattern "$pattern" ||
				fail "cannot download $source"
		else
			gh release download "$tag" --repo "$repo" --dir "$directory" ||
				fail "cannot download $source"
		fi
		# shellcheck disable=SC2046
		set -- $(find "$directory" -type f | LC_ALL=C sort)
		[ "$#" -gt 0 ] || fail "$source matched no asset"
		unpack_files "$@"
		rmdir -- "$directory" 2>/dev/null || true
		;;
	*+*)
		# The parts of one split archive, by URL.
		index=0
		parts=
		old_ifs=$IFS
		IFS=+
		for part in $source; do
			IFS=$old_ifs
			index=$((index + 1))
			destination=$(printf '%s/split-%s-%03d' "$DOWNLOADS" "$$" "$index")
			download "$part" "$destination"
			parts="$parts $destination"
		done
		IFS=$old_ifs
		joined="$DOWNLOADS/joined-$$-$COUNT"
		# shellcheck disable=SC2086
		join_parts "$joined" $parts
		unpack "$joined"
		;;
	http://* | https://*)
		name=$(basename -- "${source%%\?*}")
		[ -n "$name" ] || name=download
		destination="$DOWNLOADS/$COUNT-$name"
		download "$source" "$destination"
		unpack_files "$destination"
		;;
	*)
		[ -e "$source" ] || fail "no such prebuilt source: $source"
		if [ -d "$source" ]; then
			if find "$source" -maxdepth 1 -type f \( -name '*.tar*' -o -name '*.tgz' \
				-o -name '*.zip' -o -name '*.7z' -o -name '*.[0-9][0-9][0-9]' \
				-o -name '*.part*' \) | grep -q .; then
				# A folder of archives (the checkout's prebuilt/): unpack each.
				# shellcheck disable=SC2046
				set -- $(find "$source" -maxdepth 1 -type f \( -name '*.tar*' -o -name '*.tgz' \
					-o -name '*.zip' -o -name '*.7z' -o -name '*.[0-9][0-9][0-9]' \
					-o -name '*.part*' \) | LC_ALL=C sort)
				copies=
				for file in "$@"; do
					cp -- "$file" "$DOWNLOADS/" && copies="$copies $DOWNLOADS/$(basename -- "$file")"
				done
				# shellcheck disable=SC2086
				unpack_files $copies
			fi
			# The folder itself may also hold unpacked trees.
			next_slot
			ln -s "$(CDPATH= cd -- "$source" && pwd -P)" "$SLOT/tree"
		else
			cp -- "$source" "$DOWNLOADS/"
			unpack_files "$DOWNLOADS/$(basename -- "$source")"
		fi
		;;
	esac
}

for argument in "$@"; do
	for source in $(printf '%s\n' "$argument" | tr ',\r' '  '); do
		[ -n "$source" ] || continue
		fetch_one "$source"
	done
done

rm -rf -- "$DOWNLOADS"
note "$COUNT prebuilt tree(s) in $OUT"
