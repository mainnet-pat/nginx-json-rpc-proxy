#!/bin/sh
set -e

# Default values
export LISTEN_PORT="${LISTEN_PORT:-8000}"
export BACKEND_HOST="${BACKEND_HOST:-localhost}"
export BACKEND_PORT="${BACKEND_PORT:-8545}"
export ALLOWED_METHODS="${ALLOWED_METHODS:-*}"
export BLOCKED_METHODS="${BLOCKED_METHODS:-}"
export AUTHORIZATION_HEADER_OVERRIDE="${AUTHORIZATION_HEADER_OVERRIDE:-}"
export CORS_ALLOW_ORIGIN="${CORS_ALLOW_ORIGIN-*}"
export CORS_ALLOW_METHODS="${CORS_ALLOW_METHODS-POST, OPTIONS}"
export CORS_ALLOW_HEADERS="${CORS_ALLOW_HEADERS-Content-Type, Authorization}"

# Validate configuration
if [ "$ALLOWED_METHODS" != "*" ] && [ -z "$ALLOWED_METHODS" ]; then
    echo "ERROR: ALLOWED_METHODS must be set to '*' or a comma-separated list of methods" >&2
    exit 1
fi

echo "=== nginx JSON-RPC Proxy ==="
echo "Listen port:    $LISTEN_PORT"
echo "Backend:        $BACKEND_HOST:$BACKEND_PORT"
echo "Allowed methods: $ALLOWED_METHODS"
if [ -n "$BLOCKED_METHODS" ]; then
    echo "Blocked methods: $BLOCKED_METHODS"
fi
if [ -n "$AUTHORIZATION_HEADER_OVERRIDE" ]; then
    echo "Auth override:  (set)"
fi
echo "CORS origin:    $CORS_ALLOW_ORIGIN"
echo "============================="

# Substitute environment variables into nginx config
envsubst '${LISTEN_PORT} ${BACKEND_HOST} ${BACKEND_PORT} ${ALLOWED_METHODS} ${BLOCKED_METHODS} ${CORS_ALLOW_ORIGIN} ${CORS_ALLOW_METHODS} ${CORS_ALLOW_HEADERS}' \
    < /etc/nginx/nginx.conf.template \
    > /usr/local/openresty/nginx/conf/nginx.conf

# Start OpenResty
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
