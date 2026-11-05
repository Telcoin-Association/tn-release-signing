#!/usr/bin/env bash
# Dry-run smoke test of the whole pipeline (plan 9.3): every step runs with RELEASE_DRY_RUN=1,
# and RELEASE_DIR stands in for the GitHub release. Two fixtures of mkfixture.sh:
#   1. a cargo package that carries this repository as a submodule at release/, whose
#      release.conf is examples/cargo.release.conf plus two fixture hooks (hook_build packs a
#      two-line script as the program, hook_changelog writes a one-entry section), runs prep,
#      tag, check-tag, notes, draft, build, sign, verify and publish for v1.3.0;
#   2. a project that commits release.sh at etc/, with examples/release.conf verbatim (the
#      node's values, every hook left empty), passes check-tag and verify for v1.2.3. Its
#      build alone runs with a stub hook_build appended, since the default one needs docker.
# cargo, gh and docker are stubs on PATH: cargo does nothing (prep runs cargo update), gh and
# docker fail, and every call is logged; the test requires that gh and docker never ran and
# that origin never received a tag.
#
#   bash tests/dry_run_test.sh [DIR]
#
# DIR (new or empty) keeps the fixtures for inspection; without it a temp dir is removed.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
. "$here/lib.sh"
# shellcheck source=SCRIPTDIR/mkfixture.sh
. "$here/mkfixture.sh"

t_setup "${1:-}"
rel() { env RELEASE_DRY_RUN=1 "$@"; }

# stub NAME STATUS: a NAME on PATH that logs its arguments to T_DIR/NAME.log and exits STATUS.
bin=$T_DIR/bin
mkdir "$bin"
stub() {
    cat >"$bin/$1" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$T_DIR/$1.log"
exit $2
EOF
    chmod 0755 "$bin/$1"
}
stub cargo 0
stub gh 1
stub docker 1
PATH=$bin:$PATH
export PATH

# The stand-in for a build: the program is a two-line script, which pack_tarball names after
# the first TARBALL_FILES entry and packs with the other files from the tag.
cat >"$T_DIR/hook-build.conf" <<'EOF'

# Fixture: a two-line script stands in for the cargo build.
hook_build() {
    printf '#!/bin/sh\necho fixture\n' >"$WORK/program"
    chmod 0755 "$WORK/program"
    pack_tarball "$1" "$WORK/program"
}
EOF

# ---------------------------------------------------------------------------------------------
# Fixture 1: a plain cargo package with the submodule layout, through every step.

cat "$FX_SRC/examples/cargo.release.conf" "$T_DIR/hook-build.conf" - >"$T_DIR/cargo.conf" <<'EOF'

# Fixture: prep's CHANGELOG section.
hook_changelog() {
    printf '## [%s] - 2026-11-05\n\n- the dry-run release\n' "$BASE" >"$1"
}
EOF
mkfixture "$T_DIR/cargo" "$T_DIR/cargo.conf"
clone=$FX/clone
rd=$T_DIR/cargo-release
fpr=$(fx_fpr alice)
tarball=tn-p2p-allow-sync-v1.3.0-x86_64-unknown-linux-musl.tar.gz
main0=$(git -C "$clone" rev-parse HEAD)

step "$clone" ./release/release.sh parse v1.3.0-adiri
expect_rc 2 "parse refuses a channel suffix, which TAG_RE does not allow"

step "$clone" rel ./release/release.sh prep v1.3.0
expect_rc 0 "prep writes v1.3.0 on main's tip"
expect_out "## [v1.3.0] - 2026-11-05" "prep prints the new CHANGELOG section"
expect_out "<!-- release-base: $main0 -->" "the section's release-base marker names main's tip"
check "prep ran cargo update --workspace" grep -q -x -e 'update --workspace' "$T_DIR/cargo.log"
check "prep set version 1.3.0 in Cargo.toml" grep -q -x -e 'version = "1.3.0"' "$clone/Cargo.toml"

# The release PR merges alone: the release commit lands on origin's main.
git -C "$clone" commit -q -a -m 'release: v1.3.0'
r1=$(git -C "$clone" rev-parse HEAD)
git -C "$FX/consumer.git" fetch -q "$clone" '+refs/heads/main:refs/heads/main'
git -C "$clone" fetch -q --no-recurse-submodules origin
check "origin's main is the release commit" test "$(git -C "$clone" rev-parse origin/main)" = "$r1"

step "$clone" rel RELEASE_YES=1 RELEASE_GPG_KEY="$fpr" ./release/release.sh tag v1.3.0
expect_rc 0 "tag signs v1.3.0 with alice's key"
expect_err "dry run: not pushing; v1.3.0 stays a local tag" "tag leaves the tag local"
check "the tag names the release commit" test "$(git -C "$clone" rev-parse 'v1.3.0^{commit}')" = "$r1"

step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 0 "check-tag accepts v1.3.0"
expect_out "commit=$r1 signer=alice fingerprint=$fpr channel=stable version=1.3.0 features= prerelease=false" \
    "check-tag prints the commit, the signer and the channel"

step "$clone" rel ./release/release.sh notes v1.3.0
expect_rc 0 "notes renders the release body"
expect_out "- the dry-run release" "the body carries the CHANGELOG entry"
expect_out "| Tarball | \`$tarball\` (\`x86_64-unknown-linux-musl\`) |" "the body names the tarball"
expect_out "REPO=Telcoin-Association/tn-p2p-allow-sync" "the verify commands name DEFAULT_REPO"
expect_out "| @alice | \`$fpr\` |" "the body lists alice's fingerprint"
expect_out 'git clone --quiet --depth 1 --recurse-submodules=release --shallow-submodules --branch main "https://github.com/$REPO.git" main &&' \
    "the verify commands clone main with the release submodule, which holds the keys"
expect_out 'in the key table of `main/release/KEYS.md` with the Status `active`' "the fingerprint check names KEYS.md in the submodule"

step "$clone" rel GITHUB_ACTIONS=true RELEASE_DIR="$rd" ./release/release.sh draft v1.3.0
expect_rc 0 "draft creates the stand-in release"
check "the stand-in release exists" test -d "$rd"
check "draft wrote the release body" test -f "$clone/target/release-artifacts/v1.3.0.notes.md"

step "$clone" rel RELEASE_DIR="$rd" ./release/release.sh build v1.3.0
expect_rc 0 "build uploads the tarball and SHA256SUMS"
expect_out "verified v1.3.0 commit=$r1 signatures=0/1" "build verifies its unsigned upload"
expect_out "SHA256SUMS sha256: " "build prints the SHA256SUMS hash for sign"
sums=$(awk '/^SHA256SUMS sha256: / { print $3 }' "$T_OUT") || sums=
check "SHA256SUMS lists the tarball alone" test "$(awk '{ print $2 }' "$rd/SHA256SUMS")" = "$tarball"
listing=$(tar -tzf "$rd/$tarball" 2>/dev/null | LC_ALL=C sort) || listing=
d=${tarball%.tar.gz}
want=$(printf '%s\n' "$d/" "$d/tn-p2p-allow-sync" "$d/LICENSE-APACHE" "$d/LICENSE-MIT" "$d/NOTICE" | LC_ALL=C sort)
check "the tarball holds the program and the TARBALL_FILES from the tag" test "$listing" = "$want"

step "$clone" rel RELEASE_DIR="$rd" RELEASE_YES=1 RELEASE_SUMS_SHA256="$sums" RELEASE_GPG_KEY="$fpr" \
    ./release/release.sh sign v1.3.0
expect_rc 0 "sign adds alice's signature over SHA256SUMS"
expect_out "signed v1.3.0 as @alice: 1/1 signatures" "sign counts one of one required signature"
check "the stand-in release holds SHA256SUMS.asc" test -f "$rd/SHA256SUMS.asc"

step "$clone" rel RELEASE_DIR="$rd" ./release/release.sh verify v1.3.0
expect_rc 0 "verify accepts the signed release"
expect_out "verified v1.3.0 commit=$r1 signatures=1/1" "verify counts alice's signature"

step "$clone" rel RELEASE_DIR="$rd" RELEASE_YES=1 ./release/release.sh publish v1.3.0
expect_rc 0 "publish verifies the draft and publishes it"
expect_err "dry run: would run gh release edit v1.3.0 --draft=false --prerelease=false --latest" \
    "publish stops short of gh"
expect_out "published v1.3.0 newest=yes" "publish reports the newest final release"

gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
origin1=$FX/consumer.git

# ---------------------------------------------------------------------------------------------
# Fixture 2: the node's release.conf, committed layout, empty hooks: check-tag and verify.

mkfixture_committed "$T_DIR/node" "$FX_SRC/examples/release.conf"
clone=$FX/clone
rd=$T_DIR/node-release
fpr=$(fx_fpr alice)
r2=$(git -C "$clone" rev-parse HEAD)
check "the node fixture's release.conf is examples/release.conf" cmp -s "$FX_SRC/examples/release.conf" "$clone/release.conf"

fx_tag alice v1.2.3 "$r2"
step "$clone" rel ./etc/release.sh check-tag v1.2.3
expect_rc 0 "check-tag accepts v1.2.3 with the node's release.conf and no hooks"
expect_out "commit=$r2 signer=alice fingerprint=$fpr channel=stable version=1.2.3 features= prerelease=false" \
    "check-tag reads the version from [workspace.package] and the key from .github/maintainer-gpg-keys"

step "$clone" rel ./etc/release.sh notes v1.2.3
expect_rc 0 "notes renders the node fixture's release body"
expect_out 'git clone --quiet --depth 1 --branch main "https://github.com/$REPO.git" main &&' \
    "the committed layout's verify commands clone main alone, which holds the keys"
expect_no_out "KEYS.md" "the committed layout's notes name no KEYS.md"

step "$clone" rel GITHUB_ACTIONS=true RELEASE_DIR="$rd" ./etc/release.sh draft v1.2.3
expect_rc 0 "draft creates the stand-in release for the node fixture"
cat "$T_DIR/hook-build.conf" >>"$clone/release.conf"
step "$clone" rel RELEASE_DIR="$rd" RELEASE_ALLOW_LOCAL_SCRIPTS=1 ./etc/release.sh build v1.2.3
expect_rc 0 "build, with the stub hook_build appended, uploads the node fixture's files"
sums=$(awk '/^SHA256SUMS sha256: / { print $3 }' "$T_OUT") || sums=
git -C "$clone" checkout -q -- release.conf
check "release.conf is examples/release.conf again" cmp -s "$FX_SRC/examples/release.conf" "$clone/release.conf"

step "$clone" rel RELEASE_DIR="$rd" RELEASE_YES=1 RELEASE_SUMS_SHA256="$sums" RELEASE_GPG_KEY="$fpr" \
    ./etc/release.sh sign v1.2.3
expect_rc 0 "sign adds alice's signature with the node's release.conf"

step "$clone" rel RELEASE_DIR="$rd" ./etc/release.sh verify v1.2.3
expect_rc 0 "verify accepts the release with the node's release.conf and no hooks"
expect_out "verified v1.2.3 commit=$r2 signatures=1/1" "verify counts alice's signature"

# ---------------------------------------------------------------------------------------------
# Nothing left the machine.

check "gh never ran" test ! -e "$T_DIR/gh.log"
check "docker never ran" test ! -e "$T_DIR/docker.log"
check "neither origin received a tag" test -z "$(git -C "$origin1" tag -l)$(git -C "$FX/consumer.git" tag -l)"

finish
