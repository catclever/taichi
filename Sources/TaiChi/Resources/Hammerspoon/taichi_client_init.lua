local M = {}

M.taichi_port = nil
M.security_token = nil

-- 熔断机制相关状态
M.fail_count = 0
M.max_fails = 5
M.is_circuit_open = false

function M.init(config)
    if config then
        M.taichi_port = config.taichi_port
        M.security_token = config.security_token
    end
    
    local inspector = require("v3.core.taichi_client.inspector")
    inspector.init(config)
end

-- 手动重连/恢复方法
function M.reconnect()
    M.fail_count = 0
    M.is_circuit_open = false
    hs.alert.show("TaiChi 客户端状态已重置\n将尝试重新连接...", 3)
    hs.printf("TaiChi Client: Circuit breaker reset manually.")
end

function M.postEvent(event_type, data, force)
    if not M.taichi_port then return end
    
    -- 如果熔断器已打开，直接放弃发送，避免控制台刷屏 (除非是强制发送)
    if M.is_circuit_open and not force then return end
    
    local url = "http://localhost:" .. M.taichi_port .. "/api/event"
    local payload = hs.json.encode({
        event = event_type,
        timestamp = os.time(),
        data = data or {}
    })
    
    local headers = {
        ["Content-Type"] = "application/json"
    }
    
    if M.security_token then
        headers["Authorization"] = "Bearer " .. M.security_token
    end
    
    -- 异步发送，绝对不阻塞主线程
    hs.http.asyncPost(url, payload, headers, function(status, body, resHeaders)
        -- status < 200 或 status >= 300 或 status == -1 (连接拒绝) 都视为失败
        if status < 200 or status >= 300 then
            M.fail_count = M.fail_count + 1
            hs.printf("TaiChi Client Error: Failed to post %s, status: %s (Fail count: %d/%d)", 
                      event_type, tostring(status), M.fail_count, M.max_fails)
            
            if M.fail_count >= M.max_fails and not M.is_circuit_open then
                M.is_circuit_open = true
                hs.alert.show("TaiChi 服务似乎已离线！\n连接已熔断，不再自动发送后台事件。", 5)
                hs.printf("TaiChi Client: Circuit breaker OPENED. Stopped sending background events.")
            end
        else
            -- 只要成功一次，立刻清零失败计数并重置熔断器
            if M.fail_count > 0 or M.is_circuit_open then
                M.fail_count = 0
                if M.is_circuit_open then
                    M.is_circuit_open = false
                    hs.alert.show("TaiChi 客户端已重新连接！", 3)
                    hs.printf("TaiChi Client: Circuit breaker RESET. Resumed sending events.")
                end
            end
        end
    end)
end

-- ============================================================
-- 注册供 TaiChi 调用的路由 (收拢自外部)
-- ============================================================
local http_bus = require("v3.core.http_bus")
local space_action = require("v3.actions.space_action")
local dock_action = require("v3.actions.dock_action")
local floating_action = require("v3.actions.floating_action")

http_bus.registerAction("hideDock", dock_action.hide)
http_bus.registerAction("showDock", dock_action.show)
http_bus.registerAction("toggleDock", dock_action.toggle)
http_bus.registerAction("gotoSpace", function(p) space_action.gotoSpace(p.spaceID) end)
http_bus.registerAction("hideApp", function(p) floating_action.hideApp(p.appName) end)
http_bus.registerAction("showApp", function(p) floating_action.showApp(p.appName) end)
http_bus.registerAction("toggleApp", function(p) floating_action.toggleApp(p.appName) end)
http_bus.registerAction("hideAppIfOnScreen", function(p) floating_action.hideAppIfOnScreen(p.appName, p.screenUUID) end)
http_bus.registerAction("alert", function(p) hs.alert.show(p.text or p.message or "...", tonumber(p.duration) or 3) end)
http_bus.registerAction("getScreens", function(p)
    local screens = {}
    for _, s in ipairs(hs.screen.allScreens()) do
        local uuid = s:getUUID()
        if type(uuid) ~= "string" or uuid == "" then
            uuid = tostring(s:id())
        end
        table.insert(screens, {
            uuid = uuid,
            name = s:name(),
            id = s:id()
        })
    end
    return screens
end)

-- ============================================================
-- 绑定全局快捷键 (汇报给 TaiChi)
-- ============================================================

function M.bindHotkeys(keys)
    keys = keys or {}
    
    local pinMods = keys.togglePin and keys.togglePin[1] or {"ctrl"}
    local pinKey = keys.togglePin and keys.togglePin[2] or "H"
    
    local allMods = keys.toggleAll and keys.toggleAll[1] or {"cmd", "ctrl"}
    local allKey = keys.toggleAll and keys.toggleAll[2] or "H"
    
    M.hotkey_refs = M.hotkey_refs or {}
    
    -- 清理旧热键
    for _, ref in pairs(M.hotkey_refs) do
        if ref then ref:delete() end
    end
    M.hotkey_refs = {}

    -- 钉住/解钉 当前应用
    M.hotkey_refs.pin = hs.hotkey.bind(pinMods, pinKey, function()
        local app = hs.application.frontmostApplication()
        if app then
            M.postEvent("togglePin", { appName = app:name() }, true)
        end
    end)

    -- 全局显隐所有浮动应用
    M.hotkey_refs.all = hs.hotkey.bind(allMods, allKey, function()
        M.postEvent("toggleAllFloatingApps", {}, true)
    end)
end

-- ============================================================
-- 反向注入 API (List Injection)
-- ============================================================

-- 向 TaiChi 注入、替换或删除列表配置项 (如 floatingApps, residentApps 等)
-- 参数 payload 可以是包含路径的 string，或者 string array，或者 table/table array
function M.updateList(listName, action, payload)
    if not M.taichi_port then
        hs.printf("TaiChi Client: Cannot update list, taichi_port is not set.")
        return
    end
    
    local validActions = { inject = true, replace = true, delete = true }
    if not validActions[action] then
        hs.printf("TaiChi Client Error: Invalid action '%s' for updateList", action)
        return
    end
    
    local url = "http://127.0.0.1:" .. M.taichi_port .. "/api/config/list/" .. listName
    local body = hs.json.encode({
        action = action,
        payload = payload
    })
    
    local headers = { ["Content-Type"] = "application/json" }
    
    hs.http.asyncPost(url, body, headers, function(status, resp, headers)
        if status == 200 then
            hs.printf("TaiChi Client: Successfully updated list '%s'", listName)
        else
            hs.printf("TaiChi Client: Failed to update list '%s', status: %d, response: %s", listName, status, tostring(resp))
        end
    end)
end

-- ============================================================
-- 壁纸状态 API (Wallpaper API)
-- ============================================================

-- 检查壁纸是否已经存在于 TaiChi 的历史记录中 (同步请求)
function M.checkWallpaper(id)
    if not M.taichi_port then return false end
    local url = "http://127.0.0.1:" .. M.taichi_port .. "/api/wallpaper/check?id=" .. hs.http.encodeForQuery(id)
    local status, body, headers = hs.http.get(url, nil)
    if status == 200 and body then
        local ok, resp = pcall(hs.json.decode, body)
        if ok and type(resp) == "table" then
            return resp.exists == true
        end
    end
    return false
end

-- 汇报壁纸已经设置成功
function M.reportWallpaperSet(id, path)
    M.postEvent("wallpaper_set", { id = id, path = path })
end

return M
