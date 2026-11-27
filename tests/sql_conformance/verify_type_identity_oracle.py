#!/usr/bin/env python3
"""Record catalog identities for the allocated type OIDs in postgres18_oracle.json.

The recorded oracle keeps raw result-column type OIDs. OIDs at or above 16384
are cluster-counter values (18673, 18682, ...) that no other server reproduces.
audit.py compares them by catalog identity (namespace, type name, kind) read
inside the fixture transaction. The in-process core driver needs the same
identity for the oracle side, so this tool replays every oracle-valid
transaction case that reports an allocated OID on native PostgreSQL, checks
that each statement reproduces the recorded oracle exactly (command tag,
transaction status, rows, column names, lengths, modifiers, formats and every
built-in OID), and records the pg_type identity of each allocated column.

The recorded oracle file itself is never modified. Development tool; stdlib.
"""
import argparse
import hashlib
import json
from pathlib import Path

from audit import FIRST_USER_OID, Pg

ROOT = Path(__file__).resolve().parent
DEFAULT_REPORT = ROOT / 'type_identity_oracle.json'
DATABASE = 'w4_features_identity'
IDENTITY = ("SELECT n.nspname,t.typname,t.typtype FROM pg_catalog.pg_type t "
            "JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE t.oid={oid}")


def allocated(statement):
    return any(column[1] >= FIRST_USER_OID for column in statement['columns'])


def same_shape(recorded, replayed):
    if recorded['command'] != replayed['command'] or recorded['transaction'] != replayed['transaction']:
        return False
    if replayed['error'] or recorded['rows'] != replayed['rows']:
        return False
    if len(recorded['columns']) != len(replayed['columns']):
        return False
    for a, b in zip(recorded['columns'], replayed['columns']):
        if a[0] != b[0] or a[2:] != b[2:]:
            return False
        if (a[1] >= FIRST_USER_OID) != (b[1] >= FIRST_USER_OID):
            return False
        if a[1] < FIRST_USER_OID and a[1] != b[1]:
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=55491)
    parser.add_argument('--user', default='postgres')
    parser.add_argument('--oracle-report', type=Path, default=ROOT / 'postgres18_oracle.json')
    parser.add_argument('--report', type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    manifest_bytes = (ROOT / 'cases.json').read_bytes().replace(b'\r\n', b'\n')
    manifest = json.loads(manifest_bytes)
    oracle_bytes = args.oracle_report.read_bytes()
    oracle = json.loads(oracle_bytes)
    if oracle.get('manifest_sha256') != hashlib.sha256(manifest_bytes).hexdigest():
        raise SystemExit('Stale oracle report for cases.json')
    admin = Pg(args.port, args.user, 'postgres')
    try:
        version = admin.query('SELECT version()')['rows'][0][0]
        if not admin.query('SHOW server_version_num')['rows'][0][0].startswith('18'):
            raise SystemExit('A native PostgreSQL 18 oracle is required')
    finally:
        admin.close()
    cases = {c['id']: c for c in manifest['cases']}
    report = {'target': 'native ' + ' '.join(version.split()[:2]), 'oracle_version': version,
              'manifest_sha256': oracle['manifest_sha256'],
              'oracle_report_sha256': hashlib.sha256(oracle_bytes.replace(b'\r\n', b'\n')).hexdigest(),
              'note': 'Statement indexes count fixture and case statements after the driver-owned BEGIN.',
              'cases': {}}
    failures = []
    for entry in oracle['cases']:
        case = cases.get(entry['id'])
        if entry.get('status') != 'oracle_valid' or case is None or case['scope'] != 'transaction':
            continue
        recorded = entry['oracle'][1:]
        if not any(allocated(statement) for statement in recorded):
            continue
        admin = Pg(args.port, args.user, 'postgres')
        try:
            admin.query(f'DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE)')
            created = admin.query(f'CREATE DATABASE {DATABASE} TEMPLATE template0')
            if created['error']:
                raise SystemExit('Cannot create ' + DATABASE)
        finally:
            admin.close()
        session = Pg(args.port, args.user, DATABASE)
        identities = {}
        try:
            session.query('BEGIN')
            commands = manifest['fixtures'][case['setup']] + case['statements']
            for index, (source, expected) in enumerate(zip(commands, recorded)):
                replayed = session.query(source)
                if not same_shape(expected, replayed):
                    failures.append({'id': entry['id'], 'statement': index, 'replayed': replayed})
                    break
                columns = {}
                for position, column in enumerate(replayed['columns']):
                    if column[1] >= FIRST_USER_OID:
                        found = session.query(IDENTITY.format(oid=column[1]))
                        if found['error'] or len(found['rows']) != 1:
                            failures.append({'id': entry['id'], 'statement': index, 'column': position})
                            break
                        columns[str(position)] = found['rows'][0]
                if columns:
                    identities[str(index)] = columns
            else:
                report['cases'][entry['id']] = identities
        finally:
            session.close()
    admin = Pg(args.port, args.user, 'postgres')
    try:
        admin.query(f'DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE)')
    finally:
        admin.close()
    if failures:
        report['failures'] = failures
    args.report.write_text(json.dumps(report, indent=1) + '\n', encoding='utf8')
    print(json.dumps({'cases': list(report['cases']), 'failures': len(failures)}))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
