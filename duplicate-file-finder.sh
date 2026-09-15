#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SEARCH_DIR=''
REPORT_FILE=''
MAX_DEPTH=''
MIN_SIZE=1

usage() {
    cat <<'EOF'
Usage:
  duplicate-file-finder.sh --path DIR [options]

Options:
  --path DIR         Directory to scan (required).
  --report FILE      Report path. Default: /tmp/duplicate-file-report-<timestamp>.txt
  --max-depth N      Limit recursion depth. Omit for unlimited depth.
  --min-size BYTES   Ignore files smaller than BYTES. Default: 1.
  -h, --help         Show this help.

The scan is read-only. Duplicate groups are determined by file size and SHA-256.
Hard links to the same inode are counted once.
EOF
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

cleanup() {
    if [[ -n ${WORK_DIR:-} && -d ${WORK_DIR:-} ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT HUP INT TERM

while (($# > 0)); do
    case $1 in
        --path)
            (($# >= 2)) || fatal '--path requires a value.'
            SEARCH_DIR=$2
            shift 2
            ;;
        --report)
            (($# >= 2)) || fatal '--report requires a value.'
            REPORT_FILE=$2
            shift 2
            ;;
        --max-depth)
            (($# >= 2)) || fatal '--max-depth requires a value.'
            MAX_DEPTH=$2
            shift 2
            ;;
        --min-size)
            (($# >= 2)) || fatal '--min-size requires a value.'
            MIN_SIZE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown argument: $1"
            ;;
    esac
done

[[ -n $SEARCH_DIR ]] || {
    usage >&2
    fatal '--path is required.'
}
[[ -d $SEARCH_DIR ]] || fatal "Directory does not exist: $SEARCH_DIR"
[[ -r $SEARCH_DIR ]] || fatal "Directory is not readable: $SEARCH_DIR"
[[ $MIN_SIZE =~ ^[0-9]+$ ]] || fatal '--min-size must be a non-negative integer.'
if [[ -n $MAX_DEPTH ]]; then
    [[ $MAX_DEPTH =~ ^[0-9]+$ ]] || fatal '--max-depth must be a non-negative integer.'
fi

if ((BASH_VERSINFO[0] < 4)); then
    fatal 'Bash 4 or newer is required.'
fi

require_command find
require_command mktemp
require_command sort
require_command stat

if [[ -z $REPORT_FILE ]]; then
    REPORT_FILE="/tmp/duplicate-file-report-$(date +%Y%m%d_%H%M%S).txt"
fi

REPORT_DIR=$(dirname -- "$REPORT_FILE")
[[ -d $REPORT_DIR ]] || fatal "Report directory does not exist: $REPORT_DIR"
[[ -w $REPORT_DIR ]] || fatal "Report directory is not writable: $REPORT_DIR"

if stat -f '%z' "$SEARCH_DIR" >/dev/null 2>&1; then
    STAT_STYLE=freebsd
elif stat -c '%s' "$SEARCH_DIR" >/dev/null 2>&1; then
    STAT_STYLE=gnu
else
    fatal 'Unsupported stat implementation. Expected FreeBSD or GNU stat.'
fi

if command -v sha256 >/dev/null 2>&1; then
    HASH_STYLE=freebsd
elif command -v sha256sum >/dev/null 2>&1; then
    HASH_STYLE=gnu
elif command -v shasum >/dev/null 2>&1; then
    HASH_STYLE=shasum
else
    fatal 'No SHA-256 utility found (sha256, sha256sum, or shasum).'
fi

get_size() {
    local path=$1
    case $STAT_STYLE in
        freebsd) stat -f '%z' -- "$path" ;;
        gnu) stat -c '%s' -- "$path" ;;
    esac
}

get_file_id() {
    local path=$1
    case $STAT_STYLE in
        freebsd) stat -f '%d:%i' -- "$path" ;;
        gnu) stat -c '%d:%i' -- "$path" ;;
    esac
}

get_sha256() {
    local path=$1
    case $HASH_STYLE in
        freebsd) sha256 -q -- "$path" ;;
        gnu) sha256sum -- "$path" | awk '{print $1}' ;;
        shasum) shasum -a 256 -- "$path" | awk '{print $1}' ;;
    esac
}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/duplicate-file-finder.XXXXXXXX")
mkdir -p -- "$WORK_DIR/by-size" "$WORK_DIR/by-hash"
ALL_PATHS="$WORK_DIR/all-paths.bin"

find_args=("$SEARCH_DIR")
if [[ -n $MAX_DEPTH ]]; then
    find_args+=( -maxdepth "$MAX_DEPTH" )
fi
find_args+=( -type f -print0 )

printf 'Scanning: %s\n' "$SEARCH_DIR"
printf 'Report:   %s\n' "$REPORT_FILE"

if ! find "${find_args[@]}" > "$ALL_PATHS"; then
    fatal 'find failed while enumerating files.'
fi

declare -A size_counts=()
declare -A seen_file_ids=()
file_count=0
eligible_count=0
hardlink_skipped=0
stat_errors=0

while IFS= read -r -d '' path; do
    ((file_count += 1))

    if ! file_id=$(get_file_id "$path" 2>/dev/null); then
        ((stat_errors += 1))
        warn "Unable to read inode metadata: $(printf '%q' "$path")"
        continue
    fi

    if [[ -n ${seen_file_ids[$file_id]+x} ]]; then
        ((hardlink_skipped += 1))
        continue
    fi
    seen_file_ids[$file_id]=1

    if ! size=$(get_size "$path" 2>/dev/null); then
        ((stat_errors += 1))
        warn "Unable to read file size: $(printf '%q' "$path")"
        continue
    fi
    [[ $size =~ ^[0-9]+$ ]] || {
        ((stat_errors += 1))
        warn "Invalid file size returned for: $(printf '%q' "$path")"
        continue
    }
    ((size >= MIN_SIZE)) || continue

    ((eligible_count += 1))
    size_counts[$size]=$(( ${size_counts[$size]:-0} + 1 ))
    printf '%s\0' "$path" >> "$WORK_DIR/by-size/$size.paths"

done < "$ALL_PATHS"

candidate_count=0
for size in "${!size_counts[@]}"; do
    if (( size_counts[$size] > 1 )); then
        candidate_count=$((candidate_count + size_counts[$size]))
    fi
done

printf 'Files found: %d; hash candidates: %d\n' "$file_count" "$candidate_count"

declare -A hash_counts=()
hashed_count=0
hash_errors=0

for size in "${!size_counts[@]}"; do
    (( size_counts[$size] > 1 )) || continue

    while IFS= read -r -d '' path; do
        if ! hash=$(get_sha256 "$path" 2>/dev/null); then
            ((hash_errors += 1))
            warn "Unable to hash: $(printf '%q' "$path")"
            continue
        fi
        [[ $hash =~ ^[[:xdigit:]]{64}$ ]] || {
            ((hash_errors += 1))
            warn "Invalid SHA-256 result for: $(printf '%q' "$path")"
            continue
        }
        hash=${hash,,}
        key="${size}:${hash}"
        hash_counts[$key]=$(( ${hash_counts[$key]:-0} + 1 ))
        printf '%s\0' "$path" >> "$WORK_DIR/by-hash/${size}.${hash}.paths"
        ((hashed_count += 1))
    done < "$WORK_DIR/by-size/$size.paths"
done

mapfile -t sorted_keys < <(printf '%s\n' "${!hash_counts[@]}" | LC_ALL=C sort -t: -k1,1n -k2,2)

group_count=0
duplicate_file_count=0
logical_reclaimable_bytes=0

{
    printf 'DUPLICATE FILE REPORT\n'
    printf 'Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Search path: %s\n' "$SEARCH_DIR"
    printf 'Minimum size: %s bytes\n' "$MIN_SIZE"
    if [[ -n $MAX_DEPTH ]]; then
        printf 'Maximum depth: %s\n' "$MAX_DEPTH"
    else
        printf 'Maximum depth: unlimited\n'
    fi
    printf 'Method: size prefilter + SHA-256 content hash\n'
    printf 'Hard links: same device/inode counted once\n'
    printf '\n'

    for key in "${sorted_keys[@]}"; do
        count=${hash_counts[$key]}
        ((count > 1)) || continue

        size=${key%%:*}
        hash=${key#*:}
        path_file="$WORK_DIR/by-hash/${size}.${hash}.paths"
        duplicate_count=$((count - 1))

        ((group_count += 1))
        duplicate_file_count=$((duplicate_file_count + duplicate_count))
        logical_reclaimable_bytes=$((logical_reclaimable_bytes + size * duplicate_count))

        printf 'GROUP %d\n' "$group_count"
        printf '  Size: %s bytes\n' "$size"
        printf '  SHA-256: %s\n' "$hash"
        printf '  Files: %s\n' "$count"
        printf '  Paths:\n'
        while IFS= read -r -d '' path; do
            printf '    %q\n' "$path"
        done < "$path_file"
        printf '\n'
    done

    if ((group_count == 0)); then
        printf 'No exact duplicate groups found.\n\n'
    fi

    printf 'SUMMARY\n'
    printf '  Files enumerated: %d\n' "$file_count"
    printf '  Unique physical files eligible by size: %d\n' "$eligible_count"
    printf '  Hard-link aliases skipped: %d\n' "$hardlink_skipped"
    printf '  Files hashed: %d\n' "$hashed_count"
    printf '  Duplicate groups: %d\n' "$group_count"
    printf '  Duplicate files beyond one retained copy per group: %d\n' "$duplicate_file_count"
    printf '  Logical reclaimable bytes (upper-bound estimate): %d\n' "$logical_reclaimable_bytes"
    printf '  Stat errors: %d\n' "$stat_errors"
    printf '  Hash errors: %d\n' "$hash_errors"
} > "$REPORT_FILE"

printf 'Duplicate groups: %d\n' "$group_count"
printf 'Logical reclaimable bytes (upper-bound estimate): %d\n' "$logical_reclaimable_bytes"
printf 'Report written to: %s\n' "$REPORT_FILE"

if ((stat_errors > 0 || hash_errors > 0)); then
    exit 2
fi
