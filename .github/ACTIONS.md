# CI pins and jobs

`.github/workflows/ci.yaml` runs on every pull request and on every push to `main`.
The workflow token has no permissions (`permissions: {}`), and each job asks for `contents: read` only.
Every checkout sets `persist-credentials: false`, so no step can push with the token.

## Pins

| What | Version | Pinned to | Used by |
|---|---|---|---|
| `actions/checkout` | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` | every job |
| `bash` image (`BASH32_IMAGE`) | `3.2` (bash 3.2.57 on Alpine 3.22) | `sha256:b6252c62fc86114f93f02104a486c71e6569371d95950ea7479a2ffd6b47f16a` (multi-platform index) | `bash32`, `dry-run (bash 3.2)` |
| runner | `ubuntu-24.04` | not pinnable; GitHub updates the image | every job |

Unpinned, by choice: the runner's `shellcheck` and `docker`, `git`, `gnupg` and `gpg-agent` from Ubuntu 24.04's apt, and `git`, `gnupg`, `gpg-agent`, `tar` and `perl-utils` from Alpine 3.22's apk inside the pinned `bash` image.
They run only the checks below, never a release step, and a failure from a newer version shows up as a red check rather than a weaker one.

## Jobs

- `shellcheck`: `shellcheck -x --severity=error` on every tracked `*.sh` (`release.sh`, `yubikey-setup.sh`, `tests/*.sh`) and on `examples/*.conf`, which release.sh sources once a project copies one to its `release.conf`.
- `bash32`: `bash -n` of the same files under bash 3.2 in the `bash` image, then a grep for what `bash -n` accepts but 3.2 or macOS cannot run: `declare -A`, `mapfile`, `readarray`, `${x,,}` and `${x^^}`, `sed -i`, GNU `date -d`, `readlink -f`.
  Comment lines are skipped, since the scripts name these constructs to forbid them.
- `dry-run`: `tests/gitlink_test.sh`, `tests/main_ref_test.sh` and `tests/dry_run_test.sh`, twice.
  `bash 5` runs them on the runner with `git` and `gnupg` from apt.
  `bash 3.2` runs them in the `bash` image with git and GnuPG from apk, GNU tar for the build step's deterministic tarball, and `sha256sum` removed, so release.sh checks hashes with `shasum` as it does on a Mac.
  Every step of every test runs with `RELEASE_DRY_RUN=1` and a throwaway key on fixture repositories, and `tests/dry_run_test.sh` fails if anything ran `gh` or `docker` or pushed a tag.

## Updating a pin

Change the SHA or digest and its tag comment together, in one commit, and update the table above.

For an action, resolve the tag to a commit:

```sh
gh api repos/actions/checkout/git/ref/tags/v7.0.1 --jq '.object.type + " " + .object.sha'
```

When the type is `tag` (an annotated tag), resolve that object once more:

```sh
gh api repos/actions/checkout/git/tags/<sha> --jq '.object.sha'
```

For the image, take the digest of the multi-platform index:

```sh
docker buildx imagetools inspect bash:3.2
```
