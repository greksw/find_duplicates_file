# Duplicate File Finder

Read-only duplicate-file analysis for TrueNAS and general Unix-like storage hosts.

The project started as a TrueNAS CORE utility for examining a shared dataset. The v2 implementation keeps that operational use case but fixes the main correctness problems of the original text-parsing pipeline.

## What it does

`duplicate-file-finder.sh` scans a directory tree and reports exact duplicate-content groups.

The scan uses two stages:

1. group files by byte size;
2. calculate SHA-256 only for size groups that contain more than one physical file.

A group is considered an exact duplicate only when both size and SHA-256 match.

The script does **not** delete, rename, move, chmod, chown, or otherwise modify scanned files.

## Key properties

- Bash implementation with no non-shell language runtime dependency;
- works with FreeBSD-style and GNU-style `stat`;
- supports `sha256`, `sha256sum`, or `shasum -a 256`;
- NUL-delimited file enumeration, so spaces and most unusual path characters are preserved correctly;
- hard links are deduplicated by device/inode and are not counted as extra duplicate copies;
- hashes only size-collision candidates instead of every file;
- optional minimum file size and recursion depth;
- reports an upper-bound logical reclaimable-byte estimate;
- returns exit code `2` when individual stat/hash errors occurred, while still producing a report;
- legacy `find_duplicates_exchange.sh` remains as a compatibility wrapper.

## Requirements

- Bash 4 or newer;
- `find`;
- `stat` compatible with FreeBSD or GNU syntax;
- one SHA-256 implementation: `sha256`, `sha256sum`, or `shasum`;
- `awk`, `sort`, `mktemp`, and standard Unix userland.

The utility is intended for TrueNAS CORE/FreeBSD-style environments, TrueNAS SCALE/Linux, and ordinary Linux storage hosts. Verify the available shell and userland commands on the target appliance before production use.

## Usage

```bash
chmod +x duplicate-file-finder.sh

./duplicate-file-finder.sh \
  --path /mnt/data/Exchange
```

Write the report to an explicit location:

```bash
./duplicate-file-finder.sh \
  --path /mnt/data/Exchange \
  --report /tmp/exchange-duplicates.txt
```

Ignore very small files and limit recursion depth:

```bash
./duplicate-file-finder.sh \
  --path /mnt/data/Exchange \
  --min-size 1048576 \
  --max-depth 10 \
  --report /tmp/exchange-duplicates.txt
```

`--min-size 1048576` limits the scan to files of at least 1 MiB.

## Report semantics

For each exact duplicate group the report contains:

- file size;
- SHA-256 digest;
- number of physical files;
- shell-escaped paths.

The summary includes:

- total files enumerated;
- unique physical files eligible by size;
- hard-link aliases skipped;
- files hashed;
- exact duplicate groups;
- duplicate copies beyond one retained file per group;
- logical reclaimable bytes;
- stat/hash error counts.

### Reclaimable space is an estimate

The reported reclaimable byte count is a logical upper-bound estimate. It does not attempt to predict actual ZFS pool-space recovery. Compression, snapshots, block sharing, recordsize, metadata, copies, deduplication, and snapshot retention can all make physical pool-space behavior differ from the logical file-size total.

## Why hard links are treated specially

Two directory entries pointing to the same `(device, inode)` already reference the same physical file data. Counting those entries as independent duplicate copies would overstate both duplicate count and reclaimable space. The scanner therefore hashes each physical inode only once.

## Safety model

The tool is intentionally analysis-only. Review the report manually before performing any cleanup.

Do not automate deletion solely from a hash report without considering:

- application ownership and retention policy;
- ZFS snapshots and replication;
- active file use;
- ACLs and metadata differences;
- whether two identical files are intentionally separate records.

## Legacy entrypoint

Existing invocations remain supported:

```bash
./find_duplicates_exchange.sh /mnt/data/Exchange /tmp/duplicates.txt 10
```

The wrapper delegates to `duplicate-file-finder.sh`.

## Validation

GitHub Actions performs:

- Bash syntax validation;
- ShellCheck;
- an integration scan containing duplicate files, unique files, spaces, a pipe character, a newline in a filename, and a hard link;
- assertions for duplicate group count and hard-link handling.

## License

No license has been selected yet.
