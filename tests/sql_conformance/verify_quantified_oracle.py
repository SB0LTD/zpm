#!/usr/bin/env python3
"""Validate the quantified Sig contract against an owned PG18.3 loopback oracle.

The independently generated 1152-case matrix uses the same SQL byte identity and
FNV-1a digest as the Sig contract. Resource/legacy-replay tests have no native SQL
equivalent and remain separate. No production dependencies are introduced.
"""
import argparse
import hashlib
import json
import operator
from pathlib import Path
import re
from audit import Pg


def matrix():
    values = [None, -1, 0, 1]
    ops = [('=', operator.eq), ('<>', operator.ne), ('<', operator.lt),
           ('<=', operator.le), ('>', operator.gt), ('>=', operator.ge)]
    for left in values:
        for mask in range(16):
            for name, compare in ops:
                for quantifier in ['ANY', 'SOME', 'ALL']:
                    terms = [None if left is None or right is None else compare(left, right)
                             for i, right in enumerate(values) if mask & (1 << i)]
                    if quantifier == 'ALL':
                        wanted = False if False in terms else None if None in terms else True
                    else:
                        wanted = True if True in terms else None if None in terms else False
                    predicate = ' OR '.join(f'(id={i} AND {str(bool(mask & (1 << i))).lower()})' for i in range(4))
                    query = f'SELECT {"NULL" if left is None else left} {name} {quantifier}(SELECT v FROM t WHERE {predicate})'
                    yield query, wanted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--user', default='postgres')
    parser.add_argument('--database', default='postgres')
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    connection = Pg(args.port, args.user, args.database)
    report = {'target': 'PostgreSQL 18.3', 'qualification': 'quantified_contract_only',
              'excluded_dimensions': ['legacy replay', 'resource/cancellation controls', 'multi-session MVCC schedules'],
              'matrix_queries': 0, 'extra_probes': 0, 'failures': []}
    digest = 14695981039346656037
    def probe(query, wanted, state=None, boolean=False):
        nonlocal digest
        marker = connection.query('SAVEPOINT oracle_case')
        if marker['error']:
            raise RuntimeError(marker['error'])
        response = connection.query(query)
        if state:
            valid = response['error'] is not None and response['error']['sqlstate'] == state
        else:
            valid = response['error'] is None and response['rows'] == [[wanted]]
            if boolean:
                valid = valid and response['columns'][0][1] == 16
        if not valid:
            report['failures'].append({'sql': query, 'wanted': wanted, 'sqlstate': state, 'actual': response})
        if response['error']:
            connection.query('ROLLBACK TO SAVEPOINT oracle_case')
        connection.query('RELEASE SAVEPOINT oracle_case')
    try:
        version = connection.query('SHOW server_version_num')
        if version['rows'] != [['180003']]:
            raise RuntimeError('Exactly PostgreSQL 18.3 is required')
        report['oracle_version'] = connection.query('SELECT version()')['rows']
        connection.query('BEGIN')
        source_path = Path(__file__).parents[1] / 'test_sql_quantified.sig'
        source = source_path.read_text(encoding='utf8').split('pub fn main')[1]
        for line in source.splitlines():
            if 'try matrix();' in line:
                for query, wanted in matrix():
                    for byte in query.encode() + bytes([2 if wanted is None else int(wanted)]):
                        digest = ((digest ^ byte) * 1099511628211) & ((1 << 64) - 1)
                    probe(query, None if wanted is None else 't' if wanted else 'f', boolean=True)
                    report['matrix_queries'] += 1
                continue
            # Control errors are tested in Sig, not imposed on the oracle.
            if 'var control:' in line:
                break
            literal = r'("(?:\\.|[^"\\])*")'
            setup = re.search(r'try db.execute\(' + literal + r',&r\)', line)
            truth = re.search(r'try truth\(' + literal + r',(true|false|null)\)', line)
            scalar = re.search(r'try scalar\(' + literal + r',(-?\d+)\)', line)
            negative = re.search(r'try rejects\(' + literal + r',error\.(\w+)\)', line)
            if setup:
                command = json.loads(setup[1])
                # Shadow persistent objects left by other owned oracle runs.
                command = command.replace('CREATE TABLE t(', 'CREATE TEMP TABLE t(')
                command = command.replace('CREATE SEQUENCE s', 'CREATE TEMP SEQUENCE s')
                response = connection.query(command)
                if response['error']:
                    raise RuntimeError(response['error'])
            elif truth:
                probe(json.loads(truth[1]), {'true': 't', 'false': 'f', 'null': None}[truth[2]], boolean=True)
                report['extra_probes'] += 1
            elif scalar:
                probe(json.loads(scalar[1]), scalar[2])
                report['extra_probes'] += 1
            elif negative:
                states = {'Syntax': '42601', 'UndefinedFunction': '42883', 'DivisionByZero': '22012'}
                probe(json.loads(negative[1]), None, states[negative[2]])
                report['extra_probes'] += 1
        report['matrix_fnv64'] = f'{digest:x}'
        report['contract_sha256'] = hashlib.sha256(source_path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()
        report['oracle_script_sha256'] = hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
        report['hash_encoding'] = 'UTF-8 with LF newlines'
    finally:
        connection.close()  # Roll back all fixture DDL/data.
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8', newline='\n')
    print(json.dumps(report, indent=2))
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
