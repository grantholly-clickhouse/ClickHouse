#!/usr/bin/env bash
# Tags: no-fasttest, no-shared-merge-tree, no-replicated-database, no-object-storage, no-random-settings
# Tag no-shared-merge-tree: plain_rewritable is not shared across replicas
# Tag no-replicated-database: plain_rewritable is per-replica
# Tag no-object-storage: uses local_plain_rewritable_03008 from tests/config

# Regression test for ClickHouse/ClickHouse#96723 and clickhouse-core-incidents#1704.
#
# On a plain_rewritable disk shared across replicas during a make-before-break,
# two replicas can independently commit overlapping merges. The resulting parts
# share `min_block` and `level` but have different `max_block`. With the previous
# behaviour, the next `ATTACH TABLE` threw `LOGICAL_ERROR: Part X intersects
# previous part Y. It is a bug or a result of manual intervention` and wedged
# the table forever. The fix in `MergeTreeData::PartLoadingTree::add` detects
# this signature on plain_rewritable disks, keeps the wider part as Active and
# marks the narrower part as Outdated.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

table="t_intersecting_parts_plain_rewritable_${CLICKHOUSE_DATABASE}"

${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS ${table} SYNC"

${CLICKHOUSE_CLIENT} -m -q "
CREATE TABLE ${table} (a Int32, b Int32)
ENGINE = MergeTree()
ORDER BY a
SETTINGS disk = 'local_plain_rewritable_03008', old_parts_lifetime = 100500;
"

# Two inserts produce two level-0 parts; OPTIMIZE merges them into one level-1 part.
${CLICKHOUSE_CLIENT} -q "INSERT INTO ${table} VALUES (1, 1)"
${CLICKHOUSE_CLIENT} -q "INSERT INTO ${table} VALUES (2, 2)"
${CLICKHOUSE_CLIENT} -q "OPTIMIZE TABLE ${table} FINAL"

# We expect a single Active level-1 part covering both inserts.
${CLICKHOUSE_CLIENT} -q "
SELECT count(), max(level)
FROM system.parts
WHERE database = currentDatabase() AND table = '${table}' AND active = 1
"

narrow_path=$(${CLICKHOUSE_CLIENT} -q "
SELECT path
FROM system.parts
WHERE database = currentDatabase() AND table = '${table}' AND active = 1
LIMIT 1
")
${CLICKHOUSE_CLIENT} -q "SELECT throwIf(substring('${narrow_path}', 1, 1) != '/', 'Path is relative: ${narrow_path}')" || exit 1

narrow_name="$(basename "${narrow_path}")"
parent_dir="$(dirname "${narrow_path}")"
# Build a wider, same-level part name by bumping the third field (max_block) by 5.
wide_name="$(awk -F_ '{print $1"_"$2"_"($3+5)"_"$4}' <<< "${narrow_name}")"
wide_path="${parent_dir}/${wide_name}"

${CLICKHOUSE_CLIENT} -q "DETACH TABLE ${table} SYNC"

# Simulate a concurrent merge committing a wider output on the same shared
# object-storage prefix while the table is detached. Copy the part directory
# under the wider name. The two directories now share `min_block` and `level`
# but differ in `max_block` -- exactly the production fingerprint. Remove the
# UUID file (Cloud build) if present so the parts aren't flagged as a duplicate
# pair; in production the two merges would have produced distinct UUIDs.
cp -r "${narrow_path}" "${wide_path}"
rm -f "${wide_path}/uuid.txt"

# Previously this would fail with LOGICAL_ERROR (code 49). After the fix it
# succeeds: the wider part is Active, the narrower is Outdated.
${CLICKHOUSE_CLIENT} -q "ATTACH TABLE ${table}"

# Sort by `level, max_block_number, active` so the reference file is stable
# regardless of which name happens to sort first lexically.
${CLICKHOUSE_CLIENT} -q "
SELECT
    if(name = '${narrow_name}', 'narrow', if(name = '${wide_name}', 'wide', name)) AS role,
    active
FROM system.parts
WHERE database = currentDatabase()
  AND table = '${table}'
  AND name IN ('${narrow_name}', '${wide_name}')
ORDER BY active DESC, role
"

# Sanity: the table is queryable.
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM ${table}"

${CLICKHOUSE_CLIENT} -q "DROP TABLE ${table} SYNC"
