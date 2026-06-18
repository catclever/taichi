local M = {}
local hotkeyEngine = require("v3.core.hotkey_engine")

function M.init(taichi_env)
    hotkeyEngine.registerAction("taichi.triggerInspector", function()
        local app = hs.application.frontmostApplication()
        if not app then return end
        
        local bundleID = app:bundleID()
        local url = "http://127.0.0.1:" .. taichi_env.taichi_port .. "/api/inspector/activate?appId=" .. bundleID
        
        hs.http.asyncGet(url, nil, function(status, body, headers)
            if status == 500 then
                hs.alert.show("❌ [TaiChi 寻星镜] 注入失败，请检查应用调试端口。", 2)
            end
        end)
    end)
end

return M
