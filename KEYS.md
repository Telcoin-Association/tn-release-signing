# Maintainer release keys

The keys in [`keys/`](keys/) may sign a release of every project that consumes this repository: its tag and its `SHA256SUMS.asc`.
Each key is generated on a YubiKey and never leaves it.
The fingerprint is the primary key's, and every check matches signatures on it.

| Holder | Primary key fingerprint | Role | YubiKey serial | Added | Status |
|--------|-------------------------|------|----------------|-------|--------|
| @grantkee | 4E36D35A4AB61B589861D01AC7173F2377CA7573 | main | 37853185 | 2026-10-17 | active |
| @MavenRain | 32F886ADE9C3A88218E4B67CA0A69159FC76DBFD | main | 16753241 | 2026-11-11 | active |

Holder is the maintainer's GitHub login, which names their file in `keys/`.
Role is `main` for the key on the maintainer's everyday YubiKey and `spare` for the key on a spare YubiKey; both keys sit in the holder's one file.
Status is `active`, or `revoked YYYY-MM-DD` for a key that may no longer sign; treat a revoked key as untrusted.
Compare these fingerprints with the ones a release check prints and with the holder's keys on GitHub at `https://github.com/<handle>.gpg`.

## Threshold

Signatures required: 1.

A release needs good signatures over `SHA256SUMS` from at least this many distinct holders, so a holder's main and spare keys count once.
Each consumer's `release.conf` sets `MIN_SIGNATURES`, which `release.sh` enforces, and it may be higher than the line above but never lower.
`release.sh` reads the line above at the commit of this repository that the consumer's `main` records, and stops with exit 1 when `MIN_SIGNATURES` is lower or the line is missing, so keep it in the form `Signatures required: N`.
`RELEASE_SIG_THRESHOLD` raises the requirement for one run, up to the number of holders in the table, and never lowers it.

## Co-signer policy

A release tag carries exactly one signature, a good one by a key in `keys/`.
Every signature in `SHA256SUMS.asc` must be a good one by a key in `keys/` as well.
`release.sh` refuses the whole file when any signature in it is bad, unverifiable, expired, revoked or by a key off the allowlist, even next to enough good ones, and an operator who verifies a release by hand applies the same rule.
tn-node-deployment's own release check differs today: it only warns on a signature by an unknown key (`NO_PUBKEY` or `ERRSIG 9`).
Reconciling that check with this policy is part of tn-node-deployment's move to this repository.

## Changing this table

- To add a maintainer, open one pull request that adds `keys/<handle>.asc` and a row here, and have it reviewed by someone other than the key's owner.
  [YubiKey signing setup](docs/yubikey-setup.md) covers creating and exporting the key.
  `yubikey-setup.sh run` writes `keys/<handle>.asc` and stages it; when this table already has a row for the handle it fills that row in and stages it too, and otherwise it prints the row for you to add.
- Every YubiKey holds a key of its own.
  A spare YubiKey's key is added to the holder's `.asc` file with a row of its own here, Role `spare`.
  A replaced or lost YubiKey means a new key: add it to the `.asc` file with a new row, set the old row's Status to `revoked YYYY-MM-DD`, and delete the old key from the file.
- When a key is revoked, keep its row, set Status to `revoked YYYY-MM-DD`, and delete the key from its `.asc` file, deleting the file when no other key remains.
- A change here reaches a consumer when its `main` moves the submodule pointer to a commit that carries it, because release checks read the keys at the pointer recorded on the consumer's `main`.
  After a revocation, move the pointer in every consumer; the key is accepted there until that change merges.
- To require more signatures, raise the Signatures required line above and the value in every consumer's `release.conf` in the same round of pull requests.
  A consumer raises `MIN_SIGNATURES` no later than the pull request that moves its pointer to the commit with the raised line, because `release.sh` refuses the lower value from then on.
  The threshold cannot exceed the number of holders in the table.
