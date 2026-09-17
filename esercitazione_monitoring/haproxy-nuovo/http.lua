local http = {}

local function parse_url(url)
    -- estrae host, porta e path da http://host:porta/path
    local host, port, path = url:match("^http://([^:/]+):?(%d*)(/?.*)$")
    if port == "" then port = "80" end
    if path == "" then path = "/" end
    return host, tonumber(port), path
end

local function do_request(method, url, body, headers)
    local host, port, path = parse_url(url)
    local sock = core.tcp()
    sock:settimeout(5)
    local ok, err = sock:connect(host, port)
    if not ok then
        return nil, "connect failed: " .. tostring(err)
    end

    body = body or ""
    local req = method .. " " .. path .. " HTTP/1.1\r\n"
    req = req .. "Host: " .. host .. "\r\n"
    req = req .. "Content-Length: " .. #body .. "\r\n"
    req = req .. "Connection: close\r\n"
    if headers then
        for k, v in pairs(headers) do
            local val = type(v) == "table" and v[1] or v
            req = req .. k .. ": " .. val .. "\r\n"
        end
    end
    req = req .. "\r\n" .. body

    sock:send(req)
    local response = sock:receive("*a")
    sock:close()

    -- estrae lo status code dalla prima riga (es. "HTTP/1.1 201 Created")
    local status = response and tonumber(response:match("^HTTP/%d%.%d (%d+)"))
    return { status_code = status, content = response }
end

function http.get(t)
    return do_request("GET", t.url, nil, t.headers)
end

function http.post(t)
    return do_request("POST", t.url, t.data, t.headers)
end

return http