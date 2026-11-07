# PostgreSQL parameter lexical boundaries (NET-02 candidate)

The L1 PostgreSQL codec now imports the canonical L0 `sql.Tokenizer` through
an explicit named module dependency. The engine owns its lexer source; the codec
never imports that file through a second relative module root. The official
package catalog already declares the SQL dependency.

Counting and interpolation visit only `.parameter` tokens. All intervening source
bytes, including nested comments and quoting, are copied verbatim. Dollar signs
inside identifiers, string literals or quoted identifiers are not substitutions.
The same tokenizer supplies borrowed spans to the existing type-inference and
DEALLOCATE helpers. Quoted delimiters are preserved for existing name decoding.
The codec's numeric literal rendering and NET-01 token-boundary protection remain.

No heap, new runtime grant or nesting limit is introduced. Comment nesting uses
bounded source traversal in the existing tokenizer. Statement/parameter/output
capacities remain and errors do not publish a partial replacement statement or
portal. Lexically invalid templates now return 42601 at Parse. This includes two
old interpolation-only probes (`1e-$1`, `$2e1`) which native PostgreSQL rejects;
valid negative/operator/comment boundary assertions remain.

This fixes a lexical mismatch, not the entire parameter subsystem. Values still
render into SQL text. Typed AST binding (B1.1), general unknown-OID inference,
additional literal forms, UTF-8 handling and the other NET findings remain open.
Text/identifier capacities and supported SQL grammar remain unchanged.

## Evidence

The new protocol regression fails on the unchanged baseline. After the fix,
Windows ReleaseSafe passes20754 assertions,1033 packets and4096 fuzz inputs.
Tests cover comment depths0..64 in text/binary formats, exact preserved prefixes,
quoted and identifier dollars, repeated placeholders, narrow unknown-OID update
inference and failed-Parse recovery without replacing an existing statement.
The pre-existing protocol/atomicity/authentication/fuzz tests remain enabled.
The native oracle is `python tools/verify_pg_parameter_lexing.py`, with an explicit
socket/port and expected version/major. It covers78 PREPARE templates and verifies
native results/types and temporary mutation rows. Hosted jobs pin the same PG16/18
image digests as RAMSQL qualification and retain actual server-version reports.
Only the initial5 native diagnostic queries ran locally; WSL then became
unavailable. The full native oracle and hosted matrices are pending, not claimed.

Canonical core inventory rows are reconciled to the previously observed12/89/17
SQRT run; historical8/93/17 rows remain separately preserved. This protocol fix
does not itself close a SQL feature family or change production release gates.
