#!/usr/bin/env bash
#
# Release pipeline shared by every signed project. CI, the build server and the maintainer
# laptop all run this one file, so the tag grammar, the maintainer allowlist, the signature
# counter and the GitHub release layer exist exactly once. Each project keeps its values and
# its project-only steps in release.conf (see "Project configuration" below and
# examples/release.conf).
#
# Usage: <path>/release.sh <subcommand> <TAG> [options]
#
# Flow:
#   1. prep TAG        server  set the version in VERSION_FILE to X.Y.Z, cargo update, splice
#                              the section hook_changelog writes into CHANGELOG_FILE; open the
#                              PR "release: TAG" and merge it alone
#   2. tag TAG         laptop  sign TAG on the release commit with an allowlisted key, push it
#   3. check-tag TAG   CI      validate the pushed tag; `notes` renders the release body and
#                              `draft` creates the draft release
#   4. build TAG       server  build the tarball from the tag (hook_build), upload SHA256SUMS,
#                              the tarball and EXTRA_ASSETS to the draft
#   5. sign TAG        laptop  re-check the draft's files as verify does, compare the SHA256SUMS
#                              hash with the one build printed, append a detached signature over
#                              SHA256SUMS to SHA256SUMS.asc
#   6. verify TAG      server  re-check tag, assets and signatures, then check the release
#      publish TAG             body, publish the draft and run hook_publish_alias
#   7. verify TAG      CI      re-check the published release (detective only)
#
# Subcommands: parse, check-tag, notes, draft, prep, tag, build, sign,
# verify [--allow-unsigned], publish. `help` or no arguments prints the usage.
#
# Exit codes:
#   0  ok
#   1  a policy or verification check failed
#   2  usage or precondition: bad TAG, missing tool, missing or incomplete release.conf, wrong
#      host, missing draft, or a prompt with no TTY and no RELEASE_YES=1
#   3  an external service (GitHub API, or a service a hook calls) stayed unavailable after
#      retries
#
# Project configuration: release.conf, in the project's repository root, which is the parent
# of the directory holding this script (etc/ when the script sits at etc/release.sh, the
# submodule directory when a project carries this repository as a submodule). The script
# therefore sits exactly one directory below the root, and SELF_REPO_PATH names it from
# there: the file (etc/release.sh) or the submodule directory (release). load_conf refuses
# any other value, as build and publish compare both files with main's copies. It is bash
# 3.2, sourced before anything else, and build and publish refuse a copy that differs from
# main's. It must set PROJECT, DEFAULT_REPO, TAG_RE, TRIPLE, TARBALL_FILES, VERSION_FILE,
# CHANGELOG_FILE, ANCHOR, MAIN_REF, ARTIFACT_ROOT, MIN_SIGNATURES, KEYS_PATH and
# SELF_REPO_PATH, may set EXTRA_ASSETS, EXTRA_SCRIPTS and BUILD_IMAGE, and may define the
# hook functions of the "Hooks" section, which do nothing unless it does (hook_build builds
# with cargo). examples/release.conf describes every key.
#
# Layouts: a project commits this script (SELF_REPO_PATH names the file, such as
# etc/release.sh, and KEYS_PATH a directory of the project) or carries this repository as a
# submodule (SELF_REPO_PATH names the submodule directory, such as release, and KEYS_PATH a
# directory inside it, such as release/keys). In the submodule layout MAIN_REF records only
# the submodule's commit, so the keys and main's copy of this script are read at that commit
# from the submodule's object store (fetched from its origin when missing), never from the
# checked-out files, and build and publish require the submodule checked out at that commit.
# There, every step that reads the keys from main refuses a KEYS_PATH outside the submodule
# (exit 2) and a MIN_SIGNATURES below the "Signatures required: N" line of the submodule's
# KEYS.md at that commit (exit 1): KEYS.md states the threshold for every consumer.
#
# Environment (all optional):
#   RELEASE_REPO                   owner/repo; default DEFAULT_REPO, GITHUB_REPOSITORY in CI
#   RELEASE_COMMIT                 tag: commit to tag instead of the MAIN_REF tip
#   RELEASE_GPG_KEY                tag, sign: signing key; default `git config user.signingkey`
#   RELEASE_SIG_THRESHOLD          maintainer signatures required; never below MIN_SIGNATURES
#   RELEASE_ALLOW_LOCAL_SCRIPTS=1  build, publish: allow this script, release.conf or an
#                                  EXTRA_SCRIPTS file to differ from main
#   RELEASE_SUMS_SHA256            sign: the SHA256SUMS sha256 that build printed last; asked for
#                                  at a prompt when unset
#   RELEASE_YES=1                  answer yes to every confirmation prompt; it never stands in
#                                  for RELEASE_SUMS_SHA256
#   GH_TOKEN                       read by gh (CI); locally `gh auth login` is used
#
# Dry run, for rehearsals (RELEASE_DRY_RUN=1). The variables below are refused without it.
# A dry run never calls gh or git push and pushes images only to RELEASE_IMAGE.
#   RELEASE_IMAGE                  image repository on localhost:PORT/ or 127.0.0.1:PORT/
#   RELEASE_ALLOWLIST_DIR          directory of *.asc used instead of main's allowlist
#   RELEASE_MAIN_REF               ref used instead of MAIN_REF; no fetch
#   RELEASE_ATTESTATION=skip       for hooks: skip the on-chain attestation check
#   RELEASE_DIR                    directory that stands in for the GitHub draft release
#
# Portable to macOS's bash 3.2: no associative arrays, mapfile, ${x,,}, sed -i or GNU date.

set -euo pipefail
# Keeps -e inside $(...) on bash >= 4.4. bash 3.2 has no such option, so every function whose
# output is captured checks its own failures and calls die.
shopt -s inherit_errexit 2>/dev/null || true

# ---------------------------------------------------------------------------------------------
# Constants

GIT_CLIFF_IMAGE=ghcr.io/orhun/git-cliff/git-cliff:2.10.1@sha256:6ba0d1fcb051bd7b154cfb19c4b2b3bfa2c22c475f5285fc30606777b6573119

# The keys release.conf must set, and the name it has in every consumer's repository root.
CONF_KEYS='PROJECT DEFAULT_REPO TAG_RE TRIPLE TARBALL_FILES VERSION_FILE CHANGELOG_FILE ANCHOR MAIN_REF ARTIFACT_ROOT MIN_SIGNATURES KEYS_PATH SELF_REPO_PATH'
CONF_REPO_PATH=release.conf

RC_RE='-rc([1-9][0-9]*)$'
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
PATH_RE='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
LIST_RE='^[A-Za-z0-9._ -]*$'
PATH_LIST_RE='^[A-Za-z0-9._/ -]*$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'
HANDLE_FILE_RE='^[A-Za-z0-9-]+\.asc$'
HEX64_RE='^[0-9a-f]{64}$'
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
LOCAL_HOST_RE='^(localhost|127\.0\.0\.1):[0-9]+$'
LOCAL_PATH_RE='^[a-z0-9._/-]+$'
BOT_LOGIN='github-actions[bot]'
MANIFEST_TYPES='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# release.conf. load_conf sets the required keys from it and these optional ones, which are
# empty unless it sets them: EXTRA_ASSETS, the release assets the build writes beside the
# tarball (SHA256SUMS lists them, and every step uploads, downloads and checks them; a hook
# may also set it in hook_parse_extras), EXTRA_SCRIPTS, more repository paths that build and
# publish require to equal main's copy, and BUILD_IMAGE, the pinned image the default
# hook_build runs cargo in.
PROJECT='' DEFAULT_REPO='' TAG_RE='' TRIPLE='' TARBALL_FILES='' VERSION_FILE='' CHANGELOG_FILE=''
ANCHOR='' MAIN_REF='' ARTIFACT_ROOT='' MIN_SIGNATURES='' KEYS_PATH='' SELF_REPO_PATH=''
EXTRA_ASSETS='' EXTRA_SCRIPTS='' BUILD_IMAGE=''
ALLOWLIST_PATH=  # load_conf: KEYS_PATH, the allowlist directory load_allowlist reads on main
CONF=            # load_conf: absolute path of the release.conf it sourced
MAIN_FETCH=      # load_conf: the refspec that fetches MAIN_REF's branch from origin

# State. parse_tag sets TAG VERSION CHANNEL CHANNEL_SUFFIX RC BASE FEATURES PRERELEASE ALIAS
# TARBALL, then hook_parse_extras may change CHANNEL FEATURES PRERELEASE ALIAS EXTRA_ASSETS;
# the functions named in the comments own the rest.
TAG='' VERSION='' CHANNEL='' CHANNEL_SUFFIX='' RC='' BASE='' FEATURES='' PRERELEASE='' ALIAS='' TARBALL=''
TF_VERSION='' TF_RC='' TF_BASE='' TF_SUFFIX=''  # tag_fields
WORK=            # setup: private temp dir, removed on exit
ORIG_PWD=        # setup: directory the script was started from
SELF=            # load_conf: absolute path of this script
DRY_RUN=0        # init_env
REPO=            # init_env: owner/repo on GitHub
IMAGE=           # init_env: image repository, without tag, for hooks that publish an image
THRESHOLD=       # load_conf, init_env
ALLOW_GNUPGHOME= # load_allowlist: keyring holding only main's allowlisted keys
ALLOW_LIST=      # load_allowlist: "handle<TAB>primary fingerprint" lines
COMMIT=          # check_tag: the commit TAG points at
SIGNER=          # check_tag_signature: handle that signed TAG
SIGNER_FPR=      # check_tag_signature: primary fingerprint that signed TAG
SIGN_KEY=        # resolve_signing_key: key spec handed to gpg / git tag -u
SIGN_FPR=        # resolve_signing_key: its primary fingerprint
SIGN_HANDLE=     # resolve_signing_key: its allowlist handle
REL_EXISTS=0     # release_state: GitHub release (or dry-run RELEASE_DIR) facts
REL_DRAFT=
REL_PRERELEASE=
REL_AUTHOR=
REL_ASSETS=
REL_ASSET_IDS=   # release_state: "name<TAB>asset id<TAB>digest" per asset, sorted
FETCHED=0        # fetch_tag ran
BUILD_WT=        # build: detached worktree of the tag, removed on exit
CONTAINERS=      # containers from docker create (hooks append), removed on exit
CREATED_TAG=     # tag: local tag deleted again on failure (until it is pushed)
PREP_RESTORE=0   # prep: 1 from the version bump until every check passed; cleanup then
                 # restores VERSION_FILE, Cargo.lock and CHANGELOG_FILE from HEAD
BODY_HEX=        # check_release_body: sha256 of the release body that publish checked

# ---------------------------------------------------------------------------------------------
# Helpers

die() {
    local code=$1
    shift
    printf 'error: %s\n' "$*" >&2
    if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error::%s\n' "$*" >&2; fi
    exit "$code"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
    if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::warning::%s\n' "$*" >&2; fi
}

# Progress goes to stderr so stdout carries only results (parse, notes, digests, summaries).
info() { printf '%s\n' "$*" >&2; }

need() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die 2 "missing required tool: $tool"
    done
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

sha256_check() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum --check --strict "$@"
    else
        shasum -a 256 --check --strict "$@"
    fi
}

sha256_hex() {
    local out
    out=$(sha256 "$1") || die 2 "cannot hash $1"
    printf '%s\n' "${out%% *}"
}

# Prompts that change shared state (tag, sign, publish) need an explicit "yes".
confirm() {
    local answer=
    if [ "${RELEASE_YES:-}" = 1 ]; then
        info "RELEASE_YES=1: continuing without a prompt"
        return 0
    fi
    [ -t 0 ] || die 2 "confirmation needed but stdin is not a TTY (set RELEASE_YES=1 to skip it)"
    printf '%s Type yes to continue: ' "$1" >&2
    read -r answer || true
    [ "$answer" = yes ] || die 1 "aborted"
}

lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }

count_lines() { awk 'NF { n++ } END { print n + 0 }'; }

# Highest X.Y.Z on stdin. Numeric per field, so it orders like `sort -V` without needing it.
version_max() { awk NF | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1; }

release_dir() { printf '%s/%s\n' "$ARTIFACT_ROOT" "$1"; }

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ORIG_PWD" "$1" ;;
    esac
}

# Physical path (symlinks, "." and ".." resolved) of the absolute directory path $1, which may
# not exist yet: its deepest existing ancestor is resolved and the rest appended, and that
# rest may not contain "." or "..".
physical_dir() {
    local head=$1 rest='' leaf
    while [ "$head" != / ] && [ "${head%/}" != "$head" ]; do head=${head%/}; done
    while [ ! -d "$head" ]; do
        leaf=${head##*/}
        case "$leaf" in '' | . | ..) die 2 "cannot resolve the directory $1" ;; esac
        rest="/$leaf$rest"
        head=${head%/*}
        if [ -z "$head" ]; then head=/; fi
    done
    head=$(cd "$head" && pwd -P) || die 2 "cannot resolve the directory $1"
    printf '%s%s\n' "${head%/}" "$rest"
}

# A dry-run image repository: localhost:PORT or 127.0.0.1:PORT, then a lowercase repository
# path with no tag, digest or "..". Anything looser (such as "localhost:5000@host/x") could
# send registry_digest's requests to another host.
is_local_image() {
    local host=${IMAGE%%/*} path=${IMAGE#*/}
    [[ "$host" =~ $LOCAL_HOST_RE ]] || return 1
    [ "$path" != "$IMAGE" ] || return 1
    [[ "$path" =~ $LOCAL_PATH_RE ]] || return 1
    case "$path" in *..*) return 1 ;; esac
    return 0
}

require_local_image_in_dry_run() {
    if [ "$DRY_RUN" = 1 ] && ! is_local_image; then
        die 2 "dry run: set RELEASE_IMAGE to a localhost: or 127.0.0.1: repository"
    fi
}

# Before the first docker call of build, sign and verify, so a stopped daemon is a precondition
# (exit 2) and not read as a registry outage.
require_docker() {
    docker info >/dev/null 2>&1 || die 2 "docker does not answer: start Docker (Docker Desktop on a Mac) and run again"
}

require_main_ref() {
    git rev-parse --verify --quiet "$MAIN_REF^{commit}" >/dev/null ||
        die 2 "$MAIN_REF does not exist; fetch main first"
}

# For hooks that push an image or move an alias on ghcr.io, so docker needs its credential.
# A dry run uses a local registry without one.
require_registry_login() {
    local cfg
    if [ "$DRY_RUN" = 1 ]; then return 0; fi
    cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    grep -q '"ghcr.io"' "$cfg" 2>/dev/null || die 2 "docker is not logged in to ghcr.io: run docker login ghcr.io"
}

# ---------------------------------------------------------------------------------------------
# Project configuration

# Sources release.conf from the project's repository root, the parent of the directory that
# holds this script, and checks it. Runs before parse_tag, so parse still needs no git. The
# locals carry a prefix because release.conf runs inside this function.
load_conf() {
    local _conf_dir _conf_key _conf_name
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    _conf_dir=${SELF%/*}
    CONF="${_conf_dir%/*}/$CONF_REPO_PATH"
    [ -f "$CONF" ] ||
        die 2 "$CONF_REPO_PATH not found at $CONF; it belongs in the project's repository root, the parent of the directory holding this script (see examples/release.conf)"
    # shellcheck source=/dev/null
    . "$CONF" || die 2 "cannot read $CONF"
    for _conf_key in $CONF_KEYS; do
        [ -n "${!_conf_key:-}" ] || die 2 "$CONF does not set $_conf_key"
    done
    case "$MIN_SIGNATURES" in
        *[!0-9]*) die 2 "$CONF: MIN_SIGNATURES must be a whole number, got '$MIN_SIGNATURES'" ;;
    esac
    [ "$MIN_SIGNATURES" -ge 1 ] || die 2 "$CONF: MIN_SIGNATURES must be at least 1"
    [[ "$PROJECT" =~ $NAME_RE ]] || die 2 "$CONF: PROJECT must be a plain name, got '$PROJECT'"
    [[ "$TRIPLE" =~ $NAME_RE ]] || die 2 "$CONF: TRIPLE must be a plain name, got '$TRIPLE'"
    [[ "$DEFAULT_REPO" =~ $REPO_RE ]] || die 2 "$CONF: DEFAULT_REPO must look like owner/repo, got '$DEFAULT_REPO'"
    for _conf_key in KEYS_PATH SELF_REPO_PATH VERSION_FILE CHANGELOG_FILE ARTIFACT_ROOT MAIN_REF; do
        repo_path_ok "${!_conf_key}" || die 2 "$CONF: $_conf_key must be a relative path without '..', got '${!_conf_key}'"
    done
    # fetch_tag, prep and tag update MAIN_REF by fetching its branch, so it must be the ref a
    # fetch of origin's branch writes.
    case "$MAIN_REF" in
        refs/remotes/origin/?*) MAIN_FETCH="+refs/heads/${MAIN_REF#refs/remotes/origin/}:$MAIN_REF" ;;
        *) die 2 "$CONF: MAIN_REF must be refs/remotes/origin/<branch>, got '$MAIN_REF'" ;;
    esac
    # Checked as a whole first, so the unquoted loops below can neither glob nor split oddly.
    [[ "$TARBALL_FILES" =~ $LIST_RE ]] || die 2 "$CONF: TARBALL_FILES must be file names separated by spaces"
    for _conf_name in $TARBALL_FILES; do
        [[ "$_conf_name" =~ $NAME_RE ]] || die 2 "$CONF: TARBALL_FILES holds '$_conf_name', which is not a plain file name"
    done
    [[ "$EXTRA_SCRIPTS" =~ $PATH_LIST_RE ]] || die 2 "$CONF: EXTRA_SCRIPTS must be repository paths separated by spaces"
    for _conf_name in $EXTRA_SCRIPTS; do
        repo_path_ok "$_conf_name" || die 2 "$CONF: EXTRA_SCRIPTS holds '$_conf_name', which is not a relative path without '..'"
    done
    # build and publish compare CONF and SELF with MAIN_REF's release.conf and SELF_REPO_PATH,
    # which name them only when this script sits one directory below the root.
    _conf_dir=${CONF%/*}
    _conf_name=${SELF#"$_conf_dir"/}
    [ "$SELF_REPO_PATH" = "$_conf_name" ] || [ "$SELF_REPO_PATH/${SELF##*/}" = "$_conf_name" ] ||
        die 2 "$CONF: SELF_REPO_PATH must be $_conf_name (this script, committed) or ${_conf_name%/*} (the submodule holding it), since release.conf is read from the parent of the script's directory; got '$SELF_REPO_PATH'"
    ALLOWLIST_PATH=$KEYS_PATH
    THRESHOLD=$MIN_SIGNATURES
}

# A relative repository path of plain names: no leading "/", no "." or ".." component.
repo_path_ok() {
    [[ "$1" =~ $PATH_RE ]] || return 1
    case "/$1/" in */./* | */../* | *//*) return 1 ;; esac
    return 0
}

# EXTRA_ASSETS, once hook_parse_extras ran: plain names, none of them a name the core owns.
check_extra_assets() {
    local name
    [[ "$EXTRA_ASSETS" =~ $LIST_RE ]] || die 2 "EXTRA_ASSETS must be file names separated by spaces"
    for name in $EXTRA_ASSETS; do
        [[ "$name" =~ $NAME_RE ]] || die 2 "EXTRA_ASSETS holds '$name', which is not a plain file name"
        case "$name" in
            SHA256SUMS | SHA256SUMS.asc | "$TARBALL") die 2 "EXTRA_ASSETS may not name $name" ;;
        esac
    done
}

# ---------------------------------------------------------------------------------------------
# The submodule layout
#
# See "Layouts" at the top: MAIN_REF records the submodule at SELF_REPO_PATH as a gitlink
# (mode 160000), and load_allowlist and check_scripts_from_main read from the submodule's
# object store at that commit.

# The commit MAIN_REF records for SELF_REPO_PATH when that is a gitlink, else nothing (the
# script is committed to the project). Call after require_main_ref. Its output is captured,
# so callers pass a die on with `|| exit`.
main_gitlink() {
    local entry
    entry=$(git ls-tree "$MAIN_REF" "$SELF_REPO_PATH") || die 2 "cannot list $SELF_REPO_PATH on $MAIN_REF"
    printf '%s\n' "$entry" | awk '$1 == "160000" && $2 == "commit" { print $3 }'
}

# git -C on the empty directory of a submodule that is not checked out would read the
# project's repository instead, so the submodule must be the top of a work tree of its own.
require_submodule_checkout() {
    local prefix
    if prefix=$(git -C "$SELF_REPO_PATH" rev-parse --show-prefix 2>/dev/null) && [ -z "$prefix" ]; then
        return 0
    fi
    die 2 "submodule layout: $SELF_REPO_PATH is a submodule on $MAIN_REF but is not checked out here; run git submodule update --init $SELF_REPO_PATH"
}

# KEYS.md at commit $1 of the submodule states the signature threshold, on its one line
# "Signatures required: N", for every project that records that commit; release.conf may
# require more, never fewer. Call after submodule_fetch.
check_keys_threshold() {
    local gitlink=$1 sub=$SELF_REPO_PATH text required
    text=$(git -C "$sub" show "$gitlink:KEYS.md" 2>/dev/null) ||
        die 1 "submodule layout: $sub at $gitlink, the commit $MAIN_REF records, has no KEYS.md to read the signature threshold from"
    required=$(printf '%s\n' "$text" | awk '
        /^Signatures required: *[0-9]+\.?[ \t]*$/ { n++; v = $0; sub(/^Signatures required: */, "", v); sub(/\.?[ \t]*$/, "", v) }
        END { if (n == 1) print v + 0 }')
    [ -n "$required" ] ||
        die 1 "submodule layout: KEYS.md in $sub at $gitlink, the commit $MAIN_REF records, must state the threshold on one line 'Signatures required: N'"
    [ "$MIN_SIGNATURES" -ge "$required" ] ||
        die 1 "submodule layout: MIN_SIGNATURES=$MIN_SIGNATURES in $CONF is below the $required signatures KEYS.md requires in $sub at $gitlink, the commit $MAIN_REF records; raise it to at least $required"
}

# Makes commit $1 of the submodule present in its object store. A checkout made before main
# moved the pointer, or a shallow one (CI), lacks it: fetch it from the submodule's origin by
# id, or the origin's branches where a server refuses an id it does not advertise. Retried
# like git_fetch.
submodule_fetch() {
    local sha=$1 sub=$SELF_REPO_PATH attempt=1
    if git -C "$sub" cat-file -e "$sha^{commit}" 2>/dev/null; then return 0; fi
    git -C "$sub" remote get-url origin >/dev/null 2>&1 ||
        die 2 "submodule layout: $sub lacks $sha, the commit $MAIN_REF records, and has no remote named origin to fetch it from"
    info "submodule layout: fetching $sha, the commit $MAIN_REF records, into $sub from its origin"
    until git -C "$sub" fetch --quiet --no-tags origin "$sha" 2>/dev/null ||
        git -C "$sub" fetch --quiet --no-tags origin; do
        [ "$attempt" -lt 3 ] || die 3 "git fetch in $sub from its origin failed after 3 attempts"
        attempt=$((attempt + 1))
        sleep 5
    done
    git -C "$sub" cat-file -e "$sha^{commit}" 2>/dev/null ||
        die 1 "submodule layout: $MAIN_REF records $sha for $sub, but neither its checkout nor its origin has that commit"
}

# ---------------------------------------------------------------------------------------------
# Hooks
#
# release.conf may define any of these; the defaults below do nothing, except hook_build.
# Hooks run with the state of the step that calls them (TAG, COMMIT, REPO, IMAGE, WORK, ...)
# and report a failure with die, as the core does. A hook whose output is captured, such as
# hook_extra_sums, checks its own failures, as bash 3.2 runs $(...) without -e.

# parse_tag, after the generic fields: may set CHANNEL, FEATURES, PRERELEASE, ALIAS,
# EXTRA_ASSETS and the project's own variables. Runs without git.
hook_parse_extras() { :; }

# check-tag ($2 = always) and tag ($2 = if-available: on the laptop, a check that needs a
# tool CI has may be left to CI), after the version and CHANGELOG rules, for commit $1.
hook_check_tag_extra() { :; }

# Writes the repository files that SHA256SUMS also covers, as committed at COMMIT, under
# directory $1 at their repository paths, and prints those paths, one per line.
hook_extra_sums() { :; }

# build: builds from BUILD_WT, a pristine worktree of the tag at COMMIT, and writes TARBALL
# and every EXTRA_ASSETS file into directory $1. The default runs `cargo build --locked
# --release` for TRIPLE (with FEATURES, if any) in BUILD_IMAGE and packs the first
# TARBALL_FILES name from the cargo output, and the others from the tag's tree, with
# pack_tarball.
hook_build() { default_build "$1"; }

# sign and verify, after the generic checks of the downloaded release files in directory $1
# (asset digests, SHA256SUMS, the tarball's file list); the tarball is extracted under $1/x.
hook_check_release_files() { :; }

# render_notes: $1 = rows prints extra "| Item | Value |" rows for the Artifacts table,
# $1 = sections extra Markdown between that table and the Verify section, $1 = verify extra
# Markdown after the Verify section's list of failed checks (such as more of its items).
hook_notes_sections() { :; }

# publish, only for a final release that is the newest of its channel: $1 = plan runs
# before the confirmation prompt (print what will move, check preconditions; nothing is
# public yet), $1 = move runs after the release was published.
hook_publish_alias() { :; }

# prep: writes the new "## [BASE] - YYYY-MM-DD" section of CHANGELOG_FILE to file $1, from
# a clean checkout of main's tip (cliff_section does so with git-cliff). The default writes
# nothing, and prep stops.
hook_changelog() { :; }

# ---------------------------------------------------------------------------------------------
# Tag grammar

# tag_fields TAG: returns 1 unless TAG matches TAG_RE, else sets TF_VERSION (X.Y.Z, from the
# first three groups of TAG_RE), TF_RC (N of a trailing -rcN, or empty), TF_BASE (TAG without
# that suffix) and TF_SUFFIX (the channel: whatever lies between vX.Y.Z and -rcN, empty for
# the plain channel). Exit 2 when TAG_RE matches but does not have that shape.
tag_fields() {
    local tag=$1 rest
    [[ "$tag" =~ $TAG_RE ]] || return 1
    TF_VERSION="${BASH_REMATCH[1]:-}.${BASH_REMATCH[2]:-}.${BASH_REMATCH[3]:-}"
    [[ "$TF_VERSION" =~ $VERSION_RE ]] ||
        die 2 "TAG_RE in $CONF must capture X, Y and Z as its first three groups ('$tag' gives '$TF_VERSION')"
    TF_RC=
    if [[ "$tag" =~ $RC_RE ]]; then TF_RC=${BASH_REMATCH[1]}; fi
    TF_BASE=$tag
    if [ -n "$TF_RC" ]; then TF_BASE=${tag%-rc"$TF_RC"}; fi
    rest=${TF_BASE#v"$TF_VERSION"}
    if [ "$rest" = "$TF_BASE" ]; then die 2 "TAG_RE in $CONF accepted '$tag', which does not start with v$TF_VERSION"; fi
    case "$rest" in
        '' | -*) ;;
        *) die 2 "TAG_RE in $CONF accepted '$tag', whose channel suffix '$rest' does not start with -" ;;
    esac
    TF_SUFFIX=$rest
}

# Splits TAG into the variables `parse` prints. Exit 2 for anything but a release tag.
parse_tag() {
    TAG=$1
    tag_fields "$TAG" || die 2 "not a release tag: '$TAG' (release tags match TAG_RE in $CONF: $TAG_RE)"
    VERSION=$TF_VERSION
    RC=$TF_RC
    BASE=$TF_BASE
    CHANNEL_SUFFIX=$TF_SUFFIX
    CHANNEL=stable
    if [ -n "$CHANNEL_SUFFIX" ]; then CHANNEL=${CHANNEL_SUFFIX#-}; fi
    FEATURES=
    ALIAS=
    # Only a final of the plain channel is a full release.
    PRERELEASE=true
    if [ -z "$RC" ] && [ -z "$CHANNEL_SUFFIX" ]; then PRERELEASE=false; fi
    TARBALL="$PROJECT-$TAG-$TRIPLE.tar.gz"
    hook_parse_extras
    check_extra_assets
}

print_parse() {
    printf 'TAG=%s\nVERSION=%s\nCHANNEL=%s\nRC=%s\nBASE=%s\nFEATURES=%s\nPRERELEASE=%s\nALIAS=%s\nTARBALL=%s\nEXTRA_ASSETS=%s\n' \
        "$TAG" "$VERSION" "$CHANNEL" "$RC" "$BASE" "$FEATURES" "$PRERELEASE" "$ALIAS" "$TARBALL" "$EXTRA_ASSETS"
}

# X.Y.Z of the final (non-rc) tags among $1 (one per line) in TAG's channel, TAG excluded.
channel_finals() {
    local t
    while IFS= read -r t; do
        if [ "$t" != "$TAG" ] && tag_fields "$t" && [ -z "$TF_RC" ] && [ "$TF_SUFFIX" = "$CHANNEL_SUFFIX" ]; then
            printf '%s\n' "$TF_VERSION"
        fi
    done <<EOF
$1
EOF
}

# ---------------------------------------------------------------------------------------------
# Allowlist and signatures

allowlist_name() {
    [[ "$1" =~ $HANDLE_FILE_RE ]] ||
        die 1 "$2/$1: allowlist files must be named <GitHub login>.asc"
}

# Fingerprint of every primary key in a gpg --with-colons listing on stdin.
primary_fprs() {
    awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10 } { want = 0 }'
}

# Imports the maintainer keys from main (never from the tagged tree) into a private keyring.
# In the submodule layout (MAIN_REF records SELF_REPO_PATH as a gitlink, and KEYS_PATH must lie
# inside it) main holds no key files, so they are read from the submodule's object store at the
# commit MAIN_REF records, never from its checkout: neither a tag nor a checkout can add a key.
# The threshold KEYS.md states at that commit is checked there too (check_keys_threshold).
# Sets ALLOW_GNUPGHOME and ALLOW_LIST ("handle<TAB>primary fingerprint", one line per primary
# key; a file may hold several during a rotation). Thresholds count distinct handles.
load_allowlist() {
    local src where names name file fprs fpr handles repo=. rev gitlink='' missing
    if [ -n "$ALLOW_GNUPGHOME" ]; then return 0; fi
    need gpg
    src=$WORK/allowlist
    mkdir "$src"
    if [ -n "${RELEASE_ALLOWLIST_DIR:-}" ]; then
        where=$RELEASE_ALLOWLIST_DIR
        [ -d "$where" ] || die 2 "RELEASE_ALLOWLIST_DIR=$where is not a directory"
        for file in "$where"/*.asc; do
            if [ -e "$file" ]; then
                allowlist_name "${file##*/}" "$where"
                cp "$file" "$src/${file##*/}"
            fi
        done
    else
        require_main_ref
        rev="$MAIN_REF:$ALLOWLIST_PATH"
        where=$rev
        missing="$ALLOWLIST_PATH does not exist on $MAIN_REF"
        gitlink=$(main_gitlink) || exit
        if [ -n "$gitlink" ]; then
            # Keys outside the submodule would come from the project's own tree on main, and
            # the allowlist of the commit main records would go unread.
            case "$ALLOWLIST_PATH" in
                "$SELF_REPO_PATH"/*) ;;
                *) die 2 "submodule layout: KEYS_PATH must lie inside SELF_REPO_PATH: $MAIN_REF records $SELF_REPO_PATH as a submodule, but KEYS_PATH is $ALLOWLIST_PATH" ;;
            esac
            require_submodule_checkout
            submodule_fetch "$gitlink"
            check_keys_threshold "$gitlink"
            repo=$SELF_REPO_PATH
            rev="$gitlink:${ALLOWLIST_PATH#"$SELF_REPO_PATH"/}"
            where="$SELF_REPO_PATH submodule $rev"
            missing="$ALLOWLIST_PATH does not exist on $MAIN_REF (submodule layout: $SELF_REPO_PATH at $gitlink has no ${ALLOWLIST_PATH#"$SELF_REPO_PATH"/})"
            info "submodule layout: maintainer keys from $SELF_REPO_PATH at $gitlink, the commit $MAIN_REF records"
        fi
        names=$(git -C "$repo" ls-tree --name-only "$rev" 2>/dev/null) || die 1 "$missing"
        while IFS= read -r name; do
            case "$name" in *.asc*) ;; *) continue ;; esac
            allowlist_name "$name" "$where"
            git -C "$repo" show "$rev/$name" >"$src/$name" || die 1 "cannot read $where/$name"
        done <<EOF
$names
EOF
    fi

    # Short path: gpg keeps its sockets in the homedir and socket paths are limited to ~100 bytes.
    ALLOW_GNUPGHOME=$WORK/g
    mkdir -m 700 "$ALLOW_GNUPGHOME"
    printf 'no-autostart\n' >"$ALLOW_GNUPGHOME/gpg.conf"
    : >"$WORK/allowlist.tsv"
    for file in "$src"/*.asc; do
        [ -e "$file" ] || continue
        name=${file##*/}
        if ! grep -q -e '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$file"; then
            die 1 "$where/$name is not a provisioned OpenPGP public key (placeholder?)"
        fi
        fprs=$(gpg --homedir "$ALLOW_GNUPGHOME" --batch --with-colons \
            --import-options show-only --import "$file" 2>/dev/null | primary_fprs) ||
            die 1 "cannot read the keys in $where/$name"
        [ -n "$fprs" ] || die 1 "$where/$name holds no OpenPGP primary key"
        while IFS= read -r fpr; do
            if awk -F'\t' -v f="$fpr" '$2 == f { hit = 1 } END { exit !hit }' "$WORK/allowlist.tsv"; then
                die 1 "primary key $fpr appears in two allowlist files (second: $where/$name)"
            fi
            printf '%s\t%s\n' "${name%.asc}" "$fpr" >>"$WORK/allowlist.tsv"
        done <<EOF
$fprs
EOF
        gpg --homedir "$ALLOW_GNUPGHOME" --batch --quiet --import "$file" >/dev/null 2>&1 ||
            die 1 "cannot import $where/$name"
    done
    ALLOW_LIST=$(cat "$WORK/allowlist.tsv")
    [ -n "$ALLOW_LIST" ] || die 1 "no maintainer keys in $where"
    handles=$(cut -f1 "$WORK/allowlist.tsv" | LC_ALL=C sort -u | count_lines)
    [ "$THRESHOLD" -le "$handles" ] ||
        die 1 "signature threshold $THRESHOLD exceeds the $handles allowlisted maintainer(s)"
}

handle_of() {
    printf '%s\n' "$ALLOW_LIST" | awk -F'\t' -v f="$1" '$2 == f { print $1 }'
}

# Reads gpg status output (--status-fd) on stdin and judges each signature block, split on
# NEWSIG. A block is good only with GOODSIG and VALIDSIG, and its signer is the VALIDSIG
# primary fingerprint (last field) mapped through the allowlist. Prints per block
# "good<TAB>handle<TAB>fpr", "bad<TAB>keyid" or "skip<TAB>reason", the reason starting with
# the gpg status, then "blocks<TAB>N".
sig_blocks() {
    awk -v allow="$WORK/allowlist.tsv" '
        BEGIN {
            while ((getline line < allow) > 0) { split(line, f, "\t"); handle[f[2]] = f[1] }
        }
        function open_block() {
            if (!inblock) { inblock = 1; n++; good = 0; valid = ""; note = ""; bad = 0; nokey = 0 }
        }
        function close_block() {
            if (!inblock) return
            if (good && valid != "") {
                if (valid in handle) print "good\t" handle[valid] "\t" valid
                else print "skip\tGOODSIG by key " valid ", which is not on the allowlist"
            } else if (note != "") print "skip\t" note (nokey ? " (NO_PUBKEY: the key is not on the allowlist)" : "")
            else if (!bad) print "skip\tsignature without GOODSIG and VALIDSIG"
            inblock = 0
        }
        $1 != "[GNUPG:]" { next }
        $2 == "NEWSIG" { close_block(); open_block(); next }
        $2 == "GOODSIG" { open_block(); good = 1; next }
        $2 == "VALIDSIG" { open_block(); valid = $NF; next }
        $2 == "BADSIG" { open_block(); bad = 1; print "bad\t" $3; next }
        $2 == "ERRSIG" { open_block(); note = "ERRSIG: cannot check the signature by key " $3; next }
        $2 == "NO_PUBKEY" { open_block(); nokey = 1; next }
        $2 == "EXPKEYSIG" { open_block(); note = "EXPKEYSIG: signature by expired key " $3; next }
        $2 == "REVKEYSIG" { open_block(); note = "REVKEYSIG: signature by revoked key " $3; next }
        $2 == "EXPSIG" { open_block(); note = "EXPSIG: expired signature by key " $3; next }
        END { close_block(); print "blocks\t" n + 0 }
    '
}

# count_sigs FILE SIG: prints the distinct allowlisted handles with a good signature over FILE
# in SIG (concatenated armored detached signatures), one per line; the count is the line
# count. Every signature in SIG must be a GOODSIG with a VALIDSIG by an allowlisted primary
# key, the rule of the operator check on the install page: one that is bad, unverifiable,
# expired, revoked or by a key off the allowlist refuses the whole file (exit 1), even next to
# good ones. Its output is captured, so callers pass a die on with `|| exit`.
count_sigs() {
    local file=$1 sig=$2 status results refused
    if [ ! -f "$file" ] || [ ! -f "$sig" ]; then die 2 "count_sigs: $file or $sig does not exist"; fi
    status=$(gpg --homedir "$ALLOW_GNUPGHOME" --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null || true)
    results=$(printf '%s\n' "$status" | sig_blocks) || die 1 "cannot judge the signatures in ${sig##*/}"
    refused=$(printf '%s\n' "$results" | awk -F'\t' -v f="${file##*/}" '
        $1 == "bad" { msg = msg sep "BADSIG: signature by key " $2 " does not match " f; sep = "; " }
        $1 == "skip" { msg = msg sep $2; sep = "; " }
        END { print msg }')
    [ -z "$refused" ] ||
        die 1 "${sig##*/} holds a signature that is not a good one by an allowlisted maintainer key, so the file is refused: $refused"
    printf '%s\n' "$results" | awk -F'\t' '$1 == "good" { print $2 }' | LC_ALL=C sort -u
}

# check-tag step (3): exactly one signature on the tag, good, by an allowlisted primary key.
# Sets SIGNER and SIGNER_FPR.
check_tag_signature() {
    local status results blocks good
    load_allowlist
    status=$(GNUPGHOME=$ALLOW_GNUPGHOME git -c gpg.format=openpgp -c gpg.program=gpg \
        -c gpg.openpgp.program=gpg verify-tag --raw "refs/tags/$TAG" 2>&1 >/dev/null || true)
    results=$(printf '%s\n' "$status" | sig_blocks)
    blocks=$(printf '%s\n' "$results" | awk -F'\t' '$1 == "blocks" { print $2 }')
    [ "$blocks" -ge 1 ] || die 1 "tag $TAG is not signed"
    if printf '%s\n' "$results" | awk -F'\t' '$1 == "bad" { hit = 1 } END { exit !hit }'; then
        die 1 "tag $TAG has a bad signature"
    fi
    [ "$blocks" = 1 ] || die 1 "tag $TAG carries $blocks signatures; exactly one is allowed"
    good=$(printf '%s\n' "$results" | awk -F'\t' '$1 == "good" { print $2 " " $3 }')
    if [ -z "$good" ]; then
        die 1 "tag $TAG is not signed by an allowlisted maintainer key ($(printf '%s\n' "$results" | awk -F'\t' '$1 == "skip" { print $2 }'))"
    fi
    SIGNER=${good%% *}
    SIGNER_FPR=${good#* }
}

# The key `tag` and `sign` use: RELEASE_GPG_KEY, else git's user.signingkey. A subkey resolves
# to its primary, which must be allowlisted. Sets SIGN_KEY, SIGN_FPR and SIGN_HANDLE.
resolve_signing_key() {
    local listing count
    SIGN_KEY=${RELEASE_GPG_KEY:-}
    if [ -z "$SIGN_KEY" ]; then SIGN_KEY=$(git config --get user.signingkey || true); fi
    [ -n "$SIGN_KEY" ] || die 2 "no signing key: set RELEASE_GPG_KEY or git config user.signingkey"
    listing=$(gpg --batch --with-colons --list-keys -- "${SIGN_KEY%!}" 2>/dev/null) ||
        die 2 "signing key ${SIGN_KEY%!} is not in your GnuPG keyring"
    SIGN_FPR=$(printf '%s\n' "$listing" | primary_fprs)
    count=$(printf '%s\n' "$SIGN_FPR" | count_lines)
    [ "$count" = 1 ] || die 2 "signing key ${SIGN_KEY%!} matches $count primary keys; give its fingerprint"
    SIGN_HANDLE=$(handle_of "$SIGN_FPR")
    [ -n "$SIGN_HANDLE" ] || die 1 "signing key $SIGN_FPR is not in the maintainer allowlist on $MAIN_REF"
}

# ---------------------------------------------------------------------------------------------
# Registry

# HEAD request for a manifest. Writes the response headers to $2 and prints the HTTP status.
manifest_head() {
    local url=$1 out=$2 token=$3
    set -- -sS -I --connect-timeout 10 --max-time 60 -o "$out" -w '%{http_code}' \
        -H "Accept: $MANIFEST_TYPES"
    if [ -n "$token" ]; then set -- "$@" -H "Authorization: Bearer $token"; fi
    curl "$@" "$url"
}

# registry_digest REF: prints the digest the registry serves for IMAGE:REF, or nothing when
# that tag does not exist. ghcr.io needs an anonymous pull token, which only works for a public
# package; the dry-run localhost registry is plain http without a token.
registry_digest() {
    local ref=$1 host path url token code digest attempt=1 out
    need curl
    host=${IMAGE%%/*}
    path=${IMAGE#*/}
    out=$WORK/registry.out
    case "$host" in
        localhost:* | 127.0.0.1:*) url="http://$host/v2/$path/manifests/$ref" ;;
        ghcr.io) url="https://ghcr.io/v2/$path/manifests/$ref" ;;
        *) die 2 "registry_digest: unsupported registry $host" ;;
    esac
    while :; do
        token=
        code=200
        if [ "$host" = ghcr.io ]; then
            code=$(curl -sS --connect-timeout 10 --max-time 60 -o "$out" -w '%{http_code}' \
                "https://ghcr.io/token?scope=repository:$path:pull") || code=000
            if [ "$code" = 200 ]; then token=$(sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p' "$out"); fi
        fi
        if [ "$code" = 200 ]; then code=$(manifest_head "$url" "$out" "$token") || code=000; fi
        case "$code" in
            200)
                digest=$(awk 'tolower($1) == "docker-content-digest:" { print $2 }' "$out" | tr -d '\r')
                if [[ "$digest" =~ $DIGEST_RE ]]; then
                    printf '%s\n' "$digest"
                    return 0
                fi
                code="200 without a valid docker-content-digest"
                ;;
            404) return 0 ;;
            401 | 403)
                die 2 "$IMAGE: the registry answered HTTP $code: package is not public (one-time setup: make the ghcr package public)"
                ;;
        esac
        [ "$attempt" -lt 3 ] || die 3 "$IMAGE:$ref: registry unavailable after 3 attempts (last answer: $code)"
        attempt=$((attempt + 1))
        sleep 5
    done
}

# ---------------------------------------------------------------------------------------------
# Tag, version and CHANGELOG checks

# A missing origin is a precondition, not an outage, so it is not retried.
require_origin() {
    git remote get-url origin >/dev/null 2>&1 || die 2 "this checkout has no git remote named origin"
}

# Retried because a fetch is the first network call on every host. git fetch exits 1 when it
# refuses a ref update (here only the unforced tags: a local one differs from origin's), 128 on
# other errors.
git_fetch() {
    local attempt=1 rc
    require_origin
    while :; do
        git fetch --quiet --no-tags origin "$@" && rc=0 || rc=$?
        case "$rc" in
            0) return 0 ;;
            1) die 1 "git fetch refused to update a local ref from origin ($*); a local tag differs from the one on origin: find out why before you delete it" ;;
        esac
        [ "$attempt" -lt 3 ] || die 3 "git fetch from origin failed after 3 attempts"
        attempt=$((attempt + 1))
        sleep 5
    done
}

# Object id of refs/tags/$1 on origin, or nothing.
ls_remote_tag() {
    local out attempt=1
    require_origin
    until out=$(git ls-remote origin "refs/tags/$1"); do
        [ "$attempt" -lt 3 ] || die 3 "git ls-remote origin failed after 3 attempts"
        attempt=$((attempt + 1))
        sleep 5
    done
    printf '%s\n' "$out" | awk -v r="refs/tags/$1" '$2 == r { print $1 }'
}

# check-tag step (1), outside CI and dry run: fetch main (MAIN_FETCH), this tag and every
# other v* tag, unforced, so a local tag that differs from origin is an error rather than
# silently replaced, and the version rules see the tags origin has.
fetch_tag() {
    local remote local_obj
    if [ "$FETCHED" = 1 ] || [ "$DRY_RUN" = 1 ] || [ "${GITHUB_ACTIONS:-}" = true ]; then return 0; fi
    remote=$(ls_remote_tag "$TAG")
    [ -n "$remote" ] || die 2 "tag $TAG does not exist on origin"
    if local_obj=$(git rev-parse --verify --quiet "refs/tags/$TAG"); then
        [ "$local_obj" = "$remote" ] || die 1 "local tag $TAG ($local_obj) differs from origin ($remote)"
    fi
    git_fetch "$MAIN_FETCH" "refs/tags/$TAG:refs/tags/$TAG" 'refs/tags/v*:refs/tags/v*'
    FETCHED=1
}

# check-tag step (2): TAG is an annotated tag object that names itself and points at a commit.
# Prints that commit.
tag_commit() {
    local tag=$1 type obj header_tag header_type
    git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || die 2 "tag $tag does not exist locally"
    type=$(git cat-file -t "refs/tags/$tag") || die 1 "cannot read refs/tags/$tag"
    [ "$type" = tag ] || die 1 "$tag is a lightweight tag (it names a $type); release tags are signed annotated tags"
    obj=$(git cat-file tag "refs/tags/$tag") || die 1 "cannot read the tag object of $tag"
    header_tag=$(printf '%s\n' "$obj" | awk 'NF == 0 { body = 1 } !body && $1 == "tag" { print $2 }')
    header_type=$(printf '%s\n' "$obj" | awk 'NF == 0 { body = 1 } !body && $1 == "type" { print $2 }')
    [ "$header_tag" = "$tag" ] || die 1 "refs/tags/$tag holds a tag object named '$header_tag'"
    [ "$header_type" = commit ] || die 1 "tag $tag points at a $header_type, not a commit"
    git rev-parse --verify --quiet "refs/tags/$tag^{commit}" || die 1 "cannot resolve $tag to a commit"
}

# check-tag step (4).
check_on_main() {
    local rc
    require_main_ref
    git merge-base --is-ancestor "$1" "$MAIN_REF" && rc=0 || rc=$?
    case "$rc" in
        0) ;;
        1) die 1 "$1 is not on main ($MAIN_REF)" ;;
        *) die 2 "git merge-base failed for $1" ;;
    esac
}

# The version a Cargo.toml on stdin declares: the first `version = "..."` inside
# [workspace.package] when it has one (a workspace), else the first inside [package].
cargo_version() {
    awk '
        /^\[/ { sec = ""; if ($0 ~ /^\[workspace\.package\][ \t]*$/) sec = "ws"; else if ($0 ~ /^\[package\][ \t]*$/) sec = "pkg" }
        sec != "" && !(sec in found) && /^[ \t]*version[ \t]*=/ {
            v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); found[sec] = v
        }
        END { if ("ws" in found) print found["ws"]; else if ("pkg" in found) print found["pkg"] }
    '
}

# Tagger time (epoch seconds) of the annotated tag $1, from its tag object; empty for a
# lightweight tag.
tagger_time() {
    local raw
    raw=$(git for-each-ref --format='%(taggerdate:raw)' "refs/tags/$1") || die 1 "cannot read refs/tags/$1"
    printf '%s\n' "${raw%% *}"
}

# Names of the annotated v* tags on origin, the ones ls-remote lists with a peeled ^{} line;
# a lightweight tag counts for no version rule, as on the cutoff path. Read with ls-remote
# because the local tags can be stale. Retried like ls_remote_tag.
remote_tags() {
    local out attempt=1
    require_origin
    until out=$(git ls-remote --tags origin 'refs/tags/v*'); do
        [ "$attempt" -lt 3 ] || die 3 "git ls-remote --tags origin failed after 3 attempts"
        attempt=$((attempt + 1))
        sleep 5
    done
    printf '%s\n' "$out" | awk '$2 ~ /\^\{\}$/ { n = $2; sub(/^refs\/tags\//, "", n); sub(/\^\{\}$/, "", n); if (n != "") print n }'
}

# Names of the annotated v* tags that count for the version rules. Without a cutoff (TAG does
# not exist yet, or CI checks the push of TAG), every one on origin, read with ls-remote, or
# every local one in a dry run and in CI, whose checkout holds origin's tags. With a cutoff
# (epoch seconds), every local one whose tagger date is strictly earlier, whatever commit it
# names.
# Its output is captured, and bash 3.2 runs $(...) without -e, so a failure dies explicitly
# and the caller passes the status on with `|| exit`.
tags_before() {
    local out
    if [ -n "$1" ]; then
        out=$(git for-each-ref --format='%(refname:strip=2) %(taggerdate:raw)' 'refs/tags/v*') ||
            die 2 "cannot list the v* tags"
        printf '%s\n' "$out" | awk -v c="$1" '$2 != "" && $2 + 0 < c + 0 { print $1 }'
    elif [ "$DRY_RUN" = 1 ] || [ "${GITHUB_ACTIONS:-}" = true ]; then
        out=$(git for-each-ref --format='%(objecttype) %(refname:strip=2)' 'refs/tags/v*') ||
            die 2 "cannot list the v* tags"
        printf '%s\n' "$out" | awk '$1 == "tag" { print $2 }'
    else
        remote_tags
    fi
}

# The release is monotonic in its channel among the tags that tags_before CUTOFF names: a
# final's version is above every other final's, and a release candidate's version is above
# every final's, its own final included.
check_version_order() {
    local earlier others highest
    earlier=$(tags_before "$1") || exit
    if [ -n "$RC" ]; then
        case $'\n'"$earlier"$'\n' in
            *$'\n'"$BASE"$'\n'*) die 1 "$BASE already exists; no release candidate may follow its final release" ;;
        esac
    fi
    others=$(channel_finals "$earlier") || exit
    highest=$(printf '%s\n%s\n' "$others" "$VERSION" | version_max)
    [ "$highest" = "$VERSION" ] ||
        die 1 "$TAG is not newer than the $CHANNEL release v$highest; $CHANNEL versions only go up"
}

# Epoch seconds at which GitHub created this workflow run: the push of the tag created it, and
# a re-run keeps it. Its output is captured, so a failure dies explicitly.
ci_run_created() {
    local t
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] || die 2 "GITHUB_RUN_ID is not set"
    t=$(gh_run api "repos/$REPO/actions/runs/$GITHUB_RUN_ID" --jq '.created_at | fromdateiso8601') || exit
    [[ "$t" =~ ^[0-9]+$ ]] || die 3 "GitHub returned no creation time for workflow run $GITHUB_RUN_ID"
    printf '%s\n' "$t"
}

# The cutoff for the version rules once TAG exists, empty for none. A tag is validated against
# every release tag that exists when it is pushed:
# - CI, on the push of TAG: the first run compares with every tag; a re-run with the tags
#   created before GitHub created the run, the time of the push.
# - Everywhere else (a dispatch, build, sign, verify, publish): the tags dated before TAG's
#   tagger date, which must lie between its commit's committer date and five minutes from now.
#   The check of the push in CI is what creates the draft that these steps need.
# Its output is captured, so a failure dies explicitly.
tag_cutoff() {
    local commit=$1 tagged committed now
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_EVENT_NAME:-}" = push ]; then
        if [ "${GITHUB_RUN_ATTEMPT:-1}" != 1 ]; then ci_run_created || exit; fi
        return 0
    fi
    tagged=$(tagger_time "$TAG") || exit
    [ -n "$tagged" ] || die 1 "tag $TAG has no tagger date"
    committed=$(git log -1 --format=%ct "$commit") || die 1 "cannot read the committer date of $commit"
    [ "$tagged" -ge "$committed" ] ||
        die 1 "tag $TAG is dated $tagged (epoch seconds), before its commit $commit was made ($committed); a release tag is made after its commit"
    now=$(date +%s) || die 2 "cannot read the clock"
    [ "$tagged" -le $((now + 300)) ] ||
        die 1 "tag $TAG is dated $tagged (epoch seconds), more than five minutes after this host's clock ($now)"
    printf '%s\n' "$tagged"
}

# check-tag step (5): the version in VERSION_FILE is X.Y.Z, and the release is monotonic in
# its channel, with no release candidate after its final.
check_version_at() {
    local commit=$1 file_version cutoff=''
    file_version=$(git show "$commit:$VERSION_FILE" 2>/dev/null | cargo_version) ||
        die 1 "cannot read $VERSION_FILE at $commit"
    [ -n "$file_version" ] || die 1 "no [workspace.package] or [package] version in $VERSION_FILE at $commit"
    [ "$file_version" = "$VERSION" ] ||
        die 1 "$VERSION_FILE at $commit has version $file_version; $TAG needs $VERSION (run the prep step)"

    # Before TAG exists (`tag` is about to create it) the rules compare with every tag on origin.
    # Once it exists they compare with the tags tag_cutoff selects, on any commit: an older
    # release stays verifiable after newer ones exist, while a lower version tagged after a
    # higher one, or a release candidate tagged after its final, fails. The other tags are not
    # verified (the tags before this process are unsigned), so the v* tag ruleset keeps bogus
    # tags out. Tags are immutable under that ruleset: a wrong tag stays, and the next version
    # supersedes it.
    if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
        cutoff=$(tag_cutoff "$commit") || exit
    fi
    check_version_order "$cutoff"
}

# Applies the CHANGELOG rules of check-tag step (6) to file $1: exactly one "## [BASE] - date"
# heading, at least one entry, and exactly one release-base marker naming $2. $3 names the
# file in messages.
check_changelog_file() {
    local file=$1 parent=$2 what=$3 stats headings entries markers sha
    stats=$(awk -v base="$BASE" '
        BEGIN { head = "## [" base "] - " }
        index($0, "## [") == 1 {
            insec = 0
            if (index($0, head) == 1 && substr($0, length(head) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
                headings++; insec = 1
            }
            next
        }
        !insec { next }
        /^- / { entries++ }
        /^<!-- release-base: [0-9a-f]+ -->$/ {
            markers++; sha = $0; sub(/^<!-- release-base: /, "", sha); sub(/ -->$/, "", sha)
        }
        END { printf "%d %d %d %s\n", headings, entries, markers, sha }
    ' "$file")
    read -r headings entries markers sha <<EOF
$stats
EOF
    [ "$headings" -ge 1 ] || die 1 "$what has no '## [$BASE] - YYYY-MM-DD' section (run the prep step)"
    [ "$headings" = 1 ] || die 1 "$what has $headings '## [$BASE]' sections"
    [ "$entries" -ge 1 ] || die 1 "the [$BASE] section of $what has no entries"
    [ "$markers" = 1 ] || die 1 "the [$BASE] section of $what needs exactly one release-base marker (found $markers)"
    [ "${#sha}" = 40 ] || die 1 "the release-base marker in $what is not a full commit id: $sha"
    [ "$sha" = "$parent" ] ||
        die 1 "$what was generated on $sha but the release commit's parent is $parent; something landed in between, run the prep step again"
}

# check-tag step (6). The marker equal to COMMIT^ proves nothing landed between the prep
# step and the release commit (merge queue batching included).
check_changelog_at() {
    local commit=$1 parent
    git show "$commit:$CHANGELOG_FILE" >"$WORK/changelog-at.md" 2>/dev/null ||
        die 1 "$CHANGELOG_FILE does not exist at $commit"
    parent=$(git rev-parse --verify --quiet "$commit^") || die 1 "$commit has no parent commit"
    check_changelog_file "$WORK/changelog-at.md" "$parent" "$CHANGELOG_FILE at $commit"
}

# Full check-tag, steps (1)-(7). MODE is "always" or "if-available", for hook_check_tag_extra.
# Sets COMMIT, SIGNER and SIGNER_FPR, and prints the summary line.
check_tag() {
    local mode=${1:-always}
    fetch_tag
    COMMIT=$(tag_commit "$TAG")
    check_tag_signature
    check_on_main "$COMMIT"
    check_version_at "$COMMIT"
    check_changelog_at "$COMMIT"
    hook_check_tag_extra "$COMMIT" "$mode"
    printf 'commit=%s signer=%s fingerprint=%s channel=%s version=%s features=%s prerelease=%s\n' \
        "$COMMIT" "$SIGNER" "$SIGNER_FPR" "$CHANNEL" "$VERSION" "$FEATURES" "$PRERELEASE"
}

# build and publish must run main's copy of this script, of release.conf (its values, such as
# MIN_SIGNATURES, and its hooks) and of every EXTRA_SCRIPTS file, so an edited or stale
# checkout cannot weaken them. In the submodule layout main's copy of this script is the one
# in the submodule commit MAIN_REF records (check_script_in_submodule).
check_scripts_from_main() {
    local mine theirs file gitlink
    if [ "${RELEASE_ALLOW_LOCAL_SCRIPTS:-}" = 1 ]; then
        warn "RELEASE_ALLOW_LOCAL_SCRIPTS=1: not comparing $SELF_REPO_PATH, $CONF_REPO_PATH and EXTRA_SCRIPTS with $MAIN_REF"
        return 0
    fi
    require_main_ref
    for file in "$SELF_REPO_PATH" "$CONF_REPO_PATH" $EXTRA_SCRIPTS; do
        if [ "$file" = "$SELF_REPO_PATH" ]; then
            gitlink=$(main_gitlink) || exit
            if [ -n "$gitlink" ]; then
                check_script_in_submodule "$gitlink"
                continue
            fi
            mine=$(git hash-object -- "$SELF") || die 2 "cannot read $SELF"
        elif [ "$file" = "$CONF_REPO_PATH" ]; then
            mine=$(git hash-object -- "$CONF") || die 2 "cannot read $CONF"
        else
            mine=$(git hash-object -- "$file") ||
                die 2 "$file is missing from this checkout; update it or set RELEASE_ALLOW_LOCAL_SCRIPTS=1"
        fi
        theirs=$(git rev-parse --verify --quiet "$MAIN_REF:$file") || theirs=missing
        [ "$mine" = "$theirs" ] ||
            die 2 "$file differs from $MAIN_REF; update the checkout or set RELEASE_ALLOW_LOCAL_SCRIPTS=1"
    done
}

# check_scripts_from_main for SELF_REPO_PATH in the submodule layout: the submodule is checked
# out at GITLINK, the commit MAIN_REF records for it, and this script equals the file of its
# name in that commit. The blob is hashed in the submodule, so its attributes apply.
check_script_in_submodule() {
    local gitlink=$1 sub=$SELF_REPO_PATH head mine theirs
    require_submodule_checkout
    head=$(git -C "$sub" rev-parse --verify --quiet 'HEAD^{commit}') || head=none
    [ "$head" = "$gitlink" ] ||
        die 2 "submodule layout: $sub is checked out at $head but $MAIN_REF records $gitlink; run git submodule update $sub, or set RELEASE_ALLOW_LOCAL_SCRIPTS=1"
    mine=$(git -C "$sub" hash-object -- "$SELF") || die 2 "cannot read $SELF"
    theirs=$(git -C "$sub" rev-parse --verify --quiet "$gitlink:${SELF##*/}") || theirs=missing
    [ "$mine" = "$theirs" ] ||
        die 2 "submodule layout: $SELF ($mine) differs from ${SELF##*/} in $sub at $gitlink ($theirs), the commit $MAIN_REF records; restore the checkout or set RELEASE_ALLOW_LOCAL_SCRIPTS=1"
}

# ---------------------------------------------------------------------------------------------
# The GitHub release, or RELEASE_DIR in a dry run

# After a failed gh call: missing auth is a precondition (2). An HTTP 4xx answer other than a
# rate limit is final: 422 is a refused change (1), the rest a precondition such as the token's
# permissions or the repository name (2). Only transport errors, 5xx and rate limits are
# retried, three attempts in all, then exit 3.
gh_failed() {
    local rc=$1 attempt=$2 what=$3
    cat "$WORK/gh.err" >&2
    if [ "$rc" = 4 ]; then die 2 "$what: gh is not authenticated (gh auth login, or GH_TOKEN in CI)"; fi
    if ! grep -q -i -e 'HTTP 429' -e 'rate limit' "$WORK/gh.err"; then
        if grep -q 'HTTP 422' "$WORK/gh.err"; then die 1 "$what: GitHub refused the request (HTTP 422)"; fi
        if grep -q 'HTTP 4[0-9][0-9]' "$WORK/gh.err"; then
            die 2 "$what: GitHub refused the request; check the token's permissions and RELEASE_REPO"
        fi
    fi
    [ "$attempt" -lt 3 ] || die 3 "$what failed after 3 attempts"
    sleep 5
}

# gh with retries; stdout passes through.
gh_run() {
    local attempt=1 out rc
    need gh
    while :; do
        out=$(gh "$@" 2>"$WORK/gh.err") && rc=0 || rc=$?
        if [ "$rc" = 0 ]; then
            if [ -n "$out" ]; then printf '%s\n' "$out"; fi
            return 0
        fi
        gh_failed "$rc" "$attempt" "gh $1 $2"
        attempt=$((attempt + 1))
    done
}

# Sets REL_EXISTS, REL_DRAFT, REL_PRERELEASE, REL_AUTHOR, REL_ASSETS (one name per line) and
# REL_ASSET_IDS. GitHub gives a replaced asset a new id and digest. A dry run's RELEASE_DIR is
# always a draft created by the bot, and its files' hashes stand in for the ids and digests.
release_state() {
    local out rc attempt=1 file hex
    REL_EXISTS=0 REL_DRAFT='' REL_PRERELEASE='' REL_AUTHOR='' REL_ASSETS='' REL_ASSET_IDS=''
    if [ "$DRY_RUN" = 1 ]; then
        [ -n "${RELEASE_DIR:-}" ] || die 2 "dry run: set RELEASE_DIR to the directory that stands in for the release"
        [ -d "$RELEASE_DIR" ] || return 0
        REL_EXISTS=1 REL_DRAFT=true REL_PRERELEASE=$PRERELEASE REL_AUTHOR=$BOT_LOGIN
        for file in "$RELEASE_DIR"/*; do
            [ -f "$file" ] || continue
            hex=$(sha256_hex "$file")
            REL_ASSETS="$REL_ASSETS${file##*/}"$'\n'
            REL_ASSET_IDS="$REL_ASSET_IDS${file##*/}"$'\t-\tsha256:'"$hex"$'\n'
        done
        REL_ASSET_IDS=$(printf '%s' "$REL_ASSET_IDS" | LC_ALL=C sort)
        return 0
    fi
    need gh
    while :; do
        out=$(gh release view "$TAG" --repo "$REPO" --json isDraft,isPrerelease,author,assets \
            --jq '.isDraft, .isPrerelease, .author.login, (.assets[] | [.name, .id, (.digest // "")] | @tsv)' \
            2>"$WORK/gh.err") && rc=0 || rc=$?
        if [ "$rc" = 0 ]; then break; fi
        if grep -q 'release not found' "$WORK/gh.err"; then return 0; fi
        gh_failed "$rc" "$attempt" "gh release view $TAG"
        attempt=$((attempt + 1))
    done
    REL_EXISTS=1
    REL_DRAFT=$(printf '%s\n' "$out" | sed -n 1p)
    REL_PRERELEASE=$(printf '%s\n' "$out" | sed -n 2p)
    REL_AUTHOR=$(printf '%s\n' "$out" | sed -n 3p)
    REL_ASSET_IDS=$(printf '%s\n' "$out" | sed 1,3d | LC_ALL=C sort)
    REL_ASSETS=$(printf '%s\n' "$REL_ASSET_IDS" | cut -f1)
}

has_asset() {
    case $'\n'"$REL_ASSETS"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
}

# check_asset_set REQUIRED... -- OPTIONAL...: the release holds every required asset, and
# nothing that is neither required nor optional.
check_asset_set() {
    local name allowed=$'\n' optional=0 asset
    for name in "$@"; do
        if [ "$name" = -- ]; then
            optional=1
            continue
        fi
        if [ "$optional" = 0 ] && ! has_asset "$name"; then die 1 "release $TAG lacks the asset $name"; fi
        allowed="$allowed$name"$'\n'
    done
    while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        case "$allowed" in *$'\n'"$asset"$'\n'*) ;; *) die 1 "release $TAG has an unexpected asset: $asset" ;; esac
    done <<EOF
$REL_ASSETS
EOF
}

# check_assets_unchanged WHAT: the release still holds exactly the assets, by name, id and
# digest, that release_state listed for the last verification, and the body that
# check_release_body checked, once it has run. WHAT ends the error message.
check_assets_unchanged() {
    local verified=$REL_ASSET_IDS
    release_state
    [ "$REL_EXISTS" = 1 ] || die 1 "release $TAG is gone; $1"
    [ "$REL_ASSET_IDS" = "$verified" ] || die 1 "the assets of $TAG changed after they were verified; $1"
    if [ -n "$BODY_HEX" ]; then
        release_body "$WORK/body.now"
        [ "$(sha256_hex "$WORK/body.now")" = "$BODY_HEX" ] || die 1 "the body of release $TAG changed after it was checked; $1"
    fi
    if [ "$REL_DRAFT" = false ] && [ "$REL_PRERELEASE" != "$PRERELEASE" ]; then
        die 1 "release $TAG is published with prerelease=$REL_PRERELEASE; expected $PRERELEASE"
    fi
}

# check_fetched_digests DIR: every listed asset, as downloaded into DIR, has the sha256 GitHub
# reports for it, so the files checked are the assets listed (nothing swapped in between).
check_fetched_digests() {
    local dir=$1 name id digest hex
    while IFS=$'\t' read -r name id digest; do
        [ -n "$name" ] || continue
        hex=$(sha256_hex "$dir/$name")
        [ -n "$digest" ] ||
            die 2 "GitHub reported no sha256 digest for $name (asset $id) on release $TAG, so the download cannot be compared with it; update gh if it is old"
        [ "$digest" = "sha256:$hex" ] || die 1 "$name on release $TAG (asset $id) changed between listing and download"
    done <<EOF
$REL_ASSET_IDS
EOF
}

# release_fetch DIR NAME...: copies the named assets into DIR.
release_fetch() {
    local dir=$1 name n attempt=1 rc
    shift
    mkdir -p "$dir"
    if [ "$DRY_RUN" = 1 ]; then
        for name in "$@"; do
            cp "$RELEASE_DIR/$name" "$dir/$name" || die 1 "cannot copy $name from $RELEASE_DIR"
        done
        return 0
    fi
    n=$#
    while [ "$n" -gt 0 ]; do
        set -- "$@" --pattern "$1"
        shift
        n=$((n - 1))
    done
    need gh
    until gh release download "$TAG" --repo "$REPO" --dir "$dir" --clobber "$@" 2>"$WORK/gh.err"; do
        rc=$?
        gh_failed "$rc" "$attempt" "gh release download $TAG"
        attempt=$((attempt + 1))
    done
}

# release_upload FILE...: replaces same-named assets.
release_upload() {
    local file
    if [ "$DRY_RUN" = 1 ]; then
        for file in "$@"; do
            if [ ! "$file" -ef "$RELEASE_DIR/${file##*/}" ]; then
                cp "$file" "$RELEASE_DIR/${file##*/}" || die 1 "cannot copy $file to $RELEASE_DIR"
            fi
        done
        info "dry run: assets written to $RELEASE_DIR"
        return 0
    fi
    gh_run release upload "$TAG" --repo "$REPO" --clobber "$@" >&2
}

# Markdown on stdin without carriage returns and without trailing blank lines, so a body
# GitHub returns compares equal to the file it was set from.
normalize_body() {
    tr -d '\r' | awk '{ line[NR] = $0 } END { n = NR; while (n > 0 && line[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print line[i] }'
}

# release_body FILE: the release body, normalized, written to FILE; a dry run reads the copy
# release_set_notes keeps next to the artifacts.
release_body() {
    local file
    if [ "$DRY_RUN" = 1 ]; then
        file="$(pwd)/$ARTIFACT_ROOT/$TAG.notes.md"
        [ -f "$file" ] || die 2 "dry run: $file does not exist; run the build first"
    else
        file=$WORK/body.raw
        gh_run release view "$TAG" --repo "$REPO" --json body --jq .body >"$file"
    fi
    normalize_body <"$file" >"$1"
}

# publish: the release body ends with the notes render_notes writes for COMMIT, line for line;
# anything above them is the operator notes a maintainer added after the build, which are
# shown for review. Sets BODY_HEX, so check_assets_unchanged also catches a later edit.
check_release_body() {
    local want=$WORK/body.want have=$WORK/body.have n_want n_have
    render_notes >"$WORK/body.rendered"
    normalize_body <"$WORK/body.rendered" >"$want"
    release_body "$have"
    n_want=$(awk 'END { print NR }' "$want")
    n_have=$(awk 'END { print NR }' "$have")
    if [ "$n_have" -lt "$n_want" ] || ! tail -n "$n_want" "$have" | cmp -s - "$want"; then
        die 1 "the body of release $TAG does not end with the notes generated for $COMMIT; re-run the tag's release workflow (gh run rerun <run-id>) to write them again, add the operator notes above them, and publish again"
    fi
    if [ "$n_have" -gt "$n_want" ]; then
        info "operator notes above the generated release notes:"
        head -n "$((n_have - n_want))" "$have" | sed 's/^/  | /' >&2
    else
        info "the release body is the generated release notes, with no operator notes"
    fi
    BODY_HEX=$(sha256_hex "$have")
}

# publish on a release that is public already, after a publish that stopped before the alias
# step: its body may carry a warning added since, and the draft job no longer writes the notes
# of a published release, so the body is recorded as it is (BODY_HEX, which
# check_assets_unchanged compares) and not compared with the generated notes.
record_release_body() {
    release_body "$WORK/body.have"
    BODY_HEX=$(sha256_hex "$WORK/body.have")
    info "release $TAG is public already: its body is kept as it is, not compared with the generated notes"
}

# The release body; a dry run keeps it next to the artifacts instead.
release_set_notes() {
    local dest
    if [ "$DRY_RUN" = 1 ]; then
        dest="$(pwd)/$ARTIFACT_ROOT/$TAG.notes.md"
        mkdir -p "${dest%/*}"
        cp "$1" "$dest"
        info "dry run: release body written to $dest"
        return 0
    fi
    gh_run release edit "$TAG" --repo "$REPO" --notes-file "$1" >&2
}

# Empties the local artifact dir $1. In a dry run the stand-in release must be neither that
# dir nor inside it; both are compared as physical paths at the moment of deletion, since
# init_env's check could be outdated by a symlink created since.
clear_release_dir() {
    local rd=$1 here stand_in
    if [ "$DRY_RUN" = 1 ] && [ -n "${RELEASE_DIR:-}" ]; then
        here=$(physical_dir "$rd") || exit
        stand_in=$(physical_dir "$RELEASE_DIR") || exit
        case "$stand_in/" in
            "$here/"*) die 2 "RELEASE_DIR=$RELEASE_DIR lies inside $rd, which this step empties; move it outside $ARTIFACT_ROOT" ;;
        esac
    fi
    rm -rf "$rd"
}

# ---------------------------------------------------------------------------------------------
# Artifact checks shared by build, sign and verify

# The release assets beside SHA256SUMS and SHA256SUMS.asc, one per line: the tarball, then
# EXTRA_ASSETS.
asset_names() {
    local name
    printf '%s\n' "$TARBALL"
    for name in $EXTRA_ASSETS; do printf '%s\n' "$name"; done
}

# The first TARBALL_FILES name: the program, which the tarball carries executable.
tarball_program() {
    local name
    for name in $TARBALL_FILES; do
        printf '%s\n' "$name"
        return 0
    done
}

# The repository paths hook_extra_sums staged under $1, one per line, each a relative path
# that no asset name or other path repeats. Its output is captured, so a failure exits
# explicitly.
sums_extra() {
    local out path seen=$'\n'
    mkdir -p "$1"
    out=$(hook_extra_sums "$1") || exit
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        repo_path_ok "$path" || die 2 "hook_extra_sums printed '$path', which is not a relative path without '..'"
        case "$seen" in *$'\n'"$path"$'\n'*) die 2 "hook_extra_sums printed $path twice" ;; esac
        case $'\n'"$(asset_names)"$'\n' in *$'\n'"$path"$'\n'*) die 2 "hook_extra_sums printed $path, which is a release asset" ;; esac
        [ -f "$1/$path" ] || die 1 "hook_extra_sums printed $path but did not write it"
        seen="$seen$path"$'\n'
        printf '%s\n' "$path"
    done <<EOF
$out
EOF
}

# Every name SHA256SUMS lists, one per line: the assets of asset_names and the repository files
# sums_extra stages under $1. Those lines carry repository paths, so `sha256sum --check` run
# from the root of a checkout of the tag checks the files there. Its output is captured, so a
# failure exits explicitly.
sums_names() {
    local extra
    extra=$(sums_extra "$1") || exit
    asset_names
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
}

# SHA256SUMS: "<hex>  <name>" for every name sums_names lists, C-locale sorted by name.
write_sums() {
    local dir=$1 names name hex lines=''
    names=$(sums_names "$dir") || exit
    while IFS= read -r name; do
        hex=$(sha256_hex "$dir/$name") || exit
        lines="$lines$hex  $name"$'\n'
    done <<EOF
$names
EOF
    printf '%s' "$lines" | LC_ALL=C sort -k2 >"$dir/SHA256SUMS"
}

# The SHA256SUMS file $1 is in the strict two-space format and names exactly the names in $2
# (one per line), each once.
check_sums_shape() {
    local sums=$1 want names
    awk '!/^[0-9a-f]+  [^ ]+$/ || length($1) != 64 { bad = 1 } END { exit bad }' "$sums" ||
        die 1 "SHA256SUMS has a malformed line"
    names=$(awk '{ print $2 }' "$sums" | LC_ALL=C sort)
    want=$(printf '%s\n' "$2" | LC_ALL=C sort)
    [ "$names" = "$want" ] ||
        die 1 "SHA256SUMS must name exactly $(printf '%s\n' "$2" | awk 'NF { printf "%s%s", sep, $0; sep = ", " }')"
}

# SHA256SUMS in DIR has the right shape, and every hash matches: the assets beside it, and
# the repository files as committed at COMMIT, staged into DIR.
check_sums() {
    local dir=$1 names
    names=$(sums_names "$dir") || exit
    check_sums_shape "$dir/SHA256SUMS" "$names"
    (cd "$dir" && sha256_check SHA256SUMS) >&2 || die 1 "SHA256SUMS does not match the files"
}

# The tarball lists exactly the TARBALL_FILES names under its top-level directory (an exact
# comparison, so nothing absolute and no ".."), they extract as regular files into $2, and
# the program is executable.
check_tarball() {
    local tarball=$1 dest=$2 dir listing want f program
    dir="$PROJECT-$TAG-$TRIPLE"
    program=$(tarball_program)
    listing=$(tar -tzf "$tarball") || die 1 "cannot list $TARBALL"
    listing=$(printf '%s\n' "$listing" | awk -v d="$dir/" '$0 != d' | LC_ALL=C sort)
    want=$(for f in $TARBALL_FILES; do printf '%s/%s\n' "$dir" "$f"; done | LC_ALL=C sort)
    [ "$listing" = "$want" ] ||
        die 1 "$TARBALL must hold exactly $TARBALL_FILES under $dir/"
    mkdir -p "$dest"
    tar -xzf "$tarball" -C "$dest" || die 1 "cannot extract $TARBALL"
    for f in $TARBALL_FILES; do
        if [ ! -f "$dest/$dir/$f" ] || [ -L "$dest/$dir/$f" ]; then die 1 "$dir/$f in $TARBALL is not a regular file"; fi
    done
    [ -x "$dest/$dir/$program" ] || die 1 "$dir/$program in $TARBALL is not executable"
}

# check_release_assets SIGNED: the release holds SHA256SUMS and every asset of asset_names,
# and SHA256SUMS.asc when SIGNED is 1 (it may hold it otherwise), and nothing else.
check_release_assets() {
    local signed=$1 name
    set -- SHA256SUMS
    if [ "$signed" = 1 ]; then set -- "$@" SHA256SUMS.asc; fi
    while IFS= read -r name; do set -- "$@" "$name"; done <<EOF
$(asset_names)
EOF
    if [ "$signed" != 1 ]; then set -- "$@" -- SHA256SUMS.asc; fi
    check_asset_set "$@"
}

# Copies SHA256SUMS, every asset of asset_names and, when the release has one, SHA256SUMS.asc
# into DIR.
fetch_release_files() {
    local dir=$1 name
    set -- SHA256SUMS
    while IFS= read -r name; do set -- "$@" "$name"; done <<EOF
$(asset_names)
EOF
    if has_asset SHA256SUMS.asc; then set -- "$@" SHA256SUMS.asc; fi
    release_fetch "$dir" "$@"
}

# The release files that fetch_release_files put in DIR, before anyone counts or adds a
# signature: each is the asset GitHub listed, SHA256SUMS matches them and the repository files
# at COMMIT, and the tarball holds the TARBALL_FILES names; then hook_check_release_files. sign
# and verify both run it.
check_release_files() {
    local dir=$1
    check_fetched_digests "$dir"
    check_sums "$dir"
    check_tarball "$dir/$TARBALL" "$dir/x"
    hook_check_release_files "$dir"
}

# ---------------------------------------------------------------------------------------------
# Release body

# Body of the "## [BASE]" section of the CHANGELOG on stdin: heading and HTML comments
# removed, surrounding blank lines trimmed.
section_body() {
    awk -v base="$BASE" '
        BEGIN { head = "## [" base "] - " }
        index($0, "## [") == 1 { if (insec) done = 1; else if (!done && index($0, head) == 1) insec = 1; next }
        !insec || done { next }
        {
            line = $0; out = ""
            while (line != "") {
                if (incomment) {
                    p = index(line, "-->")
                    if (p == 0) { line = "" } else { line = substr(line, p + 3); incomment = 0 }
                } else {
                    p = index(line, "<!--")
                    if (p == 0) { out = out line; line = "" } else { out = out substr(line, 1, p - 1); line = substr(line, p + 4); incomment = 1 }
                }
            }
            if (out != $0 && out ~ /^[ \t]*$/) next
            lines[++n] = out
        }
        END {
            first = 1; while (first <= n && lines[first] ~ /^[ \t]*$/) first++
            last = n; while (last >= first && lines[last] ~ /^[ \t]*$/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    '
}

# Renders the release body for TAG at COMMIT to stdout.
render_notes() {
    local body handle fpr features_cell extra path name gitlink=''
    git show "$COMMIT:$CHANGELOG_FILE" >"$WORK/notes-changelog.md" 2>/dev/null ||
        die 1 "$CHANGELOG_FILE does not exist at $COMMIT"
    body=$(section_body <"$WORK/notes-changelog.md")
    [ -n "$body" ] || die 1 "$CHANGELOG_FILE at $COMMIT has no entries for [$BASE]"
    if [ -n "$RC" ]; then
        printf "Release candidate %s for \`%s\`. Prerelease.\n\n" "$RC" "$BASE"
    fi
    printf '%s\n\n' "$body"

    features_cell=none
    if [ -n "$FEATURES" ]; then features_cell="\`$FEATURES\`"; fi
    printf '## Artifacts\n\n| Item | Value |\n|---|---|\n'
    printf '| %s | %s |\n' \
        Channel "\`$CHANNEL\`" \
        Commit "\`$COMMIT\`" \
        "Cargo features" "$features_cell" \
        Tarball "\`$TARBALL\` (\`$TRIPLE\`)"
    hook_notes_sections rows
    printf '\n'
    hook_notes_sections sections

    # The repository files SHA256SUMS lists depend only on COMMIT, so the commands below can
    # name them before the build has run.
    extra=$(sums_extra "$WORK/notes-extra") || exit
    # In the submodule layout main holds the keys only as the gitlink, so the reader clones
    # that one submodule too, at the commit main records, and finds KEYS.md beside the keys.
    case "$KEYS_PATH" in
        "$SELF_REPO_PATH"/*)
            require_main_ref
            gitlink=$(main_gitlink) || exit
            ;;
    esac

    # The verification block, with TAG, REPO and the file names filled in. The heredocs are
    # quoted, so $TAG, $2 and $NF reach the reader as written; only the @NAME@ placeholders
    # are substituted.
    sed -e "s|@TAG@|$TAG|g" -e "s|@REPO@|$REPO|g" <<'EOF'
## Verify

Check the signed checksums before you extract or run anything. In a new, empty directory, run these commands in one shell; the first one stops on a directory that is not empty, so no file from an earlier download is checked in place of this release's. They take the maintainer keys from `main`, never from the tag, download the release files, stopping at the first download that fails, check the signature over `SHA256SUMS`, and check the hashes:

```sh
TAG=@TAG@
REPO=@REPO@
BASE="https://github.com/$REPO/releases/download/$TAG"
if [ -n "$(ls -A)" ]; then echo "Run these commands in a new, empty directory" >&2; false; fi &&
EOF
    if [ -n "$gitlink" ]; then
        sed -e "s|@SUB@|$SELF_REPO_PATH|g" <<'EOF'
git clone --quiet --depth 1 --recurse-submodules=@SUB@ --shallow-submodules --branch main "https://github.com/$REPO.git" main &&
EOF
    else
        cat <<'EOF'
git clone --quiet --depth 1 --branch main "https://github.com/$REPO.git" main &&
EOF
    fi
    if [ -n "$extra" ]; then
        cat <<'EOF'
git -C main fetch --quiet --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" &&
EOF
        printf '%s' "git -C main archive \"refs/tags/\$TAG\""
        while IFS= read -r path; do printf ' %s' "$path"; done <<EOF
$extra
EOF
        printf ' | tar -xf - &&\n'
    fi
    sed -e "s|@KEYS_PATH@|$KEYS_PATH|g" <<'EOF'
for k in main/@KEYS_PATH@/*.asc; do gpg --dearmor < "$k"; done > release-keys.gpg &&
gpg --show-keys --with-fingerprint main/@KEYS_PATH@/*.asc &&
EOF
    printf '%s' "curl -fsSL --fail-early --remote-name-all \"\$BASE/SHA256SUMS\" \"\$BASE/SHA256SUMS.asc\""
    while IFS= read -r name; do printf " \"\$BASE/%s\"" "$name"; done <<EOF
$(asset_names)
EOF
    printf ' &&\n'
    cat <<'EOF'
gpgv --status-fd 1 --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS |
awk '$2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)$/ { bad = 1 } $2 ~ /^(GOODSIG|BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)$/ { s = $2; print $2 } $2 == "VALIDSIG" && s == "GOODSIG" { print "signed by primary key " $NF; n++ } END { exit (n && !bad) ? 0 : 1 }' &&
sha256sum --check SHA256SUMS &&
echo "Signature and hashes verified"
```

If the last line `Signature and hashes verified` is missing, the files are not verified; stop, do not extract or run anything from this release, and report it.

EOF
    if [ -n "$gitlink" ]; then
        sed -e "s|@SUB@|$SELF_REPO_PATH|g" <<'EOF'
Then check the key fingerprints: every primary key fingerprint `gpg --show-keys` printed, including the one after `signed by primary key`, must appear in the table below, in the key table of `main/@SUB@/KEYS.md` with the Status `active`, and in `https://github.com/<handle>.gpg`, where `<handle>` is the key file's name without `.asc`. Stop on any mismatch.
EOF
    else
        cat <<'EOF'
Then check the key fingerprints: every primary key fingerprint `gpg --show-keys` printed, including the one after `signed by primary key`, must appear in the table below and in `https://github.com/<handle>.gpg`, where `<handle>` is the key file's name without `.asc`. Stop on any mismatch.
EOF
    fi
    cat <<'EOF'

Maintainer release keys on `main` when these notes were written:

| Maintainer | Primary key fingerprint |
|---|---|
EOF
    while IFS=$'\t' read -r handle fpr; do
        if [ -n "$handle" ]; then printf '| @%s | %s |\n' "$handle" "\`$fpr\`"; fi
    done <<EOF
$ALLOW_LIST
EOF
    sed -e "s|@TARBALL@|$TARBALL|g" -e "s|@DIR@|$PROJECT-$TAG-$TRIPLE|g" <<'EOF'

Tarball, only after the last line was `Signature and hashes verified` and the fingerprints matched:

```sh
tar -xzf "@TARBALL@" &&
ls -l "@DIR@"
```

When a check fails, do not extract, install or run anything from this release:

- The last line is not `Signature and hashes verified`: a step failed, and the lines above it say which.
- `BADSIG`: `SHA256SUMS` changed after it was signed. Report it.
- `Run these commands in a new, empty directory`: the directory holds files already. Start again in a new, empty directory.
- `curl` reports an error, such as `404`: a release file did not download, and the block stopped there. Check `TAG`; if it is right, report it.
- `ERRSIG`: the signing key is not in the allowlist on `main`, or `TAG` is wrong. Check `TAG`; if it is right, report it.
- `EXPKEYSIG` or `REVKEYSIG`: the signing key has expired or was revoked, although gpgv still prints `Good signature`. Report it; a release signed before that can no longer be verified against `main`, which is intended.
- `EXPSIG`: the signature itself has expired. Report it.
- Any of `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG` stops the block even when another signature in `SHA256SUMS.asc` is good.
- `sha256sum` prints `FAILED`: a file differs from its signed hash. Check `TAG` and run the block again in a new, empty directory; if it fails again, report it.
EOF
    if [ -n "$extra" ]; then
        cat <<'EOF'
- `sha256sum` prints `FAILED open or read` for a file from the repository: `git archive` did not extract it. Check that the tag was fetched; if it was, report it.
EOF
    fi
    if [ -n "$gitlink" ]; then
        sed -e "s|@SUB@|$SELF_REPO_PATH|g" <<'EOF'
- A fingerprint is missing from the table above, from `main/@SUB@/KEYS.md` or from GitHub, differs, or its Status in `KEYS.md` is not `active`, such as `revoked YYYY-MM-DD`. Report it.
EOF
    else
        cat <<'EOF'
- A fingerprint is missing from the table above or from GitHub, or differs. Report it.
EOF
    fi
    hook_notes_sections verify
    sed -e "s|@REPO@|$REPO|g" <<'EOF'

Report a failed check through the [security policy](https://github.com/@REPO@/blob/main/SECURITY.md).
EOF
}

# ---------------------------------------------------------------------------------------------
# prep helpers

# Rewrites the version string on the line cargo_version reads: the first `version =` line in
# [workspace.package] when VERSION_FILE has one there, else in [package] (temp file + mv, no
# sed -i).
set_version() {
    local tmp="$VERSION_FILE.release-tmp" sec=package
    if awk '
        /^\[/ { in_ws = ($0 ~ /^\[workspace\.package\][ \t]*$/) }
        in_ws && /^[ \t]*version[ \t]*=/ { hit = 1 }
        END { exit !hit }
    ' "$VERSION_FILE"; then
        sec=workspace.package
    fi
    awk -v v="$1" -v s="[$sec]" '
        /^\[/ { in_sec = (index($0, s) == 1 && substr($0, length(s) + 1) ~ /^[ \t]*$/) }
        in_sec && !done && /^[ \t]*version[ \t]*=/ { sub(/"[^"]*"/, "\"" v "\""); done = 1 }
        { print }
        END { if (!done) exit 3 }
    ' "$VERSION_FILE" >"$tmp" || {
        rm -f "$tmp"
        die 1 "no version line in [$sec] of $VERSION_FILE"
    }
    mv "$tmp" "$VERSION_FILE"
}

# Makes the pinned image $1 available locally, pulling it with retries; exit 3 when the
# registry stays unavailable.
pull_image() {
    local attempt=1
    if docker image inspect "$1" >/dev/null 2>&1; then return 0; fi
    until docker pull --quiet "$1" >&2; do
        [ "$attempt" -lt 3 ] || die 3 "docker pull $1 failed after 3 attempts"
        attempt=$((attempt + 1))
        sleep 5
    done
}

# For hook_changelog: writes the commits since the previous final release as the "## [BASE]"
# section to $1, with the pinned git-cliff image and the project's cliff.toml. The range
# starts at the nearest final tag of either channel reachable from HEAD (the whole history
# when there is none), not at --unreleased, which would start after an ignored rc tag and
# drop the rc's changes from the final's section.
# A worktree's .git points into the common dir and a shared clone borrows objects through
# alternates, so each of those is mounted read-only at its own path.
cliff_section() {
    local out=$1 top common alt prev
    need docker
    [ -f cliff.toml ] || die 2 "cliff.toml is missing"
    top=$(pwd)
    common=$(git rev-parse --path-format=absolute --git-common-dir) || die 2 "git rev-parse --git-common-dir failed"
    prev=$(git describe --tags --abbrev=0 --match 'v*' --exclude '*-rc[0-9]*' HEAD 2>/dev/null) || prev=
    set -- -v "$top:$top:ro" -v "$common:$common:ro"
    if [ -f "$common/objects/info/alternates" ]; then
        while IFS= read -r alt; do
            case "$alt" in /*) set -- "$@" -v "$alt:$alt:ro" ;; esac
        done <"$common/objects/info/alternates"
    fi
    set -- "$@" -w "$top" "$GIT_CLIFF_IMAGE" --config cliff.toml --tag "$BASE" --strip all
    if [ -n "$prev" ]; then
        info "CHANGELOG section for $BASE: commits since $prev"
        set -- "$@" "$prev..HEAD"
    else
        info "CHANGELOG section for $BASE: no earlier final release tag, so the whole history"
    fi
    pull_image "$GIT_CLIFF_IMAGE"
    docker run --rm --network none -u "$(id -u):$(id -g)" -e HOME=/tmp "$@" >"$out" ||
        die 1 "git-cliff failed"
}

# Splices section file $1 into CHANGELOG_FILE right after the anchor line, replacing a top
# section already headed "## [BASE]". A "## [BASE]" further down means the history is wrong
# and is an error.
splice_changelog() {
    local section=$1 rc
    awk -v base="$BASE" -v anchor="$ANCHOR" -v section="$section" '
        function is_base(l) { return index(l, "## [" base "] ") == 1 || l == "## [" base "]" }
        state == "" {
            print
            if ($0 == anchor) { while ((getline s < section) > 0) print s; state = "top" }
            next
        }
        state == "skip" { if (index($0, "## [") != 1) next; state = "rest" }
        state == "top" && index($0, "## [") == 1 { if (is_base($0)) { state = "skip"; next } state = "rest" }
        state == "rest" && is_base($0) { lower = 1 }
        { print }
        END { if (lower) exit 3 }
    ' "$CHANGELOG_FILE" >"$WORK/CHANGELOG.new" && rc=0 || rc=$?
    case "$rc" in
        0) cat "$WORK/CHANGELOG.new" >"$CHANGELOG_FILE" ;;
        3) die 1 "$CHANGELOG_FILE already has a [$BASE] section below the top one" ;;
        *) die 1 "cannot rewrite $CHANGELOG_FILE" ;;
    esac
}

# ---------------------------------------------------------------------------------------------
# Subcommands

cmd_check_tag() { check_tag always; }

cmd_notes() {
    COMMIT=$(tag_commit "$TAG")
    load_allowlist
    render_notes
}

# gh release create is not idempotent, and it can fail after GitHub created the draft. Look
# again before each retry, so a retry cannot leave two drafts for TAG.
create_draft() {
    local notes=$1 attempt=1 rc
    need gh
    set -- release create "$TAG" --repo "$REPO" --draft --verify-tag --title "$TAG" --notes-file "$notes"
    if [ "$PRERELEASE" = true ]; then set -- "$@" --prerelease; fi
    while :; do
        gh "$@" >&2 2>"$WORK/gh.err" && rc=0 || rc=$?
        if [ "$rc" = 0 ]; then return 0; fi
        gh_failed "$rc" "$attempt" "gh release create $TAG"
        attempt=$((attempt + 1))
        release_state
        if [ "$REL_EXISTS" = 1 ]; then
            [ "$REL_DRAFT" = true ] || die 1 "release $TAG is already published"
            [ "$REL_AUTHOR" = "$BOT_LOGIN" ] || die 1 "the draft for $TAG was created by $REL_AUTHOR, not $BOT_LOGIN"
            info "the draft for $TAG exists after the failed call; not creating it again"
            return 0
        fi
    done
}

# CI only: create the draft, or refresh the body of a draft the bot created earlier.
cmd_draft() {
    local notes=$WORK/notes.md
    [ "${GITHUB_ACTIONS:-}" = true ] || die 2 "draft runs only in CI (GITHUB_ACTIONS=true)"
    COMMIT=$(tag_commit "$TAG")
    load_allowlist
    release_state
    if [ "$REL_EXISTS" = 1 ]; then
        [ "$REL_DRAFT" = true ] || die 1 "release $TAG is already published"
        [ "$REL_AUTHOR" = "$BOT_LOGIN" ] || die 1 "the draft for $TAG was created by $REL_AUTHOR, not $BOT_LOGIN"
    fi
    render_notes >"$notes"
    if [ "$DRY_RUN" = 1 ]; then
        mkdir -p "$RELEASE_DIR"
        release_set_notes "$notes"
        return 0
    fi
    if [ "$REL_EXISTS" = 1 ]; then
        gh_run release edit "$TAG" --repo "$REPO" --notes-file "$notes" >&2
    else
        create_draft "$notes"
    fi
    info "draft release $TAG is ready"
}

# build server: on a clean checkout of main's tip, bump the version and splice the CHANGELOG
# section. The marker records main's tip so check-tag can prove nothing landed in between.
cmd_prep() {
    local main_sha remote anchors changed name
    need cargo
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die 2 "tracked files have local changes; prep needs a clean checkout of main"
    if [ "$DRY_RUN" != 1 ]; then git_fetch "$MAIN_FETCH"; fi
    require_main_ref
    main_sha=$(git rev-parse "$MAIN_REF^{commit}")
    [ "$(git rev-parse HEAD)" = "$main_sha" ] || die 2 "HEAD is not the tip of main ($MAIN_REF = $main_sha)"
    if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then die 1 "tag $TAG already exists locally"; fi
    if [ "$DRY_RUN" != 1 ]; then
        remote=$(ls_remote_tag "$TAG")
        [ -z "$remote" ] || die 1 "tag $TAG already exists on origin"
    fi
    # The version rules of tag and check-tag, against origin's tags, before anything is written:
    # a release candidate after its final would replace the released section at the top of
    # CHANGELOG_FILE.
    check_version_order ''
    [ -f "$VERSION_FILE" ] || die 2 "$VERSION_FILE is missing"
    [ -f "$CHANGELOG_FILE" ] || die 2 "$CHANGELOG_FILE is missing"
    anchors=$(awk -v a="$ANCHOR" '$0 == a { n++ } END { print n + 0 }' "$CHANGELOG_FILE")
    [ "$anchors" = 1 ] || die 1 "$CHANGELOG_FILE must contain the line '$ANCHOR' exactly once (found $anchors)"

    # From here until the checks below pass, a failure restores the three files prep writes, so
    # the next run finds a clean tree.
    PREP_RESTORE=1
    set_version "$VERSION"
    info "cargo update --workspace"
    cargo update --workspace >&2 ||
        die 3 "cargo update --workspace failed; a failed download from crates.io is the usual cause, so run the prep step again, and if it fails the same way, the output above shows the cause, such as a version conflict"

    : >"$WORK/section.raw"
    hook_changelog "$WORK/section.raw"
    [ -s "$WORK/section.raw" ] ||
        die 2 "hook_changelog wrote no CHANGELOG section; define it in $CONF (with git-cliff: hook_changelog() { cliff_section \"\$1\"; })"
    awk -v base="$BASE" -v m="$main_sha" '
        NF == 0 && !started { next }
        { started = 1; print }
        !marked && index($0, "## [" base "] - ") == 1 { print "<!-- release-base: " m " -->"; marked = 1 }
    ' "$WORK/section.raw" >"$WORK/section.md"
    splice_changelog "$WORK/section.md"
    check_changelog_file "$CHANGELOG_FILE" "$main_sha" "$CHANGELOG_FILE"
    [ "$(cargo_version <"$VERSION_FILE")" = "$VERSION" ] || die 1 "$VERSION_FILE does not read back version $VERSION"

    changed=$(git diff --name-only HEAD)
    while IFS= read -r name; do
        case "$name" in
            '' | "$VERSION_FILE" | Cargo.lock | "$CHANGELOG_FILE") ;;
            *) die 1 "prep changed $name; only $VERSION_FILE, Cargo.lock and $CHANGELOG_FILE may change" ;;
        esac
    done <<EOF
$changed
EOF
    PREP_RESTORE=0

    cat "$WORK/section.md"
    cat <<EOF

Next:
  git switch -c release/$TAG
  git commit -am "release: $TAG"
  gh pr create --title "release: $TAG" --body "Version $VERSION and the CHANGELOG section for $BASE."
  Merge it alone (no batching): check-tag requires the release commit's parent to be
  $main_sha, the commit the release-base marker names.
  Then, on the signing laptop: $0 tag $TAG
  (with RELEASE_COMMIT=<the release commit> if main has moved past it)
EOF
}

# laptop: sign the tag on main's tip (or RELEASE_COMMIT) and push it.
cmd_tag() {
    local target remote rc
    need gpg
    if [ "$DRY_RUN" != 1 ]; then git_fetch "$MAIN_FETCH"; fi
    require_main_ref
    if [ -n "${RELEASE_COMMIT:-}" ]; then
        target=$(git rev-parse --verify --quiet "$RELEASE_COMMIT^{commit}") ||
            die 2 "RELEASE_COMMIT=$RELEASE_COMMIT is not a commit"
    else
        target=$(git rev-parse --verify "$MAIN_REF^{commit}")
    fi
    check_on_main "$target"
    if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then die 1 "tag $TAG already exists locally"; fi
    if [ "$DRY_RUN" != 1 ]; then
        remote=$(ls_remote_tag "$TAG")
        [ -z "$remote" ] || die 1 "tag $TAG already exists on origin"
    fi
    load_allowlist
    check_version_at "$target"
    check_changelog_at "$target"
    hook_check_tag_extra "$target" if-available
    resolve_signing_key

    CREATED_TAG=$TAG
    git -c gpg.format=openpgp tag -s -u "$SIGN_KEY" -m "Release $TAG" "$TAG" "$target" ||
        die 2 "git tag -s failed: is the YubiKey that holds $SIGN_FPR plugged in, and does gpg --card-status show it?"
    COMMIT=$(tag_commit "$TAG")
    [ "$COMMIT" = "$target" ] || die 1 "the new tag points at $COMMIT, not $target"
    check_tag_signature
    [ "$SIGNER" = "$SIGN_HANDLE" ] || die 1 "the tag verifies as @$SIGNER, expected @$SIGN_HANDLE"
    check_on_main "$COMMIT"

    info "tag      $TAG ($CHANNEL, features: ${FEATURES:-none}, prerelease: $PRERELEASE)"
    info "commit   $COMMIT"
    info "signer   @$SIGNER $SIGNER_FPR"
    confirm "Push $TAG to origin?"
    if [ "$DRY_RUN" = 1 ]; then
        info "dry run: not pushing; $TAG stays a local tag"
        CREATED_TAG=
        return 0
    fi
    git push origin "refs/tags/$TAG" 2>"$WORK/push.err" && rc=0 || rc=$?
    cat "$WORK/push.err" >&2
    if [ "$rc" != 0 ]; then
        # A ruleset (GH013), a protected ref or an existing tag is a refusal, not an outage.
        if grep -q -i -e 'rejected\]' -e GH013 -e protected "$WORK/push.err"; then
            die 1 "origin refused $TAG (tag ruleset, protected ref, or the tag exists there); see the git output above"
        fi
        die 3 "git push origin refs/tags/$TAG failed"
    fi
    CREATED_TAG=
    info "pushed $TAG; CI now validates it and creates the draft release"
}

# Packs TARBALL into directory $1: the program file $2 as the first TARBALL_FILES name and the
# other names from the tag's tree (BUILD_WT), under "$PROJECT-$TAG-$TRIPLE/", with fixed modes,
# owner, order and mtime (the commit's), so the same files give the same bytes. For hook_build.
pack_tarball() {
    local rd=$1 program_file=$2 dir stage program f mtime
    dir="$PROJECT-$TAG-$TRIPLE"
    stage=$WORK/stage
    program=$(tarball_program)
    rm -rf "$stage"
    mkdir -p "$stage/$dir"
    cp "$program_file" "$stage/$dir/$program" || die 1 "cannot copy $program_file into the tarball"
    chmod 0755 "$stage/$dir" "$stage/$dir/$program"
    for f in $TARBALL_FILES; do
        if [ "$f" != "$program" ]; then
            cp "$BUILD_WT/$f" "$stage/$dir/$f" || die 1 "$f is missing at $TAG"
            chmod 0644 "$stage/$dir/$f"
        fi
    done
    mtime=$(git log -1 --format=%ct "$COMMIT")
    LC_ALL=C tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$mtime" --format=gnu \
        -cf - -C "$stage" "$dir" | gzip -n -9 >"$rd/$TARBALL" || die 1 "packaging $TARBALL failed"
}

# The default hook_build: `cargo build --locked --release` of the program for TRIPLE in the
# pinned BUILD_IMAGE, with the worktree of the tag mounted at a fixed path and a fresh
# CARGO_HOME inside the container, so no host path ends up in the program; then pack_tarball.
default_build() {
    local rd=$1 program
    [ -n "$BUILD_IMAGE" ] || die 2 "$CONF sets no BUILD_IMAGE, which the default hook_build needs (an image pinned by digest)"
    case "$BUILD_IMAGE" in
        *@sha256:*) ;;
        *) die 2 "BUILD_IMAGE must be pinned by digest (image@sha256:<hex>), got '$BUILD_IMAGE'" ;;
    esac
    need docker
    require_docker
    pull_image "$BUILD_IMAGE"
    program=$(tarball_program)
    set -- cargo build --locked --release --target "$TRIPLE" --bin "$program"
    if [ -n "$FEATURES" ]; then set -- "$@" --features "$FEATURES"; fi
    info "building $program for $TRIPLE in $BUILD_IMAGE (features: ${FEATURES:-none})"
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
        -v "$BUILD_WT:/build" -w /build "$BUILD_IMAGE" "$@" >&2 ||
        die 3 "cargo build failed; a failed download from crates.io is the usual cause, so run the build step again, and report it if the output above shows a build error instead"
    [ -f "$BUILD_WT/target/$TRIPLE/release/$program" ] || die 1 "cargo built no $program for $TRIPLE"
    pack_tarball "$rd" "$BUILD_WT/target/$TRIPLE/release/$program"
}

# build server: build the tarball (and EXTRA_ASSETS) from the tag with hook_build, attach the
# artifacts.
cmd_build() {
    local rd name sums_hex
    if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
        die 2 "build runs on Linux x86_64 (this host is $(uname -s) $(uname -m))"
    fi
    need tar gzip
    fetch_tag
    check_scripts_from_main
    check_tag always
    release_state
    [ "$REL_EXISTS" = 1 ] || die 2 "no draft release for $TAG yet; CI creates it when the tag is pushed"
    [ "$REL_DRAFT" = true ] || die 1 "release $TAG is already published"
    [ "$REL_AUTHOR" = "$BOT_LOGIN" ] || die 1 "the draft for $TAG was created by $REL_AUTHOR, not $BOT_LOGIN"
    if has_asset SHA256SUMS.asc; then
        die 1 "the draft for $TAG already carries SHA256SUMS.asc; a rebuild would void those signatures"
    fi

    # Build from a pristine checkout of the tag, never from the working tree.
    umask 022
    BUILD_WT=$WORK/src
    git worktree add --detach "$BUILD_WT" "refs/tags/$TAG" >&2 || die 2 "git worktree add failed"
    [ "$(git -C "$BUILD_WT" rev-parse HEAD)" = "$COMMIT" ] || die 1 "the build worktree is not at $COMMIT"

    rd="$(pwd)/$(release_dir "$TAG")"
    clear_release_dir "$rd"
    mkdir -p "$rd"
    hook_build "$rd"
    set -- "$rd/SHA256SUMS"
    while IFS= read -r name; do
        [ -f "$rd/$name" ] || die 1 "the build wrote no $name"
        set -- "$@" "$rd/$name"
    done <<EOF
$(asset_names)
EOF
    write_sums "$rd"

    release_upload "$@"
    render_notes >"$WORK/notes.md"
    release_set_notes "$WORK/notes.md"
    cmd_verify 1
    sums_hex=$(sha256_hex "$rd/SHA256SUMS")
    printf 'SHA256SUMS sha256: %s\n' "$sums_hex"
}

# sign: $1 is the sha256 of the SHA256SUMS about to be signed. It must equal the value build
# printed last, taken from RELEASE_SUMS_SHA256 or typed at the prompt (the whole printed line
# is accepted). RELEASE_YES=1 does not answer this prompt, and a mismatch always stops.
check_build_sums_hash() {
    local have=$1 want=${RELEASE_SUMS_SHA256:-}
    if [ -z "$want" ]; then
        [ -t 0 ] || die 2 "set RELEASE_SUMS_SHA256 to the SHA256SUMS sha256 that the build step printed (stdin is not a TTY)"
        printf 'Paste the SHA256SUMS sha256 from the last line of the build step: ' >&2
        read -r want || true
    fi
    # The last word of the last non-blank line, so a trailing blank or CR does not matter.
    want=$(printf '%s\n' "$want" | tr -d '\r' | awk 'NF { w = $NF } END { print tolower(w) }')
    [[ "$want" =~ $HEX64_RE ]] || die 2 "the SHA256SUMS sha256 from the build step must be 64 hex characters, got '$want'"
    [ "$want" = "$have" ] ||
        die 1 "SHA256SUMS on the draft has sha256 $have, but the build step printed $want; do not sign, find out what changed the draft"
    info "SHA256SUMS sha256 matches the value from the build step"
}

# laptop: re-check the draft's files as verify does, compare the SHA256SUMS hash with the one
# build printed, then append this maintainer's detached signature to SHA256SUMS.asc.
cmd_sign() {
    local rd before after recount n_before n_after n_back sums_hex up_hex back_hex
    need tar gzip gpg
    check_tag if-available
    release_state
    [ "$REL_EXISTS" = 1 ] || die 2 "no draft release for $TAG"
    [ "$REL_DRAFT" = true ] || die 1 "release $TAG is already published; signatures go on the draft"
    check_release_assets 0
    rd="$(pwd)/$(release_dir "$TAG")"
    clear_release_dir "$rd"
    fetch_release_files "$rd"
    check_release_files "$rd"
    resolve_signing_key
    before=
    if [ -f "$rd/SHA256SUMS.asc" ]; then before=$(count_sigs "$rd/SHA256SUMS" "$rd/SHA256SUMS.asc") || exit; fi
    n_before=$(printf '%s\n' "$before" | count_lines)
    case $'\n'"$before"$'\n' in
        *$'\n'"$SIGN_HANDLE"$'\n'*) die 1 "SHA256SUMS for $TAG is already signed by @$SIGN_HANDLE" ;;
    esac

    sums_hex=$(sha256_hex "$rd/SHA256SUMS")
    info "tag        $TAG"
    info "commit     $COMMIT"
    info "signer     @$SIGN_HANDLE $SIGN_FPR"
    info "signatures $n_before so far, $THRESHOLD required"
    info "SHA256SUMS sha256: $sums_hex"
    info "$(cat "$rd/SHA256SUMS")"
    check_build_sums_hash "$sums_hex"
    confirm "Sign SHA256SUMS for $TAG?"
    gpg --armor --detach-sign --local-user "$SIGN_KEY" --output "$WORK/new.asc" "$rd/SHA256SUMS" ||
        die 2 "gpg could not sign SHA256SUMS: is the YubiKey that holds $SIGN_FPR plugged in, and does gpg --card-status show it?"
    if [ -f "$rd/SHA256SUMS.asc" ]; then
        cat "$rd/SHA256SUMS.asc" "$WORK/new.asc" >"$WORK/combined.asc"
    else
        cp "$WORK/new.asc" "$WORK/combined.asc"
    fi
    after=$(count_sigs "$rd/SHA256SUMS" "$WORK/combined.asc") || exit
    n_after=$(printf '%s\n' "$after" | count_lines)
    [ "$n_after" = $((n_before + 1)) ] || die 1 "the new signature did not count (before $n_before, after $n_after)"
    case $'\n'"$after"$'\n' in
        *$'\n'"$SIGN_HANDLE"$'\n'*) ;;
        *) die 1 "the new signature does not verify as @$SIGN_HANDLE" ;;
    esac
    mv "$WORK/combined.asc" "$rd/SHA256SUMS.asc"
    release_upload "$rd/SHA256SUMS.asc"

    # Read it back from the release, so what operators download is what was counted. A
    # maintainer signing at the same moment replaces the whole file (assets have no
    # compare-and-swap), so it must be byte for byte the file just uploaded.
    release_fetch "$WORK/readback" SHA256SUMS SHA256SUMS.asc
    up_hex=$(sha256_hex "$rd/SHA256SUMS.asc")
    back_hex=$(sha256_hex "$WORK/readback/SHA256SUMS.asc")
    [ "$back_hex" = "$up_hex" ] ||
        die 1 "SHA256SUMS.asc on the release is not the file just uploaded (did another maintainer sign at the same time?); run the sign step again"
    recount=$(count_sigs "$WORK/readback/SHA256SUMS" "$WORK/readback/SHA256SUMS.asc") || exit
    case $'\n'"$recount"$'\n' in
        *$'\n'"$SIGN_HANDLE"$'\n'*) ;;
        *) die 1 "the uploaded SHA256SUMS.asc carries no signature by @$SIGN_HANDLE" ;;
    esac
    n_back=$(printf '%s\n' "$recount" | count_lines)
    [ "$n_back" = "$n_after" ] || die 1 "the uploaded SHA256SUMS.asc counts $n_back signatures, expected $n_after"
    printf 'signed %s as @%s: %s/%s signatures\n' "$TAG" "$SIGN_HANDLE" "$n_after" "$THRESHOLD"
}

# build server, CI, operators: re-check everything about a release. $1 = 1 allows a missing
# SHA256SUMS.asc (build's own self-check before anyone has signed).
cmd_verify() {
    local allow_unsigned=$1 dir handles n=0
    need tar gzip gpg
    check_tag always
    release_state
    [ "$REL_EXISTS" = 1 ] || die 2 "no GitHub release for $TAG"
    if [ "$allow_unsigned" = 1 ] && [ "$REL_DRAFT" != true ]; then
        die 2 "release $TAG is published; --allow-unsigned applies only to a draft"
    fi
    if [ "$REL_DRAFT" = false ] && [ "$REL_PRERELEASE" != "$PRERELEASE" ]; then
        die 1 "release $TAG is published with prerelease=$REL_PRERELEASE; expected $PRERELEASE"
    fi
    if [ "$allow_unsigned" = 1 ]; then check_release_assets 0; else check_release_assets 1; fi
    dir=$WORK/verify
    rm -rf "$dir"
    fetch_release_files "$dir"
    check_release_files "$dir"
    if [ -f "$dir/SHA256SUMS.asc" ]; then
        handles=$(count_sigs "$dir/SHA256SUMS" "$dir/SHA256SUMS.asc") || exit
        n=$(printf '%s\n' "$handles" | count_lines)
    fi
    if [ "$allow_unsigned" != 1 ] && [ "$n" -lt "$THRESHOLD" ]; then
        die 1 "SHA256SUMS carries $n of the $THRESHOLD required maintainer signatures"
    fi
    printf 'verified %s commit=%s signatures=%s/%s\n' "$TAG" "$COMMIT" "$n" "$THRESHOLD"
}

# Versions of the published final releases in TAG's channel, TAG excluded. A dry run has no
# GitHub to ask and treats TAG as the only release. Its output is captured, and bash 3.2 runs
# $(...) without -e, so `|| exit` passes on the status of a die inside gh_run.
published_versions() {
    local tags
    if [ "$DRY_RUN" = 1 ]; then return 0; fi
    tags=$(gh_run release list --repo "$REPO" --limit 1000 --json tagName,isDraft \
        --jq '.[] | select(.isDraft | not) | .tagName') || exit
    channel_finals "$tags"
}

# build server: verify, publish the draft and, for the newest final of its channel, run
# hook_publish_alias. Safe to re-run.
cmd_publish() {
    local published highest latest=--latest=false newest=0
    fetch_tag
    check_scripts_from_main
    cmd_verify 0
    if [ "$REL_DRAFT" = true ]; then check_release_body; else record_release_body; fi
    published=$(published_versions) || exit
    highest=$(printf '%s\n%s\n' "$published" "$VERSION" | version_max)
    if [ -z "$RC" ] && [ "$highest" = "$VERSION" ]; then
        newest=1
        if [ "$PRERELEASE" = false ]; then latest=--latest; fi
    fi

    info "tag      $TAG (commit $COMMIT)"
    if [ "$REL_DRAFT" = true ]; then
        info "release  draft -> published, prerelease=$PRERELEASE, $latest"
    else
        info "release  already published"
    fi
    # Before anything is made public, so a hook can show what it will move and check its
    # preconditions (such as a registry credential).
    if [ "$newest" = 1 ]; then hook_publish_alias plan; fi
    confirm "Publish $TAG?"
    # Anyone with write access can change a draft's assets while the prompt waits, and
    # publishing takes whatever the draft holds at that moment.
    check_assets_unchanged "run the publish step again to verify them"

    if [ "$REL_DRAFT" = true ]; then
        if [ "$DRY_RUN" = 1 ]; then
            info "dry run: would run gh release edit $TAG --draft=false --prerelease=$PRERELEASE $latest"
        else
            gh_run release edit "$TAG" --repo "$REPO" --draft=false "--prerelease=$PRERELEASE" "$latest" >&2
        fi
    fi
    # Catches a change between the check above and the edit, before a hook moves anything.
    check_assets_unchanged "the release is public: follow After publish in the maintainer guide"
    if [ "$newest" = 1 ]; then hook_publish_alias move; fi
    printf 'published %s newest=%s\n' "$TAG" "$(if [ "$newest" = 1 ]; then printf yes; else printf no; fi)"
}

# ---------------------------------------------------------------------------------------------
# Setup and dispatch

usage() {
    cat >&2 <<EOF
usage: $0 <subcommand> <TAG> [options]

  parse TAG                          print TAG's channel, features and file names
  check-tag TAG                      validate a pushed release tag (CI, build server, laptop)
  notes TAG                          render the release body (CI, build server)
  draft TAG                          create or refresh the draft release (CI only)
  prep TAG                           bump the version and write the CHANGELOG section (build server)
  tag TAG                            sign and push the release tag (laptop)
  build TAG                          build and attach the artifacts (build server)
  sign TAG                           add a maintainer signature to SHA256SUMS.asc (laptop)
  verify TAG [--allow-unsigned]      check a release end to end (build server, CI, operators)
  publish TAG                        verify and publish the draft (build server)

TAG is vX.Y.Z or vX.Y.Z-rcN, with the channels TAG_RE in release.conf allows.
See the header of this file for release.conf, the environment variables and exit codes.
EOF
    exit 2
}

reject_unless_dry() {
    if [ -n "$2" ]; then die 2 "$1 is honoured only in a dry run (RELEASE_DRY_RUN=1)"; fi
}

# Reads and checks the environment once; see the header for each variable.
init_env() {
    local artifacts
    case "${RELEASE_DRY_RUN:-}" in
        '' | 0) DRY_RUN=0 ;;
        1) DRY_RUN=1 ;;
        *) die 2 "RELEASE_DRY_RUN must be 1 or unset" ;;
    esac
    if [ "$DRY_RUN" = 0 ]; then
        reject_unless_dry RELEASE_IMAGE "${RELEASE_IMAGE+set}"
        reject_unless_dry RELEASE_ALLOWLIST_DIR "${RELEASE_ALLOWLIST_DIR+set}"
        reject_unless_dry RELEASE_MAIN_REF "${RELEASE_MAIN_REF+set}"
        reject_unless_dry RELEASE_ATTESTATION "${RELEASE_ATTESTATION+set}"
        reject_unless_dry RELEASE_DIR "${RELEASE_DIR+set}"
    else
        warn "dry run: no gh calls, no git push, images go only to RELEASE_IMAGE"
    fi

    if [ -n "${RELEASE_REPO:-}" ]; then
        REPO=$RELEASE_REPO
    elif [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
        REPO=$GITHUB_REPOSITORY
    else
        REPO=$DEFAULT_REPO
    fi
    [[ "$REPO" =~ $REPO_RE ]] || die 2 "RELEASE_REPO must look like owner/repo, got '$REPO'"
    if [ "$REPO" != "$DEFAULT_REPO" ]; then warn "using repository $REPO"; fi

    if [ -n "${RELEASE_IMAGE:-}" ]; then
        IMAGE=$RELEASE_IMAGE
        is_local_image ||
            die 2 "RELEASE_IMAGE must be localhost:PORT/ or 127.0.0.1:PORT/ and a lowercase repository path without a tag or digest, e.g. 127.0.0.1:5000/tn"
    else
        IMAGE=ghcr.io/$(lower "$REPO")
    fi

    if [ -n "${RELEASE_MAIN_REF:-}" ]; then MAIN_REF=$RELEASE_MAIN_REF; fi
    if [ -n "${RELEASE_ATTESTATION:-}" ] && [ "$RELEASE_ATTESTATION" != skip ]; then
        die 2 "RELEASE_ATTESTATION accepts only 'skip'"
    fi
    if [ -n "${RELEASE_DIR:-}" ]; then
        # build and sign empty the local artifact dir, which must not delete the stand-in
        # release, however either path is spelled (./, .., symlinks).
        RELEASE_DIR=$(physical_dir "$(abspath "$RELEASE_DIR")") || exit
        artifacts=$(physical_dir "$(pwd)/$ARTIFACT_ROOT") || exit
        case "$RELEASE_DIR/" in
            "$artifacts/"*) die 2 "RELEASE_DIR must lie outside $ARTIFACT_ROOT" ;;
        esac
    fi
    if [ -n "${RELEASE_ALLOWLIST_DIR:-}" ]; then RELEASE_ALLOWLIST_DIR=$(abspath "$RELEASE_ALLOWLIST_DIR"); fi

    THRESHOLD=${RELEASE_SIG_THRESHOLD:-$MIN_SIGNATURES}
    case "$THRESHOLD" in
        '' | *[!0-9]*) die 2 "RELEASE_SIG_THRESHOLD must be a whole number" ;;
    esac
    [ "$THRESHOLD" -ge "$MIN_SIGNATURES" ] ||
        die 2 "RELEASE_SIG_THRESHOLD=$THRESHOLD is below MIN_SIGNATURES=$MIN_SIGNATURES"
}

cleanup() {
    local ctr
    if [ "$PREP_RESTORE" = 1 ]; then
        if git checkout HEAD -- "$VERSION_FILE" Cargo.lock "$CHANGELOG_FILE" 2>/dev/null; then
            info "prep stopped: restored $VERSION_FILE, Cargo.lock and $CHANGELOG_FILE from HEAD"
        else
            warn "prep stopped and could not restore its files: run git checkout HEAD -- $VERSION_FILE Cargo.lock $CHANGELOG_FILE"
        fi
    fi
    if [ -n "$CREATED_TAG" ] && git tag -d "$CREATED_TAG" >/dev/null 2>&1; then
        info "removed the unpushed local tag $CREATED_TAG"
    fi
    while IFS= read -r ctr; do
        if [ -n "$ctr" ]; then docker rm -f "$ctr" >/dev/null 2>&1 || true; fi
    done <<EOF
$CONTAINERS
EOF
    if [ -n "$BUILD_WT" ]; then git worktree remove --force --force "$BUILD_WT" >/dev/null 2>&1 || true; fi
    if [ -n "$ALLOW_GNUPGHOME" ] && command -v gpgconf >/dev/null 2>&1; then
        gpgconf --homedir "$ALLOW_GNUPGHOME" --kill all >/dev/null 2>&1 || true
    fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

# Runs from the repository root of the current directory, with a private temp dir.
setup() {
    local top
    need git awk
    ORIG_PWD=$(pwd)
    top=$(git rev-parse --show-toplevel 2>/dev/null) || die 2 "not inside a git checkout"
    cd "$top"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/tn-release.XXXXXX") || die 2 "mktemp failed"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    init_env
}

main() {
    local cmd allow_unsigned=0
    [ $# -ge 1 ] || usage
    cmd=$1
    shift
    case "$cmd" in
        parse | check-tag | notes | draft | prep | tag | build | sign | verify | publish) ;;
        *) usage ;;
    esac
    [ $# -ge 1 ] || usage
    load_conf
    parse_tag "$1"
    shift
    while [ $# -gt 0 ]; do
        case "$cmd:$1" in
            verify:--allow-unsigned)
                allow_unsigned=1
                shift
                ;;
            *) die 2 "unknown option for $cmd: $1" ;;
        esac
    done

    # parse needs neither git nor the network.
    if [ "$cmd" = parse ]; then
        print_parse
        return 0
    fi
    setup
    case "$cmd" in
        check-tag) cmd_check_tag ;;
        notes) cmd_notes ;;
        draft) cmd_draft ;;
        prep) cmd_prep ;;
        tag) cmd_tag ;;
        build) cmd_build ;;
        sign) cmd_sign ;;
        verify) cmd_verify "$allow_unsigned" ;;
        publish) cmd_publish ;;
    esac
}

# Sourcing the file (tests) defines the functions without running anything; a test calls
# load_conf, or sets the release.conf variables itself, before parse_tag.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
