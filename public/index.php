<?php

declare(strict_types=1);

/**
 * staticphp.sh - single-file endpoint for the StaticPHP prebuilt binaries.
 *
 *   GET /api/fetch?combination=common&version=8.4&os=linux&arch=x86_64&sapi=cli
 *       -> 302 https://dl.static-php.dev/v3/php-bin/common/php-8.4.27-1-cli-linux-x86_64.tar.gz
 *   GET /api/fetch?...&format=json
 *       -> 200 {version, file, size, sha256, url, ...}
 *   GET /fetch.sh, /fetch.ps1
 *       -> the client scripts (also served directly by nginx when they exist in the docroot)
 *   GET /, /health
 *
 * The published layout lives in dl.static-php.dev/v3/php-bin/<combination>/version_<MM>.json.
 * Artifacts and revisions are tracked per platform, so the file name always comes from
 * artifacts.<platform>.<sapi>.file; the top level "revision" must not be used to build one.
 */

const DEFAULT_BASE = 'https://dl.static-php.dev/v3/php-bin';
const DEFAULT_TTL = 300;
const CACHE_HEADER_TTL = 300;

const SAPIS = ['cli', 'micro', 'fpm'];
const OSES = ['linux', 'macos', 'windows'];

/** Architecture aliases users are likely to type. */
const ARCH_ALIASES = [
    'x86_64' => 'x86_64',
    'amd64' => 'x86_64',
    'x64' => 'x86_64',
    'arm64' => 'aarch64',
    'aarch64' => 'aarch64',
];

const ASSETS = ['/fetch.sh' => 'text/plain; charset=utf-8', '/fetch.ps1' => 'text/plain; charset=utf-8'];

function env(string $name, string $default): string
{
    $value = getenv($name);

    return ($value === false || $value === '') ? $default : $value;
}

function base_url(): string
{
    return rtrim(env('PHP_BIN_BASE', DEFAULT_BASE), '/');
}

function cache_dir(): string
{
    $dir = env('PHP_BIN_CACHE_DIR', sys_get_temp_dir() . '/staticphp-sh');
    if (!is_dir($dir) && !@mkdir($dir, 0775, true) && !is_dir($dir)) {
        return sys_get_temp_dir();
    }

    return $dir;
}

function meta_ttl(): int
{
    return max(0, (int) env('PHP_BIN_CACHE_TTL', (string) DEFAULT_TTL));
}

/**
 * Write through a temporary file so a concurrent reader never sees a half-written document.
 */
function store_cache(string $file, array $payload): void
{
    $tmp = $file . '.' . bin2hex(random_bytes(4)) . '.tmp';
    $encoded = json_encode($payload, JSON_UNESCAPED_SLASHES);
    if ($encoded === false || @file_put_contents($tmp, $encoded) === false) {
        return;
    }
    if (!@rename($tmp, $file)) {
        @unlink($tmp);
    }
}

/**
 * Fetch one document of a combination (<file> such as version_84.json), from cache when fresh.
 * Returns null when it does not exist upstream, or when upstream failed and nothing is cached.
 *
 * @return array{body: string, cache: string}|null
 */
function fetch_document(string $combination, string $file): ?array
{
    $cacheFile = cache_dir() . '/' . $combination . '-' . preg_replace('/[^a-z0-9_.-]/i', '_', $file);
    $ttl = meta_ttl();

    $cached = null;
    if (is_file($cacheFile)) {
        $raw = @file_get_contents($cacheFile);
        $stored = $raw === false ? null : json_decode($raw, true);
        if (is_array($stored)) {
            $cached = $stored;
            if (($stored['expires'] ?? 0) > time()) {
                return isset($stored['body'])
                    ? ['body' => (string) $stored['body'], 'cache' => 'hit']
                    : null;
            }
        }
    }

    $ch = curl_init(base_url() . '/' . $combination . '/' . $file);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => 10,
        CURLOPT_USERAGENT => 'staticphp-sh/1.0',
    ]);
    $body = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    unset($ch); // curl_close() is a no-op since PHP 8.0 and deprecated in 8.5

    if ($status === 200 && is_string($body) && $body !== '') {
        store_cache($cacheFile, ['expires' => time() + $ttl, 'body' => $body]);

        return ['body' => $body, 'cache' => 'miss'];
    }

    if ($status === 404) {
        // Negative cache: a typo must not hammer the CDN on every request.
        store_cache($cacheFile, ['expires' => time() + $ttl]);

        return null;
    }

    // Upstream unavailable: keep serving the last known good document instead of breaking the redirect.
    if (is_array($cached) && isset($cached['body'])) {
        return ['body' => (string) $cached['body'], 'cache' => 'stale'];
    }

    return null;
}

function platform_key(string $combination, string $os, string $arch): string
{
    if ($os === 'windows') {
        return 'win';
    }
    if ($combination === 'gnu-bulk') {
        return $os . '-' . $arch . '-gnu';
    }

    return $os . '-' . $arch;
}

function respond_json(int $status, array $payload, array $headers = []): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Access-Control-Allow-Origin: *');
    header('Cache-Control: public, max-age=' . CACHE_HEADER_TTL);
    foreach ($headers as $name => $value) {
        header($name . ': ' . $value);
    }
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'HEAD') {
        echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT), "\n";
    }
}

function fail(int $status, string $error, string $message, array $hints = []): void
{
    respond_json($status, ['error' => $error, 'message' => $message] + ($hints ? ['hint' => $hints] : []));
}

function usage_html(): string
{
    return <<<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>StaticPHP prebuilt PHP</title>
<style>body{font:15px/1.6 system-ui,sans-serif;max-width:48rem;margin:3rem auto;padding:0 1rem}
code{background:#f3f3f3;padding:.1rem .3rem;border-radius:3px}pre{background:#f6f8fa;padding:1rem;overflow:auto}
td,th{padding:.2rem .6rem;text-align:left}</style>
</head><body>
<h1>StaticPHP prebuilt PHP</h1>
<p>One endpoint that redirects to the newest published static PHP binary on
<a href="https://dl.static-php.dev/v3/php-bin/">dl.static-php.dev</a>.</p>
<pre>GET /api/fetch?combination=common&amp;version=8.4&amp;os=linux&amp;arch=x86_64&amp;sapi=cli
GET /api/fetch?combination=common&amp;version=8.4&amp;os=linux&amp;arch=x86_64&amp;sapi=cli&amp;format=json</pre>
<h2>Parameters</h2>
<table>
<tr><th>name</th><th>values</th><th>default</th></tr>
<tr><td><code>combination</code></td><td>minimal, common, bulk, gnu-bulk, spc-min, spc-max</td><td>common</td></tr>
<tr><td><code>version</code></td><td>8.2, 8.3, 8.4, 8.5, an exact patch (8.3.36) or <code>latest</code></td><td>latest</td></tr>
<tr><td><code>os</code></td><td>linux, macos, windows</td><td>linux</td></tr>
<tr><td><code>arch</code></td><td>x86_64, aarch64 (amd64/arm64/x64 accepted)</td><td>x86_64</td></tr>
<tr><td><code>sapi</code></td><td>cli, micro, fpm (fpm is unix only)</td><td>cli</td></tr>
<tr><td><code>format</code></td><td>json returns the resolution instead of redirecting</td><td></td></tr>
</table>
<h2>Client scripts</h2>
<pre>curl -fsSLO https://staticphp.sh/fetch.sh    &amp;&amp; chmod +x fetch.sh &amp;&amp; ./fetch.sh -v 8.4 -c bulk
iwr -useb https://staticphp.sh/fetch.ps1 -OutFile fetch.ps1; .\fetch.ps1 -Version 8.4 -Combination bulk</pre>
<h2>Examples</h2>
<pre>curl -fL -o php "https://staticphp.sh/api/fetch?combination=bulk&amp;version=8.3&amp;os=linux&amp;arch=aarch64&amp;sapi=cli"
curl -fsSL "https://staticphp.sh/api/fetch?combination=bulk&amp;version=8.3&amp;sapi=micro&amp;format=json"</pre>
</body></html>
HTML;
}

function serve_asset(string $path, string $contentType): void
{
    $file = __DIR__ . $path;
    if (!is_file($file)) {
        fail(404, 'not_found', "The script '$path' is not deployed next to this endpoint.");

        return;
    }
    http_response_code(200);
    header('Content-Type: ' . $contentType);
    header('Content-Length: ' . filesize($file));
    header('Cache-Control: public, max-age=' . CACHE_HEADER_TTL);
    header('X-Content-Type-Options: nosniff');
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'HEAD') {
        readfile($file);
    }
}

/**
 * Resolve one published binary. Prints the response and returns.
 */
function api_fetch(array $query): void
{
    $combination = strtolower(trim((string) ($query['combination'] ?? 'common')));
    $version = strtolower(trim((string) ($query['version'] ?? ($query['minor'] ?? 'latest'))));
    $os = strtolower(trim((string) ($query['os'] ?? 'linux')));
    $arch = strtolower(trim((string) ($query['arch'] ?? 'x86_64')));
    $sapi = strtolower(trim((string) ($query['sapi'] ?? 'cli')));
    $wantsJson = ($query['format'] ?? '') === 'json';

    $arch = ARCH_ALIASES[$arch] ?? '';

    if (!preg_match('/^[a-z0-9][a-z0-9.-]*$/', $combination)) {
        fail(400, 'invalid_combination', 'combination must look like common, bulk or spc-max.');

        return;
    }
    if ($version !== 'latest' && !preg_match('/^\d+\.\d+(?:\.\d+)?$/', $version)) {
        fail(400, 'invalid_version', 'version must be 8.4, an exact patch such as 8.4.27, or latest.', [
            'example: /api/fetch?combination=common&version=8.4&os=linux&arch=x86_64',
        ]);

        return;
    }
    if (!in_array($os, OSES, true)) {
        fail(400, 'invalid_os', 'os must be one of: ' . implode(', ', OSES) . '.');

        return;
    }
    if ($arch === '') {
        fail(400, 'invalid_arch', 'arch must be x86_64 or aarch64 (amd64, x64 and arm64 are accepted).');

        return;
    }
    if (!in_array($sapi, SAPIS, true)) {
        fail(400, 'invalid_sapi', 'sapi must be one of: ' . implode(', ', SAPIS) . '.');

        return;
    }
    if ($os === 'windows' && $arch !== 'x86_64') {
        fail(404, 'platform_not_published', 'Windows binaries are only published for x86_64.');

        return;
    }

    if ($version === 'latest') {
        // versions.json lists every minor line of this combination; take the highest one.
        $index = fetch_document($combination, 'versions.json');
        if ($index === null) {
            fail(404, 'unknown_combination', "No published metadata for combination '$combination'.", [
                'known combinations: minimal, common, bulk, gnu-bulk, spc-min, spc-max',
            ]);

            return;
        }
        $list = json_decode($index['body'], true);
        $latest = is_array($list) && isset($list['latest']) && is_array($list['latest']) ? $list['latest'] : [];
        $version = '';
        foreach (array_keys($latest) as $minor) {
            if ($version === '' || version_compare((string) $minor, $version, '>')) {
                $version = (string) $minor;
            }
        }
        if ($version === '') {
            fail(502, 'bad_upstream_metadata', "versions.json for '$combination' has no published minor lines.");

            return;
        }
    }

    $mm = implode('', array_slice(explode('.', $version), 0, 2));
    $meta = fetch_document($combination, 'version_' . $mm . '.json');
    if ($meta === null) {
        fail(404, 'version_not_published', "No published metadata for combination '$combination' (minor $mm).", [
            'known combinations: minimal, common, bulk, gnu-bulk, spc-min, spc-max',
        ]);

        return;
    }

    $doc = json_decode($meta['body'], true);
    if (!is_array($doc) || !isset($doc['artifacts']) || !is_array($doc['artifacts'])) {
        fail(502, 'bad_upstream_metadata', 'The published metadata could not be parsed.');

        return;
    }

    $resolvedVersion = (string) ($doc['php-version'] ?? '');
    if (substr_count($version, '.') === 2 && $version !== $resolvedVersion) {
        fail(404, 'version_not_published', "Only the newest patch of each minor line is published ($resolvedVersion).", [
            'requested: ' . $version,
        ]);

        return;
    }

    $platform = platform_key($combination, $os, $arch);
    $platformEntry = $doc['artifacts'][$platform] ?? null;
    if (!is_array($platformEntry)) {
        fail(404, 'platform_not_published', "Combination '$combination' does not publish $os/$arch.", [
            'available platforms: ' . implode(', ', array_keys($doc['artifacts'])),
        ]);

        return;
    }

    $sapiEntry = $platformEntry[$sapi] ?? null;
    if (!is_array($sapiEntry) || !isset($sapiEntry['file'])) {
        fail(404, 'sapi_not_published', "SAPI '$sapi' is not published for $combination $os/$arch.", [
            'available sapis: ' . implode(', ', array_filter(
                SAPIS,
                static fn ($name) => isset($platformEntry[$name])
            )),
        ]);

        return;
    }

    $file = (string) $sapiEntry['file'];
    $url = base_url() . '/' . $combination . '/' . $file;
    $revision = (int) ($platformEntry['revision'] ?? 0);
    $headers = [
        'X-Php-Bin-Version' => $resolvedVersion,
        'X-Php-Bin-Revision' => (string) $revision,
        'X-Php-Bin-File' => $file,
        'X-Php-Bin-Cache' => $meta['cache'],
    ];

    if ($wantsJson) {
        respond_json(200, [
            'combination' => $combination,
            'minor' => $mm[0] . '.' . $mm[1],
            'version' => $resolvedVersion,
            'platform' => $platform,
            'os' => $os,
            'arch' => $arch,
            'sapi' => $sapi,
            'revision' => $revision,
            'file' => $file,
            'size' => $sapiEntry['size'] ?? null,
            'sha256' => $sapiEntry['sha256'] ?? null,
            'url' => $url,
            'metadata' => base_url() . '/' . $combination . '/version_' . $mm . '.json',
            'spc-ref' => $doc['spc-ref'] ?? null,
            'built-at' => $doc['built-at'] ?? null,
        ], $headers);

        return;
    }

    http_response_code(302);
    header('Cache-Control: public, max-age=' . CACHE_HEADER_TTL);
    foreach ($headers as $name => $value) {
        header($name . ': ' . $value);
    }
    header('Location: ' . $url, true, 302);
}

function handle(string $path, array $query): void
{
    $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
    if ($method === 'OPTIONS') {
        http_response_code(204);
        header('Access-Control-Allow-Origin: *');
        header('Access-Control-Allow-Methods: GET, HEAD, OPTIONS');

        return;
    }
    if ($method !== 'GET' && $method !== 'HEAD') {
        header('Allow: GET, HEAD, OPTIONS');
        fail(405, 'method_not_allowed', 'Only GET and HEAD are supported.');

        return;
    }

    $path = '/' . trim($path, '/');
    if ($path === '/') {
        header('Content-Type: text/html; charset=utf-8');
        echo usage_html();

        return;
    }
    if ($path === '/health') {
        header('Content-Type: text/plain; charset=utf-8');
        echo "ok\n";

        return;
    }
    if (isset(ASSETS[$path])) {
        serve_asset($path, ASSETS[$path]);

        return;
    }
    if ($path === '/api/fetch') {
        api_fetch($query);

        return;
    }

    fail(404, 'not_found', 'Unknown endpoint.', [
        'try /api/fetch?combination=common&version=8.4 or /',
    ]);
}

handle(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/', $_GET);
