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
            
            hs.printf("🚀 [SpaceWatcher] spaceChanged! currentSpace=%s, screenUUID=%s", tostring(currentSpace), tostring(screenUUID))
            os.execute("echo '[SpaceWatcher] spaceChanged! currentSpace=" .. tostring(currentSpace) .. "' >> /tmp/hs_space.log")
            
            emit("spaceChanged", {
                currentSpaceId = currentSpace,
                screenUUID = screenUUID
            })
        end)
        watchers.space:start()
    end

    -- 2. Window Focus Watcher (Removed for power optimization)
    -- Global window filtering is highly intensive and currently unused by the backend.

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

    -- =============================================================================
    -- [BUG FIX DOCUMENTATION - Task fix_wallpaper_target_screen_mapping_003]
    -- 1. Problem Fixed:
    --    Line 82 called `utils.getScreens({ includeVirtual = true })`, which is undefined
    --    in `v3.core.utils`. This caused a Lua runtime exception inside reportScreens(),
    --    silently failing screen topology reporting and preventing `screensChanged` events
    --    from reaching TaiChi.
    -- 2. Resolution:
    --    Replaced `utils.getScreens(...)` with `hs.screen.allScreens()`.
    -- 3. Caveats:
    --    Ensure getUUID() handles nil or empty string by falling back to tostring(s:id()).
    -- =============================================================================
    -- 5. Screen Topology Watcher
    if enabled_watchers.screen then
        local function reportScreens()
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
