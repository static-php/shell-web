#!/usr/bin/env bash
# fetch.sh - download and verify a StaticPHP prebuilt static PHP binary.
#
#   ./fetch.sh                              # newest common/cli for this machine
#   ./fetch.sh -v 8.3 -c bulk -s micro      # bulk 8.3, micro.sfx
#   ./fetch.sh -v 8.4 -c minimal -e         # download and unpack
#   ./fetch.sh --direct -v 8.3 -d ./php-bin # resolve through the published metadata only
#
# Options:
#   -v, --version VERSION    8.2 | 8.3 | 8.4 | 8.5, an exact patch (8.3.36) or latest   (default: latest)
#   -c, --combination NAME   minimal | common | bulk | gnu-bulk | spc-min | spc-max    (default: common)
#   -s, --sapi NAME          cli | micro | fpm                                         (default: cli)
#   -o, --os NAME            linux | macos | windows                                   (default: autodetect)
#   -a, --arch NAME          x86_64 | aarch64                                          (default: autodetect)
#   -d, --dir PATH           download directory                                        (default: .)
#   -e, --extract            unpack the binary next to the archive
#       --json               print the resolution instead of downloading
#       --direct             skip the redirect API and read dl.static-php.dev metadata
#
# Environment:
#   PHP_BIN_API    redirect API base    (default: https://staticphp.sh)
#   PHP_BIN_BASE   metadata/archive root (default: https://dl.static-php.dev/v3/php-bin)
set -euo pipefail

API="${PHP_BIN_API:-https://staticphp.sh}"
BASE="${PHP_BIN_BASE:-https://dl.static-php.dev/v3/php-bin}"

COMBINATION=common
VERSION=latest
SAPI=cli
OS=""
ARCH=""
DEST=.
DIRECT=0
JSON_ONLY=0
EXTRACT=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version) VERSION="${2:-}"; shift 2 ;;
    -c|--combination) COMBINATION="${2:-}"; shift 2 ;;
    -s|--sapi) SAPI="${2:-}"; shift 2 ;;
    -o|--os) OS="${2:-}"; shift 2 ;;
    -a|--arch) ARCH="${2:-}"; shift 2 ;;
    -d|--dir) DEST="${2:-}"; shift 2 ;;
    -e|--extract) EXTRACT=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    --direct) DIRECT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

need curl
need jq
[ -n "$VERSION" ] || die "missing --version"
[ -n "$COMBINATION" ] || die "missing --combination"
[ -n "$SAPI" ] || die "missing --sapi"

# ---- platform detection -------------------------------------------------------------
if [ -z "$OS" ]; then
  case "$(uname -s)" in
    Linux) OS=linux ;;
    Darwin) OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) die "unsupported OS '$(uname -s)'; pass --os" ;;
  esac
fi
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) die "unsupported architecture '$(uname -m)'; pass --arch" ;;
  esac
fi

# Metadata keys platforms as <os>-<arch>, "win" for Windows and <os>-<arch>-gnu for gnu-bulk,
# while the archive file name keeps the plain <os>-<arch> suffix.
case "$OS" in
  windows) PLATFORM=win ;;
  *) if [ "$COMBINATION" = gnu-bulk ]; then PLATFORM="$OS-$ARCH-gnu"; else PLATFORM="$OS-$ARCH"; fi ;;
esac

# ---- resolution ---------------------------------------------------------------------
# Both resolvers print the same JSON shape: {version, file, sha256, url}.
# Errors reported by the API (400/404/405) are user errors: return 2 with the body in stdout.
# Anything else (5xx, DNS, timeout) is an outage: return 1 so the caller falls back.
resolve_via_api() {
  local url out code body
  url="$API/fetch.php?combination=$COMBINATION&version=$VERSION&os=$OS&arch=$ARCH&sapi=$SAPI&format=json"
  out=$(curl -s --max-time 20 --retry 2 -w '\n%{http_code}' "$url") || return 1
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  case "$code" in
    200) printf '%s' "$body" ;;
    4??)
      # Only a JSON error from our own endpoint is authoritative: a bare 404 (for example an
      # nginx page while the service is not deployed yet) means "no API here", so fall back.
      if printf '%s' "$body" | jq -e '.error' >/dev/null 2>&1; then
        printf '%s' "$body"
        return 2
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

resolve_via_metadata() {
  local meta ver mm doc
  meta="$BASE/$COMBINATION"
  case "$VERSION" in
    latest)
      ver=$(curl -fsSL --max-time 20 --retry 2 "$meta/versions.json" |
        jq -r '.latest | to_entries | sort_by(.key | split(".") | map(tonumber)) | last | .value // empty') ||
        die "cannot read $meta/versions.json"
      ;;
    *.*.*)
      ver=$VERSION
      ;;
    *)
      ver=$(curl -fsSL --max-time 20 --retry 2 "$meta/versions.json" |
        jq -r --arg m "$VERSION" '.latest[$m] // empty') ||
        die "cannot read $meta/versions.json"
      ;;
  esac
  [ -n "$ver" ] || die "no published version for $VERSION in combination $COMBINATION"
  mm=$(printf '%s' "$ver" | awk -F. '{print $1 $2}')
  doc=$(curl -fsSL --max-time 20 --retry 2 "$meta/version_$mm.json") ||
    die "cannot read $meta/version_$mm.json"
  docver=$(printf '%s' "$doc" | jq -r '.["php-version"] // empty')
  if [ "$(printf '%s' "$VERSION" | awk -F. '{print NF}')" = 3 ] && [ "$VERSION" != "$docver" ]; then
    die "only the newest patch is published ($docver), requested $VERSION"
  fi
  printf '%s' "$doc" | jq -c --arg p "$PLATFORM" --arg s "$SAPI" --arg base "$meta" '
    (.artifacts[$p] // {}) as $plat |
    ($plat[$s] // {}) as $art |
    if ($art.file // "") == "" then error("no \($s) published for \($p)") else
      {version: .["php-version"], platform: $p, sapi: $s,
       revision: ($plat.revision // 0), file: $art.file,
       size: ($art.size // null), sha256: ($art.sha256 // ""),
       url: "\($base)/\($art.file)"}
    end'
}

RESOLVED=""
if [ "$DIRECT" = "1" ]; then
  RESOLVED=$(resolve_via_metadata) || die "resolution through the published metadata failed"
else
  API_STATUS=0
  API_OUT=$(resolve_via_api) || API_STATUS=$?
  case "$API_STATUS" in
    0) RESOLVED="$API_OUT" ;;
    2) die "api: $(printf '%s' "$API_OUT" | jq -r '.message // "request rejected"' 2>/dev/null)" ;;
    *)
      printf 'note: %s did not answer, falling back to the published metadata\n' "$API" >&2
      RESOLVED=$(resolve_via_metadata) || die "resolution failed"
      ;;
  esac
fi

VERSION_OUT=$(printf '%s' "$RESOLVED" | jq -r '.version')
FILE=$(printf '%s' "$RESOLVED" | jq -r '.file')
SHA=$(printf '%s' "$RESOLVED" | jq -r '.sha256 // ""')
URL=$(printf '%s' "$RESOLVED" | jq -r '.url')

if [ "$JSON_ONLY" = "1" ]; then
  printf '%s\n' "$RESOLVED" | jq .
  exit 0
fi

# ---- download + verify --------------------------------------------------------------
mkdir -p "$DEST"
TARGET="$DEST/$FILE"
printf 'PHP %s (%s, %s/%s, %s) -> %s\n' "$VERSION_OUT" "$COMBINATION" "$OS" "$ARCH" "$SAPI" "$TARGET"
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TARGET" "$URL"

if [ -n "$SHA" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$TARGET" | awk '{print $1}')
  else
    ACTUAL=$(shasum -a 256 "$TARGET" | awk '{print $1}')
  fi
  [ "$ACTUAL" = "$SHA" ] || die "sha256 mismatch for $TARGET (expected $SHA, got $ACTUAL)"
  printf 'sha256 OK\n'
else
  printf 'warning: no sha256 in the metadata, skipping verification\n' >&2
fi

# ---- optional extraction ------------------------------------------------------------
if [ "$EXTRACT" = "1" ]; then
  case "$FILE" in
    *.tar.gz)
      case "$SAPI" in
        cli) MEMBER=php ;;
        micro) MEMBER=micro.sfx ;;
        fpm) MEMBER=php-fpm ;;
      esac
      tar -xzf "$TARGET" -C "$DEST" "$MEMBER" && printf 'extracted %s/%s\n' "$DEST" "$MEMBER"
      ;;
    *.zip)
      need unzip
      unzip -o -q "$TARGET" -d "$DEST" && printf 'extracted into %s\n' "$DEST"
      ;;
  esac
fi
