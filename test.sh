#!/usr/bin/env bash
#
# Test suite for nginx JSON-RPC Proxy
#
# Spins up a mock JSON-RPC backend and the proxy in Docker containers,
# then runs tests against every filtering mode and edge case.
#
# Requirements: docker, curl
#
# Usage: ./test.sh
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────

IMAGE_NAME="jsonrpc-proxy"
NETWORK="jsonrpc-test-$$"
MOCK_NAME="jsonrpc-mock-$$"
PROXY_NAME="jsonrpc-proxy-$$"
PROXY_PORT=18545
MOCK_PORT=9999

# ── Output ─────────────────────────────────────────────────────────────────

PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    echo "  PASS  $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo "  FAIL  $1"
    [[ -n "${2:-}" ]] && echo "        $2"
    return 0
}

# ── HTTP helpers ───────────────────────────────────────────────────────────

RESPONSE_STATUS=""
RESPONSE_BODY=""
RESPONSE_HEADERS=""

do_request() {
    local output
    output=$(curl -s -w "\n%{http_code}" "$@" 2>&1) || true
    RESPONSE_STATUS=$(echo "$output" | tail -1)
    RESPONSE_BODY=$(echo "$output" | sed '$d')
    RESPONSE_HEADERS=""
}

do_request_with_headers() {
    local tmpfile
    tmpfile=$(mktemp)
    local output
    output=$(curl -s -D "$tmpfile" -w "\n%{http_code}" "$@" 2>&1) || true
    RESPONSE_STATUS=$(echo "$output" | tail -1)
    RESPONSE_BODY=$(echo "$output" | sed '$d')
    RESPONSE_HEADERS=$(cat "$tmpfile")
    rm -f "$tmpfile"
}

assert_header() {
    local name="$1" pattern="$2"
    if echo "$RESPONSE_HEADERS" | grep -qiF -- "$pattern"; then
        pass "$name"
    else
        fail "$name" "headers do not contain: $pattern"
    fi
}

assert_status() {
    local name="$1" expected="$2"
    if [[ "$RESPONSE_STATUS" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected HTTP $expected, got $RESPONSE_STATUS"
    fi
}

assert_contains() {
    local name="$1" pattern="$2"
    if echo "$RESPONSE_BODY" | grep -qF -- "$pattern"; then
        pass "$name"
    else
        fail "$name" "body does not contain: $pattern"
    fi
}

assert_not_contains() {
    local name="$1" pattern="$2"
    if echo "$RESPONSE_BODY" | grep -qF -- "$pattern"; then
        fail "$name" "body unexpectedly contains: $pattern"
    else
        pass "$name"
    fi
}

rpc() {
    local method="$1" id="${2:-1}"
    echo "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":$id}"
}

post_rpc() {
    do_request -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" \
        -d "$1"
}

# ── Docker helpers ─────────────────────────────────────────────────────────

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker rm -f "$PROXY_NAME" "$MOCK_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
    local url="$1" seconds="${2:-15}" i=0
    while ! curl -sf "$url" >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ $i -ge $seconds ]]; then
            echo "ERROR: $url not reachable after ${seconds}s" >&2
            return 1
        fi
        sleep 1
    done
}

start_proxy() {
    docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true

    local env_args=(-e "LISTEN_PORT=8000" -e "BACKEND_HOST=$MOCK_NAME" -e "BACKEND_PORT=$MOCK_PORT")
    while [[ $# -gt 0 ]]; do
        env_args+=(-e "$1")
        shift
    done

    docker run -d --name "$PROXY_NAME" --network "$NETWORK" \
        -p "$PROXY_PORT:8000" "${env_args[@]}" "$IMAGE_NAME" >/dev/null

    wait_healthy "http://localhost:$PROXY_PORT/health"
}

stop_proxy() {
    docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
}

# ── Mock backend ───────────────────────────────────────────────────────────

start_mock() {
    docker run -d --name "$MOCK_NAME" --network "$NETWORK" \
        python:3-alpine sh -c 'cat > /tmp/mock.py << "PYEOF"
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        auth = self.headers.get("Authorization", "")
        path = self.path
        try:
            data = json.loads(body)
            if isinstance(data, list):
                resp = [
                    {"jsonrpc": "2.0", "result": {"ok": True, "auth": auth, "path": path}, "id": r.get("id")}
                    for r in data
                ]
            else:
                resp = {"jsonrpc": "2.0", "result": {"ok": True, "auth": auth, "path": path}, "id": data.get("id")}
        except Exception:
            resp = {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": None}
        out = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *_):
        pass

HTTPServer(("0.0.0.0", 9999), Handler).serve_forever()
PYEOF
python3 /tmp/mock.py' >/dev/null
    sleep 2
}

# ── Tests: health & basic validation ───────────────────────────────────────

test_health() {
    echo ""
    echo "Health endpoint"

    do_request "http://localhost:$PROXY_PORT/health"
    assert_status "GET /health returns 200" "200"
    assert_contains "body contains status ok" '"status":"ok"'

    do_request -X POST "http://localhost:$PROXY_PORT/health"
    assert_status "POST /health returns 200" "200"
}

test_http_methods() {
    echo ""
    echo "HTTP method enforcement"

    do_request "http://localhost:$PROXY_PORT/"
    assert_status "GET returns 405" "405"
    assert_contains "GET error message" "Only POST method is allowed"

    do_request -X PUT "http://localhost:$PROXY_PORT/"
    assert_status "PUT returns 405" "405"

    do_request -X DELETE "http://localhost:$PROXY_PORT/"
    assert_status "DELETE returns 405" "405"
}

test_invalid_requests() {
    echo ""
    echo "Invalid requests"

    do_request -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" -d ""
    assert_status "empty body returns 400" "400"
    assert_contains "empty body error" "Empty request body"

    do_request -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" -d "not json"
    assert_status "invalid JSON returns 400" "400"
    assert_contains "invalid JSON error" "Invalid JSON"

    do_request -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1}'
    assert_status "missing method field returns 200" "200"
    assert_contains "missing method error" "Missing or invalid"
}

# ── Tests: allow all ───────────────────────────────────────────────────────

test_allow_all() {
    echo ""
    echo "Allow all methods"

    post_rpc "$(rpc eth_blockNumber)"
    assert_status "eth_blockNumber proxied" "200"
    assert_contains "eth_blockNumber reaches backend" '"ok": true'

    post_rpc "$(rpc eth_sendTransaction)"
    assert_status "eth_sendTransaction proxied" "200"
    assert_contains "eth_sendTransaction reaches backend" '"ok": true'

    post_rpc "$(rpc any_method_at_all)"
    assert_status "arbitrary method proxied" "200"
    assert_contains "arbitrary method reaches backend" '"ok": true'
}

# ── Tests: blacklist ───────────────────────────────────────────────────────

test_blacklist() {
    echo ""
    echo "Blacklist filtering"

    post_rpc "$(rpc eth_blockNumber)"
    assert_status "non-blocked method allowed" "200"
    assert_contains "non-blocked method reaches backend" '"ok": true'

    post_rpc "$(rpc eth_sendTransaction)"
    assert_status "blocked method returns 200" "200"
    assert_contains "blocked method error code" "-90"
    assert_contains "blocked method error message" "Method not allowed"
    assert_contains "error names the method" "eth_sendTransaction"

    post_rpc "$(rpc eth_sign)"
    assert_status "second blocked method returns 200" "200"
    assert_contains "second blocked method rejected" "Method not allowed"

    post_rpc "$(rpc eth_call)"
    assert_status "unlisted method allowed" "200"
    assert_contains "unlisted method reaches backend" '"ok": true'
}

# ── Tests: whitelist ───────────────────────────────────────────────────────

test_whitelist() {
    echo ""
    echo "Whitelist filtering"

    post_rpc "$(rpc eth_call)"
    assert_status "whitelisted method allowed" "200"
    assert_contains "whitelisted method reaches backend" '"ok": true'

    post_rpc "$(rpc eth_blockNumber)"
    assert_status "second whitelisted method allowed" "200"
    assert_contains "second whitelisted method reaches backend" '"ok": true'

    post_rpc "$(rpc eth_sendTransaction)"
    assert_status "non-whitelisted method returns 200" "200"
    assert_contains "non-whitelisted method rejected" "Method not allowed"

    post_rpc "$(rpc net_version)"
    assert_status "another non-whitelisted method returns 200" "200"
    assert_contains "another non-whitelisted method rejected" "Method not allowed"
}

# ── Tests: blacklist wins over whitelist ───────────────────────────────────

test_blacklist_precedence() {
    echo ""
    echo "Blacklist takes precedence over whitelist"

    post_rpc "$(rpc eth_call)"
    assert_status "whitelisted and not blacklisted: allowed" "200"
    assert_contains "passes through to backend" '"ok": true'

    post_rpc "$(rpc eth_sendRawTransaction)"
    assert_status "whitelisted but also blacklisted: blocked" "200"
    assert_contains "blacklist wins" "Method not allowed"
    assert_contains "error names the method" "eth_sendRawTransaction"
}

# ── Tests: batch requests ──────────────────────────────────────────────────

test_batch_allowed() {
    echo ""
    echo "Batch requests - all allowed"

    post_rpc '[
        {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
        {"jsonrpc":"2.0","method":"eth_call","params":[],"id":2}
    ]'
    assert_status "batch with allowed methods returns 200" "200"
    assert_contains "batch proxied to backend" '"ok": true'
}

test_batch_blocked() {
    echo ""
    echo "Batch requests - one method blocked"

    post_rpc '[
        {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
        {"jsonrpc":"2.0","method":"eth_sendTransaction","params":[],"id":2}
    ]'
    assert_status "batch with blocked method returns 200" "200"
    assert_contains "batch rejected" "Method not allowed"
    assert_contains "error names blocked method" "eth_sendTransaction"
    assert_not_contains "backend not reached" '"ok": true'
}

# ── Tests: authorization header ────────────────────────────────────────────

test_auth_override() {
    echo ""
    echo "Authorization header override"

    post_rpc "$(rpc eth_blockNumber)"
    assert_status "request with auth override succeeds" "200"
    assert_contains "backend receives override token" "Bearer my-secret-token"

    do_request -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer client-token" \
        -d "$(rpc eth_blockNumber)"
    assert_status "client auth header ignored when override set" "200"
    assert_contains "backend still gets override token" "Bearer my-secret-token"
    assert_not_contains "client token not forwarded" "client-token"
}

test_auth_passthrough() {
    echo ""
    echo "Authorization header passthrough"

    do_request -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer client-token" \
        -d "$(rpc eth_blockNumber)"
    assert_status "client auth forwarded" "200"
    assert_contains "backend receives client token" "Bearer client-token"
}

test_auth_absent() {
    echo ""
    echo "No authorization header"

    post_rpc "$(rpc eth_blockNumber)"
    assert_status "request without auth succeeds" "200"
    assert_contains "backend receives empty auth" '"auth": ""'
}

# ── Tests: CORS ────────────────────────────────────────────────────────

test_cors() {
    echo ""
    echo "CORS handling"

    do_request_with_headers -X OPTIONS "http://localhost:$PROXY_PORT/"
    assert_status "OPTIONS preflight returns 204" "204"
    assert_header "OPTIONS has Access-Control-Allow-Origin" "Access-Control-Allow-Origin: *"
    assert_header "OPTIONS has Access-Control-Allow-Methods" "Access-Control-Allow-Methods: POST, OPTIONS"
    assert_header "OPTIONS has Access-Control-Allow-Headers" "Access-Control-Allow-Headers: Content-Type, Authorization"

    do_request_with_headers -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" \
        -d "$(rpc eth_blockNumber)"
    assert_status "POST response returns 200" "200"
    assert_header "POST has Access-Control-Allow-Origin" "Access-Control-Allow-Origin: *"

    do_request_with_headers "http://localhost:$PROXY_PORT/health"
    assert_status "health returns 200" "200"
    assert_header "health has Access-Control-Allow-Origin" "Access-Control-Allow-Origin: *"
}

# ── Tests: subpath ─────────────────────────────────────────────────────

test_subpath() {
    echo ""
    echo "Subpath and query parameter handling"

    do_request -X POST "http://localhost:$PROXY_PORT/json_rpc" \
        -H "Content-Type: application/json" \
        -d "$(rpc eth_blockNumber)"
    assert_status "POST /json_rpc proxied" "200"
    assert_contains "POST /json_rpc reaches backend" '"ok": true'
    assert_contains "backend sees /json_rpc path" '"path": "/json_rpc"'

    do_request -X POST "http://localhost:$PROXY_PORT/json_rpc?apikey=test123" \
        -H "Content-Type: application/json" \
        -d "$(rpc eth_blockNumber)"
    assert_status "POST /json_rpc?apikey=... proxied" "200"
    assert_contains "query params forwarded to backend" '"path": "/json_rpc?apikey=test123"'

    do_request_with_headers -X OPTIONS "http://localhost:$PROXY_PORT/json_rpc"
    assert_status "OPTIONS /json_rpc returns 204" "204"
    assert_header "OPTIONS /json_rpc has CORS origin" "Access-Control-Allow-Origin: *"

    do_request -X GET "http://localhost:$PROXY_PORT/json_rpc"
    assert_status "GET /json_rpc returns 405" "405"

    do_request_with_headers -X POST "http://localhost:$PROXY_PORT/json_rpc" \
        -H "Content-Type: application/json" \
        -d "$(rpc eth_blockNumber)"
    assert_header "POST /json_rpc has CORS origin" "Access-Control-Allow-Origin: *"
}

# ── Tests: custom CORS ────────────────────────────────────────────────

assert_no_header() {
    local name="$1" pattern="$2"
    if echo "$RESPONSE_HEADERS" | grep -qiF -- "$pattern"; then
        fail "$name" "headers unexpectedly contain: $pattern"
    else
        pass "$name"
    fi
}

test_cors_custom_origin() {
    echo ""
    echo "CORS with custom origin"

    do_request_with_headers -X OPTIONS "http://localhost:$PROXY_PORT/"
    assert_status "OPTIONS returns 204" "204"
    assert_header "OPTIONS has custom origin" "Access-Control-Allow-Origin: https://example.com"

    do_request_with_headers -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" \
        -d "$(rpc eth_blockNumber)"
    assert_status "POST succeeds" "200"
    assert_header "POST has custom origin" "Access-Control-Allow-Origin: https://example.com"

    do_request_with_headers "http://localhost:$PROXY_PORT/health"
    assert_header "health has custom origin" "Access-Control-Allow-Origin: https://example.com"
}

test_cors_disabled() {
    echo ""
    echo "CORS disabled (empty CORS_ALLOW_ORIGIN)"

    do_request_with_headers -X OPTIONS "http://localhost:$PROXY_PORT/"
    assert_status "OPTIONS still returns 204" "204"
    assert_no_header "OPTIONS has no CORS origin" "Access-Control-Allow-Origin"

    do_request_with_headers -X POST "http://localhost:$PROXY_PORT/" \
        -H "Content-Type: application/json" \
        -d "$(rpc eth_blockNumber)"
    assert_status "POST succeeds" "200"
    assert_no_header "POST has no CORS origin" "Access-Control-Allow-Origin"

    do_request_with_headers "http://localhost:$PROXY_PORT/health"
    assert_no_header "health has no CORS origin" "Access-Control-Allow-Origin"
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    echo "nginx JSON-RPC Proxy - Test Suite"
    echo ""

    echo "Building proxy image..."
    docker build -t "$IMAGE_NAME" . >/dev/null 2>&1

    echo "Creating test network..."
    docker network create "$NETWORK" >/dev/null

    echo "Starting mock backend..."
    start_mock

    # ── Allow all ──────────────────────────────────────────────────────
    echo ""
    echo "== Proxy config: ALLOWED_METHODS=* =="
    start_proxy "ALLOWED_METHODS=*" "BLOCKED_METHODS="
    test_health
    test_http_methods
    test_invalid_requests
    test_allow_all
    test_batch_allowed
    test_cors
    test_subpath
    stop_proxy

    # ── Blacklist ──────────────────────────────────────────────────────
    echo ""
    echo "== Proxy config: ALLOWED_METHODS=*  BLOCKED=eth_sendTransaction,eth_sign =="
    start_proxy "ALLOWED_METHODS=*" "BLOCKED_METHODS=eth_sendTransaction,eth_sign"
    test_blacklist
    test_batch_blocked
    stop_proxy

    # ── Whitelist ──────────────────────────────────────────────────────
    echo ""
    echo "== Proxy config: ALLOWED_METHODS=eth_call,eth_blockNumber =="
    start_proxy "ALLOWED_METHODS=eth_call,eth_blockNumber" "BLOCKED_METHODS="
    test_whitelist
    stop_proxy

    # ── Blacklist precedence ───────────────────────────────────────────
    echo ""
    echo "== Proxy config: ALLOWED=eth_call,eth_sendRawTransaction  BLOCKED=eth_sendRawTransaction =="
    start_proxy "ALLOWED_METHODS=eth_call,eth_sendRawTransaction" "BLOCKED_METHODS=eth_sendRawTransaction"
    test_blacklist_precedence
    stop_proxy

    # ── Auth override ──────────────────────────────────────────────────
    echo ""
    echo "== Proxy config: AUTHORIZATION_HEADER_OVERRIDE=Bearer my-secret-token =="
    start_proxy "ALLOWED_METHODS=*" "AUTHORIZATION_HEADER_OVERRIDE=Bearer my-secret-token"
    test_auth_override
    stop_proxy

    # ── Auth passthrough ───────────────────────────────────────────────
    echo ""
    echo "== Proxy config: no auth override =="
    start_proxy "ALLOWED_METHODS=*"
    test_auth_passthrough
    test_auth_absent
    stop_proxy

    # ── Custom CORS origin ─────────────────────────────────────────────
    echo ""
    echo "== Proxy config: CORS_ALLOW_ORIGIN=https://example.com =="
    start_proxy "ALLOWED_METHODS=*" "CORS_ALLOW_ORIGIN=https://example.com"
    test_cors_custom_origin
    stop_proxy

    # ── CORS disabled ──────────────────────────────────────────────────
    echo ""
    echo "== Proxy config: CORS disabled =="
    start_proxy "ALLOWED_METHODS=*" "CORS_ALLOW_ORIGIN="
    test_cors_disabled
    stop_proxy

    # ── Summary ────────────────────────────────────────────────────────
    echo ""
    local total=$((PASSED + FAILED))
    echo "========================================"
    if [[ $FAILED -eq 0 ]]; then
        echo "  All $total tests passed"
    else
        echo "  $PASSED passed  $FAILED failed  (of $total)"
    fi
    echo "========================================"

    [[ $FAILED -gt 0 ]] && exit 1
    exit 0
}

main "$@"
