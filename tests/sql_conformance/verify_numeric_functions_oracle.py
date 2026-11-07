#!/usr/bin/env python3
"""Independent decimal expectations and native PG18.3 numeric-function oracle."""
import argparse
from decimal import Decimal, ROUND_CEILING, ROUND_FLOOR, ROUND_DOWN
import hashlib
import json
from pathlib import Path
import re
import socket
import struct
from audit import Pg


class PeerPg(Pg):
    """Use the same wire reader over an explicitly selected local Unix socket."""
    def __init__(self,path):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        self.sock.settimeout(30)
        try:
            self.sock.connect(path)
            payload=struct.pack('!I',196608)+b'user\0postgres\0database\0postgres\0client_encoding\0UTF8\0\0'
            self.sock.sendall(struct.pack('!I',len(payload)+4)+payload)
            while True:
                kind,body=self.message()
                if kind==b'R' and struct.unpack('!I',body[:4])[0]!=0:
                    raise RuntimeError('Explicit local peer/trust-auth instance required')
                if kind==b'E':raise RuntimeError(self.error(body))
                if kind==b'Z':break
        except BaseException:
            self.close()
            raise


def matrix():
    for n in [-12345, -10001, -9999, -101, -100, -99, -10, -1, 0,
              1, 10, 99, 100, 101, 9999, 10001, 12345]:
        value = Decimal(n).scaleb(-2)
        text = format(value, '.2f')
        for name in ['abs', 'ceil', 'floor', 'sign', 'trunc']:
            if name == 'abs':
                result = abs(value)
            elif name == 'sign':
                result = Decimal(-1 if value < 0 else 1 if value > 0 else 0)
            else:
                result = value.to_integral_value(rounding={
                    'ceil': ROUND_CEILING, 'floor': ROUND_FLOOR,
                    'trunc': ROUND_DOWN}[name])
            if result == 0:
                result = abs(result)
            yield f'SELECT {name}({text}::numeric)', 1700, str(result)
        for scale in [-3, -2, -1, 0, 1, 2, 3]:
            result = value.quantize(Decimal(1).scaleb(-scale), rounding=ROUND_DOWN)
            if result == 0:
                result = abs(result)
            yield (f'SELECT trunc({text}::numeric,{scale})', 1700,
                   format(result, f'.{max(scale, 0)}f'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--unix-socket',help='explicit local peer-auth socket (run as its database user)')
    parser.add_argument('--expected-server-version',default='180003',help='exact server_version_num, default180003')
    args = parser.parse_args()
    pg = PeerPg(args.unix_socket) if args.unix_socket else Pg(args.port, 'postgres', 'postgres')
    source_path = Path(__file__).parents[1] / 'test_sql_numeric_functions.sig'
    report = {'target': 'PostgreSQL 18.3', 'matrix_queries': 0,
              'extra_probes': 0, 'failures': [],
              'excluded_dimensions': ['numeric results outside configured coefficient/display capacity',
                                      'other mathematical functions and overloads',
                                      'extended-wire parameter lifecycle',
                                      'WAL replay and execution budgets (Sig-only tests)']}
    digest = hashlib.sha256()

    def probe(query, oid=None, wanted=None, state=None):
        pg.query('SAVEPOINT oracle_case')
        actual = pg.query(query)
        if state:
            good = actual['error'] is not None and actual['error']['sqlstate'] == state
        else:
            good = (actual['error'] is None and actual['rows'] == [[wanted]]
                    and len(actual['columns']) == 1 and actual['columns'][0][1] == oid
                    and actual['columns'][0][3] == -1)
        if not good:
            report['failures'].append(dict(sql=query, oid=oid, text=wanted,
                                            sqlstate=state, actual=actual))
        if actual['error']:
            pg.query('ROLLBACK TO SAVEPOINT oracle_case')
        pg.query('RELEASE SAVEPOINT oracle_case')

    try:
        if pg.query('SHOW server_version_num')['rows'] != [[args.expected_server_version]]:
            raise RuntimeError('Unexpected native PostgreSQL version')
        report['target']='PostgreSQL '+pg.query('SHOW server_version')['rows'][0][0]
        report['oracle_version'] = pg.query('SELECT version()')['rows']
        pg.query('BEGIN')
        for query, oid, wanted in matrix():
            probe(query, oid, wanted)
            digest.update(json.dumps([query, oid, wanted], separators=(',', ':')).encode())
            report['matrix_queries'] += 1
        for line in source_path.read_text(encoding='utf8').split('pub fn main')[1].splitlines():
            if 'var primary:' in line:
                break
            literal = r'("(?:\\.|[^"\\])*")'
            case = re.search(r'try row\(' + literal + r',(\d+),(null|' + literal + r')\)', line)
            setup = re.search(r'try db.execute\(' + literal + r',&r\)', line)
            negative = re.search(r'try rejects\(' + literal + r',error\.(\w+)\)', line)
            if case:
                probe(json.loads(case[1]), int(case[2]), json.loads(case[3]))
                report['extra_probes'] += 1
            elif setup:
                query = json.loads(setup[1]).replace('CREATE TABLE ', 'CREATE TEMP TABLE ').replace('CREATE SEQUENCE ', 'CREATE TEMP SEQUENCE ')
                actual = pg.query(query)
                if actual['error']:
                    raise RuntimeError(actual['error'])
            elif negative:
                states = {'UndefinedFunction': '42883', 'AmbiguousFunction':'42725','InvalidTextRepresentation': '22P02',
                          'IntegerOverflow': '22003', 'NumericValueOutOfRange': '22003',
                          'DivisionByZero':'22012','GroupingError':'42803','InvalidColumnReference':'42P10'}
                probe(json.loads(negative[1]), state=states[negative[2]])
                report['extra_probes'] += 1
        report.update(matrix_sha256=digest.hexdigest(), hash_encoding='UTF-8 with LF newlines',
                      contract_sha256=hashlib.sha256(source_path.read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
                      oracle_script_sha256=hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n', b'\n')).hexdigest())
    finally:
        pg.close()
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8', newline='\n')
    print(json.dumps({k: report[k] for k in ['matrix_queries', 'extra_probes', 'failures']}))
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
