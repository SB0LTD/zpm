"""Compare the six original MYSQL.* inventory cases through PyMySQL."""

import argparse
from contextlib import contextmanager
from datetime import date, datetime, time
from decimal import Decimal
import hashlib
import json
from importlib.metadata import version
from pathlib import Path
from queue import Empty, Queue
import re
import socket
import subprocess
from threading import Thread
from time import monotonic, sleep

import pymysql
from pymysql.constants import FLAG

CASE_IDS = (
    "MYSQL.IDENTIFIERS", "MYSQL.TYPES", "MYSQL.AUTO_INCREMENT",
    "MYSQL.REPLACE_UPSERT", "MYSQL.LIMIT", "MYSQL.FUNCTIONS",
)
FIXTURE = Path(__file__).with_name("cases.json")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def original_cases():
    inventory = json.loads(FIXTURE.read_bytes())
    cases = [item for item in inventory["cases"] if item["id"].startswith("MYSQL.")]
    if tuple(item["id"] for item in cases) != CASE_IDS or any(item["dialect"] != "mysql" for item in cases):
        raise ValueError("MySQL inventory case membership or dialect changed")
    return [(case, inventory["fixtures"][case["setup"]]) for case in cases]


def local_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def connect(port, **options):
    return pymysql.connect(host="127.0.0.1", port=port, user="root", password="",
                          autocommit=True, charset="utf8mb4", connect_timeout=2,
                          read_timeout=5, write_timeout=5, **options)


@contextmanager
def native_server(executable, work):
    base = executable.parent.parent
    data = work / "mysql-data"
    options = [str(executable), "--no-defaults", f"--basedir={base}", f"--datadir={data}"]
    with (work / "mysql-init.log").open("wb") as output:
        subprocess.run([*options, "--initialize-insecure", "--console"],
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=60)
    port = local_port()
    with (work / "mysql-server.log").open("wb") as output:
        process = subprocess.Popen([*options, "--console", "--bind-address=127.0.0.1",
                                    "--mysqlx=OFF", "--skip-log-bin", f"--port={port}"],
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            until = monotonic() + 30
            while monotonic() < until and process.poll() is None:
                try:
                    admin = connect(port)
                    break
                except pymysql.err.OperationalError:
                    sleep(.1)
            else:
                raise RuntimeError("Native MySQL did not start; see mysql-server.log")
            with admin:
                try:
                    yield port, admin
                finally:
                    with admin.cursor() as cursor:
                        cursor.execute("SHUTDOWN")
                    process.wait(timeout=15)
        finally:
            stop(process)


@contextmanager
def ramsql_server(executable, work, case_id):
    with (work / f"{case_id}-ramsql.log").open("wb") as output:
        process = subprocess.Popen([str(executable), "--serve", "--memory", "--insecure-local",
                                    "--protocol", "mysql", "--port", "0", "--max-clients", "2"],
                                   stdout=subprocess.PIPE, stderr=output)
        try:
            lines = Queue()
            Thread(target=lambda: lines.put(process.stdout.readline()), daemon=True).start()
            try:
                banner = lines.get(timeout=20)
            except Empty as error:
                raise RuntimeError("RAMSQL did not report its loopback port") from error
            match = re.fullmatch(rb"RAMSQL mysql 127\.0\.0\.1:(\d+)\r?\n", banner)
            if not match:
                raise RuntimeError(f"Unexpected RAMSQL startup banner {banner!r}")
            yield int(match[1])
        finally:
            stop(process)
            process.stdout.close()


def value(item):
    if isinstance(item, (date, datetime, time)):
        return item.isoformat()
    if isinstance(item, Decimal):
        return str(item)
    if isinstance(item, bytes):
        return {"bytes_hex": item.hex()}
    return item


def execute(cursor, source, ordered):
    try:
        cursor.execute(source)
    except pymysql.err.MySQLError as error:
        if len(error.args) != 2 or not isinstance(error.args[0], int):
            raise
        errno, message = error.args
        if 2000 <= errno < 3000:
            raise
        return {"kind": "error", "errno": errno, "message": message}
    if cursor.description is None:
        return {"kind": "command", "affected_rows": cursor.rowcount}
    rows = [[value(item) for item in row] for row in cursor.fetchall()]
    if not ordered:
        rows.sort(key=lambda row: json.dumps(row, sort_keys=True))
    fields = [{"name": field.name, "type": field.type_code, "unsigned": bool(field.flags & FLAG.UNSIGNED),
               "scale": field.scale} for field in cursor._result.fields]
    return {"kind": "rows", "rows": rows, "fields": fields}


def run_case(connection, setup, statements, ordered):
    trace = {"setup": [], "body": []}
    with connection.cursor() as cursor:
        for stage, sources in (("setup", setup), ("body", statements)):
            for source in sources:
                event = execute(cursor, source, ordered if stage == "body" else True)
                trace[stage].append(event)
                if event["kind"] == "error":
                    return trace
    return trace


def first_difference(reference, candidate, setup, statements):
    for stage, queries in (("setup", setup), ("body", statements)):
        for index, (wanted, actual) in enumerate(zip(reference[stage], candidate[stage])):
            if wanted != actual:
                return {"stage": stage, "index": index, "sql": queries[index]}
        if len(reference[stage]) != len(candidate[stage]):
            raise ValueError(f"Missing {stage} events without a prior recorded difference")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mysqld", type=Path, required=True)
    parser.add_argument("--mysql-version", required=True)
    parser.add_argument("--ramsql", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True, help="new directory for the owned native server and evidence")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    mysqld, ramsql = [path.resolve(strict=True) for path in (args.mysqld, args.ramsql)]
    report = {"schema": 1, "fixture_sha256": sha256(FIXTURE), "client": f"PyMySQL {version('PyMySQL')}",
              "native": {"mysqld_sha256": sha256(mysqld)}, "candidate": {"ramsql_sha256": sha256(ramsql)},
              "cases": []}
    with native_server(mysqld, work) as (native_port, admin):
        with admin.cursor() as cursor:
            cursor.execute("SELECT VERSION(), @@version_comment")
            actual, comment = cursor.fetchone()
        if actual != args.mysql_version or "MySQL Community Server" not in comment:
            raise RuntimeError(f"Unexpected native oracle: {actual!r}, {comment!r}")
        report["native"].update(version=actual, version_comment=comment)
        for index, (case, setup) in enumerate(original_cases()):
            name = f"zpm_inventory_{index}"
            source = case["statements"]
            with admin.cursor() as cursor:
                cursor.execute(f"CREATE DATABASE `{name}`")
            with connect(native_port, database=name) as reference:
                expected = run_case(reference, setup, source, case["ordered"])
            if any(event["kind"] == "error" for events in expected.values() for event in events):
                raise RuntimeError(f"Native oracle rejected {case['id']}: {expected!r}")
            with ramsql_server(ramsql, work, case["id"]) as candidate_port:
                with connect(candidate_port) as candidate:
                    actual = run_case(candidate, setup, source, case["ordered"])
            difference = first_difference(expected, actual, setup, source)
            report["cases"].append({"id": case["id"], "setup": setup, "statements": source, "ordered": case["ordered"],
                                    "native": expected, "candidate": actual, "match": difference is None,
                                    "first_difference": difference})
    report["matched"] = sum(case["match"] for case in report["cases"])
    report["gaps"] = len(report["cases"]) - report["matched"]
    (work / "mysql-inventory.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"MySQL inventory: {report['matched']} matched, {report['gaps']} gaps")
    for case in report["cases"]:
        difference = case["first_difference"]
        print(case["id"], "match" if difference is None else f"{difference['stage']} gap: {difference['sql']}")
    return int(report["gaps"] != 0)


if __name__ == "__main__":
    raise SystemExit(main())
