# Contributing to zpm

Thanks for your interest in contributing to zpm.

## Prerequisites

- **Zig 0.16+** — [ziglang.org/download](https://ziglang.org/download/)
- Git

## Building

```bash
# Build the zpm CLI
cd zpm/cli
zig build

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Running Tests

```bash
# CLI + pkg module tests (from zpm/cli/)
cd zpm/cli
zig build test --summary all

# Root-level tests — transport, core, platform (from zpm/)
cd zpm
zig build test --summary all
```

## Code Style

zpm follows strict conventions:

- **Zero allocation** — all storage is stack or comptime-sized. No heap allocation in the hot path.
- **Comptime dispatch** — platform selection via `@import("builtin").os.tag` at comptime, not runtime.
- **Vtable I/O** — all I/O goes through function-pointer vtables (`CommandContext`, `HttpVtable`, `BootstrapVtable`). This keeps pure logic testable without mocking frameworks.
- **Static buffers** — fixed-size stack buffers throughout (max 64KB for ZON files, 256 entries for dependency graphs).
- **Layer ordering** — Layer 0 (Core) never imports from Layer 1 (Platform/Transport) or Layer 2 (Render). Layer 1 never imports from Layer 2.

## Pull Request Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes
4. Run all tests: `zig build test --summary all` from both `zpm/` and `zpm/cli/`
5. Submit a PR with a clear description of the change

## Issue Templates

### Bug Report

- Zig version (`zig version`)
- OS and architecture
- Steps to reproduce
- Expected vs actual behavior
- Relevant error output

### Feature Request

- Description of the feature
- Use case / motivation
- Proposed API or CLI interface (if applicable)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
