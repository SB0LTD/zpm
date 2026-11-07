#!/usr/bin/env python3
"""Independent PG18.3 oracle for stored generated-column restrictions."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from audit import Pg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--user', default='postgres')
    parser.add_argument('--database', default='postgres')
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    pg = Pg(args.port, args.user, args.database)
    report = {'target': 'PostgreSQL 18.3', 'qualification': 'stored_generated_restrictions',
              'matrix_queries': 0, 'extra_probes': 0, 'failures': [], 'unsupported_examples': [],
              'excluded_dimensions': ['virtual generated columns', 'inheritance and partitioning', 'system columns', 'complete planner reductions and coercion overloads', 'schema replay', 'work/cancellation budgets']}
    digest = 14695981039346656037
    def text(value):
        return None if value is None else 't' if value else 'f'
    def probe(query, wanted=None, state=None, boolean=False, affected=None):
        pg.query('SAVEPOINT oracle_case')
        actual = pg.query(query)
        if state:
            good = actual['error'] is not None and actual['error']['sqlstate'] == state
        elif affected is not None:
            good = actual['error'] is None and actual['command'].split()[-1] == affected
        else:
            good = actual['error'] is None and actual['rows'] == wanted
            if boolean:
                good = good and len(actual['columns']) == 1 and actual['columns'][0][1] == 16
        if not good:
            report['failures'].append({'sql': query, 'wanted': wanted, 'sqlstate': state, 'affected': affected, 'actual': actual})
        if actual['error']:
            pg.query('ROLLBACK TO SAVEPOINT oracle_case')
        pg.query('RELEASE SAVEPOINT oracle_case')
    try:
        if pg.query('SHOW server_version_num')['rows'] != [['180003']]:
            raise RuntimeError('Exactly PostgreSQL 18.3 is required')
        report['oracle_version'] = pg.query('SELECT version()')['rows']
        pg.query('BEGIN')
        source_path = Path(__file__).parents[1] / 'test_sql_generated_restrictions.sig'
        source = source_path.read_text(encoding='utf8').split('pub fn main')[1]
        for line in source.splitlines():
            if 'var primary:' in line:
                break
            literal = r'("(?:\\.|[^"\\])*")'
            setup = re.search(r'try db.execute\(' + literal + r',&r\)', line)
            truth = re.search(r'try truth\(' + literal + r',(true|false|null)\)', line)
            scalar = re.search(r'try scalar\(' + literal + r',(-?\d+)\)', line)
            rows = re.search(r'try booleans\(' + literal + r',&\.\{([^}]+)\}\)', line)
            mutation = re.search(r'try mutate\(' + literal + r',(\d+)\)', line)
            negative = re.search(r'try rejects\(' + literal + r',error\.(\w+)\)', line)
            unsupported = re.search(r'try unsupported\(' + literal + r'\)', line)
            if setup:
                sql = json.loads(setup[1]).replace('CREATE TABLE ', 'CREATE TEMP TABLE ').replace('CREATE SEQUENCE grseq', 'CREATE TEMP SEQUENCE grseq')
                actual = pg.query(sql)
                if actual['error']:
                    raise RuntimeError(actual['error'])
            elif truth:
                probe(json.loads(truth[1]), [[{'true': 't', 'false': 'f', 'null': None}[truth[2]]]], boolean=True)
                report['extra_probes'] += 1
            elif scalar:
                probe(json.loads(scalar[1]), [[scalar[2]]])
                report['extra_probes'] += 1
            elif rows:
                probe(json.loads(rows[1]), [[{'true': 't', 'false': 'f', 'null': None}[item.strip()]] for item in rows[2].split(',')], boolean=True)
                report['extra_probes'] += 1
            elif mutation:
                probe(json.loads(mutation[1]), affected=mutation[2])
                report['extra_probes'] += 1
            elif negative:
                states = {'Syntax': '42601', 'UndefinedFunction': '42883', 'InvalidTextRepresentation': '22P02', 'UnsupportedStatement': '0A000', 'TypeMismatch': '42804', 'DivisionByZero': '22012', 'GroupingError': '42803', 'ColumnNotFound': '42703', 'InvalidParameterValue': '22023', 'TableNotFound': '42P01', 'InvalidObjectDefinition': '42P17', 'IntegerOverflow': '22003'}
                probe(json.loads(negative[1]), state=states[negative[2]])
                report['extra_probes'] += 1
            elif unsupported:
                report['unsupported_examples'].append(json.loads(unsupported[1]))
        report.update(matrix_fnv64=f'{digest:x}', hash_encoding='UTF-8 with LF newlines',
                      contract_sha256=hashlib.sha256(source_path.read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
                      oracle_script_sha256=hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n', b'\n')).hexdigest())
    finally:
        pg.close()
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8', newline='\n')
    print(json.dumps({'matrix_queries': report['matrix_queries'], 'extra_probes': report['extra_probes'], 'failures': report['failures']}))
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
