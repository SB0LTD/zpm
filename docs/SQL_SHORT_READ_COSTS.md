# Work charging and short prepared-message costs

The reviewer's dbMeter workload exercises real PostgreSQL JDBC prepared queries.
Sampling its point lookup shows copies as the largest named user-code hotspot
after wait/syscall samples. Parse and Bind previously zeroed and copied entire
SQL-capacity arrays even for a short source. The protocol now stages only the
initialized source and publishes its length-bounded prefix after all validation.
Portal row/completion/affected/command/savepoint/format metadata is reset
explicitly. Old unused source/format tails remain inaccessible through every
length/count-bounded accessor. This does not change SQL/message capacities.

Compact filters also previously charged large blocks through one function call
per scalar checkpoint. `ExecutionControl.advance(count)` skips only stretches
between observable polls. It preserves the original scalar method's used count,
saturation, maximum-work error position, callback work positions, callback errors,
and zero polling interval. Callbacks can change the following interval/limit.
The scalar method remains independent and is the test oracle. Session batch
charging is used only at the existing bounded compact scan charge points; no
operator side effects or result publication move across a callback.

Native contracts compare errors, exact state and every callback work position
across finite/unlimited budgets, partial poll intervals, saturation, cancellation
and callback mutations. Protocol contracts poison unused source/format tails,
rebind binary/text results repeatedly, shorten previously longer SQL, and check
that invalid Bind cannot replace the previous portal. SQL filters still compare
actual rows and work counts with the independent scalar executor.
