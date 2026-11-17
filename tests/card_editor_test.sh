#!/usr/bin/env bash
# The card editor steps of yubikey-setup.sh (issue #1). gpg drops the first argument after
# --card-edit, so the script gives admin, key-attr or generate, and quit on gpg's command fd,
# as answers to its prompt. A stand-in for gpg that drops the argument the same way records
# every answer, and the test checks them. It also checks that the stand-in, given the arguments
# the script used to pass, exits 0 with the card unchanged; that an unanswered question, a
# question asked twice in a row and a prompt with no command left each stop gpg; and that a
# failure keeps gpg's output in the script's temp dir, also when gpg exited 0 and printed
# nothing, while a success removes it.
#
#   bash tests/card_editor_test.sh [DIR]
#
# DIR (new or empty) keeps the files for inspection; without it a temp dir is removed. It needs
# no YubiKey, no real gpg and no network: a probe sources yubikey-setup.sh with HOME set to a
# scratch dir and calls card_editor or drive_gpg_editor with GPG set to the stand-in.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
. "$here/lib.sh"

t_setup "${1:-}"
unset FAKE_CARD_HAS_KEY FAKE_REJECT_CURVE
script=$(cd "$here/.." && pwd)/yubikey-setup.sh
fake=$T_DIR/gpg

# The stand-in for gpg --card-edit, after gpg 2.4's g10/gpg.c and g10/card-util.c. It drops the
# first argument after --card-edit, runs the others as commands, and only then asks
# cardedit.prompt on the status fd, once per command. admin toggles admin mode; key-attr and
# generate do nothing without it and say so nowhere, as gpg's "Admin-only command" goes to the
# tty, which --no-tty discards. It logs its arguments to $HOME/gpg.argv and every answer it
# reads to $HOME/gpg.answers, one per line, and writes $HOME/card when a command takes effect.
# FAKE_CARD_HAS_KEY=1 makes generate ask cardedit.genkeys.replace_keys, as for a card that
# holds a key; FAKE_REJECT_CURVE=1 makes key-attr ask keygen.curve twice, as gpg does after an
# answer it rejects. It has no TERM trap, so the script's SIGTERM stops it inside read.
cat >"$fake" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >"$HOME/gpg.argv"
printf 'Reader ...........: stand-in YubiKey\n'
admin=0
ans=

# ask KIND KEYWORD: asks on the status fd and puts the line read from the command fd in ans.
ask() {
    printf '[GNUPG:] %s %s\n' "$1" "$2" >&5
    IFS= read -r ans <&4 || exit 2
    printf '%s\n' "$ans" >>"$HOME/gpg.answers"
    printf '[GNUPG:] GOT_IT\n' >&5
}

key_attr() {
    local slot attrs=
    for slot in signature encryption authentication; do
        ask GET_LINE cardedit.genkeys.algo
        [ "$ans" = 2 ] || return 0
        ask GET_LINE keygen.curve
        if [ "${FAKE_REJECT_CURVE:-0}" = 1 ]; then ask GET_LINE keygen.curve; fi
        [ "$ans" = 1 ] || return 0
        if [ "$slot" = encryption ]; then attrs="$attrs cv25519"; else attrs="$attrs ed25519"; fi
    done
    printf '%s\n' "${attrs# }" >"$HOME/card"
}

generate() {
    local backup valid name email
    ask GET_LINE cardedit.genkeys.backup_enc
    backup=$ans
    if [ "${FAKE_CARD_HAS_KEY:-0}" = 1 ]; then
        ask GET_BOOL cardedit.genkeys.replace_keys
        [ "$ans" = y ] || return 0
    fi
    ask GET_LINE keygen.valid
    valid=$ans
    ask GET_LINE keygen.name
    name=$ans
    ask GET_LINE keygen.email
    email=$ans
    ask GET_LINE keygen.comment
    printf 'key "%s <%s>" valid %s backup %s\n' "$name" "$email" "$valid" "$backup" >>"$HOME/card"
}

editor_command() {
    case "$1" in
        quit) exit 0 ;;
        admin) admin=$((1 - admin)) ;;
        key-attr) if [ "$admin" = 1 ]; then key_attr; fi ;;
        generate) if [ "$admin" = 1 ]; then generate; fi ;;
    esac
}

while [ $# -gt 0 ] && [ "$1" != --card-edit ]; do shift; done
if [ $# = 0 ]; then
    printf 'stand-in gpg: no --card-edit\n' >&2
    exit 2
fi
shift
if [ $# -gt 0 ]; then shift; fi
while [ $# -gt 0 ]; do
    editor_command "$1"
    shift
done
while :; do
    ask GET_LINE cardedit.prompt
    editor_command "$ans"
done
EOF
chmod 0755 "$fake"

# probe.sh SCRIPT GPG CASE, run in a case's dir: sources SCRIPT with that dir as HOME and sets
# the state setup and stage_identity would, then runs CASE against GPG. WORK is $HOME/work.
cat >"$T_DIR/probe.sh" <<'EOF'
probe_script=$1
probe_gpg=$2
probe_case=$3
export HOME=$PWD
. "$probe_script"
MODE=run
GPG=$probe_gpg
HOME_GNUPG=$HOME/.gnupg
NAME='Test Maintainer'
EMAIL=maintainer@example.com
WORK=$HOME/work
mkdir -m 700 "$WORK"
trap cleanup EXIT
trap 'exit 143' TERM
case "$probe_case" in
    key-attr) card_editor key-attr keyattr_answer "Nothing was generated." ;;
    generate) card_editor generate generate_answer "The card may hold a partial key." ;;
    no-quit)
        rc=0
        drive_gpg_editor keyattr_answer "$WORK/card-no-quit" admin key-attr || rc=$?
        printf 'rc=%s keyword=%s\n' "$rc" "$EDITOR_KEYWORD"
        ;;
    read-back)
        # What generate_key does when gpg exited 0 and the card reads back unchanged.
        : >"$WORK/card-key-attr.out"
        card_editor_failed key-attr "the key attributes read back unchanged"
        ;;
    old)
        # The arguments card_editor gave gpg before the fix.
        "$GPG" --no-tty --command-fd 4 --status-fd 5 --no-options --homedir "$HOME_GNUPG" \
            --pinentry-mode ask --card-edit admin key-attr quit 4</dev/null 5>"$WORK/old.status"
        ;;
esac
EOF

# limit COMMAND...: COMMAND under timeout 60 where timeout exists, so that a protocol mismatch
# fails the test instead of hanging it. A stock Mac has no timeout.
if command -v timeout >/dev/null 2>&1; then
    limit() { timeout 60 "$@"; }
else
    limit() { "$@"; }
fi

# home NAME: makes T_DIR/NAME with an empty .gnupg in it and sets h to it. The next probe runs
# there, with that dir as HOME.
home() {
    mkdir -m 700 "$T_DIR/$1" "$T_DIR/$1/.gnupg"
    h=$T_DIR/$1
}

# probe CASE [VAR=VALUE]: runs probe.sh CASE in the dir home made, with VAR=VALUE set.
probe() {
    step "$h" limit env ${2:+"$2"} bash "$T_DIR/probe.sh" "$script" "$fake" "$1"
}

# answers_are LINE...: the stand-in read exactly these answers, in this order.
answers_are() {
    printf '%s\n' "$@" >"$T_DIR/expected"
    if cmp -s "$T_DIR/expected" "$h/gpg.answers"; then return 0; fi
    printf '#   answers read: '
    tr '\n' ' ' <"$h/gpg.answers" 2>/dev/null || true
    printf '\n'
    return 1
}

# card_is TEXT: the stand-in's card holds exactly TEXT.
card_is() { [ -f "$h/card" ] && [ "$(cat "$h/card")" = "$1" ]; }

home key-attr
probe key-attr
expect_rc 0 "card_editor key-attr succeeds"
check "key-attr: the answers are admin, key-attr, ECC and Curve 25519 for three keys, quit" \
    answers_are admin key-attr 2 1 2 1 2 1 quit
check "key-attr sets ed25519 cv25519 ed25519" card_is "ed25519 cv25519 ed25519"
check "no word follows --card-edit in gpg's arguments" \
    test "$(tail -n 1 "$h/gpg.argv")" = --card-edit
check "after key-attr succeeds the temp dir is removed" test ! -e "$h/work"

home generate
probe generate
expect_rc 0 "card_editor generate succeeds"
check "generate: the answers are admin, generate, no backup, 2y, name, email, no comment, quit" \
    answers_are admin generate n 2y 'Test Maintainer' maintainer@example.com '' quit
check "generate puts a key with that user ID on the card" \
    card_is 'key "Test Maintainer <maintainer@example.com>" valid 2y backup n'
check "after generate succeeds the temp dir is removed" test ! -e "$h/work"

home old
probe old
expect_rc 0 "the stand-in given --card-edit admin key-attr quit exits 0, as gpg did in issue #1"
check "and leaves the card unchanged" test ! -e "$h/card"
check "and asks nothing" test ! -e "$h/gpg.answers"

home has-key
probe generate FAKE_CARD_HAS_KEY=1
expect_rc 1 "a question generate_answer does not answer fails card_editor"
expect_err "gpg --card-edit generate asked 'cardedit.genkeys.replace_keys'" \
    "the error names the question"
check "gpg is stopped at that question: the answers end with admin, generate, n" \
    answers_are admin generate n
check "and the card is unchanged" test ! -e "$h/card"
expect_err "gpg's last lines:" "the failure prints gpg's last lines"
expect_err "Reader ...........: stand-in YubiKey" "which hold gpg's output"
expect_err "gpg's card editor output is kept in $h/work; remove that directory" \
    "the failure names the temp dir it keeps"
check "the kept temp dir holds gpg's output" test -s "$h/work/card-generate.out"

home reject-curve
probe key-attr FAKE_REJECT_CURVE=1
expect_rc 1 "a question asked twice in a row fails card_editor"
expect_err "keygen.curve (asked again, so gpg rejected the answer)" "the error names it as asked again"
check "gpg is stopped at the second keygen.curve" answers_are admin key-attr 2 1
check "and the card is unchanged" test ! -e "$h/card"

home no-quit
probe no-quit
expect_rc 0 "the probe of drive_gpg_editor admin key-attr runs"
expect_out "rc=3 keyword=cardedit.prompt (no command is left to give)" \
    "a prompt with no command left stops gpg"
check "after the commands it was given" answers_are admin key-attr 2 1 2 1 2 1

home read-back
probe read-back
expect_rc 1 "card_editor_failed fails the run for a card that reads back unchanged"
expect_err "gpg printed nothing." "it says so when gpg printed nothing"
expect_err "error: the key attributes read back unchanged" "it ends with the caller's message"
expect_err "gpg's card editor output is kept in $h/work; remove that directory" \
    "and it names the temp dir it keeps"
check "which is still there" test -d "$h/work"

finish
