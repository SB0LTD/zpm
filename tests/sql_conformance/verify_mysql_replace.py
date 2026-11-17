"""Compare primary-key REPLACE state and affected rows with native MySQL."""

import argparse
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event

from pymysql.err import IntegrityError

from verify_mysql_inventory import connect, native_server, ramsql_server, sha256


def rows(cursor):
    cursor.execute("SELECT id,v,note FROM replacements ORDER BY id")
    return [list(row) for row in cursor.fetchall()]


def operations(first, second):
    results = {}
    with first.cursor() as writer, second.cursor() as reader:
        writer.execute("CREATE TABLE replacements(id INT PRIMARY KEY,v INT NOT NULL DEFAULT 9,note TEXT)")
        results["insert"] = writer.execute("REPLACE INTO replacements VALUES(1,2,'old')")
        results["replace_with_default"] = writer.execute("REPLACE replacements(id) VALUES(1)")
        results["defaults"] = rows(reader)
        results["repeated_keys"] = writer.execute("REPLACE INTO replacements VALUES(1,3,NULL),(1,4,NULL)")
        try:
            writer.execute("REPLACE INTO replacements VALUES(1,5,NULL),(2,NULL,NULL)")
        except IntegrityError as error:
            results["invalid_row_errno"] = error.args[0]
        else:
            raise AssertionError("Invalid replacement statement succeeded")
        results["after_statement_error"] = rows(reader)

        first.begin()
        results["rollback_replacement"] = writer.execute("REPLACE INTO replacements VALUES(1,7,NULL)")
        results["private"] = rows(writer)
        results["uncommitted_peer"] = rows(reader)
        first.rollback()
        results["after_rollback"] = rows(reader)

        first.begin()
        results["locking_replacement"] = writer.execute("REPLACE INTO replacements VALUES(1,7,NULL)")
        requested = Event()
        finished = Event()

        def waiting_replacement():
            try:
                requested.set()
                return reader.execute("REPLACE INTO replacements VALUES(1,8,NULL)")
            finally:
                finished.set()

        with ThreadPoolExecutor(max_workers=1) as pool:
            replacement = pool.submit(waiting_replacement)
            try:
                if not requested.wait(5) or finished.wait(.25):
                    raise AssertionError("Second replacement did not wait for the first transaction")
            finally:
                first.commit()
            results["waiting_replacement"] = replacement.result(timeout=5)
        results["final"] = rows(reader)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mysqld", type=Path, required=True)
    parser.add_argument("--mysql-version", required=True)
    parser.add_argument("--ramsql", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    mysql, ramsql = (path.resolve(strict=True) for path in (args.mysqld, args.ramsql))
    with native_server(mysql, work) as (port, admin):
        with admin.cursor() as cursor:
            cursor.execute("SELECT VERSION(), @@version_comment")
            version, comment = cursor.fetchone()
            if version != args.mysql_version or "MySQL Community Server" not in comment:
                raise RuntimeError(f"Unexpected native oracle: {version!r}, {comment!r}")
            cursor.execute("CREATE DATABASE replace_oracle")
        with connect(port, database="replace_oracle") as first, connect(port, database="replace_oracle") as second:
            reference = operations(first, second)

    with ramsql_server(ramsql, work, "memory") as port, connect(port) as first, connect(port) as second:
        memory = operations(first, second)
    storage = ("--data", str(work / "replace.wal"))
    with ramsql_server(ramsql, work, "durable", (*storage, "--create-data")) as port:
        with connect(port) as first, connect(port) as second:
            durable = operations(first, second)
    with ramsql_server(ramsql, work, "reopen", storage) as port, connect(port) as peer, peer.cursor() as cursor:
        reopened = rows(cursor)

    expected = {
        "insert": 1, "replace_with_default": 2, "defaults": [[1, 9, None]],
        "repeated_keys": 4, "invalid_row_errno": 1048, "after_statement_error": [[1, 4, None]],
        "rollback_replacement": 2, "private": [[1, 7, None]], "uncommitted_peer": [[1, 4, None]],
        "after_rollback": [[1, 4, None]], "locking_replacement": 2,
        "waiting_replacement": 2, "final": [[1, 8, None]],
    }
    matched = reference == expected == memory == durable and reopened == expected["final"]
    report = {"version": version, "mysqld_sha256": sha256(mysql), "ramsql_sha256": sha256(ramsql),
              "native": reference, "memory": memory, "durable": durable, "reopened": reopened, "match": matched}
    (work / "mysql-replace.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return not matched


if __name__ == "__main__":
    raise SystemExit(main())
