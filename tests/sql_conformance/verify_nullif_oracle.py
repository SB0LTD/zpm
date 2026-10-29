#!/usr/bin/env python3
"""Validate NULLIF result OIDs and text values on an owned PG18.3 instance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from audit import Pg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    pg = Pg(args.port, 'postgres', 'postgres')
    report = {'target': 'PostgreSQL 18.3', 'cases': [], 'failures': []}
    source = Path(__file__).parents[1] / 'test_sql_nullif_types.sig'
    try:
        if pg.query('SHOW server_version_num')['rows'] != [['180003']]:
            raise RuntimeError('Exactly PostgreSQL 18.3 is required')
        pg.query("SET TIME ZONE 'UTC'")
        pg.query('BEGIN')
        for line in source.read_text(encoding='utf8').split('pub fn main')[1].splitlines():
            literal = r'("(?:\\.|[^"\\])*")'
            case = re.search(r'try row\(' + literal + r',(\d+),(null|' + literal + r')\)', line)
            setup = re.search(r'try db.execute\(' + literal + r',&result\)', line)
            if case:
                query, oid, wanted = json.loads(case[1]), int(case[2]), json.loads(case[3])
                actual = pg.query(query)
                good = actual['error'] is None and actual['rows'] == [[wanted]] and len(actual['columns']) == 1 and actual['columns'][0][1] == oid
                item = {'sql': query, 'oid': oid, 'text': wanted, 'pass': good}
                report['cases'].append(item)
                if not good:
                    report['failures'].append(dict(item, actual=actual))
            elif setup:
                command = json.loads(setup[1]).replace('CREATE SEQUENCE nt', 'CREATE TEMP SEQUENCE nt').replace('CREATE TABLE nt_values(', 'CREATE TEMP TABLE nt_values(')
                actual = pg.query(command)
                if actual['error']:
                    raise RuntimeError(actual['error'])
        report['contract_sha256'] = hashlib.sha256(source.read_bytes().replace(b'\r\n', b'\n')).hexdigest()
        report['oracle_script_sha256'] = hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
        report['hash_encoding'] = 'UTF-8 with LF newlines'
    finally:
        pg.close()
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8', newline='\n')
    print(json.dumps({'cases': len(report['cases']), 'failures': report['failures']}))
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
