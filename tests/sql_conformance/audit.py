#!/usr/bin/env python3
"""Strict differential smoke audit. Development tool; Python stdlib only.

Use disposable local test servers. Read/write SQL fixtures are intentional.
Unimplemented scopes, invalid oracle fixtures and missing closure dimensions
prevent qualification; identical rejection by both servers is NOT success.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import socket
import struct


class Pg:
    def __init__(self, port, user, database):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=30)
        payload = struct.pack("!I", 196608) + (
            f"user\0{user}\0database\0{database}\0client_encoding\0UTF8\0\0"
        ).encode()
        self.sock.sendall(struct.pack("!I", len(payload) + 4) + payload)
        while True:
            kind, body = self.message()
            if kind == b"R" and struct.unpack("!I", body[:4])[0] != 0:
                self.close()
                raise RuntimeError("Audit requires an owned loopback trust-auth test instance")
            if kind == b"E":
                raise RuntimeError(self.error(body))
            if kind == b"Z":
                break

    def close(self):
        self.sock.close()

    def read(self, count):
        chunks = bytearray()
        while len(chunks) < count:
            chunk = self.sock.recv(count - len(chunks))
            if not chunk:
                raise ConnectionError("PostgreSQL connection closed")
            chunks.extend(chunk)
        return bytes(chunks)

    def message(self):
        kind = self.read(1)
        size = struct.unpack("!I", self.read(4))[0]
        if not 4 <= size <= 64 * 1024 * 1024:
            raise ValueError("Invalid protocol message length")
        return kind, self.read(size - 4)

    @staticmethod
    def error(body):
        fields = {}
        offset = 0
        while offset < len(body) and body[offset]:
            tag = chr(body[offset])
            end = body.index(0, offset + 1)
            fields[tag] = body[offset + 1:end].decode("utf8", errors="replace")
            offset = end + 1
        return {"sqlstate": fields.get("C"), "message": fields.get("M")}

    def query(self, sql):
        data = sql.encode() + b"\0"
        self.sock.sendall(b"Q" + struct.pack("!I", len(data) + 4) + data)
        result = {"columns": [], "rows": [], "command": None, "error": None}
        while True:
            kind, body = self.message()
            if kind == b"T":
                count = struct.unpack("!H", body[:2])[0]
                offset = 2
                for _ in range(count):
                    end = body.index(0, offset)
                    name = body[offset:end].decode()
                    _, _, oid, size, modifier, fmt = struct.unpack("!IhIhih", body[end+1:end+19])
                    result["columns"].append([name, oid, size, modifier, fmt])
                    offset = end + 19
            elif kind == b"D":
                count = struct.unpack("!H", body[:2])[0]
                offset, row = 2, []
                for _ in range(count):
                    size = struct.unpack("!i", body[offset:offset+4])[0]
                    offset += 4
                    row.append(None if size == -1 else body[offset:offset+size].decode())
                    if size != -1:
                        offset += size
                result["rows"].append(row)
            elif kind == b"C":
                result["command"] = body.rstrip(b"\0").decode()
            elif kind == b"E":
                result["error"] = self.error(body)
            elif kind == b"Z":
                result["transaction"] = body.decode()
                return result


def run_case(port, args, manifest, case):
    connection = Pg(port, args.user, args.database)
    try:
        commands = ["BEGIN"] + manifest["fixtures"][case["setup"]] + case["statements"]
        results = []
        for command in commands:
            result = connection.query(command)
            results.append(result)
            if result["error"]:
                break
        return results
    finally:
        connection.close()  # Disconnect aborts the isolated fixture transaction.


def equivalent(left, right, ordered):
    if len(left) != len(right):
        return False
    for a, b in zip(left, right):
        # Object OIDs are not compared; type OIDs, typmods and formats are.
        if a["error"] or b["error"]:
            return False
        if any(a[key] != b[key] for key in ("columns", "command", "transaction")):
            return False
        if ordered:
            if a["rows"] != b["rows"]:
                return False
        elif Counter(map(tuple, a["rows"])) != Counter(map(tuple, b["rows"])):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle-port", type=int, required=True)
    parser.add_argument("--candidate-port", type=int)
    parser.add_argument("--oracle-only", action="store_true", help="Validate fixture SQL without running a candidate")
    parser.add_argument("--user", default="postgres")
    parser.add_argument("--database", default="postgres")
    parser.add_argument("--case", action="append", help="Select stable feature IDs")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not args.oracle_only and args.candidate_port is None:
        parser.error("--candidate-port is required unless --oracle-only")
    if args.oracle_port == args.candidate_port:
        parser.error("Oracle and candidate must be different servers")
    manifest_bytes = Path(__file__).with_name("cases.json").read_bytes().replace(b"\r\n", b"\n")
    manifest = json.loads(manifest_bytes)
    selected = [c for c in manifest["cases"] if not args.case or c["id"] in args.case]
    if not selected or (args.case and set(args.case) - {c["id"] for c in selected}):
        parser.error("Unknown or empty case selection")
    connection = Pg(args.oracle_port, args.user, args.database)
    try:
        version = connection.query("SHOW server_version_num")
        full_version = connection.query("SELECT version()")
        if version["error"] or version["rows"] != [["180003"]]:
            raise RuntimeError("Fixture target is exactly PostgreSQL 18.3; version and revalidate a new target explicitly")
    finally:
        connection.close()
    report = {"qualification": "incomplete", "scope": "smoke_only",
              "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
              "manifest_hash_encoding": "UTF-8 with LF newlines",
              "oracle_version": full_version["rows"], "cases": []}
    for case in selected:
        entry = {"id": case["id"], "status": "unexecuted_scope"}
        if case["scope"] == "transaction" and case["dialect"] == "postgresql18":
            try:
                oracle = run_case(args.oracle_port, args, manifest, case)
                if any(item["error"] for item in oracle):
                    entry.update(status="oracle_invalid", oracle=oracle)
                elif args.oracle_only:
                    entry.update(status="oracle_valid", oracle=oracle)
                elif case.get("comparator", "exact") != "exact":
                    entry.update(status="unexecuted_comparator", oracle=oracle)
                else:
                    candidate = run_case(args.candidate_port, args, manifest, case)
                    passed = equivalent(oracle, candidate, case.get("ordered", False))
                    entry.update(status="smoke_pass" if passed else "fail", oracle=oracle, candidate=candidate)
            except (OSError, ValueError, RuntimeError) as error:
                entry.update(status="harness_error", detail=str(error))
        report["cases"].append(entry)
        print(entry["id"], entry["status"], flush=True)
    report["counts"] = dict(Counter(c["status"] for c in report["cases"]))
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    # Even all smoke passes are not full conformance. Closure tests are required.
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
