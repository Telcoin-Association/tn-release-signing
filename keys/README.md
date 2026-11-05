# Maintainer release keys

This directory is the allowlist of OpenPGP keys that may sign a release tag and its `SHA256SUMS.asc`, for every project that consumes this repository.
The table of these keys, the signature threshold and the co-signer policy are in [KEYS.md](../KEYS.md).

## Format

Each file is named `<handle>.asc`, where `<handle>` is the maintainer's GitHub login and matches `^[A-Za-z0-9-]+$`.
Its content is the output of `gpg --armor --export --export-options export-minimal <PRIMARY_FPR>`: the key as it was generated on the maintainer's YubiKey, the primary key and its subkeys.
A spare YubiKey holds a key of its own, which is appended to the same file by listing both primary fingerprints in that command.
Signatures are matched on the primary key fingerprint, and a primary fingerprint may appear in only one file.

## Readers

- `release.sh` and each consumer's release workflow read this directory at the commit of this repository that the consumer's `main` records for its submodule, never from the tagged tree or the checked-out submodule, so a release cannot vouch for its own signer.
- Operators read it at that same commit too, by cloning the consumer's `main` with its submodule, verify `SHA256SUMS.asc` against it, and compare the fingerprints with the table in [KEYS.md](../KEYS.md).
- Every reader uses the files at that commit, so once a consumer's `main` moves its pointer past a change here, a signature by a key that has since expired, been revoked or been removed stops verifying there, older releases included.

## Rules

- When an expiry date changes or a spare YubiKey's key is added, re-export the keys and update the file in place.
- Extend a key before it expires, even a spare's that is rarely used, or the releases it signed stop verifying.
- When a key is revoked, delete it from the file, or delete the file when no other key remains, and mark its row in [KEYS.md](../KEYS.md) as revoked.
- Never add a placeholder for a new maintainer; add the file only once the real key exists.

Provisioning a key on a YubiKey is covered in [YubiKey signing setup](../docs/yubikey-setup.md), whose steps `yubikey-setup.sh` at the root of this repository runs.
