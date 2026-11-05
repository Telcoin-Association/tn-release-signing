# tn-release-signing

This repository holds the release script, the YubiKey provisioning script and the maintainer keys that every signed Telcoin project shares.
Each project consumes it as a git submodule, so one allowlist and one signing procedure cover every release.

`release.sh` was imported from telcoin-network `etc/release.sh` at commit `a0d6e6e26` (2222 lines) on 2026-11-05.
Its history before that date lives in the telcoin-network repository.
