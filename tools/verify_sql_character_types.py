"""Replay character-type fixtures on an explicit isolated native PG endpoint.

Requires loopback trust/peer test access as postgres/postgres. Only session-local
TEMP tables/sequences are created. This verifies frozen observations, not RAMSQL.
"""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests/sql_conformance'))
from audit import Pg
from verify_numeric_functions_oracle import PeerPg

def temporary(source):
    if source.startswith('CREATE TABLE '):
        return source.replace('CREATE TABLE ', 'CREATE TEMP TABLE ', 1)
    if source.startswith('CREATE SEQUENCE '):
        return source.replace('CREATE SEQUENCE ', 'CREATE TEMP SEQUENCE ', 1)
    return source


def compare(actual, expected):
    state = actual['error']['sqlstate'] if actual['error'] else '00000'
    if state != (expected['error']['sqlstate'] if expected['error'] else '00000'):
        return False
    if state != '00000':
        return True
    return (actual['columns'] == expected['columns'] and actual['rows'] == expected['rows']
            and actual['command'] == expected['command'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    endpoint = parser.add_mutually_exclusive_group(required=True)
    endpoint.add_argument('--port', type=int)
    endpoint.add_argument('--unix-socket')
    parser.add_argument('--expected-major', type=int, choices=[16, 18], required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    fixture = json.loads((ROOT / 'tests/fixtures/character_types_pg16.json').read_text(encoding='utf8'))
    connect = lambda: PeerPg(args.unix_socket) if args.unix_socket else Pg(args.port, 'postgres', 'postgres')
    report = {'cases': [], 'scope': 'Finite native observations only; not a candidate compatibility gate'}
    result = 0
    try:
        pg = connect()
        try:
            version = pg.query('SHOW server_version_num')
            if version['error']:
                raise RuntimeError(version['error'])
            report['server_version_num'] = version['rows'][0][0]
            if int(report['server_version_num']) // 10000 != args.expected_major:
                raise RuntimeError('Unexpected native server major: ' + report['server_version_num'])
        finally:
            pg.close()
        for case in fixture['cases']:
            pg = connect()
            try:
                for source in fixture['native_session_setup']:
                    outcome = pg.query(source)
                    if outcome['error']:
                        raise RuntimeError({'case': case['id'], 'session_setup': source, 'result': outcome})
                for source in case['setup']:
                    source = temporary(source)
                    outcome = pg.query(source)
                    if outcome['error']:
                        raise RuntimeError({'case': case['id'], 'setup': source, 'result': outcome})
                events = []
                for event in case['events']:
                    actual = pg.query(temporary(event['sql']))
                    matched = compare(actual, event['outcome'])
                    events.append({'sql': event['sql'], 'match': matched, 'actual': actual})
                matched = all(event['match'] for event in events)
                report['cases'].append({'id': case['id'], 'match': matched, 'events': events})
                print(('PASS ' if matched else 'GAP ') + case['id'])
                if not matched:
                    result = 1
            finally:
                pg.close()  # drops only this connection's TEMP objects
        report['failures'] = sum(not case['match'] for case in report['cases'])
    except Exception as error:
        report['harness_error'] = {'class': type(error).__name__, 'message': str(error)}
        result = 2
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8')
    return result


if __name__ == '__main__':
    raise SystemExit(main())
