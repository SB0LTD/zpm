#!/usr/bin/env python3
"""Capture the six original T-SQL smoke cases from an owned SQL Server over TDS."""
import argparse
from collections import Counter
from contextlib import closing
from datetime import date
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
from time import monotonic, sleep

import pytds


SERVER_VERSION = "16.0.4325.4"
DRIVER_VERSION = "1.17.1"
IMAGE = "mcr.microsoft.com/mssql/server@sha256:e10cd49443c94dbdcb7a050987db22ff4d8c87052ac53768abe1ed848d3fcef6"
PROBE_SHA256 = "21f7bd63c830788e20b8c265728d38244c0e90b90710380d90e26cad1b5efa74"
EXPECTED_ROWS = {
    "TSQL.IDENTIFIERS": [[1]],
    "TSQL.TOP": [[1], [2]],
    "TSQL.OUTPUT": [[1]],
    "TSQL.APPLY": [[1, 2], [2, 3], [3, 4], [4, 5]],
    "TSQL.FUNCTIONS": [[2, "2025-01-02"]],
    "TSQL.PROCEDURAL": [[1]],
}


def manifest_cases():
    raw = Path(__file__).with_name("cases.json").read_bytes().replace(b"\r\n", b"\n")
    manifest = json.loads(raw)
    cases = [case for case in manifest["cases"] if case["dialect"] == "tsql"]
    if (len(cases) != len(EXPECTED_ROWS) or {case["id"] for case in cases} != EXPECTED_ROWS.keys()
            or any(case["scope"] != "native_dialect" or case["setup"] != "base" for case in cases)):
        raise ValueError("T-SQL inventory differs from the six original native smoke cases")
    fixture = manifest["fixtures"]["base"]
    probes = [(case["id"], case["ordered"], case["statements"]) for case in cases]
    if hashlib.sha256(json.dumps([fixture, probes], separators=(",", ":")).encode()).hexdigest() != PROBE_SHA256:
        raise ValueError("Original T-SQL probe SQL or setup has changed")
    return hashlib.sha256(raw).hexdigest(), fixture, cases


def cell(value):
    if value is None or type(value) in (int, str):
        return value
    if type(value) is date:
        return value.isoformat()
    raise TypeError(f"Unexpected TDS value type {type(value).__name__}")


def observe(cursor, source):
    observation = {"sql": source, "results": [], "error": None}
    try:
        cursor.execute(source)
        while True:
            columns = cursor.description
            rows = [] if columns is None else [[cell(value) for value in row] for row in cursor.fetchall()]
            observation["results"].append({
                "columns": [] if columns is None else [list(column) for column in columns],
                "rows": rows,
                "rowcount": cursor.rowcount,
            })
            if not cursor.nextset():
                break
    except pytds.DatabaseError as error:
        observation["error"] = {
            "number": error.number, "severity": error.severity, "state": error.state,
            "line": error.line, "message": error.text,
        }
    return observation


def calibrate(case, statements):
    if len(statements) != len(case["statements"]) or any(item["error"] for item in statements):
        return False
    tabular = [result for item in statements for result in item["results"] if result["columns"]]
    if len(tabular) != 1:
        return False
    result = tabular[0]
    expected = EXPECTED_ROWS[case["id"]]
    if len(result["columns"]) != len(expected[0]):
        return False
    if case["id"] == "TSQL.IDENTIFIERS" and result["columns"][0][0] != "value":
        return False
    if case["id"] == "TSQL.FUNCTIONS" and result["columns"][1][1] != 40:  # TDS DATENTYPE
        return False
    actual = result["rows"]
    if case["ordered"]:
        return actual == expected
    return Counter(map(tuple, actual)) == Counter(map(tuple, expected))


def capture_case(connect, fixture, case):
    entry = {"id": case["id"], "ordered": case["ordered"], "status": "oracle_invalid",
             "setup": [], "statements": []}
    try:
        with closing(connect()) as connection:
            try:
                with closing(connection.cursor()) as cursor:
                    for sql in fixture:
                        record = observe(cursor, sql)
                        entry["setup"].append(record)
                        if record["error"]:
                            return entry
                    for sql in case["statements"]:
                        record = observe(cursor, sql)
                        entry["statements"].append(record)
                        if record["error"]:
                            return entry
            finally:
                connection.rollback()
        if calibrate(case, entry["statements"]):
            entry["status"] = "oracle_valid"
    except (OSError, ValueError, TypeError, pytds.Error) as error:
        entry.update(status="harness_error", detail=f"{type(error).__name__}: {error}")
    return entry


def server_identity(connect, wait_seconds):
    deadline = monotonic() + wait_seconds
    while True:
        try:
            with closing(connect()) as connection, closing(connection.cursor()) as cursor:
                cursor.execute("""
                    SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(32)),
                           CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(32)),
                           CAST(SERVERPROPERTY('Edition') AS varchar(128)),
                           CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS varchar(128)),
                           CAST(@@VERSION AS varchar(1024))
                """)
                identity = cursor.fetchone()
                return dict(zip(("version", "update_level", "edition", "collation", "version_description"), identity))
        except (OSError, pytds.Error):
            if monotonic() >= deadline:
                raise
            sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True, help="Loopback port of the disposable SQL Server")
    parser.add_argument("--wait-seconds", type=int, default=0)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    password = os.getenv("ZPM_SQLSERVER_ORACLE_PASSWORD")
    if not password:
        parser.error("Set ZPM_SQLSERVER_ORACLE_PASSWORD for the disposable server")
    if not 0 < args.port < 65536 or not 0 <= args.wait_seconds <= 300:
        parser.error("Invalid port or startup wait")
    if args.report.exists():
        parser.error("Choose a fresh report path")
    client_version = version("python-tds")
    if client_version != DRIVER_VERSION:
        parser.error(f"Oracle client must be python-tds {DRIVER_VERSION}")

    digest, fixture, cases = manifest_cases()
    report = {"schema": 1, "scope": "native_tsql_smoke", "qualification": "incomplete",
              "manifest_sha256": digest, "manifest_hash_encoding": "UTF-8 with LF newlines",
              "probes_sha256": PROBE_SHA256,
              "expected_oracle_version": SERVER_VERSION, "expected_oracle_image": IMAGE,
              "client": {"name": "python-tds", "version": client_version},
              "column_fields": ["name", "type_code", "display_size", "internal_size", "precision", "scale", "nullable"],
              "oracle_server": None, "cases": []}

    def connect():
        return pytds.connect(server="127.0.0.1", port=args.port, user="sa", password=password,
                             database="tempdb", autocommit=False, use_mars=False,
                             login_timeout=3, timeout=30, disable_connect_retry=True)

    try:
        report["oracle_server"] = server_identity(connect, args.wait_seconds)
        if report["oracle_server"]["version"] != SERVER_VERSION:
            raise ValueError("Unexpected SQL Server build")
        for case in cases:
            entry = capture_case(connect, fixture, case)
            report["cases"].append(entry)
            print(entry["id"], entry["status"], flush=True)
    except (OSError, ValueError, TypeError, pytds.Error) as error:
        report["error"] = f"{type(error).__name__}: {error}"
        report["cases"] = [{"id": case["id"], "ordered": case["ordered"], "status": "oracle_unavailable"}
                           for case in cases]
    report["counts"] = dict(Counter(case["status"] for case in report["cases"]))
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    return 0 if report["counts"] == {"oracle_valid": len(EXPECTED_ROWS)} else 1


if __name__ == "__main__":
    raise SystemExit(main())
