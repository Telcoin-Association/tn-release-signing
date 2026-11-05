# Signing a release

A consumer signs and publishes its releases with this repository's [`release.sh`](../release.sh), which it carries as a git submodule.
The script holds the tag grammar, the maintainer allowlist, the signature count and the GitHub release layer; the consumer keeps its own values and release steps in a `release.conf`.
Every check reads the maintainer keys at the commit of this repository that the consumer's `main` records for the submodule, so a change here reaches a consumer only when its `main` moves that pointer.

Setting up a signing key is covered in [YubiKey signing setup](yubikey-setup.md), and the key table, the threshold and the co-signer policy are in [`KEYS.md`](../KEYS.md).
`release.sh --help` prints the steps, and the header of `release.sh` has the full reference.

## How a consumer carries this repository

The consumer adds this repository as a submodule at `release/` and writes a `release.conf` in its own repository root, the parent of the directory that holds `release.sh`:

```sh
git submodule add <URL of this repository> release
cp release/examples/cargo.release.conf release.conf
```

[`examples/cargo.release.conf`](../examples/cargo.release.conf) is written for this layout, a plain cargo package with the submodule at `release/`; in the copy, `KEYS_PATH=release/keys` and `SELF_REPO_PATH=release` stay, and the other values become the consumer's own.
The submodule sits one directory below the root, as `release/` does, and nowhere deeper: `release.sh` reads `release.conf` from the parent of its own directory, while `build` and `publish` compare `release.conf` and `SELF_REPO_PATH` with `main`'s copies from the root, so every step refuses (exit 2) a `SELF_REPO_PATH` that does not name the directory holding `release.sh`.
Every step then runs from the consumer's root as `release/release.sh <step> <TAG>`, and a consumer may wrap the steps in make targets of its own.

Every machine that runs a step needs the submodule checked out, and `build` and `publish` need it at the commit `main` records, so run this after every pull of `main`:

```sh
git submodule update --init -- release
```

A CI job that runs `release.sh` checks the consumer out with its submodules as well.
The keys come from the submodule's object store at the commit `main` records, never from its checked-out files, and `release.sh` fetches that commit from the submodule's `origin` when the checkout lacks it.
`build` and `publish` also require the submodule to be checked out at that commit and `release.sh` to equal its copy there, and `release.conf` and every `EXTRA_SCRIPTS` file to equal `main`'s copy, unless `RELEASE_ALLOW_LOCAL_SCRIPTS=1` is set.

## release.conf

`release.sh` sources `release.conf` before anything else, so it is bash 3.2: no associative arrays, `mapfile`, `${x,,}`, `sed -i` or GNU `date`.
[`examples/cargo.release.conf`](../examples/cargo.release.conf) sets every required key for the submodule layout, and [`examples/release.conf`](../examples/release.conf), telcoin-network's values for its committed `etc/release.sh`, describes every key at more length; a missing required key or a malformed value stops every step with exit 2.

| Key | Required | What it sets |
| --- | --- | --- |
| `PROJECT` | yes | The project name; the tarball is `PROJECT-TAG-TRIPLE.tar.gz` with the directory `PROJECT-TAG-TRIPLE/` inside. |
| `DEFAULT_REPO` | yes | `owner/repo` on GitHub, used when `RELEASE_REPO` is unset outside CI. |
| `TAG_RE` | yes | The release tags; groups 1-3 capture X, Y and Z, a trailing `-rcN` marks a release candidate, and anything between `vX.Y.Z` and `-rcN` names a channel. |
| `TRIPLE`, `TARBALL_FILES` | yes | The target triple in the tarball name, and the files the tarball holds: the program first, then files from the root of the tag's tree. |
| `VERSION_FILE` | yes | The `Cargo.toml` whose version `prep` sets and the tag checks compare with the tag. |
| `CHANGELOG_FILE`, `ANCHOR` | yes | The changelog, and the line after which `prep` writes each release's section. |
| `MAIN_REF` | yes | The ref a release must be on, where the keys and the scripts are read, such as `refs/remotes/origin/main`. |
| `ARTIFACT_ROOT` | yes | The local directory for the files `build` and `sign` write, one subdirectory per tag. |
| `MIN_SIGNATURES` | yes | The maintainer signatures over `SHA256SUMS` that `publish` requires, at least 1, and never below the threshold in `KEYS.md`, which `release.sh` checks. |
| `KEYS_PATH` | yes | The allowlist directory, `release/keys` for the submodule. |
| `SELF_REPO_PATH` | yes | The submodule path, `release`, one directory below the root. |
| `EXTRA_ASSETS` | no | Release assets the build writes beside the tarball; `SHA256SUMS` lists them, and every step uploads, downloads and checks them. |
| `EXTRA_SCRIPTS` | no | More repository paths that `build` and `publish` require to equal `main`'s copy. |
| `BUILD_IMAGE` | no | The image, pinned by digest, in which the default `hook_build` runs cargo. |

### Hooks

`release.conf` may define these functions; each does nothing unless the consumer defines it, except `hook_build`.
A hook reports a failure with `die`, as the core does.

| Hook | Called by | What it does |
| --- | --- | --- |
| `hook_parse_extras` | every step, after the tag is parsed | May set `CHANNEL`, `FEATURES`, `PRERELEASE`, `ALIAS`, `EXTRA_ASSETS` and the consumer's own variables; runs without git. |
| `hook_check_tag_extra` | `check-tag`, `build`, `verify` and `publish` (`always`); `tag` and `sign` (`if-available`) | Extra checks of the release commit, such as an attestation; with `if-available` a check that needs a tool CI has may be left to CI. |
| `hook_extra_sums` | `notes`, `draft`, `build`, `sign`, `verify` and `publish` | Writes the repository files that `SHA256SUMS` also covers, as committed at the release commit, and prints their paths. |
| `hook_build` | `build` | Builds from a pristine worktree of the tag and writes the tarball and every `EXTRA_ASSETS` file; the default runs `cargo build --locked --release` for `TRIPLE` in `BUILD_IMAGE` and packs the tarball deterministically. |
| `hook_check_release_files` | `sign` and `verify`, which `build` and `publish` run too | Extra checks of the downloaded release files, after the generic ones. |
| `hook_notes_sections` | `notes`, `draft`, `build` and `publish`, which render the release body | Extra rows for the Artifacts table, extra sections, and extra items for the Verify section of the release notes. |
| `hook_publish_alias` | `publish`, for a final that is the newest of its channel | `plan` before the confirmation prompt, `move` after the release is published, such as moving an image alias. |
| `hook_changelog` | `prep` | Writes the new changelog section; with none defined, `prep` stops. |

## The steps

| Step | Where | What it does |
| --- | --- | --- |
| `parse TAG` | anywhere | Prints the tag's channel, features, tarball and extra assets; needs neither git nor the network. |
| `prep TAG` | build server | On a clean checkout of `main`'s tip, sets the version in `VERSION_FILE`, runs `cargo update --workspace` and writes the changelog section with a marker naming `main`'s tip, then prints the commands for the release PR. |
| `tag TAG` | laptop | Checks the version and changelog rules, signs the tag on `main`'s tip (or `RELEASE_COMMIT`) with your allowlisted key, verifies it, and pushes it after you confirm. |
| `check-tag TAG` | CI, build server, laptop | Validates the pushed tag: a signed annotated tag with exactly one signature, a good one by an allowlisted key, on a commit on `main`, with the version and changelog rules. |
| `notes TAG` | CI, build server | Renders the release body. |
| `draft TAG` | CI only | Creates the draft release, or refreshes the body of the draft the bot created. |
| `build TAG` | build server, Linux x86_64 | Builds the tarball and `EXTRA_ASSETS` from the tag with `hook_build`, writes `SHA256SUMS`, uploads them to the draft, checks the draft as `verify --allow-unsigned` does, and prints `SHA256SUMS sha256: <hex>`. |
| `sign TAG` | laptop | Re-checks the draft's files, compares the `SHA256SUMS` hash with the one `build` printed, and appends your detached signature to `SHA256SUMS.asc` after you confirm. |
| `verify TAG [--allow-unsigned]` | build server, CI, operators | Re-checks the tag, the assets and the signatures, and requires `MIN_SIGNATURES` of them, or `RELEASE_SIG_THRESHOLD`; `--allow-unsigned` allows a draft without `SHA256SUMS.asc`. |
| `publish TAG` | build server | Verifies, checks the release body, publishes the draft after you confirm, and runs `hook_publish_alias` for the newest final of its channel; safe to run again. |

A release goes through them in this order:

1. `release/release.sh prep vX.Y.Z` on the build server, then the PR `release: vX.Y.Z` it prints, merged alone: the tag checks require the release commit's parent to be the commit the changelog marker names.
2. `release/release.sh tag vX.Y.Z` on the laptop, one touch of the YubiKey.
3. The consumer's release workflow runs `check-tag` and `draft` when the tag is pushed.
4. `release/release.sh build vX.Y.Z` on the build server; note the `SHA256SUMS sha256:` line it prints last.
5. `release/release.sh sign vX.Y.Z` on the laptop of each signer, with that hash pasted at the prompt or set in `RELEASE_SUMS_SHA256`, one touch each.
6. `release/release.sh verify vX.Y.Z`, then `release/release.sh publish vX.Y.Z`, on the build server.
7. The consumer's workflow runs `verify` again on the published release, as a detective check.

`tag`, `sign` and `publish` show what they are about to do and wait for you to type `yes`; `RELEASE_YES=1` answers those prompts, but never stands in for the `SHA256SUMS` hash that `sign` asks for.
A final version must be higher than every other final version in its channel, and a release candidate's version higher than every final in its channel, so no release candidate can follow its own final.

### Environment

All of these are optional.

| Variable | Steps | Effect |
| --- | --- | --- |
| `RELEASE_REPO` | all but `parse` | `owner/repo`; the default is `DEFAULT_REPO`, or `GITHUB_REPOSITORY` in CI. |
| `RELEASE_COMMIT` | `tag` | The commit to tag instead of `main`'s tip. |
| `RELEASE_GPG_KEY` | `tag`, `sign` | The signing key; the default is `git config user.signingkey`. |
| `RELEASE_SIG_THRESHOLD` | all but `parse` | The signatures required; never below `MIN_SIGNATURES`, nor above the number of allowlisted holders. |
| `RELEASE_ALLOW_LOCAL_SCRIPTS=1` | `build`, `publish` | Allows `release.sh`, `release.conf` or an `EXTRA_SCRIPTS` file to differ from `main`. |
| `RELEASE_SUMS_SHA256` | `sign` | The `SHA256SUMS` sha256 that `build` printed last; asked for at a prompt when unset. |
| `RELEASE_YES=1` | `tag`, `sign`, `publish` | Answers every confirmation prompt. |
| `GH_TOKEN` | all that call `gh` | Read by `gh` in CI; locally the `gh auth login` login is used. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | a policy or verification check failed |
| 2 | usage or precondition: a bad tag, a missing tool, a missing or incomplete `release.conf`, the wrong host, a missing draft, or a prompt with no TTY and no `RELEASE_YES=1` |
| 3 | an external service, the GitHub API or a service a hook calls, stayed unavailable after retries |

## Rehearse with a dry run

`RELEASE_DRY_RUN=1` runs the steps without calling `gh` or `git push`: a directory named by `RELEASE_DIR` stands in for the GitHub draft release, `tag` leaves the tag local, and `publish` prints the edit it would make.
These variables are honoured only in a dry run and refused without it:

| Variable | Effect |
| --- | --- |
| `RELEASE_DIR` | The directory that stands in for the GitHub release; it must lie outside `ARTIFACT_ROOT`. |
| `RELEASE_ALLOWLIST_DIR` | A directory of `*.asc` used instead of the allowlist at the pointer on `main`. |
| `RELEASE_MAIN_REF` | A ref used instead of `MAIN_REF`, with no fetch. |
| `RELEASE_IMAGE` | An image repository on `localhost:PORT/` or `127.0.0.1:PORT/`, for hooks that push an image. |
| `RELEASE_ATTESTATION=skip` | For hooks: skip an on-chain attestation check. |

A rehearsal of one release, from the consumer's root, with the hash from the `build` step in place of `<hex>`:

```sh
export RELEASE_DRY_RUN=1 RELEASE_DIR="$HOME/rehearsal/v1.2.3"
release/release.sh tag v1.2.3
GITHUB_ACTIONS=true release/release.sh draft v1.2.3
release/release.sh build v1.2.3
RELEASE_SUMS_SHA256=<hex> release/release.sh sign v1.2.3
release/release.sh verify v1.2.3
release/release.sh publish v1.2.3
```

`draft` runs only where `GITHUB_ACTIONS=true`, so the rehearsal sets it for that one step.
Afterwards delete the local tag with `git tag -d v1.2.3`, and remove `RELEASE_DIR` and the tag's directory under `ARTIFACT_ROOT`.

## Verify a release by hand

An operator checks a release before extracting or running anything from it.
The commands below take the maintainer keys from this repository at the commit the consumer's `main` records for `release/`, never from the release's tag, so a tag cannot bring its own key, and a key removed from the allowlist stops verifying once the consumer's pointer moves past its removal.
They clone the consumer's `main` with only the `release` submodule, at that commit, build a keyring from `release/keys/`, download the release files, stopping at the first download that fails, check the signatures over `SHA256SUMS`, and check the hashes.

Run them in one shell in a new, empty directory; the first command stops on a directory that is not empty, so no file from an earlier download is checked in place of this release's.
Set `TAG`, `REPO` and `TARBALL` first: the tarball is `PROJECT-TAG-TRIPLE.tar.gz` from the consumer's `release.conf`, and `release/release.sh parse <TAG>` in a checkout of the consumer prints it as `TARBALL`.

```sh
TAG="<tag>"
REPO="<owner>/<repo>"
TARBALL="<project>-$TAG-<triple>.tar.gz"
BASE="https://github.com/$REPO/releases/download/$TAG"
if [ -n "$(ls -A)" ]; then echo "Run these commands in a new, empty directory" >&2; false; fi &&
git clone --quiet --depth 1 --branch main --recurse-submodules=release --shallow-submodules "https://github.com/$REPO.git" main &&
for k in main/release/keys/*.asc; do gpg --dearmor < "$k"; done > release-keys.gpg &&
gpg --show-keys --with-fingerprint main/release/keys/*.asc &&
curl -fsSL --fail-early --remote-name-all "$BASE/SHA256SUMS" "$BASE/SHA256SUMS.asc" "$BASE/$TARBALL" &&
gpgv --status-fd 1 --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS |
awk '$2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)$/ { bad = 1 } $2 ~ /^(GOODSIG|BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)$/ { s = $2; print $2 } $2 == "VALIDSIG" && s == "GOODSIG" { print "signed by primary key " $NF; n++ } END { exit (n && !bad) ? 0 : 1 }' &&
sha256sum --check SHA256SUMS &&
echo "Signature and hashes verified"
```

The clone line may also be written as two commands, a clone of `main` and then the submodule at the commit `main` records:

```sh
git clone --quiet --depth 1 --branch main "https://github.com/$REPO.git" main &&
git -C main submodule --quiet update --init --depth 1 -- release &&
```

`git -C main submodule status -- release` prints the commit of this repository the keys came from.
A consumer with `EXTRA_ASSETS` adds each of them to the `curl` line.
A consumer whose `SHA256SUMS` also lists repository files fetches the tag and extracts those files before `gpgv`, with their paths in place of `<paths>`:

```sh
git -C main fetch --quiet --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" &&
git -C main archive "refs/tags/$TAG" <paths> | tar -xf - &&
```

If the last line `Signature and hashes verified` is missing, the files are not verified; stop, do not extract or run anything from this release, and report it.
gpgv prints `Good signature from` and exits 0 even when the signing key is revoked or expired, so the block reads gpgv's status lines instead: it counts only a `GOODSIG`, and it fails when any signature in `SHA256SUMS.asc` is `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG`, even if another one is good.
`release.sh` applies the same rule before a maintainer signs and before a release is published.
Then check the fingerprints: every primary key fingerprint `gpg --show-keys` printed, including the one after `signed by primary key`, must appear in the table in `main/release/KEYS.md` and at `https://github.com/<handle>.gpg`, where `<handle>` is the key file's name without `.asc`.
Stop on any mismatch.

## Moving the submodule pointer

A change to the keys, the threshold or the scripts here reaches a consumer only when its `main` records a commit of this repository that carries it.
To move the pointer, on a branch of the consumer that starts at an up-to-date `main`:

```sh
git submodule update --init -- release &&
git -C release fetch --quiet origin main &&
git -C release checkout --quiet --detach FETCH_HEAD &&
git diff --submodule=log -- release &&
git -C release diff "$(git rev-parse HEAD:release)" HEAD -- keys KEYS.md release.sh &&
git add release
```

The last two commands before `git add` show the commits the move brings in and their changes to the keys, the key table and the script, which is what the reviewer checks.
Commit, open a PR, and have it reviewed by a code owner, as the next section sets up.
Once it merges, every machine that runs a step runs `git submodule update --init -- release` after its next pull of `main`.

### CODEOWNERS for the pointer

The pointer on `main` decides which keys may sign the consumer's releases, so every consumer has a CODEOWNERS rule that puts each move of it in front of a maintainer:

```text
# release signing: the pointer to tn-release-signing, where it is fetched from, and the values and hooks release.sh enforces
/release       <owners>
/.gitmodules   <owners>
/release.conf  <owners>
```

`<owners>` stands for the maintainers who hold release keys, as GitHub logins or a team.
The pointer is one path, `release`, so the rule names it without a trailing slash.
`.gitmodules` and `release.conf` belong under the same rule: the first names where the submodule is fetched from, and the second sets `MIN_SIGNATURES` and the hooks every step runs.
The rule binds only where the branch protection or ruleset of `main` requires a review from code owners.

## Adding a maintainer or changing the threshold

- The new maintainer follows [YubiKey signing setup](yubikey-setup.md).
- One PR to this repository adds `keys/<handle>.asc` and the maintainer's row in the `KEYS.md` table.
- An existing maintainer reviews it and confirms the fingerprint with the new maintainer over a separate channel, such as a call, and against `https://github.com/<handle>.gpg`.
- Once it merges, each consumer moves its pointer to that commit, as [Moving the submodule pointer](#moving-the-submodule-pointer) describes; the key can sign a consumer's releases as soon as that consumer's PR merges, because every check reads the keys at the pointer on the consumer's `main`.

The threshold is stated once here, as the Signatures required line in [`KEYS.md`](../KEYS.md#threshold), and each consumer's `release.conf` sets `MIN_SIGNATURES`, which `release.sh` enforces and which may be higher than that line but never lower.
Every step that reads the keys also reads that line at the commit the consumer's `main` records, and stops with exit 1 when `MIN_SIGNATURES` is below it or the line is missing.
`RELEASE_SIG_THRESHOLD` raises it for a single command, and can go neither below `MIN_SIGNATURES` nor above the number of allowlisted holders.
To raise it for every release, raise the Signatures required line here, and in the same round of PRs `MIN_SIGNATURES` in every consumer's `release.conf`, with that consumer's operator docs updated to say how many good signatures to expect.
A consumer's `MIN_SIGNATURES` goes up no later than the PR that moves its pointer to the commit with the raised line, since its releases stop with exit 1 from then on until it does.
`build` and `publish` refuse a `release.conf` that differs from `main`'s, so a consumer's new value applies once its PR merges.
Signatures count per holder, so several keys in one holder's file count once.
With a threshold above 1, each signer runs `release.sh sign` on their own laptop before anyone runs `release.sh publish`.

## Rotating or revoking a key

[Expiry, loss and rotation](yubikey-setup.md#expiry-loss-and-rotation) has the commands.
`keys/` and `KEYS.md` change like this:

- for an extended expiry or a spare YubiKey's key, update `<handle>.asc` in place, and add a `KEYS.md` row with role `spare` for a spare's key;
- for a replacement YubiKey, which holds a new key, add that key to `<handle>.asc` with a new `KEYS.md` row, and revoke the old key;
- for a revoked key, after a lost YubiKey or a compromise, delete it from `<handle>.asc` (the whole file when no other key remains), mark its `KEYS.md` row `revoked YYYY-MM-DD`, and remove it from GitHub as [Lost or broken YubiKey](yubikey-setup.md#lost-or-broken-yubikey) describes;
- never add a placeholder file for a new maintainer; the file is added when the key exists.

Once the change merges here, move the pointer in every consumer, as [Moving the submodule pointer](#moving-the-submodule-pointer) describes.
After a revocation, move them all at once: each consumer accepts the revoked key until its own pointer move merges.

`release.sh verify` refuses `SHA256SUMS.asc` when any signature in it is by an expired, revoked or removed key, and it reads the keys at the pointer on the consumer's `main`.
So once a key expires, or a consumer's pointer moves past its revocation, that consumer's CI verification of the older releases the key signed fails.
Extend keys before they expire.
After revoking a compromised key, tell the operators of every consumer which releases are no longer trusted.
