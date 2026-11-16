#!/usr/bin/env bash
# smoke.sh - exercise the staticphp.sh service and its client scripts.
#
#   php -S 127.0.0.1:8098 -t public &
#   tests/smoke.sh                       # local instance
#   BASE=https://staticphp.sh tests/smoke.sh
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8098}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PUBLIC="$(cd "$HERE/.." && pwd)/public"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

final_code() { curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$1"; }
status_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$1"; }

expect() {
  local want=$1 url=$2 label=$3 got
  got=$(status_of "$url")
  [ "$got" = "$want" ] && ok "$label ($got)" || bad "$label (want $want, got $got)"
}

# reachable <api-url> <label>: JSON resolve, then follow the redirect to the archive.
reachable() {
  local url=$1 label=$2 raw target code
  raw=$(curl -sS --max-time 30 --retry 2 "$url")
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    bad "$label (not JSON: $(printf '%s' "$raw" | head -c 120))"
    return
  fi
  target=$(printf '%s' "$raw" | jq -r '.url // empty')
  if [ -z "$target" ]; then
    bad "$label (no url: $(printf '%s' "$raw" | jq -r '.error // "unknown error"'))"
    return
  fi
  code=$(final_code "$target")
  [ "$code" = "200" ] && ok "$label" || bad "$label (archive $code)"
}

api() { printf '%s/fetch.php?%s' "$BASE" "$1"; }

echo "== every combination resolves for linux/x86_64 =="
for combo in minimal common bulk gnu-bulk; do
  for sapi in cli micro fpm; do
    reachable "$(api "combination=$combo&version=8.3&os=linux&arch=x86_64&sapi=$sapi&format=json")" "$combo 8.3 linux/x86_64 $sapi"
  done
done
reachable "$(api 'combination=bulk&version=8.3&os=linux&arch=aarch64&sapi=cli&format=json')" "bulk 8.3 linux/aarch64 cli"
reachable "$(api 'combination=common&version=8.3&os=macos&arch=aarch64&sapi=micro&format=json')" "common 8.3 macos/aarch64 micro"
reachable "$(api 'combination=gnu-bulk&version=8.3&os=linux&arch=aarch64&sapi=cli&format=json')" "gnu-bulk 8.3 linux/aarch64 cli"
reachable "$(api 'combination=spc-max&version=8.3&os=windows&arch=x86_64&sapi=cli&format=json')" "spc-max 8.3 win cli"
reachable "$(api 'combination=spc-min&version=8.3&os=windows&arch=x86_64&sapi=micro&format=json')" "spc-min 8.3 win micro"

echo "== defaults, version forms and aliases =="
expect 302 "$(api 'combination=bulk&version=8.4')" "defaults (linux/x86_64/cli) redirect"
expect 302 "$(api 'combination=bulk')" "version defaults to latest"
expect 302 "$(api 'combination=bulk&version=8.3.36')" "exact patch"
expect 404 "$(api 'combination=bulk&version=8.3.99')" "unknown patch refused"
same_a=$(curl -sS "$(api 'combination=bulk&version=8.3&arch=arm64&format=json')" | jq -r .file)
same_b=$(curl -sS "$(api 'combination=bulk&version=8.3&arch=aarch64&format=json')" | jq -r .file)
[ -n "$same_a" ] && [ "$same_a" = "$same_b" ] && ok "arm64 aliases aarch64" || bad "arm64 alias"

echo "== download + sha256 =="
meta=$(curl -sS "$(api 'combination=bulk&version=8.3&sapi=cli&format=json')")
file=$(printf '%s' "$meta" | jq -r .file)
sha=$(printf '%s' "$meta" | jq -r .sha256)
if curl -fsSL --max-time 300 -o "$TMP/$file" "$(api 'combination=bulk&version=8.3&sapi=cli')"; then
  ok "downloaded $file"
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$TMP/$file" | awk '{print $1}'); else actual=$(shasum -a 256 "$TMP/$file" | awk '{print $1}'); fi
  [ "$actual" = "$sha" ] && ok "sha256 matches metadata" || bad "sha256 mismatch"
  tar -tzf "$TMP/$file" | grep -qx php && ok "archive contains php" || bad "archive does not contain php"
else
  bad "download failed"
fi

echo "== errors =="
expect 400 "$(api 'version=8.3&os=freebsd')" "unsupported os"
expect 400 "$(api 'version=8.3&arch=riscv64')" "unsupported arch"
expect 400 "$(api 'version=8.3&sapi=source')" "unsupported sapi"
expect 400 "$(api 'version=8')" "short version"
expect 404 "$(api 'combination=does-not-exist')" "unknown combination"
expect 404 "$(api 'combination=spc-max&version=8.3&sapi=fpm')" "windows has no fpm"
expect 404 "$(api 'combination=gnu-bulk&os=macos&version=8.3')" "gnu-bulk is linux only"
expect 404 "$(api 'combination=minimal&version=8.0')" "minor not published"
# 405 when PHP answers, 403 when the vhost denies non-GET before PHP (nginx limit_except).
got=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$(api 'combination=common')")
case "$got" in
  405|403) ok "POST rejected ($got)" ;;
  *) bad "POST rejected (got $got)" ;;
esac
expect 200 "$BASE/" "usage page"
expect 200 "$BASE/health" "health"

echo "== client scripts served =="
for asset in fetch.sh fetch.ps1; do
  code=$(status_of "$BASE/$asset")
  [ "$code" = "200" ] && ok "$asset served ($code)" || bad "$asset served ($code)"
  bytes=$(curl -sS "$BASE/$asset" | wc -c | tr -d ' ')
  [ "$bytes" -gt 1000 ] && ok "$asset has content ($bytes bytes)" || bad "$asset content ($bytes bytes)"
done
cmp -s <(curl -sS "$BASE/fetch.sh") "$PUBLIC/fetch.sh" && ok "served fetch.sh matches public/fetch.sh" || bad "served fetch.sh differs"
cmp -s <(curl -sS "$BASE/fetch.ps1") "$PUBLIC/fetch.ps1" && ok "served fetch.ps1 matches public/fetch.ps1" || bad "served fetch.ps1 differs"

echo "== HEAD and cache =="
hdr=$(curl -sI "$(api 'combination=bulk&version=8.3&sapi=cli')")
printf '%s' "$hdr" | grep -qi '^HTTP/[0-9.]* 302' && ok "HEAD returns 302" || bad "HEAD returns 302"
printf '%s' "$hdr" | grep -qi '^X-Php-Bin-File:' && ok "HEAD carries X-Php-Bin-File" || bad "HEAD carries X-Php-Bin-File"
curl -s -o /dev/null "$(api 'combination=bulk&version=8.3&format=json')"
cache=$(curl -s -D - -o /dev/null "$(api 'combination=bulk&version=8.3&format=json')" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-php-bin-cache"{print $2}')
[ "$cache" = "hit" ] && ok "metadata served from cache" || bad "metadata cache ($cache)"

echo "== fetch.sh default combination follows the OS =="
win=$(PHP_BIN_API="$BASE" bash "$PUBLIC/fetch.sh" -o windows -a x86_64 -v 8.3 --json 2>/dev/null | jq -r '.combination + " " + .file')
case "$win" in
  "spc-max "*.zip) ok "windows default resolves to spc-max ($win)" ;;
  *) bad "windows default combination ($win)" ;;
esac
loc=$(PHP_BIN_API="$BASE" bash "$PUBLIC/fetch.sh" -v 8.3 --json 2>/dev/null | jq -r '.combination')
[ "$loc" = "common" ] && ok "unix default resolves to common" || bad "unix default combination ($loc)"

echo "== fetch.sh end to end (resolve only) =="
if PHP_BIN_API="$BASE" bash "$PUBLIC/fetch.sh" -v 8.3 -c bulk -s cli --json > "$TMP/res.json" 2>"$TMP/res.err"; then
  jq -e '.file' "$TMP/res.json" >/dev/null && ok "fetch.sh resolved via API" || bad "fetch.sh output not JSON"
else
  bad "fetch.sh failed: $(head -2 "$TMP/res.err")"
fi
if bash "$PUBLIC/fetch.sh" -v 8.3 -c bulk -s cli --direct --json > "$TMP/res2.json" 2>"$TMP/res2.err"; then
  jq -e '.sha256' "$TMP/res2.json" >/dev/null && ok "fetch.sh --direct resolved" || bad "fetch.sh --direct output incomplete"
else
  bad "fetch.sh --direct failed: $(head -2 "$TMP/res2.err")"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
