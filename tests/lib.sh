# shellcheck shell=bash
# Checks for the tests in this directory. A test sources this file, runs each command under
# test with `step`, judges it with the expect_* functions and ends with `finish`, which prints
# the result line and returns non-zero when a check failed. Every check prints one
# "ok N - what" or "not ok N - what" line; a failed check after a step shows its output.
# Bash 3.2 safe.

T_NAME=${0##*/}
T_PASS=0
T_FAIL=0
T_DIR=       # t_setup: the test's scratch directory
T_KEEP=0     # t_setup: 1 when the caller gave the directory, which then stays
T_DONE=0     # finish ran
T_OUT=       # step: file holding the last step's stdout
T_ERR=       # step: file holding the last step's stderr
T_RC=        # step: the last step's exit status

# t_setup [DIR]: the scratch directory, DIR (new or empty, kept afterwards) or a fresh temp
# dir (removed on exit), and an environment without the caller's release and CI variables.
t_setup() {
    local v
    if [ -n "${1:-}" ]; then
        mkdir -p "$1"
        [ -z "$(ls -A "$1")" ] || { printf 'Bail out! %s is not empty\n' "$1"; exit 2; }
        T_DIR=$(cd "$1" && pwd -P)
        T_KEEP=1
    else
        T_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tn-release-test.XXXXXX")
        T_DIR=$(cd "$T_DIR" && pwd -P)
    fi
    trap t_exit EXIT
    for v in $(env | sed -n 's/^\(RELEASE_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    unset GITHUB_ACTIONS GITHUB_EVENT_NAME GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_REPOSITORY
}

t_exit() {
    local rc=$?
    if [ "$T_DONE" != 1 ]; then printf 'Bail out! %s stopped early (exit %s)\n' "$T_NAME" "$rc"; fi
    if [ -n "${GNUPGHOME:-}" ] && command -v gpgconf >/dev/null 2>&1; then
        gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
    fi
    if [ "$T_KEEP" = 0 ] && [ -n "$T_DIR" ]; then rm -rf "$T_DIR"; fi
}

t_ok() {
    T_PASS=$((T_PASS + 1))
    printf 'ok %d - %s\n' $((T_PASS + T_FAIL)) "$1"
}

t_fail() {
    T_FAIL=$((T_FAIL + 1))
    printf 'not ok %d - %s\n' $((T_PASS + T_FAIL)) "$1"
    if [ -n "$T_OUT" ]; then
        printf '#   exit %s\n' "$T_RC"
        sed 's/^/#   out| /' "$T_OUT"
        sed 's/^/#   err| /' "$T_ERR"
    fi
}

# step DIR COMMAND...: runs COMMAND in DIR and keeps its stdout, stderr and exit status.
step() {
    local dir=$1
    shift
    T_OUT=$T_DIR/step.out
    T_ERR=$T_DIR/step.err
    (cd "$dir" && "$@") >"$T_OUT" 2>"$T_ERR" && T_RC=0 || T_RC=$?
}

# expect_rc N WHAT: the last step exited with N.
expect_rc() {
    if [ "$T_RC" = "$1" ]; then t_ok "$2"; else t_fail "$2 (exit $T_RC, expected $1)"; fi
}

# expect_err TEXT WHAT / expect_out TEXT WHAT: the last step's stderr / stdout holds TEXT.
expect_err() {
    if grep -F -q -e "$1" "$T_ERR"; then t_ok "$2"; else t_fail "$2 (stderr lacks '$1')"; fi
}

expect_out() {
    if grep -F -q -e "$1" "$T_OUT"; then t_ok "$2"; else t_fail "$2 (stdout lacks '$1')"; fi
}

# expect_no_out TEXT WHAT: the last step's stdout does not hold TEXT.
expect_no_out() {
    if grep -F -q -e "$1" "$T_OUT"; then t_fail "$2 (stdout holds '$1')"; else t_ok "$2"; fi
}

# check WHAT COMMAND...: COMMAND succeeds (a fact about the fixture, not a step's output).
check() {
    local what=$1
    shift
    if "$@"; then
        t_ok "$what"
    else
        T_OUT=
        t_fail "$what"
    fi
}

finish() {
    T_DONE=1
    printf '%s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" = 0 ]
}
