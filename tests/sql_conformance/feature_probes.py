#!/usr/bin/env python3
"""SQL-standard feature probes: source format, canonical results, shared paths.

Probe programs live in `features/<family>.sql`. A probe starts with

    -- probe <ID>.<name> [EXTRA-ID ...]
    -- ordered                      (optional: rows must keep their order)

followed by statements. A statement ends with a line whose last character is
`;` outside a dollar-quoted body. Lines starting with `-- #` are file comments.
The probe counts for the feature named before the first `.` of its ID and for
every extra ID on its header line.

Every probe runs on a fresh database through one PostgreSQL simple-query
session, one statement per Query message, continuing after errors (like psql
without ON_ERROR_STOP). The recorder and the generated in-process contract
reduce each statement to the same canonical bytes:

    head: the response messages in order, joined by `;`:
          T:<col>,<col>...   RowDescription; col = name/type/typlen/typmod
          C:<command tag>    CommandComplete
          E:<SQLSTATE>       ErrorResponse (message text is not compared)
          I                  EmptyQueryResponse
          Z:<I|T|E>          ReadyForQuery transaction status
    rows: one string per DataRow, cells joined by `|`, NULL as `\\N`.

A built-in type is its OID. A type OID at or above 16384 is allocated by the
cluster; it is replaced by its catalog identity `@namespace.name.kind`, read
from pg_type inside the same session, on both sides. Text is escaped bytewise:
backslash, `|`, `,`, `/`, `;`, `#` and control bytes become `\\` sequences.
"""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROBE_DIR = ROOT / 'features'
FEATURES = ROOT / 'postgres18_features.json'
ORACLE = ROOT / 'feature_probes_oracle.json'
STATUS = ROOT / 'postgres18_feature_status.json'
FIRST_USER_OID = 16384
FAMILY_FILES = ('B', 'E', 'F', 'S', 'T', 'X')
IDENTITY_SQL = ("SELECT n.nspname,t.typname,t.typtype FROM pg_catalog.pg_type t "
                "JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE t.oid={oid}")

_ESCAPED = {0x5c: b'\\\\', 0x7c: b'\\|', 0x2c: b'\\,', 0x2f: b'\\/', 0x3b: b'\\;', 0x23: b'\\#'}


def esc(value: bytes) -> bytes:
    out = bytearray()
    for byte in value:
        if byte in _ESCAPED:
            out += _ESCAPED[byte]
        elif byte < 0x20 or byte == 0x7f:
            out += b'\\x%02x' % byte
        else:
            out.append(byte)
    return bytes(out)


def _dollar_balanced(text: str) -> bool:
    """True when every $tag$ opened in `text` is closed again."""
    open_tag = None
    for match in re.finditer(r"\$[A-Za-z_]*\$", text):
        tag = match.group(0)
        if open_tag is None:
            open_tag = tag
        elif tag == open_tag:
            open_tag = None
    return open_tag is None


def parse_file(path: Path):
    probes, current, pending = [], None, []
    for number, raw in enumerate(path.read_text(encoding='utf8').splitlines(), 1):
        line = raw.rstrip()
        stripped = line.strip()
        if not pending and stripped.startswith('-- #'):
            continue
        if not pending and stripped.startswith('-- probe '):
            words = stripped[len('-- probe '):].split()
            if not words or '.' not in words[0]:
                raise ValueError(f'{path.name}:{number}: probe needs <FEATURE>.<name>')
            current = {'id': words[0], 'features': [words[0].split('.', 1)[0]] + words[1:],
                       'ordered': False, 'statements': [], 'file': path.name}
            probes.append(current)
            continue
        if not pending and stripped == '-- ordered':
            if current is None:
                raise ValueError(f'{path.name}:{number}: directive outside a probe')
            current['ordered'] = True
            continue
        if not pending and not stripped:
            continue
        if current is None:
            raise ValueError(f'{path.name}:{number}: SQL outside a probe')
        pending.append(line)
        text = '\n'.join(pending)
        if line.endswith(';') and _dollar_balanced(text):
            current['statements'].append(text[:-1].strip())
            pending = []
    if pending:
        raise ValueError(f'{path.name}: unterminated statement: {pending[0]!r}')
    return probes


def load_probes():
    probes = []
    for family in FAMILY_FILES:
        path = PROBE_DIR / f'{family}.sql'
        if path.exists():
            probes += parse_file(path)
    seen = set()
    for probe in probes:
        if probe['id'] in seen:
            raise ValueError('Duplicate probe id ' + probe['id'])
        if not probe['statements']:
            raise ValueError('Empty probe ' + probe['id'])
        seen.add(probe['id'])
    return probes


def probes_digest(probes) -> str:
    canonical = json.dumps([[p['id'], p['features'], p['ordered'], p['statements']] for p in probes],
                           ensure_ascii=False, separators=(',', ':'))
    return hashlib.sha256(canonical.encode('utf8')).hexdigest()


def load_features():
    return json.loads(FEATURES.read_text(encoding='utf8'))['features']
