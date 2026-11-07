# Temporal boundary correctness

This batch addresses the six unchecked-overflow paths identified as SQLF-01
and infinite DATE subtraction (SQLF-05). SQL parsing, operators and arithmetic
remain allocator-free in ZPM; RAMSQL supplies independent server qualification.

## Behavior

- Timestamp parsing checks the day-to-microsecond product and time/zone additions.
  Zone resolution checks the final seconds-to-microseconds reconstruction too.
- DATE-to-timestamp conversion and calendar month reconstruction use checked
  multiplication/addition. Day offsets use checked addition even for direct
  library callers with an i64 offset.
- DATE operators accept SMALLINT/INTEGER, reject BIGINT with 42883, and reject
  either infinite subtraction operand with 22008.
- Interval input signs its integral/fractional microseconds before checked
  accumulation. This preserves the representable negative i64 boundary while
  rejecting positive overflow and negating that boundary with `ago`.
- Interval input overflow reports 22015. Interval unary/binary arithmetic retains
  native PostgreSQL's distinct 22008 error class.

PostgreSQL 16.15 and PostgreSQL 18.3 source both allow TIMESTAMP(p) rounding across
its documented finite upper boundary. This is preserved, with a regression case;
the earlier audit's proposal to reject that value would change native semantics.

## Evidence and scope

`tests/fixtures/temporal_boundary_pg16.json` records 28 native PostgreSQL 16.15
queries with explicit UTC session settings, output and SQLSTATE diagnostics.
`tests/test_sql_types.sig` replays these and an additional overflow literal.
Its wide-integer property oracle exercises every astronomical candidate timestamp
year from -4713 through 294277: text parsing, DATE conversion and month addition
are compared with i128 range arithmetic. Direct i64 day-offset/zone overflow
cases cover callers outside SQL's narrowed operator signatures.

Red-before-green local ReleaseSafe runs independently reproduced process panics
for timestamp input and fractional interval accumulation. The fix returns SQL
errors and keeps later statements usable. The normal hosted SQL contracts run
these cases; RAMSQL adds PG16/PG18 memory/durable differential cases and native
SB0X/SB0K error/session-survival probes. CI links and final results are recorded
in the integrating RAMSQL change.

This is not full temporal compatibility or a formal proof of all inputs. TIME,
TIMETZ, EXTRACT/date_part/date_trunc/age/make_*, alternate input styles, SQL-standard
interval forms, duplicate interval-field rules, fractional half-even rounding,
zone abbreviation policy and out-of-timestamp-range DATE comparisons remain
separate work. FV-12's formal theorem remains open.

Reference implementation:
[PostgreSQL 18.3 timestamp.c](https://github.com/postgres/postgres/blob/REL_18_3/src/backend/utils/adt/timestamp.c),
[date.c](https://github.com/postgres/postgres/blob/REL_18_3/src/backend/utils/adt/date.c).
