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
    
    for _, win in ipairs(app:allWindows()) do
        local winScreen = win:screen()
        if winScreen and winScreen:getUUID() == screenUUID then
            -- 修复1：如果当前 App 在前台，hide() 会触发 macOS 的焦点回退，导致 Space 经常被“拉回”上一个屏幕
            -- 修复2：绝对不能获取所有 Space 的窗口去 focus，否则会导致无限跨屏跳跃循环！
            if app:isFrontmost() then
                -- 仅获取当前 Space 上的标准窗口
                local wf = hs.window.filter.new():setCurrentSpace(true)
                local windows = wf:getWindows()
                local anchored = false
                
                for _, w in ipairs(windows) do
                    local s = w:screen()
                    if s and s:getUUID() == screenUUID and w:application():name() ~= appName and w:isStandard() and w:isVisible() then
                        w:focus()
                        anchored = true
                        break
                    end
                end
                
                if not anchored then
                    -- 如果当前屏幕真的没有任何其他窗口，绝不能调用 finder:activate()，
                    -- 因为如果 Finder 在别的屏幕有窗口，这依然会导致跨屏拉回！
                    -- 这里的最佳处理是尝试 focus 桌面本身，或者什么都不做。
                    local desktop = hs.window.desktop()
                    if desktop then
                        desktop:focus()
                    end
                end
            end
            
            app:hide()
            return
        end
    end
end

return M
