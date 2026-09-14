# Contributing to zpm

Thanks for your interest in contributing to zpm.

## Prerequisites

- **Sig compiler** — [github.com/SB0LTD/sig](https://github.com/SB0LTD/sig)
  0.5.9 (put `sig` on your PATH). Use the complete matched release, including
  its library and build tools; no source overlay is needed.
- Git

## Building

```bash
# Build the zpm CLI
cd zpm/cli
sig build zpm

# Build with optimizations
sig build zpm -Doptimize=ReleaseFast
```

## Running Tests

```bash
# CLI + pkg module tests (from zpm/cli/)
cd zpm/cli
sig build test --summary all

# Root-level tests — core, crypto, transport, net, LSP, AI, render, platform
# (from zpm/)
cd zpm
sig build test --summary all
```

Native interaction contracts and actual CLI process forwarding:

```bash
# From zpm/
sig build test-now --summary all
python tests/test_cli_forwarding.py --sig /absolute/path/to/sig --zpm cli/sig-out/bin/zpm
```

On Windows use the `.exe` paths. The forwarding test compiles a real child
process and checks URLs, Unicode, quotes, empty and long arguments, overflow
and child failure. `SIG_LIB_DIR` may select the matching library source checkout
when testing toolchain changes. Compile ZPM with `sig build zpm` before running
it; Windows cannot replace the executable while that same ZPM process is running.

For consumers, declare ZPM once in `build.sig.zon` as a pinned archive with its
SHA-256 (or an explicit local `.path` during co-development). Resolve it through
`ctx.getDependency("zpm")` and wire named modules from that root. Do not copy
individual files into a consumer's `Lib` directory or silently locate a sibling
checkout. Nexus additionally accepts the explicit `-Dzpm-root=../zpm` override.

## Code Style

zpm follows strict conventions:

- **Zero allocation** — all storage is stack or comptime-sized. No heap
  allocation in the hot path. (In Sig's strict `.sig` mode, allocator usage is a
  compile-time error.)
- **Comptime dispatch** — platform selection via `@import("builtin").os.tag` at
  comptime, not runtime.
- **Vtable I/O** — all I/O goes through function-pointer vtables
  (`CommandContext`, `HttpVtable`, `BootstrapVtable`). This keeps pure logic
  testable without mocking frameworks.
- **Static buffers** — fixed-size stack buffers throughout (max 64KB for ZON
  files, 256 entries for dependency graphs).
- **Layer ordering** — Layer 0 (Core) never imports from Layer 1
  (Platform/Transport) or Layer 2 (Render). Layer 1 never imports from Layer 2.

## Pull Request Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes
4. Run all tests: `sig build test --summary all` from both `zpm/` and `zpm/cli/`
5. Submit a PR with a clear description of the change

## Issue Templates

### Bug Report

- Sig compiler version (`sig version`)
- OS and architecture
- Steps to reproduce
- Expected vs actual behavior
- Relevant error output

### Feature Request

- Description of the feature
- Use case / motivation
- Proposed API or CLI interface (if applicable)

## License

By contributing, you agree that your contributions will be licensed under the
MIT License.
