# vi:filetype=perl

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::Nginx::CachePurge;

repeat_each(1);

plan tests => repeat_each() * (blocks() * 4 + 3 * 1);

our $http_config = Test::Nginx::CachePurge::cache_http_config();

our $config = <<'_EOC_';
    location /proxy {
        proxy_pass         $scheme://127.0.0.1:$server_port/etc/passwd;
        proxy_cache        test_cache;
        proxy_cache_key    $uri$is_args$args;
        proxy_cache_valid  3m;
        add_header         X-Cache-Status $upstream_cache_status;
    }

    location ~ /purge(/.*) {
        proxy_cache        test_cache;
        proxy_cache_key    $1$is_args$args;
        proxy_cache_purge  1;
    }

    location = /etc/passwd {
        root               /;
    }
_EOC_

Test::Nginx::CachePurge::set_default_http_config(
    http_config => $http_config,
);

Test::Nginx::CachePurge::add_default_block_config(
    config => $config,
    timeout => 10,
);

worker_connections(128);
no_shuffle();
run_tests();

no_diff();

__DATA__

=== TEST 1: prepare
--- request
GET /proxy/passwd
--- error_code: 200
--- response_headers
Content-Type: text/plain
--- response_body_like: root
--- no_error_log eval
qr/\[(warn|error|crit|alert|emerg)\]/
--- skip_nginx2: 4: < 0.8.3 or < 0.7.62



=== TEST 2: get from cache
--- request
GET /proxy/passwd
--- error_code: 200
--- response_headers
Content-Type: text/plain
X-Cache-Status: HIT
--- response_body_like: root
--- no_error_log eval
qr/\[(warn|error|crit|alert|emerg)\]/
--- skip_nginx2: 5: < 0.8.3 or < 0.7.62



=== TEST 3: purge from cache
--- request
PURGE /purge/proxy/passwd
--- error_code: 200
--- response_headers
Content-Type: application/json
--- response_body_like: \{\"key\": 
--- no_error_log eval
qr/\[(warn|error|crit|alert|emerg)\]/
--- skip_nginx2: 4: < 0.8.3 or < 0.7.62



=== TEST 4: purge from empty cache
--- request
PURGE /purge/proxy/passwd
--- error_code: 412
--- response_headers
Content-Type: text/html
--- response_body_like: 412 Precondition Failed
--- no_error_log eval
qr/\[(warn|error|crit|alert|emerg)\]/
--- skip_nginx2: 4: < 0.8.3 or < 0.7.62



=== TEST 5: get from source
--- request
GET /proxy/passwd
--- error_code: 200
--- response_headers
Content-Type: text/plain
X-Cache-Status: MISS
--- response_body_like: root
--- no_error_log eval
qr/\[(warn|error|crit|alert|emerg)\]/
--- skip_nginx2: 5: < 0.8.3 or < 0.7.62



=== TEST 6: get from cache
--- request
GET /proxy/passwd
--- error_code: 200
--- response_headers
Content-Type: text/plain
X-Cache-Status: HIT
--- response_body_like: root
--- no_error_log eval
qr/\[(warn|error|crit|alert|emerg)\]/
--- skip_nginx2: 5: < 0.8.3 or < 0.7.62
