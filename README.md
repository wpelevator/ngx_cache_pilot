# ngx_cache_pilot

[![CI](https://github.com/wpelevator/ngx_cache_pilot/actions/workflows/ci.yml/badge.svg)](https://github.com/wpelevator/ngx_cache_pilot/actions/workflows/ci.yml)
[![Bench](https://github.com/wpelevator/ngx_cache_pilot/actions/workflows/bench.yml/badge.svg)](https://github.com/wpelevator/ngx_cache_pilot/actions/workflows/bench.yml)
[![Publish Docker Images](https://github.com/wpelevator/ngx_cache_pilot/actions/workflows/publish-docker-images.yml/badge.svg)](https://github.com/wpelevator/ngx_cache_pilot/actions/workflows/publish-docker-images.yml)

`ngx_cache_pilot` is an nginx module that purges cached pages from [`fastcgi_cache`](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html), [`proxy_cache`](https://nginx.org/en/docs/http/ngx_http_proxy_module.html), [`scgi_cache`](https://nginx.org/en/docs/http/ngx_http_scgi_module.html), and [`uwsgi_cache`](https://nginx.org/en/docs/http/ngx_http_uwsgi_module.html). It is a fork of [`ngx_cache_purge`](https://github.com/nginx-modules/ngx_cache_purge).

It works at two points in a cached response's life. When nginx stores a response, the module reads the tag headers your upstream sent (`Cache-Tag` or `Surrogate-Key`) and indexes the cache file under those tags and under its cache key. When a `PURGE` arrives, that index lets you purge by:

- **exact cache key**: the page you just published, including every `Vary` variant of it
- **wildcard key**: everything under `/articles/2026/*`
- **cache tag**, also called a surrogate key: everything labelled `article-42`, whatever its URL and wherever it sits in the cache

A purge either deletes the entry (hard) or marks it expired (soft), so the next visitor gets a revalidated `EXPIRED` instead of a cold `MISS`. `cache_pilot_stats` reports what the cache and the purges are doing, as JSON or Prometheus.

Compared with `ngx_cache_purge`:

| | `ngx_cache_purge` | `ngx_cache_pilot` |
| --- | --- | --- |
| Exact-key and wildcard purge | yes | yes |
| `Vary` variants of one key | opt-in walk of the whole cache directory, per purge | index lookup |
| Cache tags / surrogate keys | none | read from responses at store time, purged by tag |
| Soft purge | none | yes, per location or per request |
| Visibility | error-log messages | JSON and Prometheus metrics endpoint |

_This module is not distributed with the nginx source. See [Installation](#installation)._

## Contents

- [Why this fork](#why-this-fork)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Purge behavior](#purge-behavior)
- [Configuration reference](#configuration-reference)
  - [`fastcgi_cache_purge`, `proxy_cache_purge`, `scgi_cache_purge`, `uwsgi_cache_purge`](#fastcgi_cache_purge-proxy_cache_purge-scgi_cache_purge-uwsgi_cache_purge)
  - [`cache_pilot_purge_response_type`](#cache_pilot_purge_response_type)
  - [`cache_pilot_purge_mode_header`](#cache_pilot_purge_mode_header)
  - [`cache_pilot_index_zone_size`](#cache_pilot_index_zone_size)
  - [`cache_pilot_index`](#cache_pilot_index)
  - [`cache_pilot_tag_headers`](#cache_pilot_tag_headers)
  - [`cache_pilot_stats`](#cache_pilot_stats)
- [How the index works](#how-the-index-works)
- [Known issues](#known-issues)
- [Development](#development)
- [License](#license)
- [See also](#see-also)

## Why this fork

Upstream `ngx_cache_purge` handles exact-key and wildcard purging well. Two things pushed this fork away from it.

### One URL can be several files in the cache

If your upstream sends a `Vary` header, and `Vary: Accept-Encoding` is the common one, nginx does not keep a single file per cache key. It stores a primary file for the key and records in it a hash of the varying request headers. When a request's headers hash differently, nginx reopens the lookup under a secondary key and reads a different file. A gzipped copy and a plain copy of one URL are two files on disk, both reached through the same `proxy_cache_key`.

A purge that resolves the key and unlinks one file therefore removes at most one variant, the one matching the purging client's own request headers. The rest stay cached and keep being served to the visitors whose headers match them. Purging every file that shares a cache key is called fanout.

Upstream handles this with its `cache_purge_vary_aware` directive, which is off by default. After deleting the primary file it walks the whole cache directory, reads the stored key out of every file, and deletes each one that matches. That works, but the cost scales with the size of the cache on every purge.

This module keeps an index of which files belong to which cache key, so fanout is a lookup instead of a directory walk. When the index is not ready, an exact-key purge falls back to the single resolved file and does not walk the tree. See [Known issues](#known-issues).

### Purging by tag, and expiring instead of deleting

When one article appears on its own page, on the front page, in a category listing, and in a feed, purging it means purging four unrelated URLs, and knowing all four. With cache tags your upstream labels each response with what it depends on (`Cache-Tag: article-42, nav`), the module records those labels as the response is cached, and you purge the label. That needs a module that participates in storing the cache, not only in emptying it. Upstream has no tag or surrogate-key support.

Deleting a hot object drops every visitor onto a cold miss until the upstream answers. A soft purge marks the entry expired, so nginx can revalidate while still holding a copy it can serve. Upstream has no soft-purge mode.

## Requirements

- nginx `1.21.4` or newer. The module uses `ngx_rbtree_data()`, which older releases do not provide.
- nginx must be built with HTTP cache support. Adding this module to a `--without-http-cache` configure run fails immediately.
- `--with-threads` is strongly recommended. With it, wildcard purge scans run in an nginx thread pool. Without it they run synchronously and block the event loop.
- Cache-tag and cache-key indexing require Linux. Exact and wildcard key purge and soft purge work anywhere nginx does.
- A dynamic build of this module still needs the nginx cache modules it integrates with (`ngx_http_proxy_module`, `ngx_http_fastcgi_module`, `ngx_http_scgi_module`, `ngx_http_uwsgi_module`). If your distribution ships those as separate dynamic modules, load them before this one.

CI validates source builds against nginx `1.26.3`, `1.28.3`, and `1.29.8`.

## Installation

A dynamic nginx module is not portable between nginx builds. It is compiled against the exact version and configure options of the nginx it will be loaded into, a combination known as the ABI (application binary interface). A module built for one nginx will refuse to load, or misbehave at runtime, in another. That leaves two supportable paths: install a module package your distribution built for its own nginx, or build the module yourself against the exact nginx source you are running.

### Packaged install (Debian/Ubuntu)

The package is a distro-native dynamic module named `libnginx-mod-http-cache-pilot`. On Ubuntu, install it from the `ppa:wpelevator/packages` PPA, which publishes builds for Ubuntu 24.04 (`noble`) and 26.04 (`resolute`):

```bash
sudo add-apt-repository ppa:wpelevator/packages
sudo apt update
sudo apt install nginx libnginx-mod-http-cache-pilot
sudo nginx -t
sudo systemctl reload nginx
```

The package places `ngx_http_cache_pilot_module.so` in `/usr/lib/nginx/modules/` and enables it through `/etc/nginx/modules-enabled/50-mod-http-cache-pilot.conf`, a symlink to `/usr/share/nginx/modules-available/mod-http-cache-pilot.conf`. Do not add a hand-written `load_module` line on top of that.

Each PPA series is built against that series' own nginx, so keep the module and `nginx` packages on the same Ubuntu release. On other Debian derivatives, build the package yourself as described in [Development](#development).

Ubuntu 22.04 (`jammy`) is not supported. It ships nginx `1.18.0`, which predates the `ngx_rbtree_data()` API this module requires, and it has no `nginx-dev` package to build a distro-native dynamic module against.

### Build a dynamic module for your installed nginx

Check your version with `nginx -v`, download that exact nginx source, and build the module against it. For `nginx/1.28.1`:

```bash
cd ~/build/nginx-cache-pilot
wget https://nginx.org/download/nginx-1.28.1.tar.gz
tar xf nginx-1.28.1.tar.gz
cd nginx-1.28.1

./configure \
    --with-compat \
    --with-threads \
    --add-dynamic-module=../ngx_cache_pilot

make modules
```

This produces `objs/ngx_http_cache_pilot_module.so`. Copy it into your nginx modules directory and load it near the top of `nginx.conf`:

```nginx
load_module modules/ngx_http_cache_pilot_module.so;
```

If a dynamic build fails at runtime with a missing `ngx_modules` symbol, that points to a packaging or build-flow problem outside the normal nginx `auto/module` path, not to your index configuration.

### Build nginx from source with the module

```bash
./configure \
    --with-debug \
    --with-threads \
    --with-http_ssl_module \
    --add-module=/path/to/ngx_cache_pilot
make
make install
```

Use `--add-dynamic-module` plus `make modules` for a dynamic build in the same workflow.

The `config` script needs no external dependency. The tag and key index lives in an nginx shared-memory zone managed by the module itself.

## Quick start

Purging is enabled per location with `proxy_cache_purge`, or the `fastcgi_`, `scgi_`, `uwsgi_` equivalent. The directive takes one or more conditions, and purge runs when at least one of them is non-empty, not `"0"`, and not `"off"`. Restricting who may purge is left to normal nginx tools such as `map`, `allow`, and `deny`.

```nginx
http {
    proxy_cache_path /tmp/cache keys_zone=tmpcache:10m;

    # Only PURGE from localhost may purge.
    map $request_method:$remote_addr $purge_request {
        default         off;
        PURGE:127.0.0.1 on;
    }

    server {
        listen 8080;

        location / {
            proxy_pass http://127.0.0.1:8000;
            proxy_cache tmpcache;
            proxy_cache_purge $purge_request;
        }
    }
}
```

Purge one URL:

```bash
curl -i -X PURGE 'http://127.0.0.1:8080/path?query=1'
```

Purge a prefix, if your cache key ends with `$uri`:

```bash
curl -i -X PURGE 'http://127.0.0.1:8080/articles/2026/*'
```

If you prefer a dedicated purge endpoint over purging on the cached location itself, give that location its own `proxy_cache` and `proxy_cache_key`:

```nginx
location ~ /purge(/.*) {
    allow 127.0.0.1;
    deny all;

    proxy_cache tmpcache;
    proxy_cache_purge $purge_request;
}
```

### Adding tags, fanout, and soft purge

Tag purging and exact-key fanout both need the index. Allocate its shared-memory zone once in `http`, then turn indexing on for the locations that should participate:

```nginx
http {
    proxy_cache_path /tmp/cache keys_zone=tmpcache:10m;

    # Shared memory for cache-tag and cache-key index metadata.
    cache_pilot_index_zone_size  32m;

    map $request_method:$remote_addr $purge_request {
        default         off;
        PURGE:127.0.0.1 on;
    }

    server {
        location /tagged/ {
            proxy_pass http://127.0.0.1:8000;
            proxy_cache tmpcache;

            # Hard purge by default.
            proxy_cache_purge $purge_request;

            # Let a request header switch a purge to soft.
            cache_pilot_purge_mode_header X-Purge-Mode;

            # Index this location's cached responses by tag and key.
            cache_pilot_index on;
        }
    }
}
```

The same `PURGE` request can now purge by tag, and switch to soft:

```bash
curl -i -X PURGE -H 'Cache-Tag: article-42, group-a' 'http://127.0.0.1:8080/tagged/item'
curl -i -X PURGE -H 'Surrogate-Key: article-42 group-a' 'http://127.0.0.1:8080/tagged/item'
curl -i -X PURGE -H 'Cache-Tag: article-42' -H 'X-Purge-Mode: soft' 'http://127.0.0.1:8080/tagged/item'
```

## Purge behavior

### Exact key, and fanout across `Vary` variants

An exact-key purge always acts on the file the request key resolves to. A hard purge deletes it, a soft purge marks it expired.

When the index is ready for that zone, the purge also fans out to the sibling files sharing the same cache key, the `Vary` variants described in [Why this fork](#why-this-fork), without walking the cache directory. If the index is not configured, or has not finished bootstrapping, the purge falls back to the single resolved file. It does not scan the whole cache to compensate, so on a zone whose index is not ready a `Vary`'d resource can keep serving other variants.

### Wildcard (partial) keys

Sometimes the purging client cannot reconstruct the exact key, because parts of it depend on cookies or query parameters. Append `*` to purge by prefix:

```bash
curl -X PURGE /page*
```

The asterisk must be the last character of the key, which means `$uri` must be last in your configured cache key.

When key-index data is ready for the zone, wildcard purges match against in-memory key metadata and avoid a filesystem walk. That is still a linear scan over the zone's indexed files rather than a prefix tree. Without index data, wildcard purges walk the cache tree on disk.

### Cache tags

With the index enabled, the module reads the headers listed in `cache_pilot_tag_headers` (`Surrogate-Key` and `Cache-Tag` by default) from each cached response and records which files carry which tags. Values split on commas and ASCII whitespace, so `Cache-Tag: a, b` and `Surrogate-Key: a b` are equivalent. Duplicates within one response are collapsed, and at most 1000 tag tokens are read per response.

To purge, send a normal `PURGE` request to a purge-enabled location with one or more tag headers. Tags match with OR semantics, so a file is purged if it carries any of the supplied tags. The request URL still has to reach a purge-enabled location, but its own cache key has no bearing on what gets purged.

A `PURGE` request to a tag-enabled location that carries no tag headers falls back to ordinary key-based purging.

Hard tag purges hand backend index deletions to the owning worker asynchronously, so a `200` means the delete work was accepted, not that the in-memory index has already caught up. Transient index-maintenance failures are logged and do not turn an otherwise successful purge into a `500`. The response reflects whether cache files were purged, not whether every index update landed.

### Soft purge

A soft purge marks matching entries expired instead of deleting them. The next request is served as `EXPIRED` rather than a cold `MISS`, which lets nginx revalidate against the upstream while still having something on disk to fall back on.

Soft mode comes from either the `soft` flag on the purge directive or, per request, from `cache_pilot_purge_mode_header`. It applies to exact-key purges including fanout, wildcard purges, and tag purges. `purge_all` honors only the configured `soft` flag and ignores the header.

For wildcard and `purge_all` soft purges the module expires both the on-disk cache header and the matching shared-memory cache node, so the next lookup is consistently treated as expired.

On hot objects, pair soft purge with nginx cache locking, or a single expiry can still release a thundering herd of concurrent upstream requests:

```nginx
proxy_cache_lock on;
proxy_cache_use_stale updating;
```

### Purge responses

Purges are idempotent. If nothing matched, the module returns a normal successful purge response with zero `purged` counters. This is a breaking change from older releases, which returned `412 Precondition Failed` on a miss. Operational declines still fail, including an index that is not ready, an unregistered zone, or an unsupported platform, so automation can tell an empty cache apart from a purge path that could not run.

JSON responses report how many entries were removed or expired, bucketed by purge type (`exact`, `wildcard`, `tag`, `all`) and mode (`hard`, `soft`), plus a `cache_pilot.purge_path` naming the route the purge took: `exact-key-fanout`, `key-prefix-index`, `reused-persisted-index`, or `filesystem-fallback`. `reused-persisted-index` means the request reused index state already built during this nginx lifetime. Nothing is persisted to disk.

## Configuration reference

Directive names here are the module's public configuration API and are intended to stay stable. New options should extend one of the existing families rather than introduce parallel spellings:

- `fastcgi_cache_purge`, `proxy_cache_purge`, `scgi_cache_purge`, `uwsgi_cache_purge` for upstream-cache purge integration
- `cache_pilot_*` for module-owned features: indexing, tag handling, response format, metrics, and tuning

### `fastcgi_cache_purge`, `proxy_cache_purge`, `scgi_cache_purge`, `uwsgi_cache_purge`

- **syntax**: `<protocol>_cache_purge string ... [soft] [purge_all]`
- **default**: `none`
- **context**: `http`, `server`, `location`

Enable purging of the corresponding cache. Purge runs when at least one condition value is non-empty, not `"0"`, and not `"off"`, matching nginx core purge semantics, with `soft` and `purge_all` as module-specific trailing flags. `soft` expires matching entries instead of deleting them. `purge_all` makes a purge request target every entry in the zone.

For a dedicated purge location, also set that location's `*_cache` zone and `*_cache_key`.

### `cache_pilot_purge_response_type`

- **syntax**: `cache_pilot_purge_response_type json|text`
- **default**: `json`
- **context**: `http`, `server`, `location`

Response format for purge results, applied in the scope where the purge response is generated. See [Purge responses](#purge-responses) for what JSON includes. `text` keeps the original plain body format.

### `cache_pilot_purge_mode_header`

- **syntax**: `cache_pilot_purge_mode_header <header>`
- **default**: `none`
- **context**: `http`, `server`, `location`

Allow a request header to override soft/hard mode:

- `soft`, `true`, or `1` forces a soft purge
- any other present value forces a hard purge
- an absent header leaves the configured mode in place
- `purge_all` ignores this override

The header only switches mode on a request that has already matched a configured purge path. It never enables purging on its own.

### `cache_pilot_index_zone_size`

- **syntax**: `cache_pilot_index_zone_size <size>`
- **default**: `32m`
- **context**: `http`

Size of the shared-memory zone holding tag and cache-key metadata. On Linux the zone is allocated at the default size even when the directive is omitted.

Usage scales with the number of indexed files, the number of distinct cache keys and tags, the number of file-tag relations, and the length of the stored keys and paths. Start at `32m` and raise it if you cache a large number of tagged objects or attach many tags per object.

### `cache_pilot_index`

- **syntax**: `cache_pilot_index on|off`
- **default**: `on` when `cache_pilot_index_zone_size` is configured and the location uses an upstream cache, otherwise `off`
- **context**: `http`, `server`, `location`

Index the cache used by this purge-enabled location, which enables tag purges, exact-key fanout, and index-assisted wildcard purges.

`cache_pilot_index off;` opts a location out of indexing. It does not release the global shared-memory zone.

### `cache_pilot_tag_headers`

- **syntax**: `cache_pilot_tag_headers <header> [header ...]`
- **default**: `Surrogate-Key Cache-Tag`
- **context**: `http`, `server`, `location`

Headers used both to extract tags from cached responses and to match tags on purge requests. Every location sharing a cache zone must configure the same list.

### `cache_pilot_stats`

- **syntax**: `cache_pilot_stats [zone ...]`
- **default**: `none`
- **context**: `location`

Expose a read-only metrics endpoint. With no arguments it reports every zone known to the module. List zone names to restrict it.

```nginx
location /_cache_stats {
    cache_pilot_stats;
}
```

The endpoint sends `Cache-Control: no-store` and supports two formats:

| Trigger                                                                              | Format          | Content-Type                |
| ------------------------------------------------------------------------------------ | --------------- | --------------------------- |
| Default, `?format=json`, or `Accept: application/json`                               | JSON            | `application/json`          |
| `?format=prometheus`, `Accept: text/plain`, or `Accept: application/openmetrics-text` | Prometheus text | `text/plain; version=0.0.4` |

Index readiness gates tag purges, so this endpoint is what deploy or purge automation should poll before it starts issuing purges.

**JSON structure** (live output, `zones` truncated to one entry):

```json
{
  "version": 1,
  "timestamp": 1776605478,
  "purges": {
    "exact": { "hard": 0, "soft": 0 },
    "wildcard": { "hard": 0, "soft": 0 },
    "tag": { "hard": 0, "soft": 6 },
    "all": { "hard": 0, "soft": 0 }
  },
  "purged": {
    "exact": { "hard": 0, "soft": 0 },
    "wildcard": { "hard": 0, "soft": 0 },
    "tag": { "hard": 0, "soft": 6 },
    "all": { "hard": 0, "soft": 0 }
  },
  "key_index": { "exact_fanout": 0, "wildcard_hits": 0 },
  "index_store": { "alloc_failures": 0 },
  "zones": {
    "zone-one": {
      "size": 35184,
      "max_size": 2251799813685247,
      "cold": false,
      "entries": { "total": 4815, "valid": 0, "expired": 4815, "updating": 0 },
      "index": {
        "state": "ready",
        "state_code": 2,
        "max_size": 33554432,
        "last_bootstrap_at": 1776605400,
        "last_updated_at": 1776605478,
        "backend": "shm"
      }
    }
  }
}
```

- `purges` counts accepted purge operations, including those matching zero entries. `purged` counts the cache entries actually removed or expired. Both use the same type and mode buckets, are global across zones, and survive `nginx -s reload`.
- `zones.<zone>.max_size` is the configured nginx cache zone limit. `index.max_size` is the `cache_pilot_index_zone_size` limit.
- `index.last_bootstrap_at` and `index.last_updated_at` are Unix epoch timestamps for the last completed bootstrap and the last index mutation.
- `index.state_code` is `0=disabled`, `1=configured`, `2=ready`. When configured but not ready, `index.not_ready_reason` explains why, with values such as `reader_unavailable`, `zone_not_registered`, or `index_not_ready`.
- `index` is omitted when the in-memory index is unavailable. `index.backend` is currently always `"shm"`.
- `index_store.alloc_failures` counts shared-memory allocation failures in the index store.

**Prometheus metrics** (prefix `nginx_cache_pilot_`):

- `purges_total{type,mode}`: counter, purge operations by type (`exact`, `wildcard`, `tag`, `all`) and mode (`hard`, `soft`)
- `purged_entries_total{type,mode}`: counter, entries removed or expired, same labels
- `key_index_total{type}`: counter, index-assisted purges by type (`exact_fanout`, `wildcard_hits`)
- `zone_size_bytes{zone}`: gauge, current zone usage
- `zone_max_size_bytes{zone}`: gauge, configured maximum nginx cache zone size
- `zone_cold{zone}`: gauge, `1` while the cache loader is still warming the zone
- `zone_entries{zone,state}`: gauge, entry count by state (`valid`, `expired`, `updating`)
- `index_max_size_bytes{zone}`: gauge, configured maximum index size
- `index_alloc_failures_total`: counter, shared-memory allocation failures
- `index_last_bootstrap_at_seconds{zone}`, `index_last_updated_at_seconds{zone}`: gauges, Unix epoch timestamps
- `index_not_ready{zone,reason}`: gauge, present with value `1` when a configured index is not ready
- `index_state{zone,state}`: gauge, `0=disabled`, `1=configured`, `2=ready`
- `index_info{zone,backend}`: info gauge, index backend type

## How the index works

Useful when diagnosing memory growth, planning capacity, or modifying the module.

The index holds three things, all in one nginx shared-memory zone sized by `cache_pilot_index_zone_size`: tag-to-file associations for tag purges, key-to-files associations for exact-key fanout, and per-file cache-key metadata reused by wildcard prefix matching. Shared memory is the only backend, and the module does not expose backend selection.

**Startup bootstrap.** The index is memory-only and does not survive a process restart. It is rebuilt from the cache files themselves. Bootstrap waits until nginx marks the cache zone warm (`cold=0`), then walks the cache tree once, reading each cached response header and extracting tags. Only after that does the zone count as ready for indexed tag purges. Requests never trigger a synchronous bootstrap. If the index is not ready, an indexed purge declines.

Rebuild time is roughly linear in the number of cache files and the cost of reading their headers, so a large cache can take seconds to minutes to become ready after a restart. Gate purge automation on `cache_pilot_stats`.

**Staying fresh.** After bootstrap there is no filesystem watcher. A header filter captures the tag headers of cacheable upstream responses, and a log-phase handler commits the file's metadata into shared memory when the response completes, so newly cached responses are indexed by the worker that served them and are visible almost immediately.

**Reads.** Tag purges look up paths in the tag index once the zone is ready. Exact-key fanout looks up siblings in the key index. Wildcard purges scan in-memory per-file key metadata before deciding whether a filesystem walk is needed.

**Writes.** Hard purges delete the cache file and drop the corresponding index entry in the same request path. Soft purges leave the index entry in place and mark the shared-memory cache node expired.

## Known issues

- Exact-key fanout across `Vary` variants depends on index readiness. When the index is unavailable or still bootstrapping, an exact-key purge targets only the directly resolved file and does not fall back to a full cache scan.
- Wildcard purges use a linear scan over in-memory key metadata even when the index is ready. That avoids the filesystem walk but is not a dedicated prefix index.
- Soft purge does not enforce `proxy_cache_lock` or `proxy_cache_use_stale updating`. Without them, expiring a hot object can still trigger concurrent upstream refreshes.
- Cache manager expirations can leave stale index entries behind temporarily. They are removed lazily when a purge path hits `ENOENT` for the file.
- Cache-tag and cache-key indexing are Linux-only, including in packaged dynamic-module installs.

## Development

The repository ships two containers: `dev` for building, testing, and manual validation, and `packaging` for Debian package work. The `dev` image carries Debian build tooling, nginx source in `/opt/nginx-src/nginx-$NGINX_VERSION`, a prebuilt nginx at `/opt/nginx/sbin/nginx`, and `Test::Nginx` from `openresty/test-nginx`.

```bash
make shell         # interactive dev container
make nginx-build
make format
make test
make bench-quick
```

Both images are published: `ghcr.io/wpelevator/ngx-cache-pilot--dev:<nginx-version>` for each nginx version validated in CI, and `ghcr.io/wpelevator/ngx-cache-pilot--packaging`. `docker compose build dev` and `docker compose build packaging` rebuild them locally when you are changing the containers themselves.

In GitHub Codespaces the `.devcontainer` is already the development environment, so run `make` targets directly. The docker-compose workflow described here is for local development only.

### Manual validation

`examples/kitchen-sink.conf` exercises every purge style in one config. Start it inside the dev container:

```bash
make shell
make nginx-build
rm -rf /tmp/ngx_cache_*
/opt/nginx/sbin/nginx -p /tmp -c ./examples/kitchen-sink.conf
```

Stop it with `kill "$(cat /tmp/ngx-cache-pilot-validation.pid)"`.

Every flow follows the same shape: fetch a URL until `X-Cache-Status: HIT`, purge, then fetch again and check the status. All of these locations are configured for soft purge, so the expected post-purge status is `EXPIRED` rather than `MISS`.

| Location             | Purge command                                                                              | Check                                                            |
| -------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| `/soft/item?t=soft`  | `curl -i -X PURGE 'http://127.0.0.1:8080/soft/item?t=soft'`                                 | Next fetch `EXPIRED`, the one after `HIT`                         |
| `/stale/item?t=demo` | `curl -i -X PURGE 'http://127.0.0.1:8080/stale/item?t=demo'`                                | Then `curl -H 'X-Origin-Fail: 1' …` returns `STALE` on upstream `500` |
| `/wild/pass-*`       | `curl -i -X PURGE 'http://127.0.0.1:8080/wild/pass*'`                                       | `pass-one`/`pass-two` `EXPIRED`, `/wild/other` still `HIT`        |
| `/purge_all/*`       | `curl -i -X PURGE 'http://127.0.0.1:8080/purge_all/anything'`                               | Every `/purge_all/…` entry `EXPIRED`                             |
| `/separate/item`     | `curl -i -X PURGE 'http://127.0.0.1:8080/purge_separate/separate/item?t=sep'`                | `/separate/item?t=sep` `EXPIRED`, purged from a separate location |
| `/tagged/a`,`b`,`c`  | `curl -i -X PURGE -H 'Surrogate-Key: group-one' 'http://127.0.0.1:8080/tagged/a'`            | The two `group-one` entries `EXPIRED`, `/tagged/c` still `HIT`    |
| `/tagged/a`,`b`,`c`  | `curl -i -X PURGE -H 'Cache-Tag: shared' 'http://127.0.0.1:8080/tagged/a'`                   | Same, matched by the other tag header                            |
| `/tagged/plain`      | `curl -i -X PURGE 'http://127.0.0.1:8080/tagged/plain'`                                      | `EXPIRED`, a tag location falling back to key purge with no tags  |
| `/tagged_custom`     | `curl -i -X PURGE -H 'Custom-Group: custom-alpha' 'http://127.0.0.1:8080/tagged_custom'`     | `EXPIRED`, using custom `cache_pilot_tag_headers` on its own zone |
| `/_stats`            | `curl -s 'http://127.0.0.1:8080/_stats'` / `?format=prometheus`                              | `purges` counters increment after the flows above                 |

### Benchmarks

`bench/` holds a container-only harness measuring purge performance under concurrent GET load. Feature validation for index readiness, fanout, and wildcard assist lives in the `Test::Nginx` suite (`t/proxy_key_index.t`), so the benchmark stays focused on steady-state throughput and latency.

```bash
make shell
make nginx-build
make bench-quick
make bench
cat ./bench/results/latest/summary.md
```

One run covers all scenarios against a single nginx runtime: `exact-baseline`, cache-tag soft purge with the shm index (`tag-shm`), `exact-scan`, `exact-index` with `Vary` siblings, `wildcard-scan` using the filesystem walk, and `wildcard-index`. Each warms 1000 cached objects, starts 50 keep-alive GET workers, then runs a sequential PURGE worker alongside them while collecting GET throughput and latency percentiles, cache hit rate and `X-Cache-Status` breakdown, purge throughput and latency, and `cache_pilot_stats` snapshots before and after.

The indexed wildcard scenario runs a short preflight first to confirm the harness can observe the `wildcard_hits` counter. If it cannot prove the assist path, it records `not-rdy` with diagnostics rather than reporting a misleading number. The summary's `Valid` column flags this: `❌ invalid` means the run hit `not-rdy` or `miss-rdy` and should be read as a readiness failure rather than a performance measurement.

Results land in `bench/results/<timestamp>/`, one JSON per scenario plus `summary.json`, `summary.md`, and nginx logs, with `bench/results/latest` symlinked to the most recent run. On pull requests the benchmark workflow aggregates per-nginx-version summaries into a sticky PR comment.

`bench/bench.pl --assert-file <path>` fails a run on threshold regressions. The file is JSON with optional `defaults` and per-scenario rules keyed by scenario id. Metrics are dot-paths into the summary (`get.rps`, `get.cache_hit_rate`, `get.latency_us.p95`, `purge.rps`), each supporting `min` and `max`. See `bench/assertions.example.json`.

### Packaging

```bash
docker compose pull packaging
docker compose run --rm packaging make debian-package-smoke
```

The same container prepares Launchpad PPA source uploads. Launchpad builds the published `.deb` files from a signed source package, and local binary builds stay available through `make debian-package` and `make debian-package-smoke`.

```bash
docker compose run --rm packaging make debian-source-package \
  DEBIAN_DISTRIBUTION=noble \
  DEBIAN_VERSION_SUFFIX=+ppa1~noble1
```

To sign and upload, supply a Launchpad-registered GPG key id. If `DEBIAN_GPG_PRIVATE_KEY` is set, the signed target imports it before signing, otherwise it uses the container's existing keyring. In CI the workflow passes `LAUNCHPAD_GPG_PRIVATE_KEY` as armored private key text and `LAUNCHPAD_GPG_KEY_ID` as the signing key id, which the Make targets accept as fallbacks for the generic `DEBIAN_GPG_*` variables.

```bash
docker compose run --rm \
  -e DEBIAN_GPG_KEY_ID \
  -e DEBIAN_GPG_PRIVATE_KEY \
  packaging make launchpad-ppa-upload \
    DEBIAN_DISTRIBUTION=noble \
    DEBIAN_VERSION_SUFFIX=+ppa1~noble1
```

### Versioning and releases

The Git tag is the upstream module version, a plain semantic version such as `1.2.0`, matching the GitHub release and the `CHANGELOG.md` entry.

`debian/changelog` carries the Debian package version: `1.2.0-1` for the first upload of upstream `1.2.0`, bumping only the Debian revision (`1.2.0-2` and so on) to republish the same upstream release. Keep its notes aligned with `CHANGELOG.md`, but keep both files. Debian tooling reads `debian/changelog` directly and needs it in Debian changelog format.

PPA uploads append an Ubuntu-series suffix (`+ppa1~noble1`, `+ppa1~resolute1`) in a temporary tree under `.pkg-build/`, leaving the working-tree `debian/changelog` untouched. Increment the `ppa` revision when rebuilding the same Debian version for Launchpad, and keep the series part alphabetically ordered against the series it targets so an Ubuntu upgrade always sees an increasing version. When `DEBIAN_DISTRIBUTION` is unset, source builds keep the distribution from `debian/changelog`.

`debian-orig-tarball` generates the upstream `.orig.tar.gz` once. The PPA workflow uploads it as an artifact and restores it for each series, so Launchpad never sees two different tarballs under one filename.

The `Publish Launchpad PPA` workflow publishes `noble` and `resolute` uploads to `ppa:wpelevator/packages`. It runs automatically on a plain semantic-version tag push, verifies the tag matches the upstream version in `debian/changelog`, and uses PPA revision `1`. Manual dispatch remains available for older tags and for retries with an incremented revision. It requires the repository secrets `LAUNCHPAD_GPG_KEY_ID` and `LAUNCHPAD_GPG_PRIVATE_KEY`.

Before tagging:

```bash
docker compose run --rm packaging make debian-release-version-check RELEASE_VERSION="$RELEASE_VERSION"
docker compose build dev
docker compose run --rm dev make format
docker compose run --rm dev make test
docker compose pull packaging
docker compose run --rm packaging make debian-package-smoke
docker compose run --rm packaging make debian-source-package DEBIAN_DISTRIBUTION=noble DEBIAN_VERSION_SUFFIX=+ppa1~noble1
docker compose run --rm packaging make debian-source-package DEBIAN_DISTRIBUTION=resolute DEBIAN_VERSION_SUFFIX=+ppa1~resolute1
```

`debian-release-version-check` is the same gate the tag-triggered workflow runs, so running it locally catches a `debian/changelog` mismatch before the tag is pushed.

Release checklist:

1. Move `## UNRELEASED` notes in `CHANGELOG.md` into a dated release entry and reopen `## UNRELEASED`.
2. Update the top `debian/changelog` entry to the release version with the same notes in Debian format.
3. Commit the release preparation.
4. Tag the upstream version, for example `git tag -a 1.2.0 -m "Release 1.2.0"`.
5. Push the release commit, let the test workflow finish, then push the tag and publish the GitHub release.

Pushing the tag starts the PPA upload, and Launchpad rejects a re-upload of a version it has already accepted. If a bad upload lands, recover by dispatching the workflow again with an incremented PPA revision rather than by re-tagging.

## License

```text
Copyright (c) 2009-2014, FRiCKLE <info@frickle.com>
Copyright (c) 2009-2014, Piotr Sikora <piotr.sikora@frickle.com>
All rights reserved.

This project was fully funded by yo.se.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## See also

- [ngx_cache_purge](https://github.com/nginx-modules/ngx_cache_purge), the upstream module this is forked from
- [ngx_slowfs_cache](http://github.com/FRiCKLE/ngx_slowfs_cache)
- [nginx `fastcgi_cache_purge` (NGINX Plus)](http://nginx.org/en/docs/http/ngx_http_fastcgi_module.html#fastcgi_cache_purge) and [`purger`](http://nginx.org/en/docs/http/ngx_http_fastcgi_module.html#purger)
- [nginx-selective-cache-purge-module](https://github.com/wandenberg/nginx-selective-cache-purge-module)
- [nginx-sorted-querystring-module](https://github.com/wandenberg/nginx-sorted-querystring-module)
- [ledge](https://github.com/ledgetech/ledge)
- [Faking Surrogate Cache-Keys for Nginx Plus](https://www.innoq.com/en/blog/faking-surrogate-cache-keys-for-nginx-plus/) ([gist](https://gist.github.com/titpetric/2f142e89eaa0f36ba4e4383b16d61474))
- [Delete NGINX cached md5 items with a PURGE with wildcard support](https://gist.github.com/nosun/0cfb58d3164f829e2f027fd37b338ede)
