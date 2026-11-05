# Changelog

## UNRELEASED

### Added

- CI builds, tests, and benchmarks against nginx `1.30.6` (latest stable) and `1.31.8` (latest mainline); source builds and the full `Test::Nginx` suite pass on both versions.

### Changed

- CI matrix covers the oldest validated nginx (`1.26.3`), latest stable (`1.30.6`), and latest mainline (`1.31.8`); intermediate `1.28.3` and `1.29.8` pins were dropped because no code special-cases those releases.
- Default local nginx version for development, dev-image builds, and dev-image tags changed from `1.25.5` to latest mainline (`1.31.8`).
- Corrected the documented dev image tag `ghcr.io/wpelevator/ngx-cache-pilot--dev:1.0.0-nginx-<nginx-version>` in the development workflow docs.

- Publish Ubuntu 26.04 (`resolute`) PPA source uploads alongside `noble`.
- Document installing the module from `ppa:wpelevator/packages` in the packaged install instructions.
- Document the minimum supported nginx version of `1.21.4`.

### Changed

- Rewrote `README.md`: deduplicated sections that had accumulated over time, added a table of contents, explained what a distro nginx ABI is and how `Vary` turns one cache key into several cache files, and stated up front how the module differs from `ngx_cache_purge` (cache tags, soft purge, indexed fanout instead of a per-purge cache-directory walk, metrics endpoint). Removed a stale note claiming the trailing purge argument is stored as a literal string; every condition is compiled as a complex value.
- Run Launchpad publishing to `ppa:wpelevator/packages` automatically for semantic-version tag pushes and reject tags that do not match the upstream version in `debian/changelog`.

### Removed

- Stop publishing Ubuntu 22.04 (`jammy`) PPA uploads. Jammy ships nginx `1.18.0`, which lacks the `ngx_rbtree_data()` API this module requires, and provides no `nginx-dev` or `nginx-abi-*` packages, so its builds could never produce an installable package.

## 2.0.0 - 2026-07-29

### Changed

- Purge misses are now idempotent: known not-found results return `200` with zero purged counters instead of `412`. Clients that need to detect no-op purges must inspect the response counters.

### Fixed

- Hardened purge-miss accounting so only explicit not-found declines are accepted as successful misses; unknown decline reasons still fail closed.
- Kept cache-key indexing correct for cache writes without tags.

## 1.2.0 - 2026-06-10

### Added

- Added Ubuntu PPA source-package publishing for Jammy and Noble.
- Added published development and packaging container images.
- Exposed cache-index health diagnostics and added benchmark summaries to pull requests.
- Expanded tests for conditional locations, purge accounting, index readiness, diagnostics, and response types.

### Changed

- Reused source artifacts between PPA uploads and prebuilt container images in CI.
- Removed the redundant runtime `NGINX_CACHE` guard because cache support is a build-time requirement.
- Documented release versioning and container-based packaging workflows.

### Fixed

- Inherited purge handlers correctly in child locations created by `if`.
- Corrected hard-purge accounting and stale cache-index cleanup.
- Marked the cache index ready after cache writes without tags.
- Improved Docker build performance.

## 1.1.0 - 2026-05-21

### Added

- Added a GitHub Codespaces development container for the build and test workflow.

### Changed

- Moved the `NGINX_CACHE` requirement check from runtime code to the NGINX module build configuration.

## 1.0.0 - 2026-04-21

- First reference release of the fork.
