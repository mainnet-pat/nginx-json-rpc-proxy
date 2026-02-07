-- JSON-RPC method filtering module for nginx/OpenResty
-- Supports whitelist and blacklist modes, including batch requests

local cjson = require("cjson.safe")

local _M = {}

-- Parse a comma-separated string into a lookup table
local function parse_method_list(str)
    if not str or str == "" then
        return nil
    end
    local tbl = {}
    for method in string.gmatch(str, "([^,]+)") do
        local trimmed = method:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            tbl[trimmed] = true
        end
    end
    return tbl
end

-- Check if a single method is allowed
-- Blacklist always takes precedence over whitelist
local function is_method_allowed(method, whitelist, blacklist, allow_all)
    if blacklist and blacklist[method] then
        return false
    end

    if allow_all then
        return true
    end

    if whitelist and whitelist[method] then
        return true
    end

    return false
end

-- Build a JSON-RPC error response
local function jsonrpc_error(id, code, message)
    return cjson.encode({
        jsonrpc = "2.0",
        id = id,
        error = { code = code, message = message },
        result = cjson.null,
    })
end

function _M.access()
    local method = ngx.req.get_method()

    -- Handle CORS preflight
    if method == "OPTIONS" then
        local cors_origin = ngx.var.cors_allow_origin
        if cors_origin and cors_origin ~= "" then
            ngx.header["Access-Control-Allow-Origin"] = cors_origin
            ngx.header["Access-Control-Allow-Methods"] = ngx.var.cors_allow_methods
            ngx.header["Access-Control-Allow-Headers"] = ngx.var.cors_allow_headers
        end
        return ngx.exit(204)
    end

    if method ~= "POST" then
        ngx.status = 405
        ngx.header["Content-Type"] = "application/json"
        ngx.say(jsonrpc_error(ngx.null, -1, "Only POST method is allowed"))
        return ngx.exit(405)
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()

    if not body then
        -- body might be in a temp file if it's too large
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "r")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end

    if not body or body == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json"
        ngx.say(jsonrpc_error(ngx.null, -1, "Empty request body"))
        return ngx.exit(400)
    end

    local data, err = cjson.decode(body)
    if not data then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json"
        ngx.say(jsonrpc_error(ngx.null, -1, "Invalid JSON: " .. (err or "parse error")))
        return ngx.exit(400)
    end

    -- Read configuration from nginx variables
    local allowed_methods_str = ngx.var.jsonrpc_allowed_methods or ""
    local blocked_methods_str = ngx.var.jsonrpc_blocked_methods or ""
    local allow_all = (allowed_methods_str == "*")

    local whitelist = nil
    local blacklist = nil

    if not allow_all then
        whitelist = parse_method_list(allowed_methods_str)
    end
    blacklist = parse_method_list(blocked_methods_str)

    -- Handle batch requests (array of JSON-RPC calls)
    local requests = data
    local is_batch = false
    if type(data) == "table" and #data > 0 and type(data[1]) == "table" then
        is_batch = true
    else
        requests = { data }
    end

    for i, req in ipairs(requests) do
        if type(req) ~= "table" then
            ngx.status = 400
            ngx.header["Content-Type"] = "application/json"
            ngx.say(jsonrpc_error(ngx.null, -1, "Invalid JSON-RPC request in batch"))
            return ngx.exit(400)
        end

        local rpc_method = req["method"]
        if not rpc_method or type(rpc_method) ~= "string" then
            ngx.status = 200
            ngx.header["Content-Type"] = "application/json"
            ngx.say(jsonrpc_error(req["id"], -1, "Missing or invalid 'method' field"))
            return ngx.exit(200)
        end

        if not is_method_allowed(rpc_method, whitelist, blacklist, allow_all) then
            ngx.status = 200
            ngx.header["Content-Type"] = "application/json"
            local msg = "Method not allowed: " .. rpc_method
            if not allow_all and allowed_methods_str ~= "" then
                msg = msg .. ". Allowed methods: " .. allowed_methods_str
            end
            ngx.say(jsonrpc_error(req["id"], -90, msg))
            return ngx.exit(200)
        end
    end

    -- All methods passed validation; request proceeds to proxy_pass
end

return _M
