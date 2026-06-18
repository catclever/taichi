local M = {}

-- 彻底剥离了复杂的状态监控，仅提供纯粹的操作执行
function M.hideApp(appName)
    local app = hs.application.get(appName)
    if app and not app:isHidden() then
        app:hide()
    end
end

function M.showApp(appName)
    local app = hs.application.get(appName)
    if app then
        app:activate()
    else
        hs.application.launchOrFocus(appName)
    end
end

function M.toggleApp(appName)
    local app = hs.application.get(appName)
    if app then
        if app:isFrontmost() then
            app:hide()
        else
            app:activate()
        end
    else
        hs.application.launchOrFocus(appName)
    end
end

function M.hideAppIfOnScreen(appName, screenUUID)
    local app = hs.application.get(appName)
    if not app or app:isHidden() then return end
    
    local mainWindow = app:mainWindow()
    if mainWindow then
        local winScreen = mainWindow:screen()
        if winScreen and winScreen:getUUID() == screenUUID then
            app:hide()
        end
    end
end

return M
