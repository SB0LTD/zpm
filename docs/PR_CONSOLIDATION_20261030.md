# SQL/database PR consolidation — 30 October 2026

Scope: all open ZPM, RAMSQL and dbMeter PRs found during this workspace sync.
Existing worktrees, uncommitted changes, experiment branches and raw evidence
are preserved. The consolidated source retains original commits and authors.
Qualification applies to the combined source, not just its individual parents.

## ZPM changes selected for main

| PR | Change | Consolidation |
| --- | --- | --- |
| 81 | Bounded ROWS/GROUPS, integral RANGE, exclusions and window FILTER | Integration vehicle; retains projection/error-timing evidence |
| 77 | Exact grouped DISTINCT over unique dimension chains | Merge original head a81e821; opt-in stays disabled by library default |
| 82 | NET-01 PostgreSQL/TDS integer parameter token boundaries | Merge original head eaae2b7; nested-comment/typed-binding work remains open |
| 83 | STO-01 out-of-order concurrent DDL replay | Merge original head c65ac14; retain OID boundary/counter follow-ups |
| 84 | STO-03 bounded in-place lock upgrades and undo | Merge original head d0656b5; checked capacity and grant rollback |
| 85 | Missing-file classification for openExisting | Merge original head a301eda; RAMSQL explicit-create policy is its consumer |

Only the build registration conflicted when combining DISTINCT with reporting;
both sets of contracts are retained. RAMSQL integrates the verified immutable
combined archive, enables the already isolated DISTINCT candidate, adopts its
SRV-01 explicit-create branch and preserves PR 30's complete benchmark evidence.
Fresh source/platform, server PG16/PG18 and native SB0 qualification remain the
adoption gates for this consolidation.

The earlier DISTINCT comparison used unchanged dbMeter scenarios, a same-library
control and candidate, and AB/BA/AB order in CI run 40994795421. Its subset mixed
medians improved from 99.49 to 263.42 QPS at one client and 240.14 to 628.81 at
eight. Those historical results justify evaluating/adopting the isolated kernel;
they are not measurements of this combined source or universal superiority.
Full-data correctness and all-engine performance gates remain separate.

## Experiments closed without adoption

| PR | Reason |
| --- | --- |
| 53 | Numeric/projection experiment did not establish a repeatable throughput benefit |
| 54 | Extra byte-lane backing had no independently qualified benefit; later dependent experiments were also inconclusive |
| 58 | Fingerprint/cascade combination retained slower results and extra backing |
| 59 | Private-destination projection showed no repeatable improvement |
| 60 | Specialized survivor loops did not improve repeated original workload measurements |
| 61 | Exact byte-domain candidate/control ranges overlapped; extra backing/write cost was not justified |
| 66 | Sparse factor-mask timings retained interference/slowdowns and no stable clean-host advantage |

All seven PRs are closed, not merged; their branches and negative/positive raw
evidence remain available. Existing already-merged ancestors stay in main.
Reconsider an experiment only with isolated current-source correctness and CI
performance evidence. Do not silently revive its entire old branch.

## dbMeter and remaining work

dbMeter PR 1 is closed without merging because run 41024725859 completed with
`qualified: false` and `merge_allowed: false`. Its workflow/source branch and all
Actions runs remain. All seven original full/subset SQL correctness checks pass,
but stock text/column/table capabilities fail and full mixed performance trails
IRDB. RAMSQL's retained reporting bundle verifies 648 raw/validator hashes and
exactly regenerates all three live summaries and the final failed gate.

The original SQL TDD inventory is `docs/SQL_CONFORMANCE_TDD_STATUS.md` with
`tests/sql_conformance/README.md`, `cases.json` and the upstream feature list.
Refresh its broad audit after this consolidation; do not infer complete language,
allocator-free 100M-row storage, native durability or production qualification
from these finite improvements. RAMSQL's wider gap plan remains authoritative
for system/operational gaps.
