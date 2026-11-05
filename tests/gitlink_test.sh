#!/usr/bin/env bash
# The gitlink rules of the submodule layout (plan 9.3), on the fixture of mkfixture.sh:
#   1. a key added only on the tag's commit is refused (check-tag);
#   2. a key present at the submodule commit main records, but absent from the checkout, is
#      found by fetching that commit (check-tag);
#   3. a checkout whose submodule HEAD differs from main's gitlink, or whose script differs
#      from the one at that commit, fails check_scripts_from_main (publish, whose first check
#      it is in a dry run);
#   4. a KEYS_PATH outside the submodule is refused (check-tag);
#   5. release.conf's MIN_SIGNATURES may exceed the threshold KEYS.md states at main's gitlink
#      but not fall below it, and that KEYS.md must state one (check-tag).
# Every step runs with RELEASE_DRY_RUN=1, so nothing calls gh or git push.
#
#   bash tests/gitlink_test.sh [DIR]
#
# DIR (new or empty) keeps the fixture for inspection; without it a temp dir is removed.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
. "$here/lib.sh"
# shellcheck source=SCRIPTDIR/mkfixture.sh
. "$here/mkfixture.sh"

t_setup "${1:-}"
mkfixture "$T_DIR/fx"
clone=$FX/clone
rel() { env RELEASE_DRY_RUN=1 "$@"; }
has_commit() { git -C "$clone/release" cat-file -e "$1^{commit}" 2>/dev/null; }
s1=$(git -C "$clone" rev-parse 'HEAD:release')
r1=$(git -C "$clone" rev-parse HEAD)

# Control: alice's key is on main through the gitlink.
fx_tag alice v1.2.3 "$r1"
step "$clone" rel ./release/release.sh check-tag v1.2.3
expect_rc 0 "check-tag accepts a tag by alice, whose key is at main's gitlink"
expect_out "signer=alice" "check-tag names alice as the signer"
expect_err "submodule layout: maintainer keys from release at $s1" "check-tag reads the keys at main's gitlink"

# Rule 1. A commit outside main moves the pointer to a signing commit that adds mallory's key;
# the clone checks it out, so the key is in the submodule's checkout and object store.
fx_key mallory
s1m=$(fx_signing_commit mallory 'signing: add the key of mallory' mallory)
git -C "$FX/consumer-work" checkout -q -b pr
fx_pin "$s1m" 'release: pin the signing commit with mallory'
fx_publish pr
git -C "$FX/consumer-work" checkout -q main
fx_git -C "$FX/consumer-work" submodule update -q
git -C "$clone" fetch -q --no-recurse-submodules origin
git -C "$clone" checkout -q --detach origin/pr
fx_git -C "$clone" submodule update -q
check "the checkout holds mallory's key" test -f "$clone/release/keys/mallory.asc"
fx_tag mallory v1.2.4 "$(git -C "$clone" rev-parse HEAD)"
step "$clone" rel ./release/release.sh check-tag v1.2.4
expect_rc 1 "check-tag refuses a key added only on the tag's commit"
expect_err "tag v1.2.4 is not signed by an allowlisted maintainer key" "the refusal names the unlisted signer"
expect_err "maintainer keys from release at $s1" "the keys still come from main's gitlink, not the checkout"
git -C "$clone" tag -d v1.2.4 >/dev/null
git -C "$clone" checkout -q main
fx_git -C "$clone" submodule update -q

# Rule 2. main moves the pointer to a signing commit that adds bob's key and releases v1.3.0;
# the clone fetches main without its submodule, so neither its checkout nor its submodule's
# object store has that commit.
fx_key bob
s2=$(fx_signing_commit main 'signing: add the key of bob' bob)
fx_pin "$s2" 'release: pin the signing commit with bob'
fx_release 1.3.0
fx_publish main
git -C "$clone" fetch -q --no-recurse-submodules origin
r2=$(git -C "$clone" rev-parse origin/main)
check "main's gitlink names the commit with bob's key" test "$(git -C "$clone" rev-parse "$r2:release")" = "$s2"
if has_commit "$s2"; then has=yes; else has=no; fi
check "the submodule's object store lacks that commit" test "$has" = no
check "the checkout lacks bob's key" test ! -e "$clone/release/keys/bob.asc"
fx_tag bob v1.3.0 "$r2"
step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 0 "check-tag accepts a tag by bob, whose key is only at main's gitlink"
expect_out "signer=bob" "check-tag names bob as the signer"
expect_err "submodule layout: fetching $s2" "check-tag fetches the commit main records"
if has_commit "$s2"; then has=yes; else has=no; fi
check "the submodule's object store has that commit afterwards" test "$has" = yes

# Rule 3. The clone's submodule is still at s1 while main records s2.
step "$clone" rel RELEASE_DIR="$T_DIR/rd" ./release/release.sh publish v1.3.0
expect_rc 2 "publish refuses a submodule checked out away from main's gitlink"
expect_err "submodule layout: release is checked out at $s1 but refs/remotes/origin/main records $s2" \
    "the refusal names both commits"
expect_no_out "signer=" "publish stops before check-tag"

git -C "$clone" merge -q --ff-only origin/main
fx_git -C "$clone" submodule update -q
step "$clone" rel RELEASE_DIR="$T_DIR/rd" ./release/release.sh publish v1.3.0
expect_out "signer=bob" "publish passes the script check once the submodule is at main's gitlink"
expect_err "no GitHub release for v1.3.0" "publish goes on to the release, which the dry run lacks"

printf '# edited\n' >>"$clone/release/release.sh"
step "$clone" rel RELEASE_DIR="$T_DIR/rd" ./release/release.sh publish v1.3.0
expect_rc 2 "publish refuses an edited script in a submodule at main's gitlink"
expect_err "differs from release.sh in release at $s2" "the refusal names the commit compared"
expect_no_out "signer=" "publish stops before check-tag"
git -C "$clone/release" checkout -q -- release.sh

# conf_set NAME VALUE: the clone's release.conf with NAME=VALUE; check-tag does not compare it
# with main's, and `git checkout -- release.conf` restores it.
conf_set() {
    sed "s|^$1=.*\$|$1=$2|" "$clone/release.conf" >"$clone/release.conf.new"
    mv "$clone/release.conf.new" "$clone/release.conf"
}

# pin_keys_md N MESSAGE: a commit on the signing repository's main whose KEYS.md requires N
# signatures (states no threshold when N is empty), pinned on the consumer's main and fetched
# by the clone without its submodule; prints the commit.
pin_keys_md() {
    local w=$FX/signing-work sha
    git -C "$w" checkout -q main
    if [ -n "$1" ]; then fx_keys_md "$w/KEYS.md" "$1"; else printf '# Maintainer release keys\n' >"$w/KEYS.md"; fi
    git -C "$w" add KEYS.md
    git -C "$w" commit -q -m "$2"
    git -C "$FX/signing.git" fetch -q "$w" '+refs/heads/main:refs/heads/main'
    sha=$(git -C "$w" rev-parse HEAD)
    fx_pin "$sha" "release: pin the signing commit that says: $2"
    fx_publish main
    git -C "$clone" fetch -q --no-recurse-submodules origin
    printf '%s\n' "$sha"
}

# Rule 4. With KEYS_PATH outside release/, the keys would come from the project's own tree.
conf_set KEYS_PATH keys
step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 2 "check-tag refuses KEYS_PATH outside the submodule"
expect_err "submodule layout: KEYS_PATH must lie inside SELF_REPO_PATH" "the refusal names the rule"
git -C "$clone" checkout -q -- release.conf

# Rule 5. KEYS.md at s2 requires one signature, and alice and bob are two holders.
conf_set MIN_SIGNATURES 2
step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 0 "check-tag accepts MIN_SIGNATURES above the threshold KEYS.md states"
git -C "$clone" checkout -q -- release.conf

s3=$(pin_keys_md 2 'signing: require two signatures')
step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 1 "check-tag refuses MIN_SIGNATURES below the threshold KEYS.md states at main's gitlink"
expect_err "MIN_SIGNATURES=1 in $clone/release.conf is below the 2 signatures KEYS.md requires in release at $s3" \
    "the refusal names both thresholds and the commit"
conf_set MIN_SIGNATURES 2
step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 0 "check-tag accepts MIN_SIGNATURES equal to that threshold"
git -C "$clone" checkout -q -- release.conf

s4=$(pin_keys_md '' 'signing: drop the threshold line')
step "$clone" rel ./release/release.sh check-tag v1.3.0
expect_rc 1 "check-tag refuses a KEYS.md at main's gitlink that states no threshold"
expect_err "KEYS.md in release at $s4, the commit refs/remotes/origin/main records, must state the threshold" \
    "the refusal names the commit read"

finish
