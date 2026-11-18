"""Run the private TLS server exchange against OpenSSL on Linux."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "src/core"
CRYPTO = CORE / "crypto"
TLS = CRYPTO / "tls"


def capture(command, *, timeout=180):
    return subprocess.run(command, capture_output=True, check=True, timeout=timeout).stdout


def identity(openssl, directory):
    def run(*args):
        return capture([openssl, *args])

    ca, ca_key = directory / "ca.pem", directory / "ca.key"
    leaf, leaf_key = directory / "leaf.pem", directory / "leaf.key"
    csr, extensions = directory / "leaf.csr", directory / "leaf.ext"
    run("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
        "-days", "1", "-subj", "/CN=ZPM TLS Test Root", "-keyout", ca_key, "-out", ca,
        "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign")
    run("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
        "-subj", "/CN=localhost", "-keyout", leaf_key, "-out", csr)
    extensions.write_text(
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature\n"
        "extendedKeyUsage=serverAuth\n"
        "subjectAltName=DNS:localhost\n",
        encoding="ascii",
    )
    run("x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-set_serial", "1", "-days", "1",
        "-extfile", extensions, "-out", leaf)
    run("x509", "-in", leaf, "-outform", "DER", "-out", directory / "leaf.der")
    key_text = run("ec", "-in", leaf_key, "-noout", "-text")
    raw_key = re.search(rb"priv:\s*([0-9a-f:\s]+?)\s*pub:", key_text, re.I)
    if raw_key is None:
        raise ValueError("OpenSSL did not provide the test key scalar")
    scalar = bytes.fromhex(raw_key[1].decode("ascii").replace(":", " "))
    if len(scalar) != 32:
        raise ValueError("OpenSSL did not provide a P-256 test key")
    fixture = directory / "fixture.sig"
    fixture.write_text(
        'pub const certificate = @embedFile("leaf.der");\n'
        "pub const private_key = [32]u8{" + ", ".join(str(byte) for byte in scalar) + "};\n",
        encoding="ascii",
    )
    return ca, fixture


def sig_command(args, verb, entry, directory, fixture=None):
    command = [str(args.sig), verb, "-OReleaseSafe", "--Sig-lib-dir", str(args.sig_lib_dir),
               "--cache-dir", str(directory / "cache"), "--global-cache-dir", str(directory / "global-cache")]
    if fixture is not None:
        command.extend(["--dep", "fixture", f"-femit-bin={directory / 'server-test'}"])
    for name in ("entropy", "sha256", "hkdf", "gcm", "chacha20poly1305", "x25519", "tls13_keys"):
        command.extend(["--dep", name])
    command.extend([
        f"-Mroot={TLS / entry}",
        f"-Mentropy={ROOT / 'src/platform/entropy.sig'}",
        "--dep", "sig_mem", "--dep", "sig_testing", f"-Msha256={CORE / 'sha256.sig'}",
        "--dep", "hmac", f"-Mhkdf={CRYPTO / 'hkdf.sig'}",
        "--dep", "aes", f"-Mgcm={CRYPTO / 'gcm.sig'}",
        f"-Mchacha20poly1305={CRYPTO / 'chacha20poly1305.sig'}",
        f"-Mx25519={CRYPTO / 'x25519.sig'}",
        "--dep", "sha256", "--dep", "hkdf", "--dep", "hmac", f"-Mtls13_keys={CRYPTO / 'tls13_keys.sig'}",
        f"-Msig_mem={CORE / 'sig_mem.sig'}", f"-Msig_testing={CORE / 'sig_testing.sig'}",
        "--dep", "sha256", f"-Mhmac={CRYPTO / 'hmac.sig'}", f"-Maes={CRYPTO / 'aes.sig'}",
    ])
    if fixture is not None:
        command.append(f"-Mfixture={fixture}")
    return command


def run_logged(command, path):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
    path.write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Sig command exited with {result.returncode}. See {path}")
    return result.stdout


def exchange(openssl, binary, ca, directory, *, mode, expected, offer=None):
    directory.mkdir()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(15)
        command = [openssl, "s_client", "-quiet", "-connect", f"127.0.0.1:{listener.getsockname()[1]}",
                   "-tls1_3", "-groups", "X25519", "-ciphersuites", "TLS_AES_128_GCM_SHA256",
                   "-sigalgs", "ecdsa_secp256r1_sha256", "-servername", "localhost",
                   "-CAfile", ca, "-verify_hostname", "localhost", "-verify_return_error"]
        if offer is not None:
            command.extend(("-alpn", offer))
        if expected == "selected":
            command.extend(("-msg", "-msgfile", directory / "openssl-handshake.log"))
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as client:
            try:
                connection, _ = listener.accept()
                with connection:
                    server = subprocess.Popen([binary, mode, expected], stdin=connection, stdout=connection, stderr=subprocess.PIPE)
                with server:
                    try:
                        output, client_error = client.communicate(b"ZPM TLS request\n", timeout=15)
                        _, server_error = server.communicate(timeout=15)
                    finally:
                        if server.poll() is None:
                            server.kill()
            finally:
                if client.poll() is None:
                    client.kill()
        (directory / "openssl-client.log").write_bytes(client_error)
        (directory / "server.log").write_bytes(server_error)
        if expected == "rejected":
            passed = client.returncode != 0 and server.returncode == 0 and output == b"" and b"alert number 120" in client_error
        elif expected == "selected":
            transcript = (directory / "openssl-handshake.log").read_bytes()
            encrypted_extensions = re.search(rb"^<<< [^\n]*, EncryptedExtensions\r?\n((?:[ \t]+[0-9a-f ]+\r?\n)+)",
                                             transcript, re.M | re.I)
            alpn = bytes.fromhex("08 00 00 13 00 11 00 10 00 0d 00 0b 0a") + b"postgresql"
            passed = (client.returncode == 0 and server.returncode == 0 and output == b"ZPM TLS response\n"
                      and encrypted_extensions is not None and bytes.fromhex(encrypted_extensions[1].decode()) == alpn)
        else:
            passed = client.returncode == 0 and server.returncode == 0 and output == b"ZPM TLS response\n"
        (directory / "openssl-stdout.log").write_bytes(output)
        if not passed:
            raise RuntimeError(f"TLS exchange failed. Client {client.returncode}, server {server.returncode}. See {directory}")
        return {"policy": mode, "offer": offer, "expected": expected, "client_exit": client.returncode,
                "server_exit": server.returncode, "after_key_update": None if expected == "rejected" else "ZPM TLS response\n"}


def main():
    if not sys.platform.startswith("linux"):
        raise SystemExit("This OpenSSL contract uses the Linux test adapter.")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sig", type=Path, required=True)
    parser.add_argument("--sig-lib-dir", type=Path, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--work-dir", type=Path, default=ROOT / ".sig-cache")
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="tls-server-openssl-", dir=args.work_dir.resolve()))

    tests = run_logged(sig_command(args, "test", "server.sig", directory), directory / "unit.log")
    for name in (b"fragmented RFC 8448 ClientHello", b"an authenticated record with wrong Finished",
                 b"application rekeys only after the complete old-key message",
                 b"application rejects invalid key updates",
                 b"application reserves the last send record",
                 b"ALPN validates opaque offers to the end of the vector",
                 b"ALPN accounts for an opaque selected protocol in its protected flight"):
        if not any(name in line and line.endswith(b"...OK") for line in tests.splitlines()):
            raise RuntimeError(f"Sig did not execute and pass {name!r}. See {directory / 'unit.log'}")
    ca, fixture = identity(args.openssl, directory)
    run_logged(sig_command(args, "build-exe", "test_server_openssl.sig", directory, fixture), directory / "build.log")
    binary = directory / "server-test"
    cases = (
        ("default-no-offer", "disabled", "fallback", None),
        ("default-ignores-offer", "disabled", "fallback", "h2"),
        ("optional-no-offer", "optional", "fallback", None),
        ("optional-matches-list", "optional", "selected", "h2,postgresql"),
        ("optional-mismatch", "optional", "rejected", "h2"),
        ("required-matches", "required", "selected", "postgresql"),
        ("required-no-offer", "required", "rejected", None),
        ("required-mismatch", "required", "rejected", "postgresqlx"),
    )
    results = {name: exchange(args.openssl, binary, ca, directory / name, mode=mode, expected=expected, offer=offer)
               for name, mode, expected, offer in cases}
    report = {
        "passed": True,
        "source": capture(["git", "-C", ROOT, "rev-parse", "HEAD"]).decode().strip(),
        "sig": capture([args.sig, "version"]).decode().strip(),
        "openssl": capture([args.openssl, "version"]).decode().strip(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "received_after_key_update": results["default-no-offer"]["after_key_update"],
        "alpn_cases": results,
        "max_transport_io_fragment_bytes": 7,
    }
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    print(directory)


if __name__ == "__main__":
    main()
