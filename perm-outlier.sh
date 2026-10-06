#!/bin/sh
#
# perm-outlier - find files whose permission bits differ from their neighbours.
#
# Most permission bugs are not "too loose" or "too tight" in the abstract.
# They are a single file that does not match everything around it.
# This script finds the dominant mode in a tree and reports what differs.
#
# POSIX sh. Works on Linux (GNU coreutils) and macOS/BSD.
#
# License: MIT
#

set -eu

PROG=$(basename "$0")
VERSION=0.1.0

TARGET_DIR="."
ONLY_GROUP_UNREADABLE=0
CHECK_DIRS=0
SHOW_FIX=0
QUIET=0

usage() {
	cat <<EOF
$PROG $VERSION - find files whose permissions differ from their neighbours

Usage:
  $PROG [options] [directory]

Options:
  -g, --group-unreadable   Only report files whose group-read bit is unset.
                           These are invisible to a webserver that reaches
                           the file through its group, even when the "other"
                           bits look permissive (e.g. 604).
  -x, --check-dirs         Also check directories. A directory missing its
                           execute bit blocks access to everything inside it,
                           regardless of the files' own permissions.
  -f, --print-fix          Print the chmod commands that would align the
                           outliers with the dominant mode. Nothing is
                           executed; review before running.
  -q, --quiet              Suppress the distribution summary.
  -h, --help               Show this help.
  -V, --version            Show version.

Exit status:
  0  no outliers found
  1  outliers found
  2  usage or runtime error

Examples:
  $PROG /var/www/html
  $PROG -g /var/www/html
  $PROG -x -f ~/public_html
EOF
}

die() {
	echo "$PROG: $1" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# stat(1) is not portable. GNU takes -c, BSD/macOS takes -f.
# Detect once, then use the wrapper everywhere.
# ---------------------------------------------------------------------------
STAT_STYLE=""

detect_stat() {
	if stat -c '%a' /dev/null >/dev/null 2>&1; then
		STAT_STYLE=gnu
	elif stat -f '%Lp' /dev/null >/dev/null 2>&1; then
		STAT_STYLE=bsd
	else
		die "cannot determine how to call stat(1) on this system"
	fi
}

# mode_of FILE -> prints octal mode, e.g. 644
mode_of() {
	if [ "$STAT_STYLE" = gnu ]; then
		stat -c '%a' "$1"
	else
		stat -f '%Lp' "$1"
	fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		-g|--group-unreadable) ONLY_GROUP_UNREADABLE=1 ;;
		-x|--check-dirs)       CHECK_DIRS=1 ;;
		-f|--print-fix)        SHOW_FIX=1 ;;
		-q|--quiet)            QUIET=1 ;;
		-h|--help)             usage; exit 0 ;;
		-V|--version)          echo "$PROG $VERSION"; exit 0 ;;
		--)                    shift; break ;;
		-*)                    die "unknown option: $1 (try --help)" ;;
		*)                     TARGET_DIR="$1" ;;
	esac
	shift
done

[ -d "$TARGET_DIR" ] || die "not a directory: $TARGET_DIR"

detect_stat

TMPDIR_WORK=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$TMPDIR_WORK"' EXIT INT TERM

LIST="$TMPDIR_WORK/list"
: > "$LIST"

# Collect "<mode> <path>" for every regular file.
# -print0 is not POSIX, so paths containing newlines are out of scope here;
# that is a deliberate limitation, not an oversight.
find "$TARGET_DIR" -type f 2>/dev/null | while IFS= read -r f; do
	m=$(mode_of "$f" 2>/dev/null) || continue
	printf '%s %s\n' "$m" "$f"
done > "$LIST"

if [ ! -s "$LIST" ]; then
	echo "$PROG: no regular files found under $TARGET_DIR" >&2
	exit 0
fi

TOTAL=$(wc -l < "$LIST" | tr -d ' ')

# ---------------------------------------------------------------------------
# Distribution, and the dominant mode
# ---------------------------------------------------------------------------
DIST="$TMPDIR_WORK/dist"
awk '{print $1}' "$LIST" | sort | uniq -c | sort -rn > "$DIST"

DOMINANT=$(awk 'NR==1 {print $2}' "$DIST")
DOMINANT_N=$(awk 'NR==1 {print $1}' "$DIST")

if [ "$QUIET" -eq 0 ]; then
	echo "Scanned $TOTAL file(s) under $TARGET_DIR"
	echo
	echo "Permission distribution:"
	while read -r count mode; do
		pct=$(awk -v c="$count" -v t="$TOTAL" 'BEGIN { printf "%.1f", (c*100)/t }')
		marker=""
		[ "$mode" = "$DOMINANT" ] && marker="  <- dominant"
		printf '  %-6s %6s file(s)  %5s%%%s\n' "$mode" "$count" "$pct" "$marker"
	done < "$DIST"
	echo
fi

# ---------------------------------------------------------------------------
# Outliers
# ---------------------------------------------------------------------------
OUT="$TMPDIR_WORK/out"
: > "$OUT"

if [ "$ONLY_GROUP_UNREADABLE" -eq 1 ]; then
	# Group-read bit is the middle digit; unset means 0, 1, 2 or 3.
	awk '{
		mode = $1
		n = length(mode)
		g = substr(mode, n-1, 1) + 0
		if (g < 4) {
			path = $0
			sub(/^[0-9]+ /, "", path)
			print mode " " path
		}
	}' "$LIST" > "$OUT"
	HEADING="Files with no group-read bit"
	NOTE="Permission checking stops at the first matching class.
A process in the file's group is judged by the group bits alone;
the \"other\" bits are never consulted. 604 therefore denies the group
even though it grants everyone else."
else
	awk -v dom="$DOMINANT" '{
		if ($1 != dom) {
			path = $0
			sub(/^[0-9]+ /, "", path)
			print $1 " " path
		}
	}' "$LIST" > "$OUT"
	HEADING="Files that differ from the dominant mode ($DOMINANT, $DOMINANT_N file(s))"
	NOTE=""
fi

FOUND=0

if [ -s "$OUT" ]; then
	FOUND=1
	echo "$HEADING:"
	echo
	sort "$OUT" | while read -r mode path; do
		printf '  %-6s %s\n' "$mode" "$path"
	done
	echo
	if [ -n "$NOTE" ]; then
		echo "$NOTE" | sed 's/^/  /'
		echo
	fi
	if [ "$SHOW_FIX" -eq 1 ]; then
		echo "Suggested commands - READ THIS FIRST:"
		echo
		echo "  Some files are restrictive on purpose: private keys, certificates,"
		echo "  credential files, configuration holding database passwords."
		echo "  Relaxing those to match the majority would expose them."
		echo "  Nothing below is executed. Go through the list and drop any line"
		echo "  whose file is meant to stay closed."
		echo
		sort "$OUT" | while read -r mode path; do
			printf '  chmod %s %s\n' "$DOMINANT" "$path"
		done
		echo
	fi
else
	echo "No outliers: every file is $DOMINANT."
	echo
fi

# ---------------------------------------------------------------------------
# Directories (optional)
# ---------------------------------------------------------------------------
if [ "$CHECK_DIRS" -eq 1 ]; then
	DLIST="$TMPDIR_WORK/dirs"
	: > "$DLIST"

	find "$TARGET_DIR" -type d 2>/dev/null | while IFS= read -r d; do
		m=$(mode_of "$d" 2>/dev/null) || continue
		# Any class without its execute bit cannot traverse the directory.
		o=$(printf '%s' "$m" | awk '{ n=length($0); print substr($0,n,1)+0 }')
		g=$(printf '%s' "$m" | awk '{ n=length($0); print substr($0,n-1,1)+0 }')
		if [ $((o % 2)) -eq 0 ] || [ $((g % 2)) -eq 0 ]; then
			printf '%s %s\n' "$m" "$d"
		fi
	done > "$DLIST"

	if [ -s "$DLIST" ]; then
		FOUND=1
		echo "Directories missing an execute bit for group or other:"
		echo
		sort "$DLIST" | while read -r mode path; do
			printf '  %-6s %s\n' "$mode" "$path"
		done
		echo
		echo "  A directory without its execute bit cannot be traversed."
		echo "  Files inside are unreachable no matter what their own bits say."
		echo
	fi
fi

[ "$FOUND" -eq 1 ] && exit 1
exit 0
