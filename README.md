# nginx JSON-RPC Proxy

A lightweight, high-performance reverse proxy for JSON-RPC services built on nginx with embedded Lua. It inspects incoming JSON-RPC requests and enforces method-level access control (whitelist/blacklist) before forwarding traffic to a backend such as an Ethereum node.

## Features

- **Method filtering** -- whitelist and/or blacklist individual JSON-RPC methods
- **Batch request support** -- every method in a JSON-RPC batch array is validated
- **Authorization header override** -- inject a static auth token for the backend without exposing it to clients
- **CORS support** -- handles preflight `OPTIONS` requests and includes CORS headers on all responses
- **Health check endpoint** -- `/health` returns `{"status":"ok"}` and bypasses all filtering
- **Docker-first** -- single image, fully configured through environment variables

## Quick Start

```bash
# Clone the repository
git clone https://github.com/mainnet-pat/nginx-json-rpc-proxy.git && cd nginx-json-rpc-proxy

# Start the proxy (builds the image automatically)
docker compose up --build
```

The proxy is now listening on `http://localhost:8000` and will forward requests to `localhost:8545`.

### Minimal Example

```bash
curl -X POST http://localhost:8000 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Configuration

All configuration is done through environment variables, either directly or via `docker-compose.yml`.

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `8000` | Port the proxy listens on |
| `BACKEND_HOST` | `localhost` | Hostname of the upstream JSON-RPC server |
| `BACKEND_PORT` | `8545` | Port of the upstream JSON-RPC server |
| `ALLOWED_METHODS` | `*` | `*` to allow all methods, or a comma-separated whitelist (e.g. `eth_call,eth_blockNumber`) |
| `BLOCKED_METHODS` | *(empty)* | Comma-separated list of methods to deny. **Blacklist always takes precedence over whitelist.** |
| `AUTHORIZATION_HEADER_OVERRIDE` | *(empty)* | When set, the proxy replaces the `Authorization` header on upstream requests with this value. When unset, the client's original header is passed through. |
| `CORS_ALLOW_ORIGIN` | `*` | Value for the `Access-Control-Allow-Origin` header. Set to a specific origin (e.g. `https://example.com`) to restrict, or empty string to disable CORS headers entirely. |
| `CORS_ALLOW_METHODS` | `POST, OPTIONS` | Value for the `Access-Control-Allow-Methods` header. |
| `CORS_ALLOW_HEADERS` | `Content-Type, Authorization` | Value for the `Access-Control-Allow-Headers` header. |

### Method Filtering

Filtering is evaluated per-method in the following order:

1. **Blacklist check** -- if the method is in `BLOCKED_METHODS`, it is denied regardless of the whitelist.
2. **Allow-all check** -- if `ALLOWED_METHODS` is `*`, the method is allowed.
3. **Whitelist check** -- if the method is in `ALLOWED_METHODS`, it is allowed.
4. **Default deny** -- everything else is rejected.

#### Example Configurations

**Allow all methods (open proxy):**

```yaml
ALLOWED_METHODS: "*"
BLOCKED_METHODS: ""
```

**Allow only read methods:**

```yaml
ALLOWED_METHODS: "eth_call,eth_blockNumber,eth_getBalance,eth_getTransactionReceipt"
BLOCKED_METHODS: ""
```

**Allow all except dangerous methods:**

```yaml
ALLOWED_METHODS: "*"
BLOCKED_METHODS: "eth_sendTransaction,eth_sendRawTransaction,eth_sign,personal_unlockAccount"
```

**Whitelist with targeted block (blacklist wins):**

```yaml
ALLOWED_METHODS: "eth_call,eth_sendRawTransaction,eth_blockNumber"
BLOCKED_METHODS: "eth_sendRawTransaction"
# eth_sendRawTransaction is blocked even though it appears in ALLOWED_METHODS
```

## Architecture

```
                          +--------------------------+
                          | nginx JSON-RPC Proxy     |
                          |                          |
  Client ──POST /──────>  │  access_by_lua_block     │
                          │  (jsonrpc-access.lua)    │
                          │    1. Validate POST      │
                          │    2. Parse JSON body    │
                          │    3. Check method rules │
                          │                          │
                          │  proxy_pass ────────────>│──> Backend (e.g. Geth :8545)
                          +--------------------------+
```

The proxy has three main components:

| File | Role |
|---|---|
| `nginx.conf.template` | nginx server config with environment variable placeholders. Defines the upstream, request buffering, Lua integration, and proxy settings. |
| `lua/jsonrpc-access.lua` | Core filtering logic executed during nginx's `access` phase. Parses JSON-RPC requests (including batches), evaluates whitelist/blacklist rules, and returns proper JSON-RPC error responses for blocked methods. |
| `docker-entrypoint.sh` | Startup script that validates configuration, substitutes environment variables into the nginx config template with `envsubst`, and launches nginx. |

## Endpoints

| Path | Method | Description |
|---|---|---|
| `/` | `POST` | JSON-RPC proxy endpoint. Validates the request, applies method filtering, and forwards to the backend. |
| `/` | `OPTIONS` | CORS preflight. Returns HTTP 204 with `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, and `Access-Control-Allow-Headers` headers. |
| `/` | Any other | Returns HTTP 405 with a JSON-RPC error. |
| `/health` | Any | Returns `{"status":"ok"}` with HTTP 200. Bypasses all filtering. No access log entry. |

## Error Responses

All errors are returned as valid JSON-RPC error objects. Blocked methods return HTTP 200 to stay compliant with the JSON-RPC 2.0 spec.

| Scenario | HTTP Status | Error Code | Example Message |
|---|---|---|---|
| Non-POST request | 405 | -1 | `Only POST method is allowed` |
| Empty request body | 400 | -1 | `Empty request body` |
| Malformed JSON | 400 | -1 | `Invalid JSON: ...` |
| Invalid batch entry | 400 | -1 | `Invalid JSON-RPC request in batch` |
| Missing `method` field | 200 | -1 | `Missing or invalid 'method' field` |
| Blocked method | 200 | -90 | `Method not allowed: eth_sendTransaction` |

## Batch Requests

The proxy fully supports [JSON-RPC batch requests](https://www.jsonrpc.org/specification#batch). When a batch (JSON array) is received, every method in the batch is validated. If any single method in the batch is blocked, the entire batch is rejected with an error referencing the first disallowed method.

```bash
# Batch request -- both methods must pass filtering
curl -X POST http://localhost:8000 \
  -H "Content-Type: application/json" \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_getBalance","params":["0x...","latest"],"id":2}
  ]'
```

## Building and Running

### Docker Compose (recommended)

```bash
# Build and start
docker compose up --build

# Start in background
docker compose up -d

# Stop
docker compose down
```

Override environment variables in `docker-compose.yml` or with an `.env` file.

### Docker

```bash
docker build -t jsonrpc-proxy .

docker run -p 8000:8000 \
  -e BACKEND_HOST=your-node-host \
  -e BACKEND_PORT=8545 \
  -e ALLOWED_METHODS="eth_call,eth_blockNumber" \
  -e BLOCKED_METHODS="eth_sendTransaction" \
  jsonrpc-proxy
```

## Proxy Behavior

- **Connection pooling** -- keeps up to 32 persistent connections to the backend via `keepalive`
- **HTTP/1.1 upstream** -- uses HTTP/1.1 with empty `Connection` header for keepalive compatibility
- **Request size limit** -- request bodies are buffered in memory up to 10 MB (`client_max_body_size`)
- **Timeouts** -- connect 30s, read 60s, write 30s
- **Authorization passthrough** -- when `AUTHORIZATION_HEADER_OVERRIDE` is not set, the client's `Authorization` header is forwarded as-is; when set, it replaces the client header. If neither is present, no `Authorization` header is sent to the backend.
- **CORS** -- configurable via `CORS_ALLOW_ORIGIN`, `CORS_ALLOW_METHODS`, and `CORS_ALLOW_HEADERS`. Defaults to allowing all origins. Set `CORS_ALLOW_ORIGIN` to a specific origin to restrict access, or to an empty string to disable CORS headers entirely. `OPTIONS` preflight requests return 204 without reaching the backend.

## License

See [LICENSE](LICENSE) for details.
