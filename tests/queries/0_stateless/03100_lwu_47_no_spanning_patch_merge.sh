#!/usr/bin/env bash

# Test that patch parts created before and after a mutation are not merged together,
# which would create a SourcePartsSet spanning the mutation boundary and cause LOGICAL_ERROR.

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

# shellcheck source=./mergetree_mutations.lib
. "$CURDIR"/mergetree_mutations.lib

set -e

$CLICKHOUSE_CLIENT --query "
    DROP TABLE IF EXISTS t_lwu_spanning SYNC;
    SET enable_lightweight_update = 1;

    CREATE TABLE t_lwu_spanning (id UInt64, u UInt64, s String)
    ENGINE = MergeTree
    ORDER BY id
    SETTINGS
        enable_block_number_column = 1,
        enable_block_offset_column = 1,
        apply_patches_on_merge = 1;

    SYSTEM STOP MERGES t_lwu_spanning;

    INSERT INTO t_lwu_spanning SELECT number, number, 'v0' FROM numbers(1000);

    -- Create a patch BEFORE the mutation
    UPDATE t_lwu_spanning SET s = 'v1' WHERE id < 500;

    -- Create a mutation (async)
    ALTER TABLE t_lwu_spanning UPDATE u = u + 1 WHERE 1 SETTINGS mutations_sync = 0;

    -- Create a patch AFTER the mutation
    UPDATE t_lwu_spanning SET s = 'v2' WHERE id >= 500;

    SYSTEM START MERGES t_lwu_spanning;
"

# Wait for the mutation to complete. Previously this would get stuck with LOGICAL_ERROR
# if patch parts from before and after the mutation were merged together.
wait_for_all_mutations "t_lwu_spanning"

$CLICKHOUSE_CLIENT --query "
    -- All rows should have u incremented by 1 (mutation applied)
    SELECT sum(u) FROM t_lwu_spanning;
    -- 500 rows with 'v1', 500 rows with 'v2'
    SELECT countIf(s = 'v1'), countIf(s = 'v2') FROM t_lwu_spanning;

    DROP TABLE t_lwu_spanning SYNC;
"
