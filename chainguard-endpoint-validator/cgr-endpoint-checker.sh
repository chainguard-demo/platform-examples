#!/usr/bin/env bash
#
# cgr-endpoint-checker.sh
#
# A standalone take on `chainctl config validate` for machines where chainctl
# is not (or cannot be) installed. It checks that this machine can actually
# reach every endpoint Chainguard tooling needs, and prints the results in
# chainctl's table / JSON layout.
#
# Unlike chainctl, which only does a DNS lookup for most hosts, every check
# here makes a real HTTPS request (honoring HTTPS_PROXY / NO_PROXY like other
# tools do). A row only passes when a response came back from the far end.
#
# Checks performed:
#   1. platform.api, platform.console, platform.issuer, platform.registry:
#      HTTPS GET of the URL (taken from CHAINGUARD_PLATFORM_* env vars >
#      chainctl config file > built-in defaults, as `chainctl config validate`
#      does when run with no flags).
#   2. domains.*: HTTPS GET https://<domain>/ for each required third-party
#      domain.
#      For 1 and 2 any response from the server passes, except 403/407/451/511,
#      which are flagged as a possible proxy block page.
#   3. issuer and api:
#        - gRPC : chainguard.platform.ping.PingService/Ping over HTTP/2
#        - HTTP : GET <url>/ping/v1/ping
#        - HTTP : GET <issuer>/.well-known/openid-configuration and <issuer>/keys
#        These must return 2xx AND the expected JSON, so a proxy's block page
#        or login page can't pass for the real service.
#
# Failures say why: DNS, connection refused, timeout, blocked by a proxy,
# connection reset (firewall), untrusted TLS certificate (TLS-inspecting
# proxy), and so on.
#
# Requirements: bash 3.2+ (macOS default is fine) and curl (with HTTP/2
# support for the gRPC checks).
#
# Usage:
#   ./cgr-endpoint-checker.sh [-o table|json|wide] [--timeout SECONDS] [-v] [-h]
#
# Exit status is 0 when the diagnostics ran (even if some checks failed),
# matching chainctl. A non-zero exit means the script itself could not run.

set -u

SCRIPT_NAME=$(basename "$0")

# ---------------------------------------------------------------------------
# Endpoints (chainctl/pkg/config/defaults.go, production build values)
# ---------------------------------------------------------------------------
DEFAULT_API="https://console-api.enforce.dev"
DEFAULT_CONSOLE="https://console.chainguard.dev"
DEFAULT_ISSUER="https://issuer.enforce.dev"
DEFAULT_REGISTRY="https://cgr.dev"

# Required domains, in the order chainctl checks them.
DOMAIN_KEYS="package-repo wolfi storage support auth0 google-user-content github-content google-storage"
domain_value() {
  case "$1" in
    package-repo)        echo "packages.wolfi.dev" ;;
    wolfi)               echo "ghcr.io" ;;
    storage)             echo "9236a389bd48b984df91adc1bc924620.r2.cloudflarestorage.com" ;;
    support)             echo "chainguardhelp.zendesk.com" ;;
    auth0)               echo "chainguard-cd-nvt30yluzzsmvk7t.edge.tenants.us.auth0.com" ;;
    google-user-content) echo "googlecode.l.googleusercontent.com" ;;
    github-content)      echo "raw.githubusercontent.com" ;;
    google-storage)      echo "storage.googleapis.com" ;;
  esac
}

GRPC_PING_PATH="/chainguard.platform.ping.PingService/Ping"
HTTP_PING_PATH="/ping/v1/ping"

MSG_GRPC_OK="gRPC enabled"
MSG_GRPC_HTTP1="gRPC not enabled. Please use --sts-http1-downgrade=true and --validate=false when logging in"
MSG_GRPC_UNTESTED="gRPC check unavailable (requires curl with HTTP/2 support)"
MSG_ENDPOINT_OK="endpoint OK"

# HTTP statuses that proxies and firewalls typically use for block pages.
BLOCK_STATUSES="403 407 451 511"

# Emoji, built from bytes so the script stays ASCII-safe.
CHECK_MARK=$(printf '\342\234\205') # U+2705
CROSS_MARK=$(printf '\342\235\214') # U+274C
WARN_MARK=$(printf '\342\235\227')  # U+2757

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
OUTPUT=""
TIMEOUT=10
VERBOSE=0

usage() {
  cat <<EOF
Check that this machine can reach the endpoints Chainguard tooling needs
(a standalone take on 'chainctl config validate').

Usage:
  $SCRIPT_NAME [-o table|json|wide] [flags]

Flags:
  -o, --output string   Output format. One of: [json, table, wide] (default table).
                        wide adds a TEST column describing each check.
      --timeout int     Per-request timeout in seconds (default 10)
  -v, --verbose         Log the raw error for each failed check to stderr.
  -h, --help            Help for $SCRIPT_NAME

Every check is a real HTTPS request and honors HTTPS_PROXY / NO_PROXY.

Platform URLs are resolved the same way 'chainctl config validate' resolves
them with no flags: CHAINGUARD_PLATFORM_* env vars > chainctl config file
(CHAINCTL_CONFIG, ./chainctl/config.yaml, <config dir>/chainctl/config.yaml,
~/.chainguard/config.yaml) > built-in production defaults.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_value() {
  [ $# -ge 2 ] && [ -n "$2" ] || die "flag needs an argument: $1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v|--verbose) VERBOSE=1 ;;
    -o|--output) need_value "$@"; OUTPUT=$2; shift ;;
    -o*) OUTPUT=${1#-o} ;;
    --output=*) OUTPUT=${1#*=} ;;
    --timeout) need_value "$@"; TIMEOUT=$2; shift ;;
    --timeout=*) TIMEOUT=${1#*=} ;;
    *) die "unknown argument \"$1\" for \"$SCRIPT_NAME\"" ;;
  esac
  shift
done

case "$OUTPUT" in
  ""|table|json|wide) ;;
  *) die "format option \"$OUTPUT\" is not implemented" ;;
esac

case "$TIMEOUT" in
  ''|*[!0-9]*|0) die "--timeout must be a positive integer" ;;
esac

log() {
  [ "$VERBOSE" -eq 1 ] && echo "INFO $*" >&2
  return 0
}

command -v curl >/dev/null 2>&1 || die "curl is required but was not found in PATH"

TMPDIR_VALIDATE=$(mktemp -d 2>/dev/null || mktemp -d -t chainctl-validate)
trap 'rm -rf "$TMPDIR_VALIDATE"' EXIT
ERRFILE="$TMPDIR_VALIDATE/err"
BODYFILE="$TMPDIR_VALIDATE/body"

# ---------------------------------------------------------------------------
# Config file discovery (chainctl/pkg/config/config.go: initialize)
# ---------------------------------------------------------------------------
user_config_dir() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "$HOME/Library/Application Support" ;;
    MINGW*|MSYS*|CYGWIN*) echo "${APPDATA:-$HOME/AppData/Roaming}" ;;
    *)
      if [ -n "${XDG_CONFIG_HOME:-}" ]; then echo "$XDG_CONFIG_HOME"; else echo "$HOME/.config"; fi
      ;;
  esac
}

CONFIG_FILE=""
explicit_config=${CHAINCTL_CONFIG:-}
if [ -n "$explicit_config" ]; then
  case "$explicit_config" in "~"*) explicit_config="$HOME${explicit_config#\~}" ;; esac
  [ -e "$explicit_config" ] || die "failed to access config file \"$explicit_config\""
  [ -d "$explicit_config" ] && die "\"$explicit_config\" is a directory, not a configuration file."
  CONFIG_FILE=$explicit_config
else
  for candidate in "./chainctl/config.yaml" "$(user_config_dir)/chainctl/config.yaml" "$HOME/.chainguard/config.yaml"; do
    if [ -f "$candidate" ]; then
      CONFIG_FILE=$candidate
      break
    fi
  done
fi
[ -n "$CONFIG_FILE" ] && log "using config file $CONFIG_FILE"

# Print platform.<key> from the YAML config file. Exit 0 if the key exists
# (even when its value is empty), 1 if it does not.
config_platform_value() {
  [ -n "$CONFIG_FILE" ] || return 1
  tr -d '\r' < "$CONFIG_FILE" | awk -v want="$1" -v q="'" '
    /^[^[:space:]#]/ {
      in_platform = ($0 ~ /^platform:[[:space:]]*(#.*)?$/)
      next
    }
    in_platform && match($0, "^[[:space:]]+" want ":") {
      v = substr($0, RLENGTH + 1)
      sub(/^[[:space:]]+/, "", v)
      c = substr(v, 1, 1)
      if (c == "\"" || c == q) {
        v = substr(v, 2)
        i = index(v, c)
        if (i > 0) v = substr(v, 1, i - 1)
      } else {
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/[[:space:]]+$/, "", v)
      }
      print v
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }'
}

# chainctl util.IsValidURL: needs a scheme and a host.
is_valid_url() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*://[^/?#[:space:]]+([/?#][^[:space:]]*)?$'
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

CONFIG_WARNINGS=""

# resolve_platform <key> <default>; sets RESOLVED.
resolve_platform() {
  local key=$1 def=$2 envname envval val fileval
  envname="CHAINGUARD_PLATFORM_$(upper "$key")"
  eval "envval=\${$envname:-}"
  if [ -n "$envval" ]; then
    val=$envval
  elif fileval=$(config_platform_value "$key"); then
    val=$fileval
  else
    val=$def
  fi
  if ! is_valid_url "$val"; then
    CONFIG_WARNINGS="${CONFIG_WARNINGS}\"${val}\" is not a valid URL for platform.${key}. Using the default \"${def}\".
"
    val=$def
  fi
  RESOLVED=$val
}

resolve_platform api "$DEFAULT_API"; PLATFORM_API=$RESOLVED
resolve_platform console "$DEFAULT_CONSOLE"; PLATFORM_CONSOLE=$RESOLVED
resolve_platform issuer "$DEFAULT_ISSUER"; PLATFORM_ISSUER=$RESOLVED
resolve_platform registry "$DEFAULT_REGISTRY"; PLATFORM_REGISTRY=$RESOLVED

if [ -n "$CONFIG_WARNINGS" ]; then
  n=$(printf '%s' "$CONFIG_WARNINGS" | grep -c .)
  if [ "$n" -eq 1 ]; then
    printf 'Configuration error: %s' "$CONFIG_WARNINGS" >&2
  else
    printf 'Configuration errors:\n%s' "$CONFIG_WARNINGS" >&2
  fi
  echo >&2
fi

platform_url() {
  case "$1" in
    api) echo "$PLATFORM_API" ;;
    console) echo "$PLATFORM_CONSOLE" ;;
    issuer) echo "$PLATFORM_ISSUER" ;;
    registry) echo "$PLATFORM_REGISTRY" ;;
  esac
}

# url_hostport <url> -> "host:port" (default port from the scheme)
url_hostport() {
  local u=$1 scheme hp
  scheme=$(printf '%s' "${u%%://*}" | tr '[:upper:]' '[:lower:]')
  hp=${u#*://}; hp=${hp%%/*}; hp=${hp%%\?*}; hp=${hp%%#*}; hp=${hp##*@}
  case "$hp" in
    *\]:*|[!\[]*:*) printf '%s' "$hp" ;;
    *) if [ "$scheme" = "http" ]; then printf '%s:80' "$hp"; else printf '%s:443' "$hp"; fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Probing
# ---------------------------------------------------------------------------
# probe <curl args...>: runs curl, sets PROBE_RC, PROBE_OUT (stdout),
# PROBE_ERR (curl's error message) and PROBE_ISSUER (who issued the server's
# TLS certificate, e.g. "R11" for Let's Encrypt or "Zscaler Root CA").
probe() {
  PROBE_OUT=$(curl -sSv --max-time "$TIMEOUT" "$@" 2>"$ERRFILE")
  PROBE_RC=$?
  read_probe_stderr
}

read_probe_stderr() {
  local line
  PROBE_ERR=$(grep '^curl: ([0-9]*)' "$ERRFILE" 2>/dev/null | tail -n1)
  # "*  issuer: C=US; O=Let's Encrypt; CN=R11"  ->  "R11" (CN, else O)
  line=$(grep -i '^\*  *issuer:' "$ERRFILE" 2>/dev/null | tail -n1)
  PROBE_ISSUER=$(printf '%s' "$line" | sed -n 's/.*CN *= *\([^;,/]*\).*/\1/p')
  [ -n "$PROBE_ISSUER" ] || PROBE_ISSUER=$(printf '%s' "$line" | sed -n 's/.*O *= *\([^;,/]*\).*/\1/p')
}

# issuer_note: ", cert issuer: X" when we know the issuer.
issuer_note() {
  if [ -n "$PROBE_ISSUER" ]; then printf ', cert issuer: %s' "$PROBE_ISSUER"; fi
}

# classify <url>: turns a failed probe into a human reason. Sets REASON, and
# REACHED=1 when the far-end server did answer but rejected TLS for this
# hostname (it is reachable, just not by that name).
classify() {
  local hp=$(url_hostport "$1") code
  REACHED=0
  case "$PROBE_RC" in
    5) REASON="Cannot resolve proxy host" ;;
    6) REASON="Cannot resolve ${hp%:*} (DNS)" ;;
    7)
      if printf '%s' "$PROBE_ERR" | grep -qi 'proxy'; then
        REASON="Cannot connect to proxy"
      else
        REASON="Cannot connect to $hp"
      fi
      ;;
    28) REASON="Timed out after ${TIMEOUT}s" ;;
    35)
      if printf '%s' "$PROBE_ERR" | grep -qiE 'alert|unrecognized name'; then
        REACHED=1; REASON="server answered but refused TLS for this name"
      elif printf '%s' "$PROBE_ERR" | grep -qiE 'reset|SYSCALL|EOF|closed'; then
        REASON="Connection reset during TLS handshake (firewall?)"
      else
        REASON="TLS handshake failed"
      fi
      ;;
    51|60)
      if printf '%s' "$PROBE_ERR" | grep -qiE 'subject name|does not match|alternative'; then
        REACHED=1; REASON="server answered with a certificate for a different name"
      else
        REASON="TLS certificate not trusted (TLS-inspecting proxy?)"
      fi
      ;;
    52) REASON="Empty reply from server" ;;
    56)
      if printf '%s' "$PROBE_ERR" | grep -qiE 'CONNECT|proxy'; then
        code=$(printf '%s' "$PROBE_ERR" | grep -oE '[0-9]{3}' | tail -n1)
        REASON="Blocked by proxy${code:+ (HTTP $code)}"
      else
        REASON="Connection reset (firewall?)"
      fi
      ;;
    *) REASON=$(printf '%s' "$PROBE_ERR" | sed 's/^curl: ([0-9]*) *//'); REASON=${REASON:-"curl error $PROBE_RC"} ;;
  esac
  log "$1: curl exit $PROBE_RC: $PROBE_ERR"
}

CURL_HTTP2=0
if curl -V 2>/dev/null | grep -qi 'HTTP2'; then
  CURL_HTTP2=1
else
  echo "WARNING: this curl build has no HTTP/2 support, so the gRPC checks cannot run." >&2
fi

# ---------------------------------------------------------------------------
# Results store (bash 3.2 has no associative arrays):
#   key<TAB>value<TAB>status<TAB>display<TAB>detail<TAB>test
# status is pass|warn|fail, display is the RESULT cell, detail is the reason or
# the HTTP status, test describes the check (shown with -o wide).
# ---------------------------------------------------------------------------
TAB=$(printf '\t')
RESULTS=""
add_row() {
  RESULTS="${RESULTS}$1${TAB}$2${TAB}$3${TAB}$4${TAB}$5${TAB}$6
"
}

# reach_row <key> <shown value> <url>: any HTTP response from the server passes.
reach_row() {
  local key=$1 value=$2 url=$3 test="HTTPS GET /"
  case "$url" in http://*) test="HTTP GET /" ;; esac
  probe -o /dev/null -w '%{http_code}' "$url"
  if [ "$PROBE_RC" -eq 0 ] && [ "$PROBE_OUT" != "000" ]; then
    case " $BLOCK_STATUSES " in
      *" $PROBE_OUT "*)
        add_row "$key" "$value" warn "$WARN_MARK HTTP $PROBE_OUT - may be a proxy block page" \
          "HTTP $PROBE_OUT$(issuer_note)" "$test"
        ;;
      *) add_row "$key" "$value" pass "$CHECK_MARK" "HTTP $PROBE_OUT$(issuer_note)" "$test" ;;
    esac
    return
  fi
  classify "$url"
  if [ "$REACHED" -eq 1 ]; then
    add_row "$key" "$value" pass "$CHECK_MARK" "$REASON" "$test"
  else
    add_row "$key" "$value" fail "$CROSS_MARK $REASON" "$REASON" "$test"
  fi
}

# http_row <key> <base url> <path> <marker>: needs a 2xx response whose body
# contains <marker> (redirects followed), so a proxy's block or login page
# cannot pass for the real endpoint.
http_row() {
  local key=$1 base=$2 path=$3 marker=$4 test="HTTP GET $3"
  : > "$BODYFILE"
  probe -L --max-redirs 10 -o "$BODYFILE" -w '%{http_code}' "$base$path"
  if [ "$PROBE_RC" -eq 0 ]; then
    case "$PROBE_OUT" in
      2??)
        if grep -q "$marker" "$BODYFILE" 2>/dev/null; then
          add_row "$key" "$base" pass "$MSG_ENDPOINT_OK" "HTTP $PROBE_OUT$(issuer_note)" "$test"
        else
          log "$base$path: HTTP $PROBE_OUT but body has no $marker: $(head -c 120 "$BODYFILE" | tr '\n' ' ')"
          add_row "$key" "$base" fail "$CROSS_MARK HTTP $PROBE_OUT but not the expected response (proxy page?)" \
            "HTTP $PROBE_OUT but the body is not the expected JSON (proxy page?)$(issuer_note)" "$test"
        fi
        ;;
      *) add_row "$key" "$base" fail "$CROSS_MARK HTTP $PROBE_OUT from server" "HTTP $PROBE_OUT from server$(issuer_note)" "$test" ;;
    esac
    return
  fi
  classify "$base$path"
  add_row "$key" "$base" fail "$CROSS_MARK $REASON" "$REASON" "$test"
}

# grpc_row <key> <base url>: unary gRPC call to PingService/Ping with an
# empty request. Needs an HTTP/2 response with grpc-status 0, which is what
# the chainctl gRPC client needs.
grpc_row() {
  local key=$1 base=$2 test="gRPC Ping (HTTP/2)" scheme url h2flag hdrs first status
  if [ "$CURL_HTTP2" -ne 1 ]; then
    add_row "$key" "$base" fail "$MSG_GRPC_UNTESTED" "$MSG_GRPC_UNTESTED" "$test"
    return
  fi
  scheme=$(printf '%s' "${base%%://*}" | tr '[:upper:]' '[:lower:]')
  url="$scheme://$(url_hostport "$base")$GRPC_PING_PATH"
  if [ "$scheme" = "http" ]; then h2flag="--http2-prior-knowledge"; else h2flag="--http2"; fi
  PROBE_OUT=$(printf '\000\000\000\000\000' | curl -sSv "$h2flag" --max-time "$TIMEOUT" \
    -X POST \
    -H 'content-type: application/grpc' \
    -H 'te: trailers' \
    -H 'grpc-accept-encoding: identity' \
    --data-binary @- -D - -o /dev/null "$url" 2>"$ERRFILE" | tr -d '\r')
  read_probe_stderr
  hdrs=$PROBE_OUT
  if [ -z "$hdrs" ]; then
    # tr's exit status hides curl's; recover curl's from its error text.
    PROBE_RC=$(printf '%s' "$PROBE_ERR" | sed -n 's/^curl: (\([0-9]*\)).*/\1/p')
    [ -n "$PROBE_RC" ] || PROBE_RC=1
    classify "$url"
    add_row "$key" "$base" fail "$CROSS_MARK $REASON" "$REASON" "$test"
    return
  fi
  first=$(printf '%s\n' "$hdrs" | head -n1)
  case "$first" in
    HTTP/2*) ;;
    *)
      log "$url: answered with $first instead of HTTP/2"
      add_row "$key" "$base" fail "$MSG_GRPC_HTTP1" "answered with ${first%% *} instead of HTTP/2" "$test"
      return
      ;;
  esac
  status=$(printf '%s\n' "$hdrs" | sed -n 's/^[Gg][Rr][Pp][Cc]-[Ss][Tt][Aa][Tt][Uu][Ss]: *\([0-9]*\).*/\1/p' | head -n1)
  if [ "$status" = "0" ]; then
    add_row "$key" "$base" pass "$MSG_GRPC_OK" "grpc-status 0" "$test"
  else
    log "$url: $(printf '%s\n' "$hdrs" | grep -Ei '^grpc-(status|message):' | tr '\n' ' ')"
    add_row "$key" "$base" fail "$CROSS_MARK gRPC call failed (grpc-status ${status:-missing})" "gRPC call failed (grpc-status ${status:-missing})" "$test"
  fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
for k in api console issuer registry; do
  u=$(platform_url "$k")
  reach_row "platform.$k" "$u" "$u"
done

for k in $DOMAIN_KEYS; do
  d=$(domain_value "$k")
  reach_row "domains.$k" "$d" "https://$d/"
done

for k in issuer api; do
  u=$(platform_url "$k")
  grpc_row "protocol.grpc.platform.$k" "$u"
  http_row "protocol.http.platform.$k" "$u" "$HTTP_PING_PATH" '"response"'
  if [ "$k" = "issuer" ]; then
    http_row "issuer/.well-known/openid-configuration" "$u" "/.well-known/openid-configuration" '"jwks_uri"'
    http_row "issuer/keys" "$u" "/keys" '"keys"'
  fi
done

SORTED=$(printf '%s' "$RESULTS" | LC_ALL=C sort -t "$TAB" -k1,1)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
BS=$(printf '\\')

# Go encoding/json string escaping (incl. HTML-safe escaping of < > &).
json_escape() {
  local s=$1
  s=${s//$BS/$BS$BS}
  s=${s//\"/$BS\"}
  s=${s//$TAB/${BS}t}
  s=${s//</${BS}u003c}
  s=${s//>/${BS}u003e}
  s=${s//&/${BS}u0026}
  printf '%s' "$s"
}

print_json() {
  local first=1 out="{" k v st d det t
  while IFS="$TAB" read -r k v st d det t; do
    [ -n "$k" ] || continue
    [ $first -eq 1 ] || out="$out,"
    first=0
    out="$out\"$(json_escape "$k")\":{\"Value\":\"$(json_escape "$v")\",\"Result\":\"$st\",\"Detail\":\"$(json_escape "$det")\",\"Test\":\"$(json_escape "$t")\"}"
  done <<EOF
$SORTED
EOF
  printf '%s}\n' "$out"
}

# Display width: everything here is ASCII except the two emoji, which occupy
# two terminal columns each (as go-runewidth counts them).
disp_width() {
  local s=$1
  s=${s//$CHECK_MARK/XX}
  s=${s//$CROSS_MARK/XX}
  s=${s//$WARN_MARK/XX}
  local LC_ALL=C
  printf '%s' "${#s}"
}

repeat_char() { # repeat_char <char> <count>
  local n=$2 out=""
  while [ "$n" -gt 0 ]; do out="$out$1"; n=$((n - 1)); done
  printf '%s' "$out"
}

pad_left()  { printf '%s%s' "$(repeat_char ' ' $(($2 - $(disp_width "$1"))))" "$1"; }
pad_center() {
  local extra=$(($2 - $(disp_width "$1")))
  local l=$((extra / 2))
  printf '%s%s%s' "$(repeat_char ' ' "$l")" "$1" "$(repeat_char ' ' $((extra - l)))"
}

# tablewriter (Markdown symbols, no outer borders, header centered and
# upper-cased, rows right-aligned), as chainctl renders it.
# print_table [wide]: "wide" appends the TEST column.
print_table() {
  local wide=${1:-} n=0 i k v st d det t w1=4 w2=5 w3=6 w4=4 dw
  while IFS="$TAB" read -r k v st d det t; do
    [ -n "$k" ] || continue
    # On a pass or warning, the TEST column also shows what came back
    # (e.g. "HTTP 400, cert issuer: R11").
    if [ "$st" != "fail" ] && [ -n "$det" ]; then t="$t ($det)"; fi
    n=$((n + 1))
    eval "ROW_K_$n=\$k; ROW_V_$n=\$v; ROW_R_$n=\$d; ROW_T_$n=\$t"
    dw=$(disp_width "$k"); [ "$dw" -gt "$w1" ] && w1=$dw
    dw=$(disp_width "$v"); [ "$dw" -gt "$w2" ] && w2=$dw
    dw=$(disp_width "$d"); [ "$dw" -gt "$w3" ] && w3=$dw
    dw=$(disp_width "$t"); [ "$dw" -gt "$w4" ] && w4=$dw
  done <<EOF
$SORTED
EOF
  if [ -n "$wide" ]; then
    printf ' %s | %s | %s | %s \n' "$(pad_center NAME "$w1")" "$(pad_center VALUE "$w2")" "$(pad_center RESULT "$w3")" "$(pad_center TEST "$w4")"
    printf '%s|%s|%s|%s\n' "$(repeat_char - $((w1 + 2)))" "$(repeat_char - $((w2 + 2)))" "$(repeat_char - $((w3 + 2)))" "$(repeat_char - $((w4 + 2)))"
  else
    printf ' %s | %s | %s \n' "$(pad_center NAME "$w1")" "$(pad_center VALUE "$w2")" "$(pad_center RESULT "$w3")"
    printf '%s|%s|%s\n' "$(repeat_char - $((w1 + 2)))" "$(repeat_char - $((w2 + 2)))" "$(repeat_char - $((w3 + 2)))"
  fi
  i=1
  while [ "$i" -le "$n" ]; do
    eval "k=\$ROW_K_$i; v=\$ROW_V_$i; d=\$ROW_R_$i; t=\$ROW_T_$i"
    if [ -n "$wide" ]; then
      printf ' %s | %s | %s | %s \n' "$(pad_left "$k" "$w1")" "$(pad_left "$v" "$w2")" "$(pad_left "$d" "$w3")" "$(pad_left "$t" "$w4")"
    else
      printf ' %s | %s | %s \n' "$(pad_left "$k" "$w1")" "$(pad_left "$v" "$w2")" "$(pad_left "$d" "$w3")"
    fi
    i=$((i + 1))
  done
}

case "$OUTPUT" in
  json) print_json ;;
  wide) print_table wide ;;
  *) print_table ;;
esac
