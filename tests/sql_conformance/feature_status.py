#!/usr/bin/env python3
"""Build the SQL-standard feature scoreboard from executed feature probes.

Input: the ndjson that `contract-sql-features` (tests/test_sql_features.sig)
prints. Every status comes from that execution, never from reading code:

  closed   every probe of the feature matches native PostgreSQL 18.7
  partial  some probes match
  open     no probe matches, or the feature has no probe yet ("unprobed")
  not_applicable  the feature is out of scope (PostgreSQL does not support
           it, or it has no meaning for a wire-protocol engine; see reason)

A parent record (for example E011) aggregates its own probes and the probes
of its in-scope subfeatures (E011-01 ...).

Writes postgres18_feature_status.json and docs/SQL_FEATURE_STATUS.md.
"""
import argparse
import json
from collections import Counter, OrderedDict
from pathlib import Path

import feature_probes as fp

DOC = fp.ROOT.parents[1] / 'docs' / 'SQL_FEATURE_STATUS.md'

# PostgreSQL lists these as supported, but they are client-side language
# bindings or PostgreSQL itself rejects them; there is nothing for the engine
# to match.
DEVIATIONS = {
    'B012': 'Embedded C is the ECPG client precompiler; it reaches the engine through the wire protocol.',
    'E182': 'Host language binding is provided by client libraries and precompilers, not the engine.',
    'F181': 'Multiple module support concerns SQL module/ECPG compilation units, not the engine.',
    'F611': 'Indicator data types belong to embedded SQL host variables (ECPG).',
    'F771': 'CONNECT / SET CONNECTION / DISCONNECT are embedded SQL client statements (ECPG).',
    'T627': ('Native PostgreSQL 18.7 rejects DISTINCT in window aggregates with 0A000 although '
             'sql_features.txt lists T627; probe T627.window_count_distinct records the rejection.'),
}

# Engine areas, in the order the ranked work list presents them (the areas
# applications exercise most come first).
AREAS = OrderedDict([
    ('query', 'Query composition: joins, subqueries, set operations, ORDER BY/FETCH/OFFSET'),
    ('constraints_dml', 'DML and integrity constraints, MERGE, referential actions'),
    ('ddl', 'DDL and schema objects: tables, views, schemas, ALTER, domains, collations'),
    ('types', 'Core data types, casts and literals'),
    ('datetime', 'Date, time, timestamp and interval'),
    ('text', 'Character strings and text functions'),
    ('numeric', 'Numeric functions'),
    ('windows', 'Window functions'),
    ('grouping', 'Aggregates and grouping sets'),
    ('transactions', 'Transactions, savepoints, isolation and session'),
    ('cursors', 'Cursors'),
    ('triggers', 'Triggers'),
    ('routines', 'Routines: functions, procedures, PL/pgSQL, overloading'),
    ('privileges', 'Privileges and roles'),
    ('catalog', 'information_schema and catalog views'),
    ('arrays', 'Arrays and user-defined type arrays'),
    ('json', 'SQL/JSON'),
    ('xml', 'SQL/XML'),
    ('lexical', 'Lexical: identifiers, comments, literals'),
    ('bindings', 'Language bindings'),
])

AREA_OF = {
    'B': 'bindings', 'X': 'xml',
    'E011': 'types', 'E021': 'text', 'E031': 'lexical', 'E051': 'query', 'E061': 'query', 'E071': 'query',
    'E081': 'privileges', 'E091': 'grouping', 'E101': 'constraints_dml', 'E111': 'query', 'E121': 'cursors',
    'E131': 'query', 'E141': 'constraints_dml', 'E151': 'transactions', 'E152': 'transactions',
    'E153': 'constraints_dml', 'E161': 'lexical', 'E171': 'transactions', 'E182': 'bindings',
    'F021': 'catalog', 'F031': 'ddl', 'F031-03': 'privileges', 'F031-19': 'privileges', 'F032': 'ddl',
    'F033': 'ddl', 'F034': 'privileges', 'F035': 'privileges', 'F036': 'privileges', 'F037': 'privileges',
    'F038': 'privileges', 'F041': 'query', 'F051': 'datetime', 'F052': 'datetime', 'F053': 'datetime',
    'F081': 'ddl', 'F111': 'transactions', 'F112': 'transactions', 'F113': 'transactions',
    'F114': 'transactions', 'F131': 'grouping', 'F171': 'ddl', 'F181': 'bindings', 'F191': 'constraints_dml',
    'F200': 'constraints_dml', 'F201': 'types', 'F202': 'constraints_dml', 'F221': 'constraints_dml',
    'F222': 'constraints_dml', 'F231': 'catalog', 'F251': 'ddl', 'F261': 'query', 'F262': 'query',
    'F271': 'lexical', 'F281': 'text', 'F292': 'constraints_dml', 'F302': 'query', 'F303': 'query',
    'F304': 'query', 'F305': 'query', 'F311': 'ddl', 'F311-04': 'constraints_dml', 'F311-05': 'privileges',
    'F312': 'constraints_dml', 'F313': 'constraints_dml', 'F314': 'constraints_dml', 'F321': 'privileges',
    'F341': 'catalog', 'F361': 'routines', 'F381': 'ddl', 'F382': 'ddl', 'F383': 'ddl', 'F384': 'ddl',
    'F385': 'ddl', 'F386': 'ddl', 'F387': 'ddl', 'F388': 'ddl', 'F391': 'lexical', 'F392': 'lexical',
    'F393': 'lexical', 'F394': 'text', 'F401': 'query', 'F402': 'query', 'F404': 'query', 'F405': 'query',
    'F406': 'query', 'F407': 'query', 'F411': 'datetime', 'F421': 'types', 'F431': 'cursors',
    'F432': 'cursors', 'F433': 'cursors', 'F434': 'cursors', 'F435': 'cursors', 'F436': 'cursors',
    'F437': 'cursors', 'F438': 'cursors', 'F441': 'grouping', 'F442': 'grouping', 'F471': 'query',
    'F481': 'query', 'F491': 'ddl', 'F492': 'constraints_dml', 'F501': 'catalog', 'F502': 'catalog',
    'F531': 'ddl', 'F555': 'datetime', 'F561': 'query', 'F571': 'query', 'F591': 'query', 'F611': 'bindings',
    'F641': 'query', 'F651': 'query', 'F661': 'query', 'F672': 'constraints_dml', 'F690': 'ddl',
    'F692': 'ddl', 'F701': 'constraints_dml', 'F711': 'ddl', 'F731': 'privileges', 'F751': 'constraints_dml',
    'F761': 'transactions', 'F762': 'catalog', 'F763': 'catalog', 'F771': 'bindings',
    'F781': 'constraints_dml', 'F791': 'cursors', 'F801': 'grouping', 'F850': 'query', 'F851': 'query',
    'F852': 'query', 'F855': 'query', 'F856': 'query', 'F857': 'query', 'F858': 'query', 'F859': 'query',
    'F860': 'query', 'F861': 'query', 'F862': 'query', 'F863': 'query', 'F864': 'query', 'F865': 'query',
    'F867': 'query', 'F868': 'query', 'F869': 'catalog',
    'S071': 'routines', 'S090': 'arrays', 'S092': 'arrays', 'S095': 'arrays', 'S096': 'arrays',
    'S098': 'arrays', 'S099': 'arrays', 'S111': 'query', 'S201': 'arrays', 'S203': 'arrays',
    'S204': 'arrays', 'S211': 'routines', 'S301': 'arrays', 'S404': 'arrays',
    'T031': 'types', 'T054': 'numeric', 'T055': 'text', 'T056': 'text', 'T061': 'text', 'T071': 'types',
    'T081': 'types', 'T121': 'query', 'T122': 'query', 'T131': 'query', 'T132': 'query', 'T133': 'query',
    'T141': 'text', 'T151': 'query', 'T152': 'query', 'T171': 'ddl', 'T172': 'ddl', 'T173': 'ddl',
    'T174': 'ddl', 'T177': 'ddl', 'T178': 'ddl', 'T191': 'constraints_dml', 'T201': 'constraints_dml',
    'T212': 'triggers', 'T213': 'triggers', 'T214': 'triggers', 'T215': 'triggers', 'T216': 'triggers',
    'T217': 'triggers', 'T241': 'transactions', 'T261': 'transactions', 'T271': 'transactions',
    'T281': 'privileges', 'T285': 'query', 'T312': 'text', 'T321': 'routines', 'T321-06': 'catalog',
    'T321-07': 'catalog', 'T323': 'routines', 'T325': 'routines', 'T331': 'privileges', 'T332': 'privileges',
    'T341': 'routines', 'T351': 'lexical', 'T431': 'grouping', 'T432': 'grouping', 'T433': 'grouping',
    'T434': 'grouping', 'T441': 'numeric', 'T461': 'query', 'T491': 'query', 'T501': 'query',
    'T521': 'routines', 'T523': 'routines', 'T524': 'routines', 'T525': 'routines', 'T551': 'lexical',
    'T581': 'text', 'T591': 'constraints_dml', 'T611': 'windows', 'T612': 'windows', 'T613': 'query',
    'T614': 'windows', 'T615': 'windows', 'T617': 'windows', 'T620': 'windows', 'T621': 'numeric',
    'T622': 'numeric', 'T623': 'numeric', 'T624': 'numeric', 'T626': 'grouping', 'T627': 'windows',
    'T631': 'query', 'T651': 'routines', 'T653': 'routines', 'T655': 'routines', 'T661': 'lexical',
    'T662': 'lexical', 'T670': 'transactions',
}

# Ranked work-list order inside an area: core families first.
FAMILY_RANK = {'E': 0, 'F': 1, 'T': 2, 'S': 3, 'X': 5, 'B': 6}


def area_of(feature_id):
    if feature_id in AREA_OF:
        return AREA_OF[feature_id]
    base = feature_id.split('-')[0]
    if base in AREA_OF:
        return AREA_OF[base]
    if feature_id.startswith('T8'):
        return 'json'
    return AREA_OF.get(feature_id[0], 'query')


def load_results(path):
    results = {}
    summary = None
    for line in path.read_text(encoding='utf8', errors='replace').splitlines():
        if not line.startswith('{'):
            continue
        row = json.loads(line)
        if 'suite' in row:
            summary = row
        elif 'probe' in row:
            results[row['probe']] = row
    return results, summary


def failure_note(row, sources):
    """The first mismatching statement: its SQL, native response, ZPM response."""
    statement = sources[row['probe']][row['statement']] if row['statement'] < len(sources[row['probe']]) else ''
    statement = ' '.join(statement.split())
    if len(statement) > 90:
        statement = statement[:87] + '...'
    detail = f"{row['probe']} #{row['statement']} `{statement}`"
    wanted, got = row.get('wanted', ''), row.get('got', '')
    if row['what'] in ('head', 'rows'):
        detail += f" {row['what']}: PostgreSQL {wanted[:60]!r}, ZPM {got[:60]!r}"
    else:
        detail += f": {row['what']}"
    return detail


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True, help='ndjson printed by contract-sql-features')
    parser.add_argument('--status', type=Path, default=fp.STATUS)
    parser.add_argument('--doc', type=Path, default=DOC)
    args = parser.parse_args()
    features = fp.load_features()
    probes = fp.load_probes()
    oracle = json.loads(fp.ORACLE.read_text(encoding='utf8'))
    if oracle['probes_sha256'] != fp.probes_digest(probes):
        raise SystemExit('Stale oracle: re-record before building the scoreboard')
    results, summary = load_results(args.results)
    sources = {p['id']: p['statements'] for p in probes}
    missing = [p['id'] for p in probes if p['id'] not in results]
    if missing:
        raise SystemExit('Results lack probes (crash or stale build?): ' + ', '.join(missing[:10]))
    ids = {f['id'] for f in features}
    unknown = sorted({fid for p in probes for fid in p['features'] if fid not in ids})
    if unknown:
        raise SystemExit('Probes name unknown feature ids: ' + ', '.join(unknown))

    by_feature = {}
    for probe in probes:
        for fid in probe['features']:
            by_feature.setdefault(fid, []).append(probe['id'])
    in_scope = {f['id'] for f in features if f['postgres_supported'] and f['id'] not in DEVIATIONS}
    children = {}
    for f in features:
        if f['subfeature'] and f['id'] in in_scope:
            children.setdefault(f['id'].split('-')[0], []).append(f['id'])

    entries = OrderedDict()
    for f in features:
        fid = f['id']
        own = list(by_feature.get(fid, []))
        evidence = own + [p for child in children.get(fid, []) for p in by_feature.get(child, []) if p not in own]
        entry = OrderedDict(name=f['name'] if not f['subfeature'] else f"{f['name']}: {f['subfeature']}")
        if not f['postgres_supported']:
            entry.update(applicability='out_of_scope', status='not_applicable', evidence=evidence,
                         note='PostgreSQL 18 does not support it (sql_features.txt).')
        elif fid in DEVIATIONS:
            entry.update(applicability='out_of_scope', reason=DEVIATIONS[fid], status='not_applicable',
                         evidence=evidence, note='')
        else:
            passed = [p for p in evidence if results[p]['pass']]
            failed = [p for p in evidence if not results[p]['pass']]
            if not evidence:
                status, note = 'open', 'unprobed'
            elif not failed:
                status, note = 'closed', f'{len(passed)}/{len(evidence)} probes match native PostgreSQL 18.7.'
            elif passed:
                status = 'partial'
                note = f'{len(passed)}/{len(evidence)} probes match; first gap: ' + failure_note(results[failed[0]], sources)
            else:
                status = 'open'
                note = f'0/{len(evidence)} probes match; first gap: ' + failure_note(results[failed[0]], sources)
            entry.update(applicability='in_scope', status=status, evidence=evidence, note=note,
                         area=area_of(fid))
        entries[fid] = entry

    scoped = [e for e in entries.values() if e['applicability'] == 'in_scope']
    totals = Counter(e['status'] for e in scoped)
    report = OrderedDict(
        schema=1,
        source='postgres18_features.json (PostgreSQL REL_18_3 sql_features.txt)',
        oracle=oracle['target'] + '; probes recorded by verify_feature_oracle.py',
        method=('Status comes from executing tests/sql_conformance/features/*.sql through ZPM\'s PostgreSQL wire '
                'session in-process (contract-sql-features) and comparing canonical results with the native '
                'recording. Parents aggregate their in-scope subfeatures.'),
        totals=OrderedDict(records=len(features), in_scope=len(scoped), closed=totals['closed'],
                           partial=totals['partial'], open=totals['open'],
                           not_applicable=len(features) - len(scoped)),
        probes=OrderedDict(total=len(probes), passed=sum(1 for p in probes if results[p['id']]['pass'])),
        features=entries,
    )
    report['probe_results'] = OrderedDict(
        [('pass', [p['id'] for p in probes if results[p['id']]['pass']]),
         ('fail', [p['id'] for p in probes if not results[p['id']]['pass']])])
    args.status.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n', encoding='utf8')
    write_doc(args.doc, features, entries, report)
    print(json.dumps(report['totals']), json.dumps(report['probes']))


def family_table(features, entries):
    rows = []
    for family in 'BEFMRSTX':
        ids = [f['id'] for f in features if f['id'][0] == family]
        counts = Counter(entries[i]['status'] for i in ids)
        scoped = sum(1 for i in ids if entries[i]['applicability'] == 'in_scope')
        rows.append((family, len(ids), scoped, counts['closed'], counts['partial'], counts['open'],
                     counts['not_applicable']))
    return rows


def write_doc(path, features, entries, report):
    t = report['totals']
    lines = [
        '# SQL-standard feature status',
        '',
        'This scoreboard covers the 755 records of PostgreSQL\'s SQL-standard feature list',
        '(`tests/sql_conformance/postgres18_features.json`, from `sql_features.txt`). It is',
        'measured, not estimated: each in-scope feature has probe programs in',
        '`tests/sql_conformance/features/`, recorded from native PostgreSQL 18.7 and executed',
        'in-process against ZPM through its PostgreSQL wire session by `contract-sql-features`.',
        'A feature is **closed** only when all of its probes match, **partial** when some do',
        'and **open** when none do. Parent records aggregate their subfeatures.',
        'The machine-readable form is `tests/sql_conformance/postgres18_feature_status.json`.',
        '',
        '## Totals',
        '',
        f"- In scope: **{t['in_scope']}** of {t['records']} records "
        f"({t['not_applicable']} out of scope: {t['not_applicable'] - len(DEVIATIONS)} that PostgreSQL does not "
        f"support, {len(DEVIATIONS)} reviewed deviations).",
        f"- Closed: **{t['closed']}**",
        f"- Partial: **{t['partial']}**",
        f"- Open: **{t['open']}**",
        f"- Probes: {report['probes']['passed']} of {report['probes']['total']} match native PostgreSQL 18.7.",
        '',
        '## Per family',
        '',
        '| Family | Records | In scope | Closed | Partial | Open | Not applicable |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: |',
    ]
    for row in family_table(features, entries):
        lines.append('| {} | {} | {} | {} | {} | {} | {} |'.format(*row))
    lines += [
        '',
        '## Reviewed deviations',
        '',
        'PostgreSQL lists these as supported, but they are out of scope here:',
        '',
    ]
    for fid, reason in DEVIATIONS.items():
        lines.append(f'- `{fid}` {entries[fid]["name"]}: {reason}')
    lines += [
        '',
        '## Ranked work list',
        '',
        'Open and partial in-scope features, grouped by engine area. Areas are ordered by how',
        'much applications use them; inside an area, partial features (closest to closing) come',
        'first, then core families (E, F) before T, S and X. Each line names the first',
        'mismatching probe statement, with the native PostgreSQL 18.7 response first.',
        '',
    ]
    for area, title in AREAS.items():
        items = [(fid, e) for fid, e in entries.items()
                 if e['applicability'] == 'in_scope' and e['status'] in ('open', 'partial') and e['area'] == area]
        if not items:
            continue
        items.sort(key=lambda item: (item[1]['status'] != 'partial', FAMILY_RANK.get(item[0][0], 4), item[0]))
        lines += [f'### {title} ({len(items)})', '']
        for fid, e in items:
            note = e['note'].replace('|', '\\|')
            lines.append(f'- `{fid}` {e["name"]} ({e["status"]}). {note}')
        lines.append('')
    lines += [
        '## Reproducing',
        '',
        '```',
        'python tests/sql_conformance/verify_feature_oracle.py          # native PostgreSQL 18.x on 55491',
        'python tests/sql_conformance/generate_feature_contract.py      # writes tests/test_sql_features.sig',
        'sig build run-contract-sql-features -Doptimize=ReleaseSafe -j1  # or build-exe and capture stdout',
        'python tests/sql_conformance/feature_status.py --results <ndjson>',
        '```',
        '',
        'The contract fails only when a probe that this scoreboard records as passing stops',
        'passing. Newly passing probes print as improvements; rerun `feature_status.py` and',
        '`generate_feature_contract.py` to fold them in.',
        '',
    ]
    path.write_text('\n'.join(lines), encoding='utf8', newline='\n')


if __name__ == '__main__':
    main()
