#!/usr/bin/env python3
"""Record native PostgreSQL results for the SQL-standard feature probes.

Each probe runs twice on a fresh database (`w4_features_probe`, created from
template0 by an admin connection to `w4_features`) through one simple-query
session with TimeZone=UTC. Both runs must produce identical canonical results,
or the probe is reported unstable and the recording fails. Roles named
`w4f_*` that a probe creates are dropped after each run. See feature_probes.py
for the canonical form. Development tool; Python stdlib only.
"""
import argparse
import json
import re
import socket
import struct
import sys

import feature_probes as fp

PROBE_DB = 'w4_features_probe'
ADMIN_DB = 'w4_features'


class Session:
    def __init__(self, port, user, database, timezone='UTC'):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=60)
        params = f'user\0{user}\0database\0{database}\0client_encoding\0UTF8\0'
        if timezone:
            params += f'TimeZone\0{timezone}\0'
        payload = struct.pack('!I', 196608) + (params + '\0').encode()
        self.sock.sendall(struct.pack('!I', len(payload) + 4) + payload)
        while True:
            kind, body = self.message()
            if kind == b'R' and struct.unpack('!I', body[:4])[0] != 0:
                raise RuntimeError('Recorder requires a trust-auth loopback oracle')
            if kind == b'E':
                raise RuntimeError(body.decode(errors='replace'))
            if kind == b'Z':
                return

    def close(self):
        try:
            self.sock.sendall(b'X\0\0\0\4')
        finally:
            self.sock.close()

    def read(self, count):
        chunks = bytearray()
        while len(chunks) < count:
            chunk = self.sock.recv(count - len(chunks))
            if not chunk:
                raise ConnectionError('PostgreSQL connection closed')
            chunks.extend(chunk)
        return bytes(chunks)

    def message(self):
        kind = self.read(1)
        size = struct.unpack('!I', self.read(4))[0]
        if not 4 <= size <= 64 * 1024 * 1024:
            raise ValueError('Invalid protocol message length')
        return kind, self.read(size - 4)

    def raw(self, sql):
        """Ordered response: [(kind, value)] with one ('D', cells) per DataRow."""
        data = sql.encode() + b'\0'
        self.sock.sendall(b'Q' + struct.pack('!I', len(data) + 4) + data)
        segments = []
        while True:
            kind, body = self.message()
            if kind == b'T':
                count = struct.unpack('!H', body[:2])[0]
                offset, columns = 2, []
                for _ in range(count):
                    end = body.index(0, offset)
                    name = body[offset:end]
                    _, _, oid, size, modifier, _ = struct.unpack('!IhIhih', body[end + 1:end + 19])
                    columns.append((name, oid, size, modifier))
                    offset = end + 19
                segments.append(('T', columns))
            elif kind == b'D':
                count = struct.unpack('!H', body[:2])[0]
                offset, row = 2, []
                for _ in range(count):
                    size = struct.unpack('!i', body[offset:offset + 4])[0]
                    offset += 4
                    row.append(None if size == -1 else body[offset:offset + size])
                    if size != -1:
                        offset += size
                segments.append(('D', row))
            elif kind == b'C':
                segments.append(('C', body.rstrip(b'\0')))
            elif kind == b'E':
                fields, offset = {}, 0
                while offset < len(body) and body[offset]:
                    end = body.index(0, offset + 1)
                    fields[chr(body[offset])] = body[offset + 1:end]
                    offset = end + 1
                segments.append(('E', fields.get('C', b'?????')))
            elif kind == b'I':
                segments.append(('I', None))
            elif kind in (b'G', b'H', b'W'):
                raise ValueError('Feature probes must not use COPY: ' + sql)
            elif kind == b'Z':
                segments.append(('Z', body[:1]))
                return segments
            # N (notice), S (parameter status), A (notification) are ignored.

    def rows(self, sql):
        return [value for kind, value in self.raw(sql) if kind == 'D']

    def canonical(self, sql):
        segments = self.raw(sql)
        status = segments[-1][1]
        # A failing statement's RowDescription and DataRows are discarded by
        # clients (libpq returns only the error): both sides drop the T and D
        # messages of the statement that ends in an ErrorResponse.
        parts, rows, mark_parts, mark_rows = [], [], 0, 0
        for kind, value in segments:
            if kind == 'D':
                rows.append(b'|'.join(b'\\N' if cell is None else fp.esc(cell) for cell in value))
                continue
            if kind == 'E':
                del parts[mark_parts:]
                del rows[mark_rows:]
            if kind == 'T':
                cols = []
                for name, oid, size, modifier in value:
                    if oid < fp.FIRST_USER_OID:
                        typ = str(oid).encode()
                    else:
                        typ = b'#' + str(oid).encode()
                    cols.append(fp.esc(name) + b'/' + typ + b'/' + str(size).encode() + b'/' + str(modifier).encode())
                parts.append(b'T:' + b','.join(cols))
            elif kind == 'C':
                parts.append(b'C:' + fp.esc(value))
            elif kind == 'E':
                parts.append(b'E:' + value)
            elif kind == 'I':
                parts.append(b'I')
            else:
                parts.append(b'Z:' + value)
            if kind != 'T':
                mark_parts, mark_rows = len(parts), len(rows)
        head = b';'.join(parts)
        # Allocated type OIDs become catalog identities, read in this session.
        def identity(match):
            if status == b'E':
                return b'@?'
            return identity_text(self.rows(fp.IDENTITY_SQL.format(oid=int(match.group(1)))))
        head = re.sub(rb'(?<!\\)#(\d+)', identity, head)
        return {'head': head.decode('utf8'), 'rows': [r.decode('utf8') for r in rows]}


def identity_text(found):
    """`@nsp.name.kind` from the pg_type lookup rows, or `@?` when it failed."""
    if not found or len(found) != 1 or None in found[0]:
        return b'@?'
    nsp, name, kind = found[0]
    return b'@' + fp.esc(nsp) + b'.' + fp.esc(name) + b'.' + fp.esc(kind)


def run_probe(port, user, probe):
    admin = Session(port, user, ADMIN_DB, timezone=None)
    try:
        reset(admin)
        session = Session(port, user, PROBE_DB)
        try:
            return [session.canonical(sql) for sql in probe['statements']]
        finally:
            session.close()
    finally:
        cleanup(admin)
        admin.close()


def cleanup(admin):
    """Drop the probe database and the w4f_* roles a probe created."""
    segments = admin.raw(f'DROP DATABASE IF EXISTS {PROBE_DB} WITH (FORCE)')
    if segments[0][0] == 'E':
        raise RuntimeError('Cannot drop the probe database')
    roles = admin.rows("SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'w4f\\_%'")
    for (name,) in roles:
        admin.raw('DROP ROLE ' + name.decode())


def reset(admin):
    cleanup(admin)
    segments = admin.raw(f'CREATE DATABASE {PROBE_DB} TEMPLATE template0')
    if segments[0][0] == 'E':
        raise RuntimeError('Cannot create the probe database')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=55491)
    parser.add_argument('--user', default='postgres')
    parser.add_argument('--probe', action='append', help='Record only these probe ids (merges into the report)')
    parser.add_argument('--report', type=__import__('pathlib').Path, default=fp.ORACLE)
    args = parser.parse_args()
    probes = fp.load_probes()
    bootstrap = Session(args.port, args.user, 'postgres', timezone=None)
    try:
        version = bootstrap.rows('SELECT version()')[0][0].decode()
        number = bootstrap.rows('SHOW server_version_num')[0][0].decode()
        if not number.startswith('18'):
            raise RuntimeError('Feature probes are recorded against PostgreSQL 18')
        found = bootstrap.rows(f"SELECT 1 FROM pg_database WHERE datname='{ADMIN_DB}'")
        if not found:
            bootstrap.raw(f'CREATE DATABASE {ADMIN_DB} TEMPLATE template0')
    finally:
        bootstrap.close()
    previous = {}
    if args.probe and args.report.exists():
        previous = {p['id']: p for p in json.loads(args.report.read_text(encoding='utf8'))['probes']}
    selected = [p for p in probes if not args.probe or p['id'] in args.probe]
    if args.probe and len(selected) != len(set(args.probe)):
        parser.error('Unknown probe id')
    unstable = []
    for probe in selected:
        first = run_probe(args.port, args.user, probe)
        second = run_probe(args.port, args.user, probe)
        if first != second:
            unstable.append(probe['id'])
        previous[probe['id']] = {'id': probe['id'], 'stable': first == second, 'statements': first}
        print(probe['id'], 'stable' if first == second else 'UNSTABLE', flush=True)
    report = {
        'target': 'native PostgreSQL ' + version.split()[1],
        'oracle_version': version,
        'session': {'user': args.user, 'database': PROBE_DB, 'TimeZone': 'UTC', 'client_encoding': 'UTF8'},
        'probes_sha256': fp.probes_digest(probes),
        'canonical_form': 'feature_probes.py',
        'probes': [previous[p['id']] for p in probes if p['id'] in previous],
    }
    missing = [p['id'] for p in probes if p['id'] not in previous]
    if missing:
        report['unrecorded'] = missing
    args.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n', encoding='utf8', newline='\n')
    if unstable:
        print('unstable probes:', ' '.join(unstable), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
