local M = {}
local server = nil
local action_router = {}

M.security_token = nil

-- 注册本地动作路由
-- 例如: http_bus.registerAction("hideDock", dock_action.hide)
function M.registerAction(action_name, callback)
    action_router[action_name] = callback
end

-- 兼容旧版 Legacy Modules 的注册语法 (namespace, action, callback)
function M.register(namespace, action, callback)
    local action_name = namespace .. "." .. action
    M.registerAction(action_name, callback)
end

local function handleRequest(method, path, headers, body)
    if method ~= "POST" or path ~= "/api/action" then
        return "Not Found", 404, {}
    end

    -- Token 校验
    if M.security_token then
        local auth = headers["Authorization"] or headers["authorization"]
        local expected = "Bearer " .. M.security_token
        if auth ~= expected then
            hs.printf("HTTP Bus: Unauthorized access attempt")
            return "Unauthorized", 401, {}
        end
    end

    local ok, req = pcall(hs.json.decode, body)
    if not ok or type(req) ~= "table" then
        return "Bad Request", 400, {}
    end

    local action = req.action
    local params = req.params or {}

    -- 支持批量执行
    if action == "batchExecute" and type(params) == "table" then
        for _, subReq in ipairs(params) do
            local subAction = subReq.action
            local subParams = subReq.params or {}
            if subAction and action_router[subAction] then
                pcall(action_router[subAction], subParams)
            end
        end
        return "OK", 200, {}
    end

    -- 执行单个动作
    if action and action_router[action] then
        local success, res1, res2, res3 = pcall(action_router[action], params)
        if success then
            -- 兼容旧模块返回: body, code, headers
            if type(res1) == "table" or type(res1) == "string" then
                local body = type(res1) == "table" and hs.json.encode(res1) or res1
                local code = res2 or 200
                local head = res3 or {}
                return body, code, head
            end
            return "OK", 200, {}
        else
            hs.printf("HTTP Bus Action Error [%s]: %s", action, tostring(res1))
            return "Internal Server Error", 500, {}
        end
    end

    return "Action Not Found", 404, {}
end

function M.init(config)
    if config then
        M.security_token = config.security_token
    end
    local port = (config and config.hs_port) or 8082
    
    server = hs.httpserver.new()
    server:setPort(port)
    server:setCallback(handleRequest)
    server:start()
    
    hs.printf("TaiChi HTTP Bus listening on port %d", port)
end

return M
