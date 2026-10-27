# Native resource observations

`machine_resources` is a Layer 1 adapter for the Layer 0 `resource_budget` planner.
It allocates nothing. Supply six disjoint scratch spans, or partition a 16-byte
aligned caller-owned page region with `Buffers.partition`. Call `observe` again
as pressure or constraints change. A plan is an admission budget, never a promise
that a future OS page commitment will succeed.

`BufferTooSmall` requires larger caller scratch and a complete retry. Short reads,
permission errors, invalid fields, overflow, aliases and observed cgroup/affinity
changes cannot silently produce a partial successful observation. Buffers impose
no compiled CPU count or resource-file size ceiling. Native Linux pathnames retain
the kernel's 4096-byte pathname syscall bound and report an error when exceeded.

## Linux

Read `/proc/self/status` for allowed CPU ranges, residency and virtual size;
`/proc/meminfo` for physical and strict commit availability; and the overcommit
policy. Resolve unified cgroup membership through decoded mountinfo paths. Prefer
the mount exposing the most ancestors. Walk every visible ancestor and combine
`memory.max`, `memory.high`, current usage and exact CPU quota fractions.
The tightest capacity and least remaining allowance can come from different
ancestors; combine them conservatively instead of pairing unrelated counters.
Recheck membership/affinity after sampling, and account for native `RLIMIT_AS`.

Only overcommit mode 2 supplies a system commit ceiling. Linux has no single
process counter for the database's commitment ownership: the caller supplies
bytes it already owns, normally from its page ledger. Virtual size and RSS are
not substitutes for that ownership. Modes 0/1 report `not_enforced` commit policy.

The adapter currently supports cgroup v2 or kernels reporting no memberships.
Legacy/hybrid v1 returns `UnsupportedControlGroupVersion`. Hidden ancestors
outside a cgroup namespace cannot be inspected; `visible_scope_levels` and
`mount_root_is_slash` describe observed paths, not proof of global visibility.
The reads form a checked sample, not an atomic kernel resource snapshot.

## Windows

Read system physical memory, process residency and app commitment. Enumerate
variable-size CPU-set records across process groups, honor default CPU sets,
single-group hard affinity, immediate job group masks and reservations belonging
to other processes. Preserve physical-core and group-local NUMA counts without
assuming one processor group. Parked CPUs remain capacity: parking is dynamic
power policy, not permanent removal.

App commit availability does **not** replace job hard limits. Query the immediate
job's process limit, job-wide limit/current committed usage, CPU group masks and
CPU rate cap. Current job usage uses information class 28, as in
[Microsoft's HCS shim](https://github.com/microsoft/hcsshim/blob/main/internal/winapi/jobobject.go);
do not use historical notification snapshots or peak usage as current usage.
Failed current-usage queries return an error rather than assuming free capacity.

`immediate_job` explicitly reports this scope: Win32 does not enumerate parent
job handles through `QueryInformationJobObject(NULL)`. Parent job constraints,
arbitrary per-thread affinity and system CPU partitions remain coverage gaps;
this adapter does not claim complete observation of those configurations.

## macOS

Read active logical/physical CPU counts, physical memory and page size through
native sysctl. Read Mach host/task counters, releasing the acquired host port
after each sample. Available physical memory is conservatively free plus
purgeable pages; speculative pages are already included in free pages. It is
reported as `free_and_purgeable`, not Linux `MemAvailable` equivalence. Inactive
anonymous pages and swap are not counted as readily available RAM.

Apply a nonzero `os_proc_available_memory` app allowance. Zero is ambiguous
(not an app, or exhausted), so it is not advertised as a discovered process
limit. Commitment ownership is supplied by the caller. Scheduling partitions,
NUMA placement, and full process-limit discovery remain coverage gaps.

Native SB0 resource ABI probing is not implemented; unsupported targets return
`UnsupportedPlatform`. None of these observations means RAMSQL has adopted
elastic storage or parallel SQL automatically.

`budgeted_region.Region` couples one unique OS mapping to the shared ledger.
Initialize it at its final caller-owned address; live handles cannot be copied
or moved. Reserve charges native page-rounded bytes, and a failed OS reservation
returns the grant. Close releases the OS mapping before returning the grant;
failed OS releases keep ownership/accounting intact. Pressure blocks new grants
without revoking live mappings. `page_region.tryClose` reports release failures;
the legacy infallible `close` stops on such a failure rather than forgetting a
live mapping. The wrapper is page ownership, not a table allocator or GC.

## Executable qualification

`sig build test-machine-resources test-resource-budget -Doptimize=ReleaseSafe`
checks actual native observations plus deterministic injected file reads. Cases
include 256 Windows CPU-set records across four groups, reservation/default/hard
affinity, parent memory pressure with a larger parent limit, quotas, mount-path
escapes, migration, missing/denied files, small/aliased buffers and 10,000 checked
random profiles. Windows additionally creates real process/job memory limits and
sets one-CPU affinity in the isolated contract process. Linux exercises real
procfs/cgroup reads and native address limits. macOS runs in the hosted OS matrix;
cross-compilation alone is not recorded as a native macOS pass.
