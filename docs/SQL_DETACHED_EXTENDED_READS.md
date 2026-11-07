# Independent execution for PostgreSQL extended queries

`postgres.Session.detachedCandidate` proposes work for a caller that owns the
session exclusively and holds the database's shared read gate. It does not
authorize arbitrary SQL under that gate. Execute/Describe candidates must bind
successfully in an independent `Database.ReadContext`, rejecting mutation,
locking, sequence and unsupported named-zone plans before codec execution.

Parse, Bind, Close, Flush and Sync operate on session-owned protocol metadata.
Parse type inference requires the private `Store.Connection.describe` adapter;
it must not install `Raw.session` or use the database's shared parser/workspace.
The caller must first establish idle autocommit eligibility, provide private
session formatting/control state, and preserve ownership through result encoding.
Transactions, COPY, authentication, failed/oversized frames, and suspended portals
retain the serialized route. Parameterized statement Describe retains its
existing route; bound portal Describe and Execute can use independent contexts.

`ReadContext.describeResult` publishes metadata from an already bound read and
never evaluates projection expressions. In particular `SELECT 1/0` can be
described without dividing. Query and general/CTE column types and typmods are
preserved. Cancellation/work errors from speculative binding must survive into
the codec response instead of disappearing during a second Describe bind.

Protocol interpolation may lend transient source text. The server must clear
retained plans/source/database references at the end of every codec call, before
reusing that worker's context. A worker context is not a prepared-plan cache.
Every Execute gets the current committed snapshot; mutations remain exclusive
until the complete shared read and result encoding finish.
