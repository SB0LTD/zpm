#!/usr/bin/env python3
"""Record native PostgreSQL results for the privileges contract (B11 wave 5).

Programs live in `privileges_programs.sql` (`-- program <name>` headers, one
statement per `;`-terminated line group, `-- #` comments). Each program runs
on a fresh database (`w5_privileges_probe`, created from template0 by an admin
connection to `w5_privileges`) through one simple-query session as the
bootstrap superuser, continuing after errors. Roles named `w5p_*` are dropped
after each program.

Each statement is reduced to feature_probes.py's canonical head and rows,
plus every NoticeResponse as `N:<SQLSTATE>:<message>` in message order (the
privileges lane checks warning and notice texts). ZPM's bootstrap superuser
is named `ramsql` where PostgreSQL's is `postgres`: that one role name is
rewritten in rows and messages. The result is written as Sig data to
tests/sql_privileges_oracle.sig. Development tool; Python stdlib only.
"""
import argparse
import re
import struct
from pathlib import Path

import feature_probes as fp
import verify_feature_oracle as vfo

ROOT = Path(__file__).resolve().parent
PROGRAMS = ROOT / 'privileges_programs.sql'
OUTPUT = ROOT.parent / 'sql_privileges_oracle.sig'
PROBE_DB = 'w5_privileges_probe'
ADMIN_DB = 'w5_privileges'
BOOTSTRAP = re.compile(rb'\bpostgres\b')


def bootstrap(value: bytes) -> bytes:
    return BOOTSTRAP.sub(b'ramsql', value)


class Session(vfo.Session):
    def notices_and_raw(self, sql):
        data = sql.encode() + b'\0'
        self.sock.sendall(b'Q' + struct.pack('!I', len(data) + 4) + data)
        segments = []
        while True:
            kind, body = self.message()
            if kind == b'N':
                fields, offset = {}, 0
                while offset < len(body) and body[offset]:
                    end = body.index(0, offset + 1)
                    fields[chr(body[offset])] = body[offset + 1:end]
                    offset = end + 1
                segments.append(('N', (fields.get('C', b'?'), fields.get('M', b''))))
                continue
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
            elif kind == b'Z':
                segments.append(('Z', body[:1]))
                return segments

    def statement(self, sql):
        parts, rows, mark_parts, mark_rows = [], [], 0, 0
        for kind, value in self.notices_and_raw(sql):
            if kind == 'D':
                rows.append(b'|'.join(b'\\N' if cell is None else fp.esc(bootstrap(cell)) for cell in value))
                continue
            if kind == 'E':
                del parts[mark_parts:]
                del rows[mark_rows:]
            if kind == 'T':
                cols = []
                for name, oid, size, modifier in value:
                    typ = str(oid).encode() if oid < fp.FIRST_USER_OID else b'#'
                    cols.append(fp.esc(name) + b'/' + typ + b'/' + str(size).encode() + b'/' + str(modifier).encode())
                parts.append(b'T:' + b','.join(cols))
            elif kind == 'N':
                state, message = value
                parts.append(b'N:' + state + b':' + fp.esc(bootstrap(message)))
            elif kind == 'C':
                parts.append(b'C:' + fp.esc(value))
            elif kind == 'E':
                parts.append(b'E:' + value)
            elif kind == 'I':
                parts.append(b'I')
            else:
                parts.append(b'Z:' + value)
            if kind not in ('T', 'N'):
                mark_parts, mark_rows = len(parts), len(rows)
        return {'head': b';'.join(parts).decode('utf8'), 'rows': [r.decode('utf8') for r in rows]}


def parse_programs():
    programs, current, pending = [], None, []
    for raw in PROGRAMS.read_text(encoding='utf8').splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not pending and (stripped.startswith('-- #') or not stripped):
            continue
        if not pending and stripped.startswith('-- program '):
            current = {'name': stripped.split()[2], 'statements': []}
            programs.append(current)
            continue
        pending.append(line)
        text = '\n'.join(pending)
        if line.endswith(';') and fp._dollar_balanced(text):
            current['statements'].append(text.strip())
            pending = []
    if pending:
        raise ValueError('unterminated statement')
    return programs


def cleanup(admin):
    segments = admin.raw(f'DROP DATABASE IF EXISTS {PROBE_DB} WITH (FORCE)')
    if segments[0][0] == 'E':
        raise RuntimeError('Cannot drop the probe database')
    for (name,) in admin.rows("SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'w5p\\_%'"):
        admin.raw('DROP ROLE ' + name.decode())


def run(port, user, program):
    admin = vfo.Session(port, user, ADMIN_DB, timezone=None)
    try:
        cleanup(admin)
        if admin.raw(f'CREATE DATABASE {PROBE_DB} TEMPLATE template0')[0][0] == 'E':
            raise RuntimeError('Cannot create the probe database')
        session = Session(port, user, PROBE_DB)
        try:
            return [session.statement(sql) for sql in program['statements']]
        finally:
            session.close()
    finally:
        cleanup(admin)
        admin.close()


def sig_string(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=55491)
    parser.add_argument('--user', default='postgres')
    args = parser.parse_args()
    version = vfo.Session(args.port, args.user, ADMIN_DB, timezone=None)
    oracle = version.rows('SELECT version()')[0][0].decode()
    version.close()
    out = ['//! GENERATED by tests/sql_conformance/record_privileges.py from',
           '//! tests/sql_conformance/privileges_programs.sql against native',
           f'//! {oracle}.',
           '//! Do not edit by hand: change the programs and re-record.',
           'pub const Statement = struct { source: []const u8, head: []const u8, rows: []const []const u8 };',
           'pub const Program = struct { name: []const u8, statements: []const Statement };',
           'pub const programs = [_]Program{']
    for program in parse_programs():
        results = run(args.port, args.user, program)
        out.append('    .{ .name = ' + sig_string(program['name']) + ', .statements = &.{')
        for sql, result in zip(program['statements'], results):
            rows = ', '.join(sig_string(r) for r in result['rows'])
            source = sql[:-1] if sql.endswith(';') else sql
            out.append('        .{ .source = ' + sig_string(source) + ', .head = ' + sig_string(result['head']) +
                       ', .rows = &.{' + rows + '} },')
        out.append('    } },')
    out.append('};')
    OUTPUT.write_text('\n'.join(out) + '\n', encoding='utf8')
    print(f'wrote {OUTPUT}')


if __name__ == '__main__':
    main()
