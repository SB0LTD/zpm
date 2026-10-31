# Frame value windows

The candidate implements first_value, last_value and nth_value over the existing
typed frame resolver: default peer frames, full partitions, ROWS, GROUPS and
supported integral RANGE bounds, including exclusions. NULL values occupy frame
positions. nth_value takes an int4 position evaluated at the current row; its
value argument executes only at the selected row. Unknown polymorphic values
require an explicit type. Invalid consumed positions raise22016; LIMIT0 and empty
input avoid runtime position evaluation, while immutable expression errors fold.

After resolving frame bounds, exclusions leave at most three ordered intervals.
Selection computes the chosen row from interval lengths without scanning the
frame or allocating per-frame storage. Existing peer tables, bounded workspace,
execution checkpoints and fixed statement pools remain in use. No runtime heap
allocator or external SQL engine is introduced.

Value expressions are deferred, rather than evaluated for all input rows.
Sensitive/throwing/nonrepeatable shapes use existing root/prefix-demand guards:
uncertain nested demand, multiple sensitive windows or blocking final order
reject0A000. This is a deliberate remaining SQL gap. Numeric/temporal RANGE,
collations and general shared volatile-window execution remain unqualified.
PostgreSQL does not implement IGNORE NULLS or FROM LAST; this candidate does not
add those extensions. Existing column/cell/statement/workspace capacities apply.

78 frozen PostgreSQL16.15 programs cover frame/exclusion/value/type/error cases;
the new test fails UndefinedFunction against the preceding source. Hosted/wire,
independent adversarial review and broader inventory qualification are pending.
Smoke success never closes the complete window or SQL inventory.

## Known PostgreSQL boundary differences

`window_values_boundary_deviations_pg16.json` separately records12 preceding/
following EXCLUDE TIES programs. Four native results differ from selecting the
first/last/nth member of the frame reported by PostgreSQL's own array_agg. For
example, with (id,key)=(1,0),(2,1),(3,1), the frame for row3 under ORDER BY key
ROWS BETWEEN2 PRECEDING AND1 PRECEDING EXCLUDE TIES contains only id1;
first_value and nth_value return1, but native last_value returns NULL. The
candidate returns1. Following frames expose related head-navigation differences.

Independent native probes also observed XX000 (cannot fetch row before the
WindowObject mark position) for first_value/nth_value1 with2 FOLLOWING through
3 FOLLOWING EXCLUDE TIES over longer peer groups. Whether it occurs depends on
outer sorting and LIMIT demand. The generic interval resolver does not reproduce
PostgreSQL's internal mark-state failure. This is an explicit native-parity gap,
not passing compatibility evidence or a closed feature. The separate fixture
retains native outputs and independent array_agg frame-membership outputs; core
tests assert the latter without changing the78 scoped parity cases. PG18 live
qualification and version characterization remain pending. REL18_3's executor
source contains the same current-row substitution in exclusion navigation;
that source observation alone does not establish live PG18 behavior.

References: [PostgreSQL18 window functions](https://www.postgresql.org/docs/18/functions-window.html)
and [REL18_3 window function implementation](https://github.com/postgres/postgres/blob/REL_18_3/src/backend/utils/adt/windowfuncs.c).
