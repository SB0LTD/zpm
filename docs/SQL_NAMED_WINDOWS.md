# Named WINDOW definitions and inheritance

The candidate parses SELECT's WINDOW list, bare OVER name and parenthesized
OVER (name ...) references. Definitions are local to one query block, may
inherit only preceding entries, preserve quoted-name case and reject duplicates.
Copying cannot add PARTITION BY, replace an existing ORDER BY, or copy a framed
base. Bare OVER name may reference a framed definition. A separate framed bit
retains this rule after canonicalizing an explicit default RANGE/ROWS frame.
Frame normalization is idempotent, including inherited running ROWS frames.

Definitions are validated even if unused: names, expressions, frame structure,
constant errors and grouping dependencies must bind. Inherited expression trees
are cloned into the caller-owned statement pool before grouping/lowering, so
one reference cannot corrupt another. No runtime allocator, socket or external
SQL engine is added. Named definitions consume the existing expression/window
slot budgets; exhaustion is54001 with statement cleanup. Lookups are bounded
and participate in ExecutionControl. Equal sort/group key expressions share one
input projection, including volatile keys, while volatile value arguments remain
separate. Mutable keys currently require a root window and repeatable surrounding
projections; uncertain parent demand/projection sharing rejects with0A000. Window definitions never enter child-query
name scopes or persistent storage.

A regression exposed unbounded volatile aggregate inputs being evaluated before
window ordering. Such arguments now remain deferred and execute at the sorted
row. Until windows can share interleaved state and propagate demand, volatile
aggregate inputs/filters/frame offsets require a root window and repeatable
surrounding projections. Multiple full unsorted, unpartitioned COUNT/MIN/MAX/
Boolean aggregates without filters can share materialized argument projection;
this preserves per-row interleaving and retains the pre-existing COUNT(nextval)
contract. Other mutable aggregate combinations currently require one window. Finite LIMIT is only admitted for an unpartitioned full
frame; unsafe combinations return0A000. Moving-frame volatile inputs retain
previous explicit rejection. These are documented window-family gaps, not full
PostgreSQL or SQL compatibility.

Initial27 native PG16.15 programs check values/types/errors, inheritance,
framed-copy rejection, scope, quoting, unused definitions and grouping.
Additional contracts compare anonymous and inherited forms across aggregate/frame
variants, force capacity/cancel/work errors, verify reuse after failure and check
volatile sequence order. The broad118-program inventory remains intentionally
red; named-window smoke success cannot close numeric/temporal RANGE, value-window
functions, collations, shared volatile-window execution or the wider SQL family.
Hosted/native/PG18 qualification remains pending.

Reference: [PostgreSQL18 WINDOW clause](https://www.postgresql.org/docs/18/sql-select.html#SQL-WINDOW).
