-- paper_client.lua
local M = {}
local http_bus = require("v3.core.http_bus")

_G.paper = {}

local function getTargetScreenDetails(screen)
    local targetScreen = nil

    if type(screen) == "userdata" then
        targetScreen = screen
    elseif type(screen) == "string" then
        for _, s in ipairs(hs.screen.allScreens()) do
            local u = s:getUUID()
            if type(u) ~= "string" or u == "" then u = tostring(s:id()) end
            if u == screen or s:name() == screen then
                targetScreen = s
                break
            end
        end
    end

    if not targetScreen then
        local win = hs.window.focusedWindow()
        if win then
            targetScreen = win:screen()
        else
            targetScreen = hs.screen.mainScreen()
        end
    end

    if targetScreen then
        local u = targetScreen:getUUID()
        if type(u) ~= "string" or u == "" then u = tostring(targetScreen:id()) end
        return u, targetScreen:name()
    end
    return nil, nil
end

local function callTaiChiWallpaperAPI(endpoint, screen)
    local screenUUID, screenName = getTargetScreenDetails(screen)
    local payload = {}
    if screenUUID then
        payload.screenUUID = screenUUID
    end
    
    local body = hs.json.encode(payload)
    local port = taichi_env and taichi_env.taichi_port or 9216
    local url = "http://127.0.0.1:" .. tostring(port) .. "/api/wallpaper/" .. endpoint
    
    local headers = {}
    if taichi_env and taichi_env.security_token then
        headers["Authorization"] = "Bearer " .. taichi_env.security_token
    end
    
    hs.http.doAsyncRequest(url, "POST", body, headers, function(status, responseBody, responseHeaders)
        if status ~= 200 then
            hs.printf("TaiChi paper.%s request failed: %d %s", endpoint, status, responseBody)
        else
            local displayName = screenName
            if not displayName and screenUUID then displayName = screenUUID end
            hs.printf("TaiChi paper.%s triggered successfully for screen: %s", endpoint, displayName or "all")
        end
    end)
end

function _G.paper.change(screen)
    callTaiChiWallpaperAPI("change", screen)
end

function _G.paper.previous(screen)
    callTaiChiWallpaperAPI("previous", screen)
end

function _G.paper.save(screen)
    callTaiChiWallpaperAPI("save", screen)
end

return M
