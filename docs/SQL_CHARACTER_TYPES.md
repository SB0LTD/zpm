# VARCHAR implementation candidate

Status: development candidate, not qualified or merged. APP-01 remains partial;
CHAR/BPCHAR padding/comparison semantics are not implemented by this slice.

## Layer and storage

Reusable runtime changes stay in allocator-free ZPM L0 SQL. VARCHAR is a distinct
bound/stored type with PostgreSQL OID1043, variable length, array catalog OID1015
and typinput varcharin metadata. It shares the existing caller-owned text cell.
The type enum additions are appended, retaining previous enum ordinals; typed
change records encode OIDs and existing record versions remain unchanged.

VARCHAR and CHARACTER VARYING accept an absent modifier or PostgreSQL's declared
character length1..10485760, represented as n+4. A large declaration allocates no
new storage and does not override Config.text_bytes or other caller budgets.
The UTF-8 helper validates complete scalar sequences and rejects embedded NUL,
including suffixes beyond an explicit truncation. It clips on character boundaries.
Assignment/input discards only excess ASCII spaces; other overflow is22001.
Explicit casts truncate without that assignment error. Malformed character input
is22021. No normalization, grapheme counting, collation or heap allocation is added.

## Binding, metadata and execution

String coercions and LIKE admit VARCHAR; MIN/MAX select text overloads. The result
keeps OID/typmod through columns, casts, groups and compatible set operations.
String common-result selection retains the first compatible type, except the
directed NAME/VARCHAR pair selects NAME; CASE selects with ELSE first after
binding arms in their original semantic order. NULLIF resolves VARCHAR through
TEXT operators. Comparisons preserve long VARCHAR values instead of coercing
them to NAME; conversion to NAME clips bytes at a complete UTF-8 boundary.
CASE/COALESCE metadata considers immutable reachable branches; speculative
inspection propagates cancellation/control errors and leaves ordinary execution
diagnostics under their existing owners. GREATEST/LEAST use common modifiers.
Catalog type/attribute records, format_type, character_maximum_length and the
information_schema.columns.data_type wire type carry the new metadata. Stored
expression deparsing retains explicit VARCHAR modifiers.

Character IN uses two fixed AST fields. Two or more provably var-free RHS
expressions form the leading array-coercion group; every member is evaluated
before matching. Remaining row-dependent operands use ordered scalar comparisons,
with the scalar evaluated for each comparison. Operator coercion stays separate
from result/common-array type selection, preserving VARCHAR bytes and NULL/NOT IN
logic. Existing nodes are relinked without array materialization or AST cloning.
Subquery/window/correlated grouping stays conservative; this is not general
PostgreSQL IN planner closure for every expression family.

Mutation uses existing statement rollback and ownership. DML applies strict length
coercion before storage, defaults and generated values. PostgreSQL binary string
parameters/results and COPY reuse text bytes with the distinct OID; MySQL/TDS
remain adapters over the shared subset, not independently qualified dialects.
Replay validates both the schema modifier and stored UTF-8/length, failing atomically
on invalid/noncanonical records. Existing fixed storage/work/result limits apply.

## Evidence and remaining gates

The initial23-program native16 corpus reproduced3matches/20gaps on unchanged
main. Independent review expanded the corpus to36programs, including directed
string common types, operator/array distinctions, volatile/NULL effects and
bind-time unknown-literal error priority. The final36case source independently
passes36/36, the storage contract318assertions, and the reviewer's separate15event
adversarial contract. The public native16 verifier also independently passes36/36.
A subsequent typed-literal and identifier program expands the candidate to 37
passing programs. It covers VARCHAR(n) and CHARACTER VARYING(n) literals while
retaining unquoted columns named varchar, character and varying. Native sessions
are explicitly UTC; the core uses its default UTC session.
Fixtures retain names/OIDs/typmods, values,
command tags, SQLSTATE and follow-up state. Cases cover multibyte/combining input,
spaces versus other whitespace, explicit/assignment coercion, multirow/update
atomicity, defaults/generated values, relational operators and catalogs.

The storage contract additionally checks malformed UTF-8/NUL, actual binary codec
round trips, exhausted value storage, typed replay/corrupt modifiers/values,
transaction visibility and cancellation through metadata inspection. Final-source
regressions, native16/18 calibration, independent review, product wire and durable
integration, all supported hosts and exact release qualification remain mandatory.

The original PG.TYPE.CHARACTER probe is titled VARCHAR/CHAR but executes only
VARCHAR SQL. Passing that smoke probe does not test CHAR or close the family.
Schema constraints, general
indexes, CHAR/BPCHAR, remaining types, general collations, catalog/application
compatibility and production-scale guarantees remain separate open work. The
existing permissive bare-alias policy also remains open: PostgreSQL rejects an
unquoted VARYING alias in contexts this parser may accept.
