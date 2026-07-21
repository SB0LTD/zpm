# Graph Report - C:\Just-Things\Projects\sb0\zpm  (2026-07-21)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 50 nodes · 51 edges · 17 communities (13 shown, 4 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `1ee5c6c7`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- debug-handshake.mjs
- package.json
- Community 2
- main
- README.md
- p256 tests
- p384 tests
- secp256k1 tests
- decodeResponse
- dependencies.zig
- check-server.sh
- GitHub CI Workflow

## God Nodes (most connected - your core abstractions)
1. `main()` - 5 edges
2. `buildExtensions()` - 4 edges
3. `buildTransportParams()` - 4 edges
4. `decodeResponse()` - 4 edges
5. `deriveInitialKeys()` - 3 edges
6. `buildClientHello()` - 3 edges
7. `encodeTP()` - 3 edges
8. `encodeVarintBuf()` - 3 edges
9. `buildInitialPacket()` - 3 edges
10. `decodeVarint()` - 3 edges

## Surprising Connections (you probably didn't know these)
- `p256 tests` --references--> `field`  [EXTRACTED]
  std/crypto/pcurves/tests/p256.zig → std/crypto/pcurves/p256/field.zig
- `p256 tests` --references--> `scalar`  [EXTRACTED]
  std/crypto/pcurves/tests/p256.zig → std/crypto/pcurves/p256/scalar.zig
- `p384 tests` --references--> `field`  [EXTRACTED]
  std/crypto/pcurves/tests/p384.zig → std/crypto/pcurves/p384/field.zig
- `p384 tests` --references--> `scalar`  [EXTRACTED]
  std/crypto/pcurves/tests/p384.zig → std/crypto/pcurves/p384/scalar.zig
- `secp256k1 tests` --references--> `field`  [EXTRACTED]
  std/crypto/pcurves/tests/secp256k1.zig → std/crypto/pcurves/secp256k1/field.zig

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **zpm Architecture Layers and Official Packages** — readme, changelog [EXTRACTED 1.00]
- **zpm CLI Commands and Flags** — readme, changelog [EXTRACTED 1.00]
- **zpm QUIC Transport Implementation** — readme, changelog [EXTRACTED 1.00]
- **Tests covering pcurves field and scalar modules** — std_crypto_pcurves_tests_p256, std_crypto_pcurves_p256_field, std_crypto_pcurves_p256_scalar, std_crypto_pcurves_tests_p384, std_crypto_pcurves_p384_field, std_crypto_pcurves_p384_scalar, std_crypto_pcurves_tests_secp256k1, std_crypto_pcurves_secp256k1_field, std_crypto_pcurves_secp256k1_scalar [EXTRACTED 1.00]

## Communities (17 total, 4 thin omitted)

### Community 0 - "debug-handshake.mjs"
Cohesion: 0.33
Nodes (6): RFC-9000, RFC-9001, deriveInitialKeys(), hkdfExpandLabel(), PORT, QUIC_V1_SALT

### Community 1 - "package.json"
Cohesion: 0.33
Nodes (5): description, main, name, type, version

### Community 2 - "Community 2"
Cohesion: 0.50
Nodes (5): buildExt(), buildExtensions(), buildTransportParams(), encodeTP(), encodeVarintBuf()

### Community 3 - "main"
Cohesion: 0.50
Nodes (4): buildClientHello(), buildInitialPacket(), main(), writeVarint()

### Community 5 - "p256 tests"
Cohesion: 0.67
Nodes (3): field, scalar, p256 tests

### Community 6 - "p384 tests"
Cohesion: 0.67
Nodes (3): field, scalar, p384 tests

### Community 7 - "secp256k1 tests"
Cohesion: 0.67
Nodes (3): field, scalar, secp256k1 tests

### Community 8 - "decodeResponse"
Cohesion: 1.00
Nodes (3): decodeFrames(), decodeResponse(), decodeVarint()

## Knowledge Gaps
- **19 isolated node(s):** `packages`, `check-server.sh script`, `PORT`, `QUIC_V1_SALT`, `RFC-9000` (+14 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `main()` connect `main` to `debug-handshake.mjs`, `decodeResponse`?**
  _High betweenness centrality (0.003) - this node is a cross-community bridge._
- **Why does `buildExtensions()` connect `Community 2` to `debug-handshake.mjs`, `main`?**
  _High betweenness centrality (0.001) - this node is a cross-community bridge._
- **Why does `buildTransportParams()` connect `Community 2` to `debug-handshake.mjs`?**
  _High betweenness centrality (0.001) - this node is a cross-community bridge._
- **What connects `packages`, `check-server.sh script`, `PORT` to the rest of the system?**
  _19 weakly-connected nodes found - possible documentation gaps or missing edges._