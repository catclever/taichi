-- wallpaper_action.lua
local M = {}
local http_bus = require("v3.core.http_bus")

-- 默认的随机壁纸目录
local defaultWallpaperDir = os.getenv("HOME") .. "/Pictures/wallpapers"

-- 记录每个屏幕期望的壁纸
local desiredByScreen = {}
local spaceWatcher = nil

--- 从指定目录随机选取一张壁纸
local function getRandomWallpaper(dirPath)
    local iter, obj = hs.fs.dir(dirPath)
    if not iter then return nil end

    local validImages = {}
    for file in iter, obj do
        if file ~= "." and file ~= ".." then
            local lowerFile = string.lower(file)
            if string.match(lowerFile, "%.jpg$") or string.match(lowerFile, "%.jpeg$") or string.match(lowerFile, "%.png$") then
                table.insert(validImages, dirPath .. "/" .. file)
            end
        end
    end

    if #validImages > 0 then
        math.randomseed(os.time())
        local randomIndex = math.random(1, #validImages)
        return validImages[randomIndex]
    end
    return nil
end

-- =============================================================================
-- [BUG FIX DOCUMENTATION - Task fix_wallpaper_target_screen_mapping_003]
-- 1. Problem Fixed:
--    When setWallpaper was called with an explicit screen target (screenUUID or screenName),
--    if the screen did not match any connected screen in `hs.screen.allScreens()`,
--    the function previously fell back to `win:screen()` or `hs.screen.mainScreen()`.
--    This caused wallpapers meant for an external display to be mistakenly applied
--    to the built-in screen.
-- 2. Resolution:
--    - Accept either table `params` or separate `(screen, path)` arguments.
--    - Track whether an explicit screen target was specified via `screenUUID`, `screenName`,
--      or userdata screen.
--    - If an explicit target was requested but not found in `hs.screen.allScreens()`, log an
--      error and return false immediately, avoiding the fallback to mainScreen.
--    - Only fallback to focused window or mainScreen when no explicit screen was requested.
-- 3. Caveats:
--    The registered HTTP action `setWallpaper` returns 404 on failure so callers know
--    the screen application failed.
-- =============================================================================
--- 全局方法：设置壁纸
--- @param screenOrParams table|string|hs.screen 目标屏幕或参数表
--- @param path string|nil 壁纸路径，如果不传则从默认目录随机取
_G.setWallpaper = function(screenOrParams, path)
    local targetScreen = nil
    local targetPath = path
    local screenUUID = nil
    local screenName = nil
    local explicitTargetRequested = false

    -- 解析 screenOrParams 参数
    if type(screenOrParams) == "userdata" then
        targetScreen = screenOrParams
        explicitTargetRequested = true
    elseif type(screenOrParams) == "table" then
        screenUUID = screenOrParams.screenUUID
        screenName = screenOrParams.screenName
        if screenOrParams.path then
            targetPath = screenOrParams.path
        end
        if (type(screenUUID) == "string" and screenUUID ~= "") or (type(screenName) == "string" and screenName ~= "") then
            explicitTargetRequested = true
        end
    elseif type(screenOrParams) == "string" then
        screenUUID = screenOrParams
        if screenUUID ~= "" then
            explicitTargetRequested = true
        end
    end

    if explicitTargetRequested and not targetScreen then
        for _, s in ipairs(hs.screen.allScreens()) do
            local u = s:getUUID()
            if type(u) ~= "string" or u == "" then u = tostring(s:id()) end
            local sName = s:name()
            if (screenUUID and (u == screenUUID or sName == screenUUID)) or
               (screenName and (u == screenName or sName == screenName)) then
                targetScreen = s
                break
            end
        end

        if not targetScreen then
            hs.printf("WallpaperAction Error: Explicit target screen requested (UUID: %s, Name: %s) but not found in hs.screen.allScreens()", tostring(screenUUID), tostring(screenName))
            return false
        end
    end

    -- 仅当未指定明确目标屏幕时，默认使用当前窗口所在屏幕或主屏幕
    if not targetScreen then
        local win = hs.window.focusedWindow()
        if win then
            targetScreen = win:screen()
        else
            targetScreen = hs.screen.mainScreen()
        end
    end

    if not targetScreen then
        hs.printf("WallpaperAction: Target screen not found")
        return false
    end

    -- 解析 path 参数
    if not targetPath then
        targetPath = getRandomWallpaper(defaultWallpaperDir)
        if not targetPath then
            hs.printf("WallpaperAction: No valid wallpapers found in %s", defaultWallpaperDir)
            return false
        end
    end

    local fileURL = "file://" .. string.gsub(targetPath, " ", "%%20")
    targetScreen:desktopImageURL(fileURL)
    
    local screenId = targetScreen:getUUID()
    if type(screenId) ~= "string" or screenId == "" then screenId = tostring(targetScreen:id()) end
    
    desiredByScreen[screenId] = fileURL
    
    hs.printf("WallpaperAction: Set wallpaper for screen %s to %s", screenId, targetPath)
    return true
end

-- 同步所有屏幕的期望壁纸
local function syncDesiredForAllScreens()
    for _, s in ipairs(hs.screen.allScreens()) do
        local u = s:getUUID()
        if type(u) ~= "string" or u == "" then u = tostring(s:id()) end
        local desired = desiredByScreen[u]
        if desired then
            local current = s:desktopImageURL()
            if current ~= desired then
                hs.printf("WallpaperAction: Syncing space for screen %s to %s", u, desired)
                s:desktopImageURL(desired)
            end
        end
    end
end

if not spaceWatcher then
    spaceWatcher = hs.spaces.watcher.new(function()
        hs.timer.doAfter(0.5, function()
            syncDesiredForAllScreens()
        end)
    end)
    spaceWatcher:start()
end

-- 注册 HTTP Bus 动作，供 TaiChi 大脑下发调用
http_bus.registerAction("setWallpaper", function(params)
    local ok = setWallpaper(params)
    if not ok then
        return { error = "Target screen not found or failed to set wallpaper" }, 404
    end
    return { status = "ok" }, 200
end)

return M
