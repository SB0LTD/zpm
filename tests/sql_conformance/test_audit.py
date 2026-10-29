"""Test the oracle machinery's semantic comparison and protocol boundaries."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import unittest
from audit import Pg, equivalent
from generate_contracts import literal
from verify_quantified_oracle import matrix
from verify_row_oracle import matrix as row_matrix


def result(rows):
    return {'columns': [['v', 23, 4, -1, 0]], 'rows': rows,
            'command': 'SELECT 2', 'error': None, 'transaction': 'T'}


class FragmentedSocket:
    def __init__(self, data):
        self.data = data
        self.sent = b''

    def recv(self, count):
        # Real TCP may split every field across reads.
        chunk, self.data = self.data[:1], self.data[1:]
        return chunk

    def sendall(self, data):
        self.sent += data


def message(kind, body):
    return kind + struct.pack('!I', len(body) + 4) + body


class AuditTests(unittest.TestCase):
    def test_nullif_oracle_identity(self):
        root = Path(__file__).parent
        report = json.loads((root / 'nullif_oracle.json').read_text(encoding='utf8'))
        self.assertEqual(report['failures'], [])
        self.assertEqual(len(report['cases']), 24)
        self.assertTrue(all(case['pass'] for case in report['cases']))
        for key, path in [('contract_sha256', root.parent / 'test_sql_nullif_types.sig'),
                          ('oracle_script_sha256', root / 'verify_nullif_oracle.py')]:
            self.assertEqual(report[key], hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest())

    def test_row_oracle_identity(self):
        root = Path(__file__).parent
        report = json.loads((root / 'row_oracle.json').read_text(encoding='utf8'))
        self.assertEqual(report['failures'], [])
        self.assertEqual(report['matrix_queries'], 4160)
        for key, path in [('contract_sha256', root.parent / 'test_sql_row_predicates.sig'),
                          ('oracle_script_sha256', root / 'verify_row_oracle.py')]:
            self.assertEqual(report[key], hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest())
        digest, count = 14695981039346656037, 0
        for query, wanted in row_matrix():
            for byte in query.encode() + bytes([2 if wanted is None else int(wanted)]):
                digest = ((digest ^ byte) * 1099511628211) & ((1 << 64) - 1)
            count += 1
        self.assertEqual(count, 4160)
        self.assertEqual(f'{digest:x}', report['matrix_fnv64'])
        self.assertTrue(report['unsupported_examples'])

    def test_quantified_oracle_identity(self):
        root = Path(__file__).parent
        report = json.loads((root / 'quantified_oracle.json').read_text(encoding='utf8'))
        self.assertEqual(report['failures'], [])
        self.assertEqual(report['matrix_queries'], 1152)
        paths = [('contract_sha256', root.parent / 'test_sql_quantified.sig'),
                 ('oracle_script_sha256', root / 'verify_quantified_oracle.py')]
        for key, path in paths:
            self.assertEqual(report[key], hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest())
        digest, count = 14695981039346656037, 0
        for query, wanted in matrix():
            for byte in query.encode() + bytes([2 if wanted is None else int(wanted)]):
                digest = ((digest ^ byte) * 1099511628211) & ((1 << 64) - 1)
            count += 1
        self.assertEqual(count, report['matrix_queries'])
        self.assertEqual(f'{digest:x}', report['matrix_fnv64'])

    def test_inventory_and_oracle_are_consistent(self):
        root = Path(__file__).parent
        content = (root / 'cases.json').read_bytes().replace(b'\r\n', b'\n')
        manifest = json.loads(content)
        evidence = json.loads((root / 'postgres18_oracle.json').read_text(encoding='utf8'))
        self.assertEqual(hashlib.sha256(content).hexdigest(), evidence['manifest_sha256'])
        ids = [case['id'] for case in manifest['cases']]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(set(ids), {case['id'] for case in evidence['cases']})
        cases = {case['id']: case for case in manifest['cases']}
        for case in evidence['cases']:
            if case['status'] == 'oracle_valid':
                source = cases[case['id']]
                commands = manifest['fixtures'][source['setup']] + source['statements']
                self.assertEqual(len(commands) + 1, len(case['oracle']))
                self.assertFalse(any(result['error'] for result in case['oracle']))
                for result in case['oracle']:
                    self.assertTrue(all(len(row) == len(result['columns']) for row in result['rows']))

    def test_bag_multiplicity_and_nulls(self):
        a = [result([[None], ['1'], ['1']])]
        b = [result([['1'], [None], ['1']])]
        self.assertTrue(equivalent(a, b, False))
        self.assertFalse(equivalent(a, b, True))
        self.assertFalse(equivalent(a, [result([[None], ['1'], ['2']])], False))
        self.assertFalse(equivalent(a, [result([['NULL'], ['1'], ['1']])], False))

    def test_matching_errors_never_pass_positive_case(self):
        a = result([])
        a['error'] = {'sqlstate': '42601', 'message': 'syntax error'}
        self.assertFalse(equivalent([a], [copy.deepcopy(a)], False))

    def test_type_typmod_name_format_transaction_and_tag(self):
        a = result([['1']])
        for field, value in [('command', 'INSERT 0 1'), ('transaction', 'I')]:
            b = copy.deepcopy(a)
            b[field] = value
            self.assertFalse(equivalent([a], [b], False))
        for index, value in enumerate(['other', 20, 8, 12, 1]):
            b = copy.deepcopy(a)
            b['columns'][0][index] = value
            self.assertFalse(equivalent([a], [b], False))

    def test_fragmented_wire_null_empty_and_utf8(self):
        description = struct.pack('!H', 1) + b'v\0' + struct.pack('!IhIhih', 0, 0, 25, -1, -1, 0)
        data = message(b'T', description)
        for text in [None, b'', 'שלום'.encode()]:
            body = struct.pack('!Hi', 1, -1 if text is None else len(text)) + (text or b'')
            data += message(b'D', body)
        data += message(b'C', b'SELECT 3\0') + message(b'Z', b'T')
        pg = Pg.__new__(Pg)
        pg.sock = FragmentedSocket(data)
        response = pg.query('SELECT v')
        self.assertEqual(response['columns'], [['v', 25, -1, -1, 0]])
        self.assertEqual(response['rows'], [[None], [''], ['שלום']])
        self.assertEqual(response['transaction'], 'T')
        self.assertTrue(pg.sock.sent.startswith(b'Q'))

    def test_error_fields_and_connection_loss(self):
        self.assertEqual(Pg.error(b'SERROR\0C22012\0Mdivision by zero\0\0'),
                         {'sqlstate': '22012', 'message': 'division by zero'})
        pg = Pg.__new__(Pg)
        pg.sock = FragmentedSocket(b'D\x00')
        with self.assertRaises(ConnectionError):
            pg.message()

    def test_sig_utf8_and_escaping(self):
        self.assertEqual(literal(None), 'null')
        self.assertEqual(literal('"\\\n'), '"\\x22\\x5c\\x0a"')
        self.assertEqual(literal('א'), '"\\xd7\\x90"')


if __name__ == '__main__':
    unittest.main()
