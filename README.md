# tn-release-signing

This repository holds the release script, the YubiKey provisioning script and the maintainer keys that every signed Telcoin project shares.
Each project consumes it as a git submodule, so one allowlist and one signing procedure cover every release.

`release.sh` was imported from telcoin-network `etc/release.sh` at commit `a0d6e6e26` (2222 lines) on 2026-11-05.
Its history before that date lives in the telcoin-network repository.

## Layout

| Path | What it is |
|------|------------|
| `release.sh` | The release pipeline, from `prep` and `tag` through `build`, `sign`, `verify` and `publish`; bash 3.2. |
| `yubikey-setup.sh` | One-time setup of a maintainer's signing key on a YubiKey; macOS only. |
| `keys/` | The allowlist, one `<handle>.asc` per maintainer, with its format and rules in `keys/README.md`. |
| `KEYS.md` | The table of maintainer keys, the signature threshold and the co-signer policy. |
| `docs/` | The maintainer guides to the YubiKey setup, signing and key rotation. |
| `examples/` | The `release.conf` files a consumer starts from. |

## How a consumer uses this repository

A consumer adds this repository as a submodule at `release/` and runs `release/release.sh <subcommand> <TAG>` from its own root.
It keeps its own values and release steps in a `release.conf` in its repository root, the parent of the directory that holds `release.sh`, with `KEYS_PATH=release/keys` and `SELF_REPO_PATH=release`.
`examples/release.conf` lists every key, with the values telcoin-network used when the script was imported and its release steps sketched as hooks.
`release.sh` reads the keys and itself at the commit of this repository that the consumer's `main` records for `release/`, so a change here reaches a consumer only when its `main` moves that pointer, and every consumer needs a CODEOWNERS rule that puts each move in front of a maintainer.
A maintainer runs `yubikey-setup.sh` from a checkout of this repository, a clone or a consumer's `release/` submodule, and opens the pull request that adds the key here.
