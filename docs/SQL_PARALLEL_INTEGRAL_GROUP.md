# Parallel integral grouping

An embedding can install `ExecutionControl.parallel_scan` for an immutable
read. The scheduler receives a bounded batch of opaque tasks. It runs each
task once and joins all started work before returning, including on failure.
It may run a batch inline when its worker team is busy. The embedding holds
the same publication guard as for detached reads until the statement ends.
The SQL layer owns no worker threads.

The optional platform `task_team.Team` gives a host persistent bounded native
helpers. It reserves one member of a batch for the caller and reports whether
it accepted the batch. A host can execute a declined batch inline. The host
owns the team, reserves the helper stack budget, and stops all helpers before
releasing the team's backing.

The initial path uses the narrow typed GROUP BY executor. It requires a dense
committed projection, one integral grouping key, at most two distinct
integral measures, and non-NULL inputs. The existing proof requires the
signed range bound of every subset and prefix to fit in i64. The path
requires at least 65,536 rows, a key span of at most 4,096 and at least 32
rows per domain entry. The existing query arena must have room for the
additional private bucket vectors. Each tile contains
at most 16,384 rows and uses two to four participants.

Workers read disjoint slices of published columns and write disjoint bucket
vectors. The coordinator charges the original work units and polls for
cancellation after each joined tile. It merges integer counts and sums before
running the existing AVG, HAVING, projection, and ORDER BY logic. A cancelled
batch publishes no result. The serial paths handle plans outside the proof
or with no installed scheduler.

`parallel_typed_group_batches` counts completed dispatched tiles and
`parallel_typed_group_plans` counts merged group transitions. A host that
chooses inline execution still increments those counters. Native thread
identity and wait cost must be established by the host when measuring speed.
