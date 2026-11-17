#!/usr/bin/env bash
# The release body does not depend on the locale. publish compares the body it renders with the
# one draft or build wrote, line for line, and those steps run on different machines: CI, the
# build server and a maintainer's Mac. The body's key table lists the allowlist, so its order
# must be the same everywhere, whatever order a glob over the key files gives.
#
#   bash tests/locale_test.sh [DIR]
#
# The fixture's allowlist holds alice and Bob, which byte order (LC_ALL=C, macOS, musl) sorts
# Bob first and glibc's en_US.UTF-8 sorts alice first. notes runs under LC_ALL=C and under
# T_LOCALE (default en_US.UTF-8), and the two bodies must be equal, with Bob's row first.
# Where T_LOCALE is missing or sorts like C, as every locale does on musl, the comparison is
# skipped, unless T_REQUIRE_LOCALE=1, which CI sets on the runner's bash.
#
# DIR (new or empty) keeps the fixture for inspection; without it a temp dir is removed.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
. "$here/lib.sh"
# shellcheck source=SCRIPTDIR/mkfixture.sh
. "$here/mkfixture.sh"

t_setup "${1:-}"
loc=${T_LOCALE:-en_US.UTF-8}

# row_line HANDLE FILE: the line number of HANDLE's row in the body's key table.
row_line() { grep -n -F -e "| @$1 | " "$2" | cut -d: -f1; }

# The release commit of v1.2.3 is the clone's main; Bob's key joins the signing repository
# after it, and main pins that commit, so the allowlist on main holds alice and Bob.
mkfixture "$T_DIR/fx"
clone=$FX/clone
r=$(git -C "$clone" rev-parse HEAD)
fx_key Bob
s=$(fx_signing_commit main 'signing: the key of Bob' Bob)
fx_pin "$s" 'pin the signing repository with the key of Bob'
fx_publish main
git -C "$clone" fetch -q --no-recurse-submodules origin
fx_tag alice v1.2.3 "$r"

step "$clone" env RELEASE_DRY_RUN=1 LC_ALL=C ./release/release.sh notes v1.2.3
expect_rc 0 "notes renders the body under LC_ALL=C"
cp "$T_OUT" "$T_DIR/body.C"
expect_out "| @alice | \`$(fx_fpr alice)\` |" "the key table lists alice"
expect_out "| @Bob | \`$(fx_fpr Bob)\` |" "the key table lists Bob"
check "the key table lists Bob before alice, in byte order" \
    test "$(row_line Bob "$T_DIR/body.C")" -lt "$(row_line alice "$T_DIR/body.C")"

# Does T_LOCALE sort the two key file names differently from C? Only then is the comparison a
# test of anything.
mkdir "$T_DIR/collate"
: >"$T_DIR/collate/alice.asc"
: >"$T_DIR/collate/Bob.asc"
first=$(cd "$T_DIR/collate" && LC_ALL=$loc bash -c 'set -- *.asc; printf "%s\n" "$1"' 2>/dev/null)
if [ "$first" = alice.asc ]; then
    step "$clone" env RELEASE_DRY_RUN=1 LC_ALL="$loc" ./release/release.sh notes v1.2.3
    expect_rc 0 "notes renders the body under LC_ALL=$loc"
    if cmp -s "$T_DIR/body.C" "$T_OUT"; then
        t_ok "the body under LC_ALL=$loc is the body under LC_ALL=C"
    else
        diff "$T_DIR/body.C" "$T_OUT" | sed 's/^/#   diff| /' >"$T_DIR/body.diff" || true
        T_OUT=
        t_fail "the body under LC_ALL=$loc is the body under LC_ALL=C"
        cat "$T_DIR/body.diff"
    fi
elif [ "${T_REQUIRE_LOCALE:-0}" = 1 ]; then
    T_OUT=
    t_fail "T_LOCALE=$loc sorts alice.asc after Bob.asc or is missing, so the comparison cannot run (T_REQUIRE_LOCALE=1)"
else
    printf '# skip: T_LOCALE=%s sorts like C or is missing, so the bodies are not compared\n' "$loc"
fi

finish
