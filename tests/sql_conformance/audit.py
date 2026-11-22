#!/usr/bin/env python3
"""Strict differential smoke audit. Development tool; Python stdlib only.

Use disposable local test servers. Read/write SQL fixtures are intentional.
Unimplemented scopes, invalid oracle fixtures and missing closure dimensions
prevent qualification; identical rejection by both servers is NOT success.
"""
import argparse
from collections import Counter
from decimal import Decimal, DecimalException
import hashlib
import json
from pathlib import Path
import socket
import struct

FIRST_USER_OID = 16384


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
        copy_bytes = bytearray()
        copy_formats = None
        copy_done = False
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
            elif kind == b"H":
                if copy_formats is not None or len(body) < 3:
                    raise ValueError("Invalid CopyOutResponse")
                overall, count = struct.unpack("!BH", body[:3])
                if overall not in (0, 1) or len(body) != 3 + 2 * count:
                    raise ValueError("Invalid COPY output format")
                formats = struct.unpack(f"!{count}H", body[3:])
                if any(fmt not in (0, 1) for fmt in formats):
                    raise ValueError("Invalid COPY column format")
                copy_formats = [overall, *formats]
            elif kind == b"d":
                if copy_formats is None or copy_done:
                    raise ValueError("CopyData outside COPY output")
                copy_bytes.extend(body)
            elif kind == b"c":
                if copy_formats is None or copy_done or body:
                    raise ValueError("Invalid CopyDone")
                copy_done = True
            elif kind in (b"G", b"W"):
                raise ValueError("Audit fixture requires server-to-client COPY")
            elif kind == b"E":
                result["error"] = self.error(body)
            elif kind == b"Z":
                result["transaction"] = body.decode()
                if copy_formats is not None and result["error"] is None:
                    if not copy_done or not (result["command"] or "").startswith("COPY "):
                        raise ValueError("Incomplete COPY output")
                    result["copy"] = {"formats": copy_formats, "hex": copy_bytes.hex()}
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
            oids = sorted({column[1] for column in result["columns"] if column[1] >= FIRST_USER_OID})
            if oids:
                oid_list = ",".join(map(str, oids))
                types = connection.query(
                    "SELECT t.oid,n.nspname,t.typname,t.typtype FROM pg_catalog.pg_type t "
                    "JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace "
                    f"WHERE t.oid IN ({oid_list})"
                )
                result["user_types"] = {row[0]: row[1:] for row in types["rows"]}
                if types["error"]:
                    result["user_type_error"] = types["error"]
        return results
    finally:
        connection.close()  # Disconnect aborts the isolated fixture transaction.


def explain_measurement(result):
    """Compare the observed final cardinality, permitting different physical plans."""
    if result["command"] != "EXPLAIN" or result["columns"] != [["QUERY PLAN", 114, -1, -1, 0]]:
        return None
    if len(result["rows"]) != 1 or len(result["rows"][0]) != 1:
        return None
    try:
        envelope = json.loads(result["rows"][0][0], parse_float=Decimal)
        if not isinstance(envelope, list) or len(envelope) != 1:
            return None
        root = envelope[0]["Plan"]
        pending = [root]
        while pending:
            node = pending.pop()
            if not isinstance(node["Node Type"], str) or not node["Node Type"]:
                return None
            rows, loops = node["Actual Rows"], node["Actual Loops"]
            if type(rows) not in (int, Decimal) or rows < 0:
                return None
            if type(loops) is not int or loops < 0:
                return None
            children = node.get("Plans", [])
            if not isinstance(children, list):
                return None
            pending.extend(children)
        rows = root["Actual Rows"]
        if root["Actual Loops"] == 1 and rows == Decimal(rows).to_integral_value():
            return rows
    except (ValueError, TypeError, KeyError, DecimalException):
        pass
    return None


def equivalent_columns(left, right):
    if len(left["columns"]) != len(right["columns"]):
        return False
    for a, b in zip(left["columns"], right["columns"]):
        if a[0] != b[0] or a[2:] != b[2:]:
            return False
        if a[1] < FIRST_USER_OID or b[1] < FIRST_USER_OID:
            if a[1] != b[1]:
                return False
            continue
        left_type = left.get("user_types", {}).get(str(a[1]))
        right_type = right.get("user_types", {}).get(str(b[1]))
        if left_type is None or left_type != right_type:
            return False
    return True


def equivalent(left, right, ordered, comparator="exact"):
    if len(left) != len(right):
        return False
    for index, (a, b) in enumerate(zip(left, right)):
        if a["error"] or b["error"]:
            return False
        if not equivalent_columns(a, b) or any(a[key] != b[key] for key in ("command", "transaction")):
            return False
        if a.get("copy") != b.get("copy"):
            return False
        if comparator == "explain_structure" and index == len(left) - 1:
            actual = explain_measurement(a)
            if actual is None or actual != explain_measurement(b):
                return False
        elif ordered:
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
        if case["scope"] in ("transaction", "copy_protocol") and case["dialect"] == "postgresql18":
            try:
                oracle = run_case(args.oracle_port, args, manifest, case)
                comparator = case.get("comparator", "exact")
                if any(item["error"] for item in oracle):
                    entry.update(status="oracle_invalid", oracle=oracle)
                elif comparator == "explain_structure" and explain_measurement(oracle[-1]) is None:
                    entry.update(status="oracle_invalid", oracle=oracle, detail="Invalid EXPLAIN ANALYZE plan")
                elif case["scope"] == "copy_protocol" and oracle[-1].get("copy") is None:
                    entry.update(status="oracle_invalid", oracle=oracle, detail="Missing COPY output")
                elif args.oracle_only:
                    entry.update(status="oracle_valid", oracle=oracle)
                elif comparator not in ("exact", "explain_structure"):
                    entry.update(status="unexecuted_comparator", oracle=oracle)
                else:
                    candidate = run_case(args.candidate_port, args, manifest, case)
                    passed = equivalent(oracle, candidate, case.get("ordered", False), comparator)
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
