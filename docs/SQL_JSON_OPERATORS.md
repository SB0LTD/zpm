# JSON operator inventory slice

This candidate implements plain JSON `->`, `->>`, `#>`, `#>>` and JSONB `||`
in ZPM core. Non-text extraction retains the input type. JSON retains lexical
spacing, duplicate-key last-wins selection and numeric scale. JSONB concatenation
is shallow; object keys from the right replace equal keys on the left. Other
kind combinations concatenate arrays or wrap scalars/objects as array elements.
An unknown operand beside JSONB resolves as JSONB; explicitly typed TEXT retains
PostgreSQL text concatenation. Arrow integer overloads accept int2/int4, not int8.
Nonempty JSONB paths cannot descend through a scalar, unlike root integer arrow.

Plain JSON input validates escape syntax without interpreting Unicode escapes.
Extraction decodes/checks the complete document, rejecting invalid surrogates
and U+0000 as PostgreSQL does, even outside the selected member.

Canonicalization uses iterative depth-first traversal, one bounded key-offset
pool and heapsort by (key length, bytes, source offset). The source offset makes
duplicate handling last-wins without depending on sort stability. Sorting is
O(k log k) comparisons per object; comparison byte costs also depend on key size.
No allocator or runtime dependency is introduced. Parsing/validation, sorting,
plain JSON extraction and concatenation accept optional execution control; SQL
input/casts/operators pass the session control. Existing containment, comparison,
hashing and rendering control coverage is not closed by this work.

## Tests and limitations

- `tests/test_sql_json_operators.sig`: 201 exact PostgreSQL 16.15 value/type/error
  fixtures, SQL NULL checks, work-limit and cancellation checks, rollback at every
  charged boundary of a two-row update, and concatenation depth rejection.
  Observed ReleaseSafe: 1,559 assertions.
- `tests/test_sql_json_canonical.sig`: 4,096 reverse-ordered keys, depth 64,
  generated duplicate-heavy nested objects and render/parse identity. Observed
  ReleaseSafe: 8,051 assertions on a worker requesting a 256 KiB stack. This is
  invariant/stress coverage, not a measured stack-consumption result. The old
  implementation also passes this stress suite; no baseline stack crash claimed.
- Independent baseline work-budget reproduction fails: max_work=64 accepts a
  duplicate-heavy JSONB document before the change; the candidate raises
  QueryWorkLimit. Baseline concat fixture fails UndefinedFunction.
- Existing `test_sql_types.sig` retains all 901,501 ReleaseSafe assertions.
- `tools/capture_sql_json_oracle.py` captures native fixtures; it does not modify
  tests. PostgreSQL 18 wire comparisons belong to RAMSQL qualification.

The unchanged 118-program inventory now has **9 smoke passes, 92 failures and
17 unexecuted scopes/comparators** locally. It still exits 1 with
SqlConformanceIncomplete. PG.JSON.OPS advances; PG.JSONB.MODIFY still fails on
jsonb_set. Smoke success does not close a feature family. The 755 upstream
feature rows still lack applicability review and are not a compatibility ratio.

Remaining JSON work includes text[] path values (existing literals have a
32-component bound), jsonb_set/deletion/exists-any/all, constructors, aggregates,
table functions, jsonpath/SQL-JSON, JSON_TABLE, collation-aware comparison and
UTF8 input validation. Encoded cells still have Config.text_bytes and the u16
65535-byte ceiling. Rendered expansion (SQLF-09) remains open. General large-cell
evaluator/formatting stack use (SQLF-06) remains open beyond the canonicalizer.
There is no measured throughput claim or full JSON/SQL compatibility claim.

### Live qualification follow-up

The new no-FROM parameter case exposed a pre-existing wire rejection. The codec
now uses its existing unknown-to-TEXT fallback for constant SELECTs, permitting
explicit JSON/JSONB SQL casts. This does not implement context-wide parameter
inference or claim PostgreSQL-exact ParameterDescription OIDs for inferred
casts; typed/ambiguous expression inference remains inventory work. The failed
live fixture is retained. The report writer escapes lone surrogate code points
so legal plain JSON results cannot truncate qualification evidence.

First Linux libc CI failed in Sig0.6.4 std.Thread.join (pthread_join unreachable),
while Windows/macOS passed. The identical canonical workload now executes on the
main stack on Linux libc, with all 8,051 assertions retained. The worker remains
on Windows/macOS and no-libc Linux. This is a harness portability workaround,
not a measured stack claim or a change to engine execution.
