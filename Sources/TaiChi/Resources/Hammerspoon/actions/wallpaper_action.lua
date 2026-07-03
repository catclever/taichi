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

--- 全局方法：设置壁纸
--- @param screen string|hs.screen 目标屏幕，默认当前窗口所在屏幕或主屏幕
--- @param path string 壁纸路径，如果不传则从默认目录随机取
_G.setWallpaper = function(screen, path)
    local targetScreen = nil

    -- 解析 screen 参数
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

    -- 默认使用当前窗口所在屏幕或主屏幕
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
    local targetPath = path
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
    local screenUUID = params.screenUUID
    local path = params.path
    setWallpaper(screenUUID, path)
end)

return M
