#!/usr/bin/env bash
# MAIN_REF names the branch that fetch_tag, prep and tag fetch: release.conf must set it to
# refs/remotes/origin/<branch>, and the fetch refspec follows that branch.
#
#   bash tests/main_ref_test.sh [DIR]
#
# DIR (new or empty) keeps the files for inspection; without it a temp dir is removed. parse
# runs with RELEASE_DRY_RUN=1; the fetch is observed by sourcing release.sh with git_fetch and
# ls_remote_tag replaced, so nothing calls origin, gh or git push.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
. "$here/lib.sh"
# shellcheck source=SCRIPTDIR/mkfixture.sh
. "$here/mkfixture.sh"

t_setup "${1:-}"
fx_init "$T_DIR/fx"
p=$FX/project
mkdir -p "$p/release"
cp "$FX_SRC/release.sh" "$p/release/release.sh"
git -C "$p" init -q

# conf MAIN_REF: the fixture consumer's release.conf with that MAIN_REF.
conf() {
    fx_conf "$p/release.conf.new"
    sed "s|^MAIN_REF=.*\$|MAIN_REF=$1|" "$p/release.conf.new" >"$p/release.conf"
    rm "$p/release.conf.new"
}

# What fetch_tag hands git_fetch for a tag origin has. It runs without init_env, so DRY_RUN
# keeps its default 0 and fetch_tag does fetch, into the stubs.
cat >"$T_DIR/probe.sh" <<'EOF'
. ./release/release.sh
load_conf
TAG=v1.2.3
ls_remote_tag() { printf '0000000000000000000000000000000000000000\n'; }
git_fetch() { printf 'fetch %s\n' "$@"; }
fetch_tag
EOF

conf refs/remotes/origin/main
step "$p" env RELEASE_DRY_RUN=1 ./release/release.sh parse v1.2.3
expect_rc 0 "parse accepts MAIN_REF=refs/remotes/origin/main"
step "$p" bash "$T_DIR/probe.sh"
expect_out "fetch +refs/heads/main:refs/remotes/origin/main" "fetch_tag fetches main into MAIN_REF"

conf refs/remotes/origin/release/v1
step "$p" env RELEASE_DRY_RUN=1 ./release/release.sh parse v1.2.3
expect_rc 0 "parse accepts MAIN_REF=refs/remotes/origin/release/v1"
step "$p" bash "$T_DIR/probe.sh"
expect_out "fetch +refs/heads/release/v1:refs/remotes/origin/release/v1" "fetch_tag fetches the branch MAIN_REF names"
expect_no_out "refs/heads/main" "fetch_tag does not fetch main for another branch"

for bad in refs/heads/main refs/remotes/upstream/main origin/main; do
    conf "$bad"
    step "$p" env RELEASE_DRY_RUN=1 ./release/release.sh parse v1.2.3
    expect_rc 2 "parse refuses MAIN_REF=$bad"
    expect_err "MAIN_REF must be refs/remotes/origin/<branch>, got '$bad'" "the refusal of $bad names the form"
done

finish
