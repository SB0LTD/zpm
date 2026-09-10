"""Exercise the built ZPM CLI, including process argv and exit status."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sig", required=True)
    parser.add_argument("--zpm", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    compiler = Path(args.sig).resolve()
    cli = Path(args.zpm).resolve()
    lib = Path(os.environ.get("SIG_LIB_DIR", compiler.parent.parent / "lib")).resolve()
    output = root / ".build" / "cli-forwarding"
    output.mkdir(parents=True, exist_ok=True)
    fixture = output / ("argv fixture.exe" if os.name == "nt" else "argv fixture")
    env = dict(os.environ, SIG_LIB_DIR=str(lib))
    subprocess.run([
        str(compiler), "build-exe", "--dep", "sig_process",
        f"-Mroot={root / 'tests' / 'build_argv_fixture.sig'}",
        f"-Msig_process={lib / 'sig' / 'process.sig'}",
        f"-femit-bin={fixture}",
    ], env=env, check=True)
    env["SIG"] = str(fixture)
    forwarded = ["https://github.com/SB0LTD/zpm/archive/main.tar.gz", "-Dpath=one/two", "scene test", "-Dzpm-root=path with spaces", "", "quotes\"and\\slashes\\",
                 "caf\u00e9 \u05e9\u05dc\u05d5\u05dd \U0001f30d", "x" * 300, "--", "-new-sig-flag"]
    for command, prefix in [("build", ["build"]), ("run", ["build", "run"])]:
        result = subprocess.run([str(cli), command, *forwarded], env=env, capture_output=True)
        assert result.returncode == 37, (command, result.returncode, result.stderr)
        actual = result.stderr.decode("ascii").splitlines()
        expected = [arg.encode("utf-8").hex() for arg in [*prefix, *forwarded]]
        assert actual == expected, (command, actual, expected)
    for overflowing in [["x" * 4097], ["x"] * 257]:
        result = subprocess.run([str(cli), "build", *overflowing], env=env, capture_output=True)
        assert result.returncode == 2, (result.returncode, result.stderr)
    env["SIG"] = str(output / "missing-compiler")
    result = subprocess.run([str(cli), "build"], env=env, capture_output=True)
    assert result.returncode == 127, (result.returncode, result.stderr)
    print("PASS real CLI forwarding: Unicode, quoting, empty/long arguments, run step, overflow and child exit status")


if __name__ == "__main__":
    main()
