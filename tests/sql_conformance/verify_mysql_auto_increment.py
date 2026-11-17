"""Capture and compare native MySQL AUTO_INCREMENT and insert-ID behavior."""

import argparse
import json
from pathlib import Path

from verify_mysql_inventory import connect, native_server, ramsql_server, sha256


def trace(first, second):
    observed = []
    with first.cursor() as writer, second.cursor() as peer:
        writer.execute("CREATE TABLE autos(id INT AUTO_INCREMENT PRIMARY KEY,v INT NOT NULL)")

        def write(source):
            count = writer.execute(source)
            insert_id = writer.lastrowid
            writer.execute("SELECT LAST_INSERT_ID()")
            observed.append({"sql": source, "affected_rows": count, "ok_insert_id": insert_id,
                             "last_insert_id": writer.fetchone()[0]})

        def snapshot(label):
            peer.execute("SELECT id,v FROM autos ORDER BY v")
            rows = [list(row) for row in peer.fetchall()]
            peer.execute("SELECT LAST_INSERT_ID()")
            observed.append({"snapshot": label, "rows": rows, "peer_last_insert_id": peer.fetchone()[0]})

        write("INSERT INTO autos(v) VALUES(11)")
        write("INSERT INTO autos VALUES(10,22)")
        write("INSERT INTO autos VALUES(NULL,33),(0,44)")
        write("INSERT INTO autos VALUES(NULL,55),(50,66),(NULL,77)")
        write("UPDATE autos SET id=100 WHERE v=22")
        write("INSERT INTO autos VALUES(DEFAULT,88)")
        snapshot("generated and explicit keys")

        first.begin()
        write("INSERT INTO autos(v) VALUES(99)")
        snapshot("peer before rollback")
        first.rollback()
        writer.execute("SELECT LAST_INSERT_ID()")
        observed.append({"state": "after rollback", "last_insert_id": writer.fetchone()[0]})
        write("INSERT INTO autos(v) VALUES(111)")
        snapshot("rollback reserves its key")

        writer.execute("SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO'")
        write("INSERT INTO autos VALUES(0,122)")
        write("INSERT INTO autos VALUES(NULL,133)")
        snapshot("NO_AUTO_VALUE_ON_ZERO")
        write("TRUNCATE TABLE autos")
        write("INSERT INTO autos(v) VALUES(144)")
        snapshot("truncate resets the counter")
    return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mysqld", type=Path, required=True)
    parser.add_argument("--mysql-version", required=True)
    parser.add_argument("--ramsql", type=Path, help="optional candidate for strict comparison")
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    mysql = args.mysqld.resolve(strict=True)
    with native_server(mysql, work) as (port, admin):
        with admin.cursor() as cursor:
            cursor.execute("SELECT VERSION(), @@version_comment")
            version, comment = cursor.fetchone()
            if version != args.mysql_version or "MySQL Community Server" not in comment:
                raise RuntimeError(f"Unexpected native oracle: {version!r}, {comment!r}")
            cursor.execute("CREATE DATABASE auto_increment_oracle")
        with connect(port, database="auto_increment_oracle") as first, connect(port, database="auto_increment_oracle") as second:
            native = trace(first, second)
    report = {"mysql_version": version, "mysqld_sha256": sha256(mysql), "native": native}
    if args.ramsql is not None:
        candidate = args.ramsql.resolve(strict=True)
        report["ramsql_sha256"] = sha256(candidate)
        try:
            with ramsql_server(candidate, work, "auto-increment") as port, connect(port) as first, connect(port) as second:
                report["candidate"] = trace(first, second)
        except Exception as error:
            report["candidate_error"] = f"{type(error).__name__}: {error}"
        report["match"] = report.get("candidate") == native
    (work / "mysql-auto-increment.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return not report.get("match", True)


if __name__ == "__main__":
    raise SystemExit(main())
