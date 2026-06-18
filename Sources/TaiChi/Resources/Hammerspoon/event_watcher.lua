local M = {}
local taichi_client = require("v3.core.taichi_client")
local utils = require("v3.core.utils")

local watchers = {}

local function emit(event_type, data)
    taichi_client.postEvent(event_type, data)
end

function M.init(taichi_env)
    -- Stop any existing watchers before re-initializing
    for k, w in pairs(watchers) do
        if w.stop then w:stop() end
    end
    watchers = {}

    -- taichi_env can contain flags to enable/disable specific watchers
    local enabled_watchers = taichi_env and taichi_env.watchers or {
        space = true,
        window = true,
        app = true,
        wifi = true,
        screen = true
    }

    -- 1. Space Watcher
    if enabled_watchers.space then
        watchers.space = hs.spaces.watcher.new(function()
            local currentSpace = hs.spaces.focusedSpace()
            local screenUUID = nil
            for uuid, spaces in pairs(hs.spaces.allSpaces()) do
                for _, s in ipairs(spaces) do
                    if s == currentSpace then screenUUID = uuid break end
                end
                if screenUUID then break end
            end
            
            emit("spaceChanged", {
                currentSpaceId = currentSpace,
                screenUUID = screenUUID
            })
        end)
        watchers.space:start()
    end

    -- 2. Window Focus Watcher
    if enabled_watchers.window then
        local ok, wf = pcall(function()
            local w = hs.window.filter.new(nil)
            w:subscribe(hs.window.filter.windowFocused, function(win, appName)
                if not win then return end
                emit("windowFocused", {
                    appName = appName,
                    windowTitle = win:title(),
                    isFullScreen = win:isFullScreen(),
                    pid = win:application() and win:application():pid() or nil,
                    windowId = win:id()
                })
            end)
            return w
        end)
        if ok and wf then watchers.window = wf end
    end

    -- 3. App Launched/Activated Watcher
    if enabled_watchers.app then
        watchers.app = hs.application.watcher.new(function(appName, eventType, app)
            if eventType == hs.application.watcher.launched then
                emit("appLaunched", { appName = appName, pid = app:pid() })
            elseif eventType == hs.application.watcher.activated or eventType == hs.application.watcher.unhidden then
                emit("appActivated", { appName = appName, pid = app:pid(), eventType = eventType })
            end
        end)
        watchers.app:start()
    end
    
    -- 4. Wi-Fi Watcher (Home Wi-Fi Tailscale Auto-Down)
    if enabled_watchers.wifi then
        local last_ssid = hs.wifi.currentNetwork()
        watchers.wifi = hs.wifi.watcher.new(function()
            local current_ssid = hs.wifi.currentNetwork()
            if current_ssid and current_ssid ~= last_ssid then
                emit("wifiChanged", { ssid = current_ssid })
            end
            last_ssid = current_ssid
        end)
        watchers.wifi:start()
    end

    -- 5. Screen Topology Watcher
    if enabled_watchers.screen then
        local function reportScreens()
            local screens = {}
            for _, s in ipairs(utils.getScreens({ includeVirtual = true })) do
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
            emit("screensChanged", { screens = screens })
        end

        watchers.screen = hs.screen.watcher.new(function()
            hs.timer.doAfter(1.0, reportScreens)
        end)
        watchers.screen:start()
        
        -- Initial report
        hs.timer.doAfter(1.0, reportScreens)
    end

    hs.printf("Event Watcher Initialized")
end

return M
