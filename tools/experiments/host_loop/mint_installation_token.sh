#!/bin/sh
# Mint a GitHub App installation token, run as root, for TASK-HLR-003 plan D'.
#
# This file is the REVIEWABLE SOURCE. It is not executed from the repository:
# the D2 window installs a copy at a root-owned path outside the checkout and
# verifies sha256(installed) == sha256(this file at protected main's exact OID).
# That indirection is the whole point. Everything a root process executes must
# be unwritable by the account the loop runs as, and in this repository neither
# the checkout (fuhanfeng:staff) nor Homebrew's python (fuhanfeng:admin) is —
# a root daemon running repo code under Homebrew python would hand root to
# anything running as that user, which is strictly worse than the passwordless
# sudo it was meant to avoid.
#
# Hence: /bin/sh only, and only binaries that are root:wheel and not
# user-writable. No python, no repository imports. /usr/bin/python3 is not an
# escape hatch either: it is 3.9.6, and it would load a user-writable
# ~/.local/.../site-packages unless carefully sandboxed, so it is avoided.
#
# The private key is never read by this script. It is passed by path to
# `openssl dgst -sign`, which runs as root; the key stays root-only.
#
# Usage:
#   mint_installation_token.sh --app-id N --installation N \
#       --pem PATH --out PATH --owner USER [--margin SECONDS] [--force]
#
# Exit codes:
#   0  a usable token is present at --out (freshly minted, or still fresh)
#   1  usage error
#   2  minting failed; any pre-existing --out is left byte-for-byte intact
set -eu
umask 077

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

APP_ID=''; INSTALLATION=''; PEM=''; OUT=''; OWNER=''; MARGIN=900; FORCE=0

die() { printf '%s: %s\n' "mint_installation_token" "$1" >&2; exit "${2:-1}"; }

# A value-taking flag in last position used to fall off the end of `shift 2`,
# which under `set -e` exits with the shell's own message and no flag name.
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --app-id)       need_value "$1" $#; APP_ID=$2; shift 2 ;;
        --installation) need_value "$1" $#; INSTALLATION=$2; shift 2 ;;
        --pem)          need_value "$1" $#; PEM=$2; shift 2 ;;
        --out)          need_value "$1" $#; OUT=$2; shift 2 ;;
        --owner)        need_value "$1" $#; OWNER=$2; shift 2 ;;
        --margin)       need_value "$1" $#; MARGIN=$2; shift 2 ;;
        --force)        FORCE=1; shift ;;
        *)              die "unknown argument: $1" ;;
    esac
done

for pair in "APP_ID:--app-id" "INSTALLATION:--installation" "PEM:--pem" \
            "OUT:--out" "OWNER:--owner"; do
    name=${pair%%:*}; flag=${pair#*:}
    eval "value=\${$name}"
    [ -n "$value" ] || die "$flag is required"
done
case "$APP_ID" in *[!0-9]*|'') die "--app-id must be digits" ;; esac
case "$INSTALLATION" in *[!0-9]*|'') die "--installation must be digits" ;; esac
case "$MARGIN" in *[!0-9]*|'') die "--margin must be digits" ;; esac

[ "$(id -u)" = "0" ] || die "must run as root; the PEM is root-only" 1
[ -f "$PEM" ] || die "private key not found at the given path" 2
# The key is passed by path to a root process. If any other account can read or
# replace it, that account can sign as the App, so ownership and mode are
# preconditions rather than hygiene.
PEM_OWNER=$(stat -f '%Su' "$PEM")
PEM_MODE=$(stat -f '%Lp' "$PEM")
[ "$PEM_OWNER" = "root" ] || die "private key must be owned by root, found $PEM_OWNER" 2
case "$PEM_MODE" in
    600|400) ;;
    *) die "private key must be mode 600 or 400, found $PEM_MODE" 2 ;;
esac
id -u "$OWNER" >/dev/null 2>&1 || die "--owner is not a local account"

OUT_DIR=$(dirname "$OUT")
[ -d "$OUT_DIR" ] || die "output directory does not exist: create it first" 2
# The directory, not just the file, is what keeps other local accounts out.
DIR_MODE=$(stat -f '%Lp' "$OUT_DIR")
DIR_OWNER=$(stat -f '%Su' "$OUT_DIR")
[ "$DIR_MODE" = "700" ] || die "output directory must be mode 700, found $DIR_MODE" 2
[ "$DIR_OWNER" = "$OWNER" ] || die "output directory must be owned by $OWNER" 2

SIDECAR="$OUT.meta"

# ---------------------------------------------------------------- freshness
# StartInterval firings are skipped, not queued, while the machine sleeps, so a
# fixed cadence does not bound staleness. Every run therefore decides for itself
# whether the token on disk still has more than --margin seconds left.
now=$(date -u +%s)
if [ "$FORCE" -eq 0 ] && [ -s "$OUT" ] && [ -f "$SIDECAR" ]; then
    not_after=$(sed -n 's/^expires_at_epoch=\([0-9]*\)$/\1/p' "$SIDECAR" | head -1)
    if [ -n "${not_after:-}" ] && [ "$not_after" -gt $((now + MARGIN)) ]; then
        printf 'fresh: %s seconds of validity remain; not re-minting\n' \
            "$((not_after - now))"
        exit 0
    fi
fi

# ------------------------------------------------------------------- the JWT
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
claims=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)
signing_input="$header.$claims"

signature=$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign "$PEM" 2>/dev/null | b64url) \
    || die "JWT signing failed; is the key readable by root and an RSA key?" 2
[ -n "$signature" ] || die "JWT signing produced no signature" 2
jwt="$signing_input.$signature"

# ------------------------------------------------------------------ the call
# The JWT goes in on stdin via --config, never in argv: `curl -H "Authorization:
# ..."` publishes it to `ps` for every local account (measured). The config is
# never written to disk either.
# Every staging path is named and trapped BEFORE the first one exists. The
# trap used to cover only the two response files and to be installed after they
# were created, so a failure between writing the token to `$staged` and the
# `mv` that renames it left the token sitting in the output directory under a
# `.mint.*` name — and a failure in the second mktemp leaked the first.
response=''; status_file=''; curl_err=''; staged=''; staged_meta=''
cleanup() {
    rm -f ${response:+"$response"} ${status_file:+"$status_file"} \
          ${curl_err:+"$curl_err"} ${staged:+"$staged"} ${staged_meta:+"$staged_meta"}
}
trap cleanup EXIT HUP INT TERM

response=$(mktemp "$OUT_DIR/.mint.XXXXXX") || die "cannot create a temp file" 2
status_file=$(mktemp "$OUT_DIR/.mint.XXXXXX") || die "cannot create a temp file" 2
curl_err=$(mktemp "$OUT_DIR/.mint.XXXXXX") || die "cannot create a temp file" 2

printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\nurl = "https://api.github.com/app/installations/%s/access_tokens"\nrequest = "POST"\nsilent\nshow-error\nfail-with-body\nmax-time = 30\noutput = "%s"\nwrite-out = "%%{http_code}"\n' \
    "$jwt" "$INSTALLATION" "$response" \
    | curl --config - > "$status_file" 2>"$curl_err" || true

http=$(cat "$status_file" 2>/dev/null || printf '000')
if [ "$http" != "201" ]; then
    # curl's own diagnostic ("Operation timed out", "Could not resolve host")
    # is the difference between a diagnosable failure and a bare HTTP 000. The
    # response body stays unprinted: a 4xx body can quote the request.
    reason=$(head -1 "$curl_err" 2>/dev/null || printf '')
    die "installation token mint failed: HTTP $http${reason:+ ($reason)} (existing token untouched)" 2
fi

token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$response" | head -1)
expires=$(sed -n 's/.*"expires_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$response" | head -1)
[ -n "$token" ] || die "response carried no token (existing token untouched)" 2

# Prefer GitHub's own expiry; fall back to a conservative hour from now, and
# never trust a parsed value that is further out than that.
horizon=$((now + 3600))
epoch=''
if [ -n "${expires:-}" ]; then
    epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s 2>/dev/null || printf '')
fi
case "${epoch:-}" in
    ''|*[!0-9]*) epoch=$horizon ;;
    *) [ "$epoch" -le "$horizon" ] || epoch=$horizon ;;
esac

# ------------------------------------------------------------- atomic install
# Permissions and ownership are set on the temp file BEFORE it takes the real
# name, so the token is never momentarily readable under the final path.
staged=$(mktemp "$OUT_DIR/.mint.XXXXXX") || die "cannot create a temp file" 2
printf '%s' "$token" > "$staged"
chmod 600 "$staged"
chown "$OWNER" "$staged"
mv -f "$staged" "$OUT"

# The digest is computed into a variable first, so that no printf line in this
# script mentions $token except the single redirected install line above. That
# keeps "the token never reaches an unredirected stdout/stderr" a property a
# simple line-level check can decide, instead of one needing a clever test.
token_digest=$(printf '%s' "$token" | openssl dgst -sha256 -r | cut -d' ' -f1)

staged_meta=$(mktemp "$OUT_DIR/.mint.XXXXXX") || die "cannot create a temp file" 2
{
    printf 'app_id=%s\n' "$APP_ID"
    printf 'installation_id=%s\n' "$INSTALLATION"
    printf 'minted_at_epoch=%s\n' "$now"
    printf 'expires_at=%s\n' "${expires:-unknown}"
    printf 'expires_at_epoch=%s\n' "$epoch"
    printf 'token_sha256=%s\n' "$token_digest"
} > "$staged_meta"
# Root-owned 600, deliberately not handed to $OWNER. This file carries
# expires_at_epoch, which is the criterion root reads to decide whether to
# re-mint; at 644/$OWNER the unprivileged loop account could rewrite root's own
# re-mint decision. Nothing outside this script reads it.
chmod 600 "$staged_meta"
mv -f "$staged_meta" "$SIDECAR"

# The sidecar carries a digest, never the token. The digest is what lets a
# receipt prove which token a round used without publishing it.
printf 'minted: valid for %s seconds\n' "$((epoch - now))"
exit 0
