## Changes

Apply native table-wide privilege sets to information_schema.tables and information_schema.columns. Share effective-grant calculation with statement authorization and preserve PostgreSQL catalog discovery behavior.

## Verification

Baseline reproduced grantless relation discovery. Candidate ReleaseSafe catalog security test passed 1,168 assertions and replayed 203 change records. Coverage includes inherited SELECT, DELETE-only grants, MAINTAIN, PUBLIC REFERENCES, revocation, owner access and pg_class visibility.

Reference: https://github.com/postgres/postgres/blob/REL_18_3/src/backend/catalog/information_schema.sql
