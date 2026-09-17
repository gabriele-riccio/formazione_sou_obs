local http = require('http')

core.register_action("mirror_to_b", {"http-req"}, function(txn)
    local method = txn.sf:method()
    local path = txn.sf:path()
    local query = txn.sf:query()
    local full_path = path
    if query and query ~= "" then
        full_path = path .. "?" .. query
    end
    local body = txn.sf:req_body()
    local content_type = txn.sf:req_hdr("content-type") or "application/json"
    local content_encoding = txn.sf:req_hdr("content-encoding")

    core.register_task(function()
        local res, err
        if method == "GET" then
            res, err = http.get{
                url = "http://192.168.56.1:9201" .. full_path,
                headers = { ["Authorization"] = {"Basic ZWxhc3RpYzphZG1pbjEyMw=="} }
            }
        else
            local req_headers = {
                ["Authorization"] = {"Basic ZWxhc3RpYzphZG1pbjEyMw=="},
                ["Content-Type"] = {content_type}
            }
            if content_encoding then
                req_headers["Content-Encoding"] = {content_encoding}
            end
            res, err = http.post{
                url = "http://192.168.56.1:9201" .. full_path,
                data = body,
                headers = req_headers
            }
        end
        if res then
            core.Info("mirror-to-b [" .. full_path .. "]: status " .. tostring(res.status_code))
        else
            core.Info("mirror-to-b [" .. full_path .. "]: errore - " .. tostring(err))
        end
    end)
end)