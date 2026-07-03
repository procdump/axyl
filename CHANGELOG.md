# Changelog

The Cargo.toml workspace version is currently `1.1.1`; mainnet shipped on the `1.x` line.
The hand-written entries below stop at `v0.1.2` and do not cover the ~30+ PRs merged on the
`1.x` line. For the authoritative per-release notes, see the
[GitHub Releases page](https://github.com/raylsnetwork/axyl/releases).

This file is being modernized as part of the documentation pass tracked in issue #380; once
that work lands, each `1.x` release will get its own entry here. Until then, treat
**GitHub Releases as the source of truth for release notes** and use this file only as a
historical record of the pre-1.x line.

## [v0.1.2] - 2026-03-20

### Features

- **AdminTransfer hardfork** with self-contained hardforks module (#231)
- **BatchDigestV2 hardfork** for go-ethereum compatibility (#223)
- Add upgrade option to manage script (#224)
- Add latest config to docker-network (#225)
- Enable tests and PR, optimize start validator script (#230)
- Add CODEOWNERS file (#229)

### Bug Fixes

- Change USDr token name and symbol; fix failing `test_invalid_batch_wrong_size` (#221)

### Security Fixes (Halborn Audit)

- **FIND-016**: Parked batch drain path bypasses deduplication guard enabling state divergence (#226)
- **FIND-010**: QuorumWaiter remaining-time subtraction inversion prevents peer drain task from spawning (#140)
- **FIND-009**: Unvalidated self-reported NodeRecord timestamps enable committee peer eviction (#129)
- **FIND-008**: Epoch transition clears non-validator IP bans and permanently desynchronizes ban counter (#144)
- **B FIND-002**: Unauthenticated manipulation of epoch synchronization state allows permanent denial of service (#138)
- **B FIND-001**: Insufficient validation in parallel certificate fetching enables persistent database poisoning (#136)

---

## [v0.1.1] - 2026-03-16
