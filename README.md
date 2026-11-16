# shell-web

The single-file service behind **https://staticphp.sh**: it resolves the newest published StaticPHP
prebuilt binary and redirects to it, and it serves the client scripts that do the same thing from
a shell.

The archives themselves stay on `dl.static-php.dev` (immutable, CDN-cached). This service only maps
*human coordinates* to *that one URL*.

```
GET /api/fetch?combination=bulk&version=8.3&os=linux&arch=aarch64&sapi=cli
    -> 302 https://dl.static-php.dev/v3/php-bin/bulk/php-8.3.36-1-cli-linux-aarch64.tar.gz

GET /api/fetch?combination=bulk&version=8.3&os=linux&arch=aarch64&sapi=cli&format=json
    -> 200 {"version":"8.3.36","file":"...","sha256":"...","url":"...", ...}
```

## Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /api/fetch` | resolve and redirect (or return JSON with `format=json`) |
| `GET /fetch.sh` | POSIX shell client (`curl … \| bash` friendly) |
| `GET /fetch.ps1` | PowerShell client (Windows PowerShell 5.1+, PowerShell 7+) |
| `GET /health` | `ok` for uptime checks |
| `GET /` | short HTML usage page |

### /api/fetch parameters

| Name | Values | Default |
|---|---|---|
| `combination` | `minimal` `common` `bulk` `gnu-bulk` `spc-min` `spc-max` | `common` |
| `version` | `8.2` `8.3` `8.4` `8.5`, an exact patch (`8.3.36`) or `latest` | `latest` |
| `os` | `linux` `macos` `windows` | `linux` |
| `arch` | `x86_64` `aarch64` (`amd64`, `x64`, `arm64` accepted) | `x86_64` |
| `sapi` | `cli` `micro` `fpm` (`fpm` is unix only) | `cli` |
| `format` | `json` returns the resolution instead of redirecting | — |

Status codes: `200` (JSON), `302` (redirect), `400` (bad parameter), `404` (combination/platform/sapi
not published), `405` (method), `502` (upstream metadata unusable).

### Behaviour

- The resolver always takes the file name from `artifacts.<platform>.<sapi>.file`, never from the top
  level `revision`: revisions are tracked **per platform**, and a republish whose build failed leaves
  one platform on its previous revision.
- Metadata (`versions.json`, `version_<MM>.json`) is cached on disk for 300 s, written atomically.
  404s are cached negatively so typos do not hammer the CDN, and a stale copy is served
  (`X-Php-Bin-Cache: stale`) when the CDN is unavailable.
- Responses carry `X-Php-Bin-Version`, `X-Php-Bin-Revision`, `X-Php-Bin-File`, `X-Php-Bin-Cache`;
  redirects and JSON are `Cache-Control: public, max-age=300` so an edge cache can absorb the rest.
- `HEAD` and `OPTIONS` (CORS) are supported.

## Client scripts

```bash
# POSIX shell: autodetects the platform, verifies the checksum, optionally unpacks
curl -fsSLO https://staticphp.sh/fetch.sh && chmod +x fetch.sh
./fetch.sh -v 8.3 -c bulk                 # bulk 8.3 cli
./fetch.sh -v 8.3 -c bulk -s micro -e     # download micro.sfx and unpack it
./fetch.sh --direct --json                # resolve from dl.static-php.dev metadata only

# PowerShell (Windows PowerShell 5.1 and 7+ on Windows, Linux and macOS)
iwr -useb https://staticphp.sh/fetch.ps1 -OutFile fetch.ps1
.\fetch.ps1 -Version 8.3 -Combination spc-min -Extract
.\fetch.ps1 -Version 8.3 -Direct -Json
```

Both scripts resolve through the API first and fall back to the published metadata when the API is
unreachable (or answers with a non-JSON page), so the redirects never become a hard dependency.
`-e`/`-Extract` unpacks `php`/`php.exe`, `micro.sfx` or `php-fpm` next to the archive.

## Development

```
public/index.php   single-file endpoint (API + usage page + /health; also streams the scripts when
                   the front controller receives those requests)
public/fetch.sh    POSIX client
public/fetch.ps1   PowerShell client
tests/smoke.sh     endpoint + shell client checks (48 assertions)
tests/smoke.ps1    PowerShell client checks, run on Windows (11 assertions)
deploy/            nginx and php-fpm configuration for staticphp.sh
```

```bash
php -S 127.0.0.1:8098 -t public public/index.php &
tests/smoke.sh

# on Windows
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
```

Requirements: PHP >= 8.2 with `curl`; no Composer dependencies. The tests need `jq` (shell) and
nothing beyond a stock PowerShell 5.1+ (PowerShell client).

## Deployment

The domain points at `23.95.166.169` (Debian 12, nginx + php8.4-fpm with a single `[www]` pool on
`/var/run/php/php8.4-fpm.sock`, vhosts in `/etc/nginx/conf.d/`, Certbot-managed TLS). The two files
in `deploy/` follow the conventions of the existing vhosts there (`dl.static-php.dev`,
`phpmirror.static-php.dev`).

```bash
# 1) files
sudo mkdir -p /var/www/staticphp.sh
sudo rsync -a --delete public/ /var/www/staticphp.sh/public/
sudo chown -R www-data:www-data /var/www/staticphp.sh

# 2) vhost + per-domain logs
sudo mkdir -p /var/log/nginx/staticphp.sh
sudo cp deploy/nginx-staticphp.sh.conf /etc/nginx/conf.d/staticphp.sh.conf
sudo nginx -t && sudo systemctl reload nginx

# 3) php-fpm environment (this box has one php8.4-fpm pool; php-fpm clears the environment)
sudo mkdir -p /var/cache/staticphp-sh
sudo chown www-data:www-data /var/cache/staticphp-sh
sudo tee -a /etc/php/8.4/fpm/pool.d/www.conf < deploy/php-fpm-env.conf
sudo php-fpm8.4 -t && sudo systemctl reload php8.4-fpm

# 4) TLS (rewrites the vhost, like the other domains on this box)
sudo certbot --nginx -d staticphp.sh

# 5) verify
curl -fsS https://staticphp.sh/health
curl -sI 'https://staticphp.sh/api/fetch?combination=common&version=8.4' | head -5
BASE=https://staticphp.sh tests/smoke.sh
```

Notes:

- `deploy/php-fpm-env.conf` is a snippet to append to the `[www]` section of `www.conf`, not a pool of
  its own: the service is stateless apart from the metadata cache, so it does not need a dedicated
  pool (and the other sites on this box share `[www]`).
- The vhost is HTTP-only on purpose: `certbot --nginx` adds the `listen 443` server and the
  `80 -> 443` redirect the same way it did for the other domains.
- `/var/cache/staticphp-sh` must stay writable by `www-data`; it only holds the 300 s metadata cache.
### Configuration

| Env | Default | Meaning |
|---|---|---|
| `PHP_BIN_BASE` | `https://dl.static-php.dev/v3/php-bin` | metadata/archive root |
| `PHP_BIN_CACHE_DIR` | `sys_get_temp_dir()/staticphp-sh` | metadata cache, must be writable by php-fpm |
| `PHP_BIN_CACHE_TTL` | `300` | metadata cache TTL in seconds |

### Operations

- Stateless apart from the metadata cache: a restart costs one upstream fetch.
- `GET /health` is enough for an uptime check.
- `X-Php-Bin-Cache: stale` in the access log means `dl.static-php.dev` is failing.
- Optional hardening: `limit_req` on `/api/fetch` in nginx, and a Cloudflare cache rule for
  `/api/fetch` (respecting the 300 s `Cache-Control`).
