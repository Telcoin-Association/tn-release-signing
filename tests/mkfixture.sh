#!/usr/bin/env bash
# Fixture of the submodule layout: a project that carries this repository as a submodule.
#
#   tests/mkfixture.sh DIR [CONF]
#
# builds, in DIR (new or empty):
#   gnupg/          GNUPGHOME with the throwaway maintainer key alice (ed25519, no passphrase)
#   alice.asc       that key, armored; fpr-alice holds its primary fingerprint
#   gitconfig       the only git configuration the fixture reads (GIT_CONFIG_GLOBAL, no
#                   system file), so the caller's signing and hook settings stay out
#   signing-work/   the signing repository: release.sh, README.md and examples/ of this
#                   checkout, keys/alice.asc and a KEYS.md that requires one signature
#   signing.git     its bare copy, the submodule's origin
#   consumer-work/  a cargo package with signing.git as a submodule at release/, CONF as its
#                   release.conf (default: fx_conf's, with KEYS_PATH=release/keys and
#                   SELF_REPO_PATH=release), a one-line file for every TARBALL_FILES name
#                   after the first, and on main a base commit and the release commit of v1.2.3
#   consumer.git    its bare copy, the clone's origin
#   clone/          git clone --recurse-submodules of consumer.git, at main
#
# mkfixture_committed DIR CONF builds the committed layout instead: no signing repository, and
# consumer-work commits release.sh at CONF's SELF_REPO_PATH and alice.asc in CONF's KEYS_PATH.
#
# A test sources this file instead and calls mkfixture DIR [CONF] (or mkfixture_committed),
# then the fx_* functions to change the fixture further; FX names DIR. The bare repositories
# are updated with fetch, never push.
# Bash 3.2 safe; the caller runs it with set -e, as the functions do not check every command.
# Every git command runs with -C, so the caller's directory is never read (in a container it
# may be a mounted worktree whose .git file names a path that does not exist there).

FX_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FX=
FX_DATE=2026-11-05

# git that may clone and fetch submodules from local paths (protocol.file.allow is "user"
# since git 2.38.1, which forbids it for submodules). Only the fixture's own commands use it:
# release.sh runs with git's defaults.
fx_git() { git -c protocol.file.allow=always "$@"; }

# fx_init DIR: FX, the keyring and the git configuration.
fx_init() {
    mkdir -p "$1"
    [ -z "$(ls -A "$1")" ] || { printf 'mkfixture: %s is not empty\n' "$1" >&2; return 1; }
    FX=$(cd "$1" && pwd -P)
    GNUPGHOME=$FX/gnupg
    GIT_CONFIG_GLOBAL=$FX/gitconfig
    GIT_CONFIG_NOSYSTEM=1
    export GNUPGHOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
    mkdir -m 700 "$GNUPGHOME"
    : >"$GIT_CONFIG_GLOBAL"
    git -C "$FX" config --global user.name 'Fixture Maintainer'
    git -C "$FX" config --global user.email fixture@example.invalid
    git -C "$FX" config --global init.defaultBranch main
    git -C "$FX" config --global commit.gpgSign false
    git -C "$FX" config --global tag.gpgSign false
    git -C "$FX" config --global gpg.program gpg
    git -C "$FX" config --global advice.detachedHead false
}

# fx_conf FILE: the consumer's release.conf.
fx_conf() {
    cat >"$1" <<'EOF'
# shellcheck shell=bash disable=SC2034 # release.sh reads these values after sourcing the file
# The fixture consumer: a cargo package that carries tn-release-signing at release/.
PROJECT=fixture
DEFAULT_REPO=example/fixture
TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$'
TRIPLE=x86_64-unknown-linux-musl
TARBALL_FILES='fixture LICENSE'
VERSION_FILE=Cargo.toml
CHANGELOG_FILE=CHANGELOG.md
ANCHOR='<!-- ANCHOR: releases -->'
MAIN_REF=refs/remotes/origin/main
ARTIFACT_ROOT=target/release-artifacts
MIN_SIGNATURES=1
KEYS_PATH=release/keys
SELF_REPO_PATH=release
EOF
}

# fx_key HANDLE: a throwaway maintainer key; writes FX/HANDLE.asc and FX/fpr-HANDLE.
fx_key() {
    local fpr
    gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@example.invalid>" ed25519 sign never 2>/dev/null
    fpr=$(gpg --batch --with-colons --list-keys "<$1@example.invalid>" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    [ -n "$fpr" ] || { printf 'mkfixture: no key for %s\n' "$1" >&2; return 1; }
    printf '%s\n' "$fpr" >"$FX/fpr-$1"
    gpg --batch --armor --export "$fpr" >"$FX/$1.asc"
}

fx_fpr() { cat "$FX/fpr-$1"; }

# fx_keys_md FILE N: a KEYS.md whose threshold line, in the form release.sh reads, requires N
# signatures.
fx_keys_md() {
    printf '# Maintainer release keys\n\n## Threshold\n\nSignatures required: %s.\n' "$2" >"$1"
}

# fx_signing_commit BRANCH MESSAGE HANDLE...: puts the keys of HANDLE... into keys/ on BRANCH
# of the signing repository (a new BRANCH starts at main), commits, updates signing.git and
# prints the commit.
fx_signing_commit() {
    local branch=$1 msg=$2 w=$FX/signing-work h
    shift 2
    if git -C "$w" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        git -C "$w" checkout -q "$branch"
    else
        git -C "$w" checkout -q -b "$branch" main
    fi
    for h in "$@"; do cp "$FX/$h.asc" "$w/keys/$h.asc"; done
    git -C "$w" add keys
    git -C "$w" commit -q -m "$msg"
    git -C "$FX/signing.git" fetch -q "$w" "+refs/heads/$branch:refs/heads/$branch"
    git -C "$w" rev-parse HEAD
}

# fx_pin SHA MESSAGE: commits the consumer's release/ submodule at SHA on the current branch of
# consumer-work.
fx_pin() {
    local w=$FX/consumer-work
    git -C "$w/release" fetch -q origin
    git -C "$w/release" checkout -q "$1"
    git -C "$w" add release
    git -C "$w" commit -q -m "$2"
}

# fx_release VERSION: the release commit of vVERSION on the current branch of consumer-work,
# as the prep step leaves it (version, CHANGELOG section with the release-base marker).
fx_release() {
    local w=$FX/consumer-work base
    base=$(git -C "$w" rev-parse HEAD)
    sed "s/^version = \".*\"\$/version = \"$1\"/" "$w/Cargo.toml" >"$w/Cargo.toml.new"
    mv "$w/Cargo.toml.new" "$w/Cargo.toml"
    printf '# Changelog\n\n<!-- ANCHOR: releases -->\n## [v%s] - %s\n<!-- release-base: %s -->\n\n- release %s\n' \
        "$1" "$FX_DATE" "$base" "$1" >"$w/CHANGELOG.md"
    git -C "$w" commit -q -a -m "release: v$1"
}

# fx_publish BRANCH: copies BRANCH of consumer-work to consumer.git.
fx_publish() {
    git -C "$FX/consumer.git" fetch -q "$FX/consumer-work" "+refs/heads/$1:refs/heads/$1"
}

# fx_tag HANDLE TAG COMMIT: TAG on COMMIT in the clone, signed with HANDLE's key.
fx_tag() {
    git -C "$FX/clone" -c gpg.format=openpgp tag -s -u "$(fx_fpr "$1")" -m "Release $2" "$2" "$3"
}

# fx_conf_value CONF NAME: the value CONF sets for NAME. CONF is sourced in a subshell, so its
# assignments and hook functions stay there.
fx_conf_value() {
    (
        # shellcheck source=/dev/null
        . "$1" >/dev/null 2>&1
        printf '%s\n' "${!2:-}"
    )
}

# fx_tree CONF: the files of consumer-work that both layouts share, not yet committed: CONF as
# release.conf (fx_conf's when CONF is empty), a one-line file for every TARBALL_FILES name
# after the first (the program comes from the build), CHANGELOG.md with the anchor and a
# .gitignore for the artifacts. The caller writes Cargo.toml.
fx_tree() {
    local w=$FX/consumer-work name first=1
    if [ -n "$1" ]; then cp "$1" "$w/release.conf"; else fx_conf "$w/release.conf"; fi
    for name in $(fx_conf_value "$w/release.conf" TARBALL_FILES); do
        if [ "$first" = 1 ]; then
            first=0
            continue
        fi
        printf 'fixture %s\n' "$name" >"$w/$name"
    done
    printf '# Changelog\n\n<!-- ANCHOR: releases -->\n' >"$w/CHANGELOG.md"
    printf 'target/\n' >"$w/.gitignore"
}

# fx_first_release: commits the tree of consumer-work as the base commit on main and the
# release commit of v1.2.3 on top, copies main to consumer.git and clones that into clone/.
fx_first_release() {
    local w=$FX/consumer-work
    git -C "$w" add -A
    git -C "$w" commit -q -m base
    fx_release 1.2.3
    git -C "$FX" init -q --bare "$FX/consumer.git"
    fx_publish main
    fx_git -C "$FX" clone -q --recurse-submodules "$FX/consumer.git" "$FX/clone"
}

mkfixture() {
    local f w
    fx_init "$1"
    fx_key alice

    w=$FX/signing-work
    git -C "$FX" init -q "$w"
    mkdir -p "$w/keys" "$w/examples"
    for f in release.sh README.md examples/release.conf; do
        if [ -f "$FX_SRC/$f" ]; then cp "$FX_SRC/$f" "$w/$f"; fi
    done
    cp "$FX/alice.asc" "$w/keys/alice.asc"
    fx_keys_md "$w/KEYS.md" 1
    git -C "$w" add -A
    git -C "$w" commit -q -m 'signing: release.sh and the key of alice'
    git -C "$FX" init -q --bare "$FX/signing.git"
    git -C "$FX/signing.git" fetch -q "$w" '+refs/heads/main:refs/heads/main'

    w=$FX/consumer-work
    git -C "$FX" init -q "$w"
    fx_git -C "$w" submodule add -q "$FX/signing.git" release
    fx_tree "${2:-}"
    printf '[package]\nname = "fixture"\nversion = "0.0.0"\nedition = "2021"\n' >"$w/Cargo.toml"
    fx_first_release
}

# mkfixture_committed DIR CONF: the layout of a project that commits release.sh (telcoin-network
# today): consumer-work holds this checkout's release.sh at CONF's SELF_REPO_PATH, alice.asc in
# CONF's KEYS_PATH, the files of fx_tree and a workspace Cargo.toml ([workspace.package]
# version), with the commits, consumer.git and clone/ of mkfixture.
mkfixture_committed() {
    local w self keys
    fx_init "$1"
    fx_key alice
    self=$(fx_conf_value "$2" SELF_REPO_PATH)
    keys=$(fx_conf_value "$2" KEYS_PATH)
    if [ -z "$self" ] || [ -z "$keys" ]; then
        printf 'mkfixture: %s sets no SELF_REPO_PATH or KEYS_PATH\n' "$2" >&2
        return 1
    fi
    w=$FX/consumer-work
    git -C "$FX" init -q "$w"
    mkdir -p "$w/$keys"
    case "$self" in */*) mkdir -p "$w/${self%/*}" ;; esac
    cp "$FX_SRC/release.sh" "$w/$self"
    cp "$FX/alice.asc" "$w/$keys/alice.asc"
    fx_tree "$2"
    printf '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "0.0.0"\n' >"$w/Cargo.toml"
    fx_first_release
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    [ $# = 1 ] || [ $# = 2 ] || { printf 'usage: %s DIR [CONF]\n' "$0" >&2; exit 2; }
    mkfixture "$1" "${2:-}"
    gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
    printf 'fixture in %s\n' "$FX"
fi
