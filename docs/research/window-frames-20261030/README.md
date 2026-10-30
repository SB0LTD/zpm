# Local correctness evidence

All eight contracts pass on Windows Sig 0.6.4 ReleaseSafe, Linux Sig 0.6.4
ReleaseSafe and Linux Sig 0.5.9 Debug. Commands and matched library paths are in
`qualify_frames.py`; those absolute paths identify this workspace and must be
adapted for another machine. Initial grouping checks ran separately; revised
logs include all eight. The final frame-only rerun also checks the native SB0
min/max intrinsic workaround against the complete frame contract on each host.

| Contract | Assertions per mode |
| --- | ---: |
| New bounded frames/FILTER | 106,873 |
| Existing windows | 8,840 |
| Grouping ROLLUP | 19,443 |
| Existing committed group synopsis | 6,409 |
| Temporal to_char | 553 |
| SQL types | 4,491 |
| SQL query engine | 63,417 |
| Streaming grouping / 100,000 actual SQL-loaded rows | 1,702 |

The new fixture contains 397 real PostgreSQL 16.15 query results. Its manifest
records the exact raw TSV digest; `.gitattributes` disables newline translation.
`capture_frames_pg16.py` is the actual reference capture script, using the local
WSL PostgreSQL instance, temporary tables and stdin SQL. It changes no permanent
reference data. `source-manifest.json` records the checked source bytes with LF
normalization and exact raw TSV bytes. Retained logs prove execution, including
work/cancellation sweeps and constrained-memory fallback; assertion counts alone
are not a PostgreSQL coverage percentage.

These are correctness and algorithmic-counter checks, not throughput benchmarks.
Hosted matrix and RAMSQL PG16/18 memory/durable+SCRAM qualification remain
separate gates. The prior original dbMeter full/subset 7/7 result applies to the
previous reporting source; the new frame candidate needs final server checks.
