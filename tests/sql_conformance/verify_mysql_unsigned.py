"""Compare BIGINT UNSIGNED storage and wire results with native MySQL."""

import argparse
import json
from pathlib import Path

from verify_mysql_inventory import connect, execute, native_server, ramsql_server, sha256


FINAL_QUERY = "SELECT id,v FROM unsigned_values ORDER BY id"
STATEMENTS = (
    "CREATE TABLE unsigned_values(id BIGINT UNSIGNED PRIMARY KEY,v BIGINT UNSIGNED)",
    "INSERT INTO unsigned_values VALUES(0,NULL),(9223372036854775808,18446744073709551615),(18446744073709551615,1)",
    FINAL_QUERY,
    "SELECT id FROM unsigned_values WHERE id=18446744073709551615",
    "SELECT id FROM unsigned_values WHERE id IN(0,18446744073709551615) ORDER BY id",
    "SELECT MIN(id) AS lo,MAX(id) AS hi FROM unsigned_values",
    "INSERT INTO unsigned_values VALUES(1,-1)",
    "INSERT INTO unsigned_values VALUES(1,18446744073709551616)",
    "INSERT INTO unsigned_values VALUES(1,7),(2,-1)",
    "INSERT INTO unsigned_values VALUES(18446744073709551615,2)",
    "UPDATE unsigned_values SET v=9223372036854775808 WHERE id=0",
    "DELETE FROM unsigned_values WHERE id=9223372036854775808",
    FINAL_QUERY,
)


def trace(connection):
    events = []
    with connection.cursor() as cursor:
        for source in STATEMENTS:
            result = execute(cursor, source, ordered=True)
            if result["kind"] == "error":
                result.pop("message")
            events.append(result)
    return events


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
            cursor.execute("CREATE DATABASE unsigned_oracle")
        with connect(port, database="unsigned_oracle") as reference:
            expected = trace(reference)
    if [event["errno"] for event in expected if event["kind"] == "error"] != [1264, 1264, 1264, 1062]:
        raise RuntimeError("Unexpected native boundary error sequence")

    storage = ("--data", str(work / "unsigned.wal"))
    with ramsql_server(ramsql, work, "unsigned", (*storage, "--create-data")) as port, connect(port) as candidate:
        actual = trace(candidate)
    with ramsql_server(ramsql, work, "reopen", storage) as port, connect(port) as candidate, candidate.cursor() as cursor:
        reopened = execute(cursor, FINAL_QUERY, ordered=True)
    matched = expected == actual and reopened == expected[-1]
    report = {"mysql_version": version, "mysqld_sha256": sha256(mysql), "ramsql_sha256": sha256(ramsql),
              "statements": STATEMENTS, "native": expected, "candidate": actual, "reopened": reopened,
              "compared": "rows, affected rows, column names and types, unsigned flag, scale, and error number",
              "match": matched}
    (work / "mysql-unsigned.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for source, wanted, got in zip(STATEMENTS, expected, actual, strict=True):
        if wanted != got:
            print(json.dumps({"source": source, "native": wanted, "candidate": got}))
    print(f"Unsigned native comparison matched={matched} recovered={reopened == expected[-1]}")
    return not matched


if __name__ == "__main__":
    raise SystemExit(main())
