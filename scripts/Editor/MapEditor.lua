--- Editor/MapEditor.lua
--- 地图编辑器主控模块：输入处理、NanoVG 渲染、状态管理
--- 在 ClientGame 的 debugSolo 模式下按 T 启用
--- UI 面板由 EditorUI.lua 通过 urhox-libs/UI 组件库渲染

local EditorConst   = require("Editor.EditorConst")
local EditorTools   = require("Editor.EditorTools")
local EditorUI      = require("Editor.EditorUI")
local MapSerializer = require("Editor.MapSerializer")
local GameConst     = require("Game.GameConst")
local LevelData     = require("Game.LevelData")
local Shared        = require("Network.Shared")
local WorldRenderer = require("Render.WorldRenderer")

local MapEditor = {}

-- ═══════════════════════════════════════════════
-- 内部状态
-- ═══════════════════════════════════════════════
local active_    = false
local vg_        = nil
local fontId_    = -1

-- 屏幕参数获取回调
-- function() -> screenW, screenH, dpr, viewScale, viewOffX, viewOffY, designW, designH, camX, camY
local getParams_ = nil
local getPlayers_ = nil   -- function() -> { red={x,y}, black={x,y} }

-- 地图数据
local mapData_   = nil
local undoStack_ = {}
local redoStack_ = {}

-- 当前工具
local curTool_        = EditorConst.TOOL.GROUND
local curNpcPresetId_ = nil   -- 选中的 NPC 预设 ID（仅 curTool_=="npc" 时有效）
local curPortalGroup_ = 1     -- 当前传送组号 1-9
local curVisibleTo_   = "all" -- 放置格子的归属（独立于视角模式）

-- 视角显示模式（纯渲染，不影响 curVisibleTo_）
local viewModeIdx_ = 1  -- 1=逻辑, 2=红鸟, 3=黑鸟

-- 隐藏背景/前景装饰层
local hideBgFg_ = false

-- 笔刷大小
local brushSize_ = EditorConst.DEFAULT_BRUSH

-- 编辑器视图（独立于游戏相机）
local edZoom_    = 1.0
local edPanX_    = 0.0
local edPanY_    = 0.0

-- 鼠标状态
local mouseDown_       = false
local lastPlacedKey_   = ""
local midDrag_         = false
local midDragStartX_   = 0
local midDragStartY_   = 0
local midDragPanStartX_ = 0
local midDragPanStartY_ = 0

-- MOVE 工具状态
local selectedElem_    = nil   -- { gx, gy, layer="cell"|"prop"|"npc", npcIdx=N }
local moveDragging_    = false
local moveDragStartGX_ = 0
local moveDragStartGY_ = 0

-- 贴图调整模式（红鸟/黑鸟视角下可开启）
local overlayAdjustMode_  = false
local selectedOverlayIds_ = {}    -- { [ovId] = true }  grid overlay + free overlay 共用
local copiedOverlays_     = {}    -- 剪贴板（overlay 深拷贝列表）
local overlayIdCounter_   = 0     -- 生成唯一 ID

-- 自由贴图拖拽状态
local freeDragging_       = false   -- 是否正在拖拽 freeOverlay
local freeDragArmed_            = false   -- 双击后进入"待机"，下次按住鼠标即激活拖拽
local freeDragArmedWaitRelease_ = false   -- 待机中等待鼠标先松开，避免双击同帧激活
local freeDragStartMouseX_ = 0      -- 拖拽开始时鼠标设计坐标 X
local freeDragStartMouseY_ = 0      -- 拖拽开始时鼠标设计坐标 Y
local freeDragOriginals_  = {}      -- { [ovId] = {x=,y=} }  拖拽开始时各选中贴图的原始坐标
-- 双击检测：双击已选中的 freeOverlay 才启动拖拽
local lastClickTime_      = 0       -- 上次左键单击时间（秒）
local lastClickOvId_      = nil     -- 上次单击命中的 freeOverlay id
local DOUBLE_CLICK_INTERVAL_ = 0.35 -- 双击判定间隔（秒）

-- 防止添加贴图后同帧鼠标事件清除选中
local justAddedOverlayFrame_ = false  -- 当帧内 addFreeOverlay 已执行，跳过命中测试清选
-- 添加贴图防抖：避免 onClick 多次触发
local lastAddOverlayTime_ = 0         -- 上次添加时间（秒）
local lastAddOverlayPath_ = nil       -- 上次添加的图片路径（防抖路径匹配用）

-- 素材库浏览器状态（贴图调整模式用）
local assetImages_      = {}   -- 当前目录下的图片路径列表（完整资源路径）
local assetDirs_        = {}   -- 当前目录下的子目录名列表
local assetBrowserPath_ = ""   -- 当前浏览路径（相对于 image/贴图/，""=根目录）

-- 防抖实时同步
local SYNC_DELAY       = 0.5   -- 编辑后延迟 N 秒自动保存+重载
local syncTimer_       = 0     -- >0 表示等待同步
local syncPending_     = false

-- 前向声明（在 Init 回调中引用，实际定义在下方）
local scanAssetImages   -- 已废弃，保留兼容
local scanAssetDir      -- function(subPath) → 扫描指定子路径
local addFreeOverlay
local markDirty

-- 地图名
local mapName_ = "custom_01"

-- 当前编辑的场景/幕索引
local curSceneIdx_ = 0
local curActIdx_   = 1   -- Lua 1-based index into LevelData.acts

-- 动画计时器（水面流动等）
local animTime_ = 0

-- PPU
local PPU = GameConst.PIXELS_PER_UNIT

-- ═══════════════════════════════════════════════
-- 初始化
-- ═══════════════════════════════════════════════

--- 初始化编辑器
---@param vg userdata NanoVG 上下文
---@param getParamsFunc function 屏幕参数获取回调
---@param getPlayersFunc function|nil 玩家位置获取回调
function MapEditor.Init(vg, getParamsFunc, getPlayersFunc)
    vg_ = vg
    getParams_ = getParamsFunc
    getPlayers_ = getPlayersFunc
    fontId_ = nvgFindFont(vg_, "sans")
    if fontId_ < 0 then
        fontId_ = nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
    end

    -- 设置 EditorUI 回调
    EditorUI.SetCallbacks({
        onToolSelect = function(toolId, npcPresetId)
            curTool_ = toolId
            curNpcPresetId_ = npcPresetId or nil
            EditorUI.RefreshToolHighlight(toolId, npcPresetId)
            local label = toolId
            if npcPresetId then label = label .. " (" .. npcPresetId .. ")" end
            print("[MapEditor] Tool: " .. label)
        end,
        onViewMode = function(modeIdx)
            viewModeIdx_ = modeIdx
            -- 切回逻辑视角时自动退出贴图调整模式
            if modeIdx == 1 and overlayAdjustMode_ then
                overlayAdjustMode_ = false
                selectedOverlayIds_ = {}
                EditorUI.UpdateState({ overlayAdjustMode = false, selectedOverlayCount = 0 })
            end
            -- 注意：视角模式只影响渲染显示，不改变 curVisibleTo_
            EditorUI.RefreshViewHighlight(modeIdx)
            print("[MapEditor] View: " .. EditorConst.VIEW_LABELS[modeIdx])
        end,
        onToggleOverlayAdjust = function()
            overlayAdjustMode_ = not overlayAdjustMode_
            if not overlayAdjustMode_ then
                selectedOverlayIds_ = {}
                freeDragging_ = false
                freeDragArmed_ = false
                freeDragArmedWaitRelease_ = false
            else
                -- 开启时从根目录开始扫描
                assetBrowserPath_ = ""
                assetImages_, assetDirs_ = scanAssetDir("")
            end
            local selCount = 0
            for _ in pairs(selectedOverlayIds_) do selCount = selCount + 1 end
            EditorUI.UpdateState({
                overlayAdjustMode    = overlayAdjustMode_,
                selectedOverlayCount = selCount,
                assetImages          = assetImages_,
                assetDirs            = assetDirs_,
                assetBrowserPath     = assetBrowserPath_,
            })
            EditorUI.RefreshOverlayAdjust()
            print("[MapEditor] Overlay adjust mode: " .. (overlayAdjustMode_ and "ON" or "OFF"))
        end,
        onAddFreeOverlay = function(imagePath)
            addFreeOverlay(imagePath)
        end,
        onNavigateAssetDir = function(subPath)
            assetBrowserPath_ = subPath
            assetImages_, assetDirs_ = scanAssetDir(subPath)
            EditorUI.UpdateState({
                assetImages      = assetImages_,
                assetDirs        = assetDirs_,
                assetBrowserPath = assetBrowserPath_,
            })
            EditorUI.RefreshOverlayAdjust()
            print("[MapEditor] Asset browser navigate: image/贴图/" .. subPath)
        end,
        onToggleBgFg = function()
            hideBgFg_ = not hideBgFg_
            EditorUI.RefreshBgFgBtn(hideBgFg_)
            print("[MapEditor] BgFg: " .. (hideBgFg_ and "hidden" or "visible"))
        end,
        onBrushSize = function(size)
            brushSize_ = size
            EditorUI.RefreshBrushLabel(size)
        end,
        onBrushDelta = function(delta)
            local newSize = math.max(EditorConst.BRUSH_MIN, math.min(EditorConst.BRUSH_MAX, brushSize_ + delta))
            brushSize_ = newSize
            EditorUI.RefreshBrushLabel(newSize)
        end,
        onMapName = function(name)
            mapName_ = name
            if mapData_ then mapData_.name = name end
        end,
        onApplySize = function(w, h)
            if not mapData_ then return end
            EditorTools.PushUndo(mapData_, undoStack_)
            redoStack_ = {}
            -- 裁剪超出新边界的格子
            for key, _ in pairs(mapData_.cells) do
                local gx, gy = EditorTools.ParseKey(key)
                if gx and gy and (gx >= w or gy >= h) then
                    mapData_.cells[key] = nil
                end
            end
            if mapData_.props then
                for key, _ in pairs(mapData_.props) do
                    local gx, gy = EditorTools.ParseKey(key)
                    if gx and gy and (gx >= w or gy >= h) then
                        mapData_.props[key] = nil
                    end
                end
            end
            for i = #mapData_.npcs, 1, -1 do
                if mapData_.npcs[i].gx >= w or mapData_.npcs[i].gy >= h then
                    table.remove(mapData_.npcs, i)
                end
            end
            mapData_.gridW = w
            mapData_.gridH = h
            if mapData_.spawnRed and (mapData_.spawnRed.gx >= w or mapData_.spawnRed.gy >= h) then
                mapData_.spawnRed = nil
            end
            if mapData_.spawnBlack and (mapData_.spawnBlack.gx >= w or mapData_.spawnBlack.gy >= h) then
                mapData_.spawnBlack = nil
            end
            if mapData_.exitPos and (mapData_.exitPos.gx >= w or mapData_.exitPos.gy >= h) then
                mapData_.exitPos = nil
            end
            -- 同步 UI 字段显示
            EditorUI.SyncSizeFields(w, h)
            print("[MapEditor] Resized to " .. w .. "x" .. h)
        end,
        onSave = function()
            if mapData_ then
                MapSerializer.SaveAsScene(mapData_, curSceneIdx_)
                print(string.format("[MapEditor] Saved to scene %d", curSceneIdx_))
                -- 输出完整 mapData JSON 到日志（用于复刻地图 / 作为默认场景）
                MapSerializer.Save(mapData_)
                -- 同时输出 ToLevelData 转换后的 sceneData（可直接粘贴到 LevelData.lua createDefaultScene）
                local sceneData = MapSerializer.ToLevelData(mapData_)
                local sceneJson = cjson.encode(sceneData)
                print("[MapEditor] === SCENE JSON START ===")
                print(sceneJson)
                print("[MapEditor] === SCENE JSON END ===")
            end
        end,
        onLoad = function()
            local loaded = MapSerializer.Load(mapName_)
            if loaded then
                mapData_ = loaded
                undoStack_ = {}
                redoStack_ = {}
                -- 同步 UI 字段
                EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
                print("[MapEditor] Map loaded")
            end
        end,
        onUndo = function()
            if mapData_ and EditorTools.PopUndo(mapData_, undoStack_, redoStack_) then
                print("[MapEditor] Undo")
                markDirty()
            end
        end,
        onReset = function()
            -- 重做 = 彻底清除地图数据 + 解锁尺寸（解锁由 EditorUI 侧处理）
            if not mapData_ then return end
            mapData_.cells = {}
            mapData_.props = {}
            mapData_.npcs = {}
            mapData_.spawnRed = nil
            mapData_.spawnBlack = nil
            mapData_.exitPos = nil
            undoStack_ = {}
            redoStack_ = {}
            -- 同步 UI 字段为当前尺寸
            EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
            print("[MapEditor] Reset (cleared + size unlocked)")
        end,
        onPortalGroupChange = function(group)
            curPortalGroup_ = group
            print("[MapEditor] Portal group: " .. group)
        end,
        onClear = function()
            if not mapData_ then return end
            EditorTools.PushUndo(mapData_, undoStack_)
            redoStack_ = {}
            mapData_.cells = {}
            mapData_.props = {}
            mapData_.npcs = {}
            mapData_.spawnRed = nil
            mapData_.spawnBlack = nil
            mapData_.exitPos = nil
            print("[MapEditor] Cleared")
        end,

        -- ─── 场景切换回调（EditorUI Step 4 会连接到 UI） ───

        onActSelect = function(actIdx)
            curActIdx_ = actIdx
            local acts = LevelData.GetActs()
            if acts[actIdx] and acts[actIdx].sceneIndices[1] ~= nil then
                -- 切换到该幕的第一个场景
                MapEditor.LoadScene(acts[actIdx].sceneIndices[1])
                EditorUI.UpdateState({
                    mapName     = mapData_.name,
                    gridW       = mapData_.gridW,
                    gridH       = mapData_.gridH,
                    curActIdx   = curActIdx_,
                    curSceneIdx = curSceneIdx_,
                })
                EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
            end
        end,

        onSceneSelect = function(sceneIdx)
            MapEditor.LoadScene(sceneIdx)
            EditorUI.UpdateState({
                mapName     = mapData_.name,
                gridW       = mapData_.gridW,
                gridH       = mapData_.gridH,
                curActIdx   = curActIdx_,
                curSceneIdx = curSceneIdx_,
            })
            EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
        end,

        onActAdd = function()
            LevelData.AddAct("新幕")
            EditorUI.UpdateState({ curActIdx = curActIdx_, curSceneIdx = curSceneIdx_ })
            EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
            print("[MapEditor] Added new act")
        end,

        onActRemove = function(actIdx)
            if LevelData.RemoveAct(actIdx) then
                -- 如果删除的是当前幕或之前的幕，调整索引
                if curActIdx_ >= actIdx then
                    curActIdx_ = math.max(1, curActIdx_ - 1)
                end
                local acts = LevelData.GetActs()
                if acts[curActIdx_] and acts[curActIdx_].sceneIndices[1] ~= nil then
                    MapEditor.LoadScene(acts[curActIdx_].sceneIndices[1])
                end
                EditorUI.UpdateState({
                    curActIdx   = curActIdx_,
                    curSceneIdx = curSceneIdx_,
                    mapName     = mapData_ and mapData_.name or "",
                    gridW       = mapData_ and mapData_.gridW or 100,
                    gridH       = mapData_ and mapData_.gridH or 30,
                })
                EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
                print("[MapEditor] Removed act " .. actIdx)
            end
        end,

        onSceneAdd = function(actIdx)
            local newIdx = LevelData.AddScene(actIdx)
            if newIdx then
                MapEditor.LoadScene(newIdx)
                EditorUI.UpdateState({
                    mapName     = mapData_.name,
                    gridW       = mapData_.gridW,
                    gridH       = mapData_.gridH,
                    curActIdx   = curActIdx_,
                    curSceneIdx = curSceneIdx_,
                })
                EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
                print("[MapEditor] Added scene " .. newIdx)
            end
        end,

        onSceneRemove = function(actIdx, sceneIdx)
            if LevelData.RemoveScene(actIdx, sceneIdx) then
                -- 如果删除的是当前场景，加载该幕第一个场景
                if curSceneIdx_ == sceneIdx then
                    local acts = LevelData.GetActs()
                    if acts[actIdx] and acts[actIdx].sceneIndices[1] ~= nil then
                        MapEditor.LoadScene(acts[actIdx].sceneIndices[1])
                    end
                end
                EditorUI.UpdateState({
                    curActIdx   = curActIdx_,
                    curSceneIdx = curSceneIdx_,
                    mapName     = mapData_ and mapData_.name or "",
                    gridW       = mapData_ and mapData_.gridW or 100,
                    gridH       = mapData_ and mapData_.gridH or 30,
                })
                EditorUI.SyncSizeFields(mapData_.gridW, mapData_.gridH)
                print("[MapEditor] Removed scene " .. sceneIdx)
            end
        end,
    })
end

--- 根据场景索引查找所属幕（1-based）
local function findActForScene(sceneIdx)
    local acts = LevelData.GetActs()
    for i, act in ipairs(acts) do
        for _, idx in ipairs(act.sceneIndices) do
            if idx == sceneIdx then return i end
        end
    end
    return 1
end

--- 加载指定场景到编辑器
---@param sceneIdx number
function MapEditor.LoadScene(sceneIdx)
    local sceneData = LevelData.GetScene(sceneIdx)
    if sceneData then
        mapData_ = MapSerializer.FromLevelData(sceneData)
        mapData_.name = "scene_" .. sceneIdx
        print(string.format("[MapEditor] Loaded scene %d (%dx%d)", sceneIdx, mapData_.gridW, mapData_.gridH))
    else
        mapData_ = EditorTools.NewMap("scene_" .. sceneIdx)
        print(string.format("[MapEditor] No data for scene %d, created empty map", sceneIdx))
    end
    mapName_ = mapData_.name
    curSceneIdx_ = sceneIdx
    curActIdx_ = findActForScene(sceneIdx)
    undoStack_ = {}
    redoStack_ = {}
    -- 重置视图到地图中心
    local cs = EditorConst.CELL_SIZE
    edPanX_ = mapData_.gridW * cs * 0.5
    edPanY_ = mapData_.gridH * cs * 0.5
    -- ── groundOverlays → freeOverlays 一次性迁移 ──
    -- groundOverlay 是旧格式（网格坐标 + 像素偏移），不支持旋转/缩放/拖拽。
    -- 将其转换为 freeOverlay（世界坐标 + 宽高 + 旋转），统一用新系统编辑。
    if not mapData_.freeOverlays then mapData_.freeOverlays = {} end
    if mapData_.groundOverlays and #mapData_.groundOverlays > 0 then
        for _, ov in ipairs(mapData_.groundOverlays) do
            -- 复原 WorldRenderer.DrawSceneOverlays 的尺寸计算
            local baseW   = (ov.gx2 - ov.gx1 + 1) * cs
            local baseH   = (ov.gy2 - ov.gy1 + 1) * cs
            local basePW  = baseW * PPU
            local basePH  = baseH * PPU
            local extraTop = ov.extraTopPx or 0
            local newPH   = basePH + extraTop
            local newPW   = basePW * (newPH / basePH)
            local centerShiftPx = (newPW - basePW) * 0.5
            local worldW  = newPW / PPU
            local worldH  = newPH / PPU
            -- 世界中心坐标（与 WorldRenderer 渲染位置一致）
            local worldLeft = ov.gx1 * cs + (ov.offsetX or 0) / PPU - centerShiftPx / PPU
            local worldBot  = ov.gy1 * cs + (ov.offsetY or 0) / PPU
            local cx = worldLeft + worldW * 0.5
            local cy = worldBot  + worldH * 0.5
            -- 检查是否已迁移过（避免重复加载时重复追加）
            local alreadyMigrated = false
            for _, fov in ipairs(mapData_.freeOverlays) do
                if fov.migratedFromId == ov.id then
                    alreadyMigrated = true
                    break
                end
            end
            if not alreadyMigrated then
                overlayIdCounter_ = overlayIdCounter_ + 1
                mapData_.freeOverlays[#mapData_.freeOverlays + 1] = {
                    id             = "fov_migrated_" .. overlayIdCounter_,
                    migratedFromId = ov.id,   -- 记录来源，防止重复迁移
                    role           = ov.role,
                    imagePath      = ov.imagePath,
                    x              = cx,
                    y              = cy,
                    w              = worldW,
                    h              = worldH,
                    rotation       = 0,
                    _pendingAspect = true,  -- 首帧渲染时用图片真实宽高比修正 h
                }
                print(string.format("[MapEditor] Migrated groundOverlay '%s' → freeOverlay (cx=%.2f, cy=%.2f, w=%.2f, h=%.2f)",
                    ov.id, cx, cy, worldW, worldH))
            end
        end
        -- 清空旧 groundOverlays（已全部迁移为 freeOverlays）
        mapData_.groundOverlays = {}
        markDirty()
    end

    -- 同步到 WorldRenderer（编辑器视角渲染贴图）
    WorldRenderer.SetSceneOverlays(mapData_.groundOverlays or {})
    WorldRenderer.SetFreeOverlays(mapData_.freeOverlays or {})
end

--- 切换编辑器
function MapEditor.Toggle()
    active_ = not active_
    if active_ then
        -- 从 getParams_ 获取当前场景索引（第11个返回值，Step 5 添加）
        local _, _, _, _, _, _, _, _, _, _, sceneIdx = getParams_()
        local targetScene = sceneIdx or 0

        -- 每次打开编辑器都重新加载当前游戏场景
        MapEditor.LoadScene(targetScene)

        -- 读取玩家实际位置，同步到编辑器 spawnRed / spawnBlack
        if getPlayers_ and mapData_ then
            local players = getPlayers_()
            local cs = EditorConst.CELL_SIZE
            if players.red then
                local px, py = players.red.x, players.red.y
                -- 防御 NaN：NaN ~= NaN 为 true
                if px == px and py == py then
                    local gx = math.floor(px / cs)
                    local gy = math.floor(py / cs)
                    -- 清除旧 spawn_red 格子
                    if mapData_.spawnRed then
                        local oldKey = EditorTools.CellKey(mapData_.spawnRed.gx, mapData_.spawnRed.gy)
                        if mapData_.cells[oldKey] and mapData_.cells[oldKey].type == "spawn_red" then
                            mapData_.cells[oldKey] = nil
                        end
                    end
                    mapData_.spawnRed = { gx = gx, gy = gy }
                    mapData_.cells[EditorTools.CellKey(gx, gy)] = { type = "spawn_red", visibleTo = "all" }
                    print(string.format("[MapEditor] Synced spawnRed to player pos (%.1f,%.1f) -> grid(%.0f,%.0f)",
                        px, py, gx, gy))
                else
                    print("[MapEditor] WARNING: spawnRed player pos is NaN, skipping sync")
                end
            end
            if players.black then
                local px, py = players.black.x, players.black.y
                -- 防御 NaN：NaN ~= NaN 为 true
                if px == px and py == py then
                    local gx = math.floor(px / cs)
                    local gy = math.floor(py / cs)
                    -- 清除旧 spawn_black 格子
                    if mapData_.spawnBlack then
                        local oldKey = EditorTools.CellKey(mapData_.spawnBlack.gx, mapData_.spawnBlack.gy)
                        if mapData_.cells[oldKey] and mapData_.cells[oldKey].type == "spawn_black" then
                            mapData_.cells[oldKey] = nil
                        end
                    end
                    mapData_.spawnBlack = { gx = gx, gy = gy }
                    mapData_.cells[EditorTools.CellKey(gx, gy)] = { type = "spawn_black", visibleTo = "all" }
                    print(string.format("[MapEditor] Synced spawnBlack to player pos (%.1f,%.1f) -> grid(%.0f,%.0f)",
                        px, py, gx, gy))
                else
                    print("[MapEditor] WARNING: spawnBlack player pos is NaN, skipping sync")
                end
            end
        end

        EditorUI.UpdateState({
            mapName     = mapData_.name,
            gridW       = mapData_.gridW,
            gridH       = mapData_.gridH,
            curTool     = curTool_,
            viewMode    = viewModeIdx_,
            brushSize   = brushSize_,
            hideBgFg    = hideBgFg_,
            curActIdx   = curActIdx_,
            curSceneIdx = curSceneIdx_,
            portalGroup = curPortalGroup_,
        })
        EditorUI.Show()
        print("[MapEditor] ON – scene " .. curSceneIdx_)
    else
        EditorUI.Hide()
        print("[MapEditor] OFF")
    end
end

---@return boolean
function MapEditor.IsActive()
    return active_
end

-- ═══════════════════════════════════════════════
-- 坐标转换
-- ═══════════════════════════════════════════════

--- 鼠标物理像素 → 设计空间坐标
local function mouseToDesign()
    local _, _, dpr, viewScale, viewOffX, viewOffY = getParams_()
    local mx = input.mousePosition.x / dpr
    local my = input.mousePosition.y / dpr
    return (mx - viewOffX) / viewScale, (my - viewOffY) / viewScale
end

--- 设计空间 → 编辑器世界坐标
local function designToWorld(dx, dy)
    local _, _, _, _, _, _, designW, designH = getParams_()
    local wx = (dx - designW * 0.5) / (PPU * edZoom_) + edPanX_
    local wy = (designH * 0.5 - dy) / (PPU * edZoom_) + edPanY_
    return wx, wy
end

--- 编辑器世界坐标 → 设计空间（含 edZoom，用于 NanoVG 缩放变换外部）
local function worldToDesign(wx, wy)
    local _, _, _, _, _, _, designW, designH = getParams_()
    local dx = (wx - edPanX_) * PPU * edZoom_ + designW * 0.5
    local dy = designH * 0.5 - (wy - edPanY_) * PPU * edZoom_
    return dx, dy
end

--- 编辑器世界坐标 → 设计空间（不含 edZoom，用于 NanoVG 缩放变换内部）
--- 与 WorldRenderer.WorldToScreen 公式一致，让 NanoVG 变换处理缩放
local function worldToScreenRaw(wx, wy)
    local _, _, _, _, _, _, designW, designH = getParams_()
    local sx = (wx - edPanX_) * PPU + designW * 0.5
    local sy = designH * 0.5 - (wy - edPanY_) * PPU
    return sx, sy
end

--- 鼠标 → 网格坐标
local function mouseToGrid()
    local dx, dy = mouseToDesign()
    local wx, wy = designToWorld(dx, dy)
    -- 移动工具、道具、NPC使用半格精度；地形保持整格
    local useHalf = (curTool_ == EditorConst.TOOL.MOVE)
                 or EditorConst.IS_PROP[curTool_]
                 or (curTool_ == EditorConst.TOOL.NPC)
    return EditorTools.WorldToGrid(wx, wy, useHalf)
end

--- 鼠标是否在 UI 面板区域
local function isMouseOverPanel()
    local _, _, dpr, viewScale = getParams_()
    -- PANEL_WIDTH 是设计像素，需乘 viewScale 转为逻辑像素，再与逻辑鼠标坐标比较
    return (input.mousePosition.x / dpr) < EditorConst.PANEL_WIDTH * viewScale
end

-- ═══════════════════════════════════════════════
-- 输入处理
-- ═══════════════════════════════════════════════

--- 标记需要防抖同步（编辑操作后调用）
markDirty = function()
    syncTimer_ = SYNC_DELAY
    syncPending_ = true
end

--- 执行同步：保存 + 发送 DEBUG_RELOAD
local function doSync()
    if not mapData_ then return end

    -- ── 诊断：同步前打印 mapData 统计 ──
    local cellCount, propCount = 0, 0
    for _ in pairs(mapData_.cells) do cellCount = cellCount + 1 end
    if mapData_.props then for _ in pairs(mapData_.props) do propCount = propCount + 1 end end
    print(string.format("[MapEditor][DIAG] doSync PRE: cells=%d, props=%d, npcs=%d, spawnRed=%s, spawnBlack=%s, exit=%s",
        cellCount, propCount, #mapData_.npcs,
        mapData_.spawnRed and (mapData_.spawnRed.gx..","..mapData_.spawnRed.gy) or "nil",
        mapData_.spawnBlack and (mapData_.spawnBlack.gx..","..mapData_.spawnBlack.gy) or "nil",
        mapData_.exitPos and (mapData_.exitPos.gx..","..mapData_.exitPos.gy) or "nil"))
    -- 打印 cells 类型分布
    local typeCounts = {}
    for _, cell in pairs(mapData_.cells) do
        local t = cell.type
        typeCounts[t] = (typeCounts[t] or 0) + 1
    end
    local typeStr = ""
    for t, c in pairs(typeCounts) do typeStr = typeStr .. t .. "=" .. c .. " " end
    print("[MapEditor][DIAG] cell types: " .. typeStr)
    -- 打印 props 详情
    if mapData_.props then
        local propDetail = ""
        for k, v in pairs(mapData_.props) do
            propDetail = propDetail .. k .. "=" .. tostring(v.type) .. " "
        end
        print("[MapEditor][DIAG] props detail: " .. propDetail)
    end

    MapSerializer.SaveAsScene(mapData_, curSceneIdx_)
    -- 需要通过 getParams_ 获取 serverConn 来发送 DEBUG_RELOAD
    -- 但 MapEditor 没有直接持有 serverConn，所以暴露一个回调
    if MapEditor.onSyncReload then
        MapEditor.onSyncReload(curSceneIdx_)
    end
    print(string.format("[MapEditor] Auto-synced scene %d", curSceneIdx_))
end

--- 查找指定网格位置的元素（用于 MOVE 工具点选）
--- 优先级：NPC > 道具 > 地形
---@param gx number
---@param gy number
---@return table|nil  { gx, gy, layer, npcIdx? }
local function findElemAt(gx, gy)
    if not mapData_ then return nil end
    -- NPC
    for i, npc in ipairs(mapData_.npcs) do
        if npc.gx == gx and npc.gy == gy then
            return { gx = gx, gy = gy, layer = "npc", npcIdx = i }
        end
    end
    -- 道具
    local key = EditorTools.CellKey(gx, gy)
    if mapData_.props and mapData_.props[key] then
        return { gx = gx, gy = gy, layer = "prop" }
    end
    -- 地形
    if mapData_.cells[key] then
        return { gx = gx, gy = gy, layer = "cell" }
    end
    return nil
end

--- 移动已选中的元素到新位置
---@param fromGX number
---@param fromGY number
---@param toGX number
---@param toGY number
---@param sel table selectedElem_
---@return boolean success
local function moveElement(fromGX, fromGY, toGX, toGY, sel)
    if not mapData_ then return false end
    if fromGX == toGX and fromGY == toGY then return false end
    if not EditorTools.InBounds(mapData_, toGX, toGY) then return false end

    local fromKey = EditorTools.CellKey(fromGX, fromGY)
    local toKey   = EditorTools.CellKey(toGX, toGY)

    print(string.format("[MOVE][DIAG] moveElement: layer=%s from=(%g,%g) key=%s → to=(%g,%g) key=%s",
        sel.layer, fromGX, fromGY, fromKey, toGX, toGY, toKey))

    if sel.layer == "npc" then
        local npc = mapData_.npcs[sel.npcIdx]
        if not npc then
            print("[MOVE][DIAG]   NPC: npcIdx=" .. tostring(sel.npcIdx) .. " NOT FOUND, return false")
            return false
        end
        -- 目标位置不能已有 NPC
        for _, n in ipairs(mapData_.npcs) do
            if n.gx == toGX and n.gy == toGY then
                print("[MOVE][DIAG]   NPC: target already has NPC, return false")
                return false
            end
        end
        npc.gx = toGX
        npc.gy = toGY
        print(string.format("[MOVE][DIAG]   NPC: moved OK, npc.gx=%g npc.gy=%g", npc.gx, npc.gy))
        return true
    elseif sel.layer == "prop" then
        local propData = mapData_.props[fromKey]
        if not propData then
            print("[MOVE][DIAG]   PROP: fromKey=" .. fromKey .. " has NO data, return false")
            return false
        end
        -- 目标已有道具则不能移
        if mapData_.props[toKey] then
            print("[MOVE][DIAG]   PROP: toKey=" .. toKey .. " already occupied, return false")
            return false
        end
        mapData_.props[toKey] = propData
        mapData_.props[fromKey] = nil
        -- 验证
        print(string.format("[MOVE][DIAG]   PROP: moved OK. props[%s]=%s props[%s]=%s",
            fromKey, tostring(mapData_.props[fromKey]),
            toKey, tostring(mapData_.props[toKey])))
        return true
    elseif sel.layer == "cell" then
        local cellData = mapData_.cells[fromKey]
        if not cellData then
            print("[MOVE][DIAG]   CELL: fromKey=" .. fromKey .. " has NO data, return false")
            return false
        end

        -- 30° 斜坡占2格，需要同时移动配对半格
        if cellData.type == "slope" and cellData.angle == 30 and cellData.half then
            local pairFromGX, pairToGX
            if cellData.half == "left" then
                pairFromGX = fromGX + 1
                pairToGX   = toGX + 1
            else  -- "right"
                pairFromGX = fromGX - 1
                pairToGX   = toGX - 1
            end
            local pairFromKey = EditorTools.CellKey(pairFromGX, fromGY)
            local pairData = mapData_.cells[pairFromKey]
            if pairData then
                -- 配对半体存在：同时移动两格
                local pairToKey = EditorTools.CellKey(pairToGX, toGY)
                if not EditorTools.InBounds(mapData_, pairToGX, toGY) then return false end
                if mapData_.cells[toKey] then return false end
                if mapData_.cells[pairToKey] then return false end
                mapData_.cells[fromKey] = nil
                mapData_.cells[pairFromKey] = nil
                mapData_.cells[toKey] = cellData
                mapData_.cells[pairToKey] = pairData
                return true
            end
            -- 配对半体已被擦除：作为孤立单cell移动（跳过，走下方普通逻辑）
            print("[MOVE][DIAG]   30° slope orphaned half, moving as single cell")
        end

        -- 目标已有地形则不能移
        if mapData_.cells[toKey] then
            print("[MOVE][DIAG]   CELL: toKey=" .. toKey .. " already occupied, return false")
            return false
        end
        mapData_.cells[toKey] = cellData
        mapData_.cells[fromKey] = nil
        -- 验证
        print(string.format("[MOVE][DIAG]   CELL: moved OK type=%s. cells[%s]=%s cells[%s]=%s",
            tostring(cellData.type),
            fromKey, tostring(mapData_.cells[fromKey]),
            toKey, tostring(mapData_.cells[toKey])))
        -- 更新特殊标记
        if cellData.type == EditorConst.TOOL.SPAWN_RED then
            mapData_.spawnRed = { gx = toGX, gy = toGY }
        elseif cellData.type == EditorConst.TOOL.SPAWN_BLACK then
            mapData_.spawnBlack = { gx = toGX, gy = toGY }
        elseif cellData.type == EditorConst.TOOL.EXIT then
            mapData_.exitPos = { gx = toGX, gy = toGY }
        end
        return true
    end
    print("[MOVE][DIAG]   unknown layer=" .. tostring(sel.layer) .. ", return false")
    return false
end

--- 笔刷放置（支持多格子笔刷）
local function placeBrush(gx, gy)
    -- 单例工具、NPC、道具（ladder/crate）、传送点：只放置单格
    if EditorTools.IsSingleton(curTool_) or curTool_ == EditorConst.TOOL.NPC
       or EditorConst.IS_PROP[curTool_] or EditorConst.IS_PORTAL[curTool_] then
        local changed = EditorTools.SetCell(mapData_, gx, gy, curTool_, curVisibleTo_, curNpcPresetId_, curPortalGroup_)
        -- 放置出生点后立即传送对应玩家
        if changed and MapEditor.onSpawnTeleport then
            if curTool_ == EditorConst.TOOL.SPAWN_RED then
                local wx, wy = EditorTools.GridToWorldCenter(gx, gy)
                MapEditor.onSpawnTeleport(Shared.ROLE.RED, wx, wy)
            elseif curTool_ == EditorConst.TOOL.SPAWN_BLACK then
                local wx, wy = EditorTools.GridToWorldCenter(gx, gy)
                MapEditor.onSpawnTeleport(Shared.ROLE.BLACK, wx, wy)
            end
        end
        -- 诊断：道具放置详细日志
        if EditorConst.IS_PROP[curTool_] then
            local propCount = 0
            if mapData_.props then for _ in pairs(mapData_.props) do propCount = propCount + 1 end end
            print(string.format("[DIAG-PROP] placeBrush tool=%s gx=%g gy=%g changed=%s propCount=%d",
                curTool_, gx, gy, tostring(changed), propCount))
        end
        return
    end
    local halfB = math.floor((brushSize_ - 1) / 2)
    for bx = 0, brushSize_ - 1 do
        for by = 0, brushSize_ - 1 do
            EditorTools.SetCell(mapData_, gx - halfB + bx, gy - halfB + by, curTool_, curVisibleTo_, curNpcPresetId_)
        end
    end
end

--- 擦除（固定只删一格，不受笔刷大小影响）
local function eraseBrush(gx, gy)
    EditorTools.EraseCell(mapData_, gx, gy)
end

--- 获取 overlay 的世界矩形（与 WorldRenderer.DrawGroundOverlays 逻辑完全一致）
--- @return number, number, number, number  (worldLeft, worldBot, worldRight, worldTop)
local function getOverlayBounds(ov)
    local cs = EditorConst.CELL_SIZE
    local basePH = (ov.gy2 - ov.gy1 + 1) * cs * PPU
    local basePW = (ov.gx2 - ov.gx1 + 1) * cs * PPU
    local extraTop = ov.extraTopPx or 0
    local newPH = basePH + extraTop
    local newPW = basePW * (newPH / basePH)
    local centerShiftPx = (newPW - basePW) * 0.5
    local worldLeft  = ov.gx1 * cs + (ov.offsetX or 0) / PPU - centerShiftPx / PPU
    local worldBot   = ov.gy1 * cs + (ov.offsetY or 0) / PPU
    local worldRight = worldLeft + newPW / PPU
    local worldTop   = worldBot  + newPH / PPU
    return worldLeft, worldBot, worldRight, worldTop
end

--- 检测鼠标当前位置是否命中某个 grid overlay（返回 ov 表或 nil）
local function hitTestOverlayAtMouse(role)
    if not mapData_ or not mapData_.groundOverlays then return nil end
    local dx, dy = mouseToDesign()
    local wx, wy = designToWorld(dx, dy)
    for _, ov in ipairs(mapData_.groundOverlays) do
        if role == "all" or ov.role == role then
            local wl, wb, wr, wt = getOverlayBounds(ov)
            if wx >= wl and wx <= wr and wy >= wb and wy <= wt then
                return ov
            end
        end
    end
    return nil
end

--- 获取 freeOverlay 的 AABB（世界坐标，仅用于命中测试，忽略旋转）
--- @return number, number, number, number  (worldLeft, worldBot, worldRight, worldTop)
local function getFreeOverlayBounds(fov)
    local hw = (fov.w or 1) * 0.5
    local hh = (fov.h or 1) * 0.5
    return fov.x - hw, fov.y - hh, fov.x + hw, fov.y + hh
end

--- 检测鼠标是否命中某个 freeOverlay（返回 fov 表或 nil，优先返回最靠前/ID最大的）
local function hitTestFreeOverlayAtMouse(role)
    if not mapData_ or not mapData_.freeOverlays then return nil end
    local dx, dy = mouseToDesign()
    local wx, wy = designToWorld(dx, dy)
    local hit = nil
    for _, fov in ipairs(mapData_.freeOverlays) do
        if fov.role == role or fov.role == "all" then
            local wl, wb, wr, wt = getFreeOverlayBounds(fov)
            if wx >= wl and wx <= wr and wy >= wb and wy <= wt then
                hit = fov  -- 最后一个（绘制最靠前）优先
            end
        end
    end
    return hit
end

--- 扫描 image/贴图/<subPath> 目录，返回 (imageList, dirList)
--- 沙箱中 GetCurrentDir / GetResourceFileName / ScanDir 均被禁止，
--- 改用静态清单文件 Editor/AssetManifest.lua 维护素材列表。
---@param subPath string  相对于 image/贴图/ 的子路径，根目录传 ""
---@return string[], string[]
scanAssetDir = function(subPath)
    local AssetManifest = require("Editor.AssetManifest")
    local images, dirs = AssetManifest.scan(subPath)
    print(string.format("[AssetBrowser] manifest scan('%s'): %d dirs, %d images",
        tostring(subPath), #dirs, #images))
    return images, dirs
end

--- 兼容旧调用（内部已不使用）
scanAssetImages = function()
    local imgs, _ = scanAssetDir("")
    return imgs
end

--- 生成唯一的 freeOverlay ID
local function nextFreeOvId()
    overlayIdCounter_ = overlayIdCounter_ + 1
    return "fov_" .. overlayIdCounter_
end

--- 在当前视角角色的视野中心添加一个自由贴图
---@param imagePath string  资源路径（相对于资源根）
addFreeOverlay = function(imagePath)
    if not mapData_ then return end
    if not mapData_.freeOverlays then mapData_.freeOverlays = {} end

    -- 防抖：同一张图片 200ms 内不重复添加（防止 onClick 因双击多次触发）
    -- 注意：不同图片不受防抖限制，允许快速连续添加不同贴图
    local now = time:GetElapsedTime()
    if imagePath == lastAddOverlayPath_ and now - lastAddOverlayTime_ < 0.2 then
        print("[MapEditor] addFreeOverlay debounced, skipped: " .. imagePath)
        return
    end
    lastAddOverlayTime_ = now
    lastAddOverlayPath_ = imagePath

    -- 标记：当帧跳过命中测试清选，避免 UI onClick 和 HandleInput 鼠标事件同帧冲突
    justAddedOverlayFrame_ = true

    -- 放置在当前编辑器视野中心
    local cx = edPanX_
    local cy = edPanY_
    local curRole = EditorConst.VIEW_MODES[viewModeIdx_]

    -- 从文件名解析网格尺寸
    -- 命名规范：任意字母前缀 + 宽格数 + "_" + 高格数 + ".png"
    -- 支持整数和小数，例如：HD4_2.png、HXD2_2.5.png、HXU4_3.5.png
    -- 若匹配则按设计网格尺寸放置；否则默认 4×1 格并依像素宽高比自动修正
    local cs = EditorConst.CELL_SIZE
    local initW, initH
    local aspectFixed = false
    local pendingAspect = false
    local fnGridW, fnGridH = imagePath:match("[A-Za-z]+(%d+%.?%d*)_(%d+%.?%d*)%.png$")
    if fnGridW and fnGridH then
        initW = tonumber(fnGridW) * cs
        initH = tonumber(fnGridH) * cs
        aspectFixed = true   -- 尺寸由文件名指定，无需首帧修正
    else
        initW = 4.0
        initH = 1.0
        pendingAspect = true -- 首帧渲染时用像素宽高比修正 h
    end
    local newFov = {
        id             = nextFreeOvId(),
        role           = curRole,
        imagePath      = imagePath,
        x              = cx,
        y              = cy,
        w              = initW,
        h              = initH,
        rotation       = 0,
        _pendingAspect = pendingAspect or nil,
        _aspectFixed   = aspectFixed or nil,
    }
    mapData_.freeOverlays[#mapData_.freeOverlays + 1] = newFov

    -- 选中刚添加的贴图
    selectedOverlayIds_ = { [newFov.id] = true }
    WorldRenderer.SetFreeOverlays(mapData_.freeOverlays)
    local selCount = 0
    for _ in pairs(selectedOverlayIds_) do selCount = selCount + 1 end
    EditorUI.UpdateState({ selectedOverlayCount = selCount, assetImages = assetImages_ })
    EditorUI.RefreshOverlayAdjust()
    markDirty()
    print(string.format("[MapEditor] Added freeOverlay: %s at (%.2f, %.2f)", imagePath, cx, cy))
end

--- 处理编辑器输入（每帧调用）
---@param dt number
function MapEditor.HandleInput(dt)
    if not active_ or not mapData_ then return end

    animTime_ = animTime_ + dt

    -- ── 防抖同步计时器 ──
    if syncPending_ then
        syncTimer_ = syncTimer_ - dt
        if syncTimer_ <= 0 then
            syncPending_ = false
            syncTimer_ = 0
            doSync()
        end
    end

    local ctrl  = input:GetQualifierDown(QUAL_CTRL)
    local shift = input:GetQualifierDown(QUAL_SHIFT)

    -- ── 快捷键 ──

    -- Ctrl+S 保存到当前场景
    if ctrl and input:GetKeyPress(KEY_S) then
        MapSerializer.SaveAsScene(mapData_, curSceneIdx_)
        print(string.format("[MapEditor] Saved to scene %d", curSceneIdx_))
        return
    end

    -- Ctrl+L 加载
    if ctrl and input:GetKeyPress(KEY_L) then
        local loaded = MapSerializer.Load(mapName_)
        if loaded then
            mapData_ = loaded
            undoStack_ = {}
            redoStack_ = {}
            print("[MapEditor] Loaded")
        end
        return
    end

    -- Ctrl+Z 撤销
    if ctrl and not shift and input:GetKeyPress(KEY_Z) then
        if EditorTools.PopUndo(mapData_, undoStack_, redoStack_) then
            print("[MapEditor] Undo")
            markDirty()
        end
        return
    end

    -- Ctrl+Shift+Z / Ctrl+Y 重做
    if (ctrl and shift and input:GetKeyPress(KEY_Z)) or (ctrl and input:GetKeyPress(KEY_Y)) then
        if EditorTools.PopRedo(mapData_, undoStack_, redoStack_) then
            print("[MapEditor] Redo")
            markDirty()
        end
        return
    end

    -- ── 贴图调整模式：Ctrl+C 复制，Ctrl+V 粘贴 ──
    if overlayAdjustMode_ then
        if ctrl and input:GetKeyPress(KEY_C) then
            copiedOverlays_ = {}
            -- 复制选中的 freeOverlays（新系统，支持旋转/缩放/拖拽）
            if mapData_ and mapData_.freeOverlays then
                for _, fov in ipairs(mapData_.freeOverlays) do
                    if selectedOverlayIds_[fov.id] then
                        local cp = {}
                        for k, v in pairs(fov) do cp[k] = v end
                        cp._isFreeOverlay = true   -- 标记来源，粘贴时区分
                        copiedOverlays_[#copiedOverlays_ + 1] = cp
                    end
                end
            end
            print(string.format("[MapEditor] Overlay copy: %d items", #copiedOverlays_))
            return
        end
        if ctrl and input:GetKeyPress(KEY_V) then
            if #copiedOverlays_ > 0 and mapData_ then
                if not mapData_.freeOverlays then mapData_.freeOverlays = {} end
                local newIds = {}
                for _, src in ipairs(copiedOverlays_) do
                    overlayIdCounter_ = overlayIdCounter_ + 1
                    local newFov = {}
                    for k, v in pairs(src) do newFov[k] = v end
                    newFov.id            = "fov_paste_" .. overlayIdCounter_
                    newFov._isFreeOverlay = nil   -- 清除临时标记
                    newFov.migratedFromId = nil   -- 粘贴副本不继承迁移来源
                    newFov.x             = (newFov.x or 0) + 0.5  -- 右移半格以示区别
                    mapData_.freeOverlays[#mapData_.freeOverlays + 1] = newFov
                    newIds[newFov.id] = true
                end
                selectedOverlayIds_ = newIds
                WorldRenderer.SetFreeOverlays(mapData_.freeOverlays)
                local selCount = 0
                for _ in pairs(selectedOverlayIds_) do selCount = selCount + 1 end
                EditorUI.UpdateState({ selectedOverlayCount = selCount })
                EditorUI.RefreshOverlayAdjust()
                markDirty()
                print(string.format("[MapEditor] Overlay paste: %d items", #copiedOverlays_))
            end
            return
        end
    end

    -- V 切换视角（仅改变显示模式，不影响 curVisibleTo_）
    if input:GetKeyPress(KEY_V) then
        viewModeIdx_ = viewModeIdx_ % #EditorConst.VIEW_MODES + 1
        EditorUI.RefreshViewHighlight(viewModeIdx_)
        print("[MapEditor] View: " .. EditorConst.VIEW_LABELS[viewModeIdx_])
    end

    -- ── 视图控制 ──

    -- 滚轮缩放（仅在工具栏外生效，工具栏内由 UI 组件自行处理滚动）
    local wheel = input.mouseMoveWheel
    if wheel ~= 0 and not isMouseOverPanel() then
        if wheel > 0 then
            edZoom_ = math.min(EditorConst.ZOOM_MAX, edZoom_ * (1 + EditorConst.ZOOM_STEP))
        else
            edZoom_ = math.max(EditorConst.ZOOM_MIN, edZoom_ * (1 - EditorConst.ZOOM_STEP))
        end
    end

    -- WASD 平移
    local panSpeed = EditorConst.PAN_SPEED / edZoom_ * dt
    if input:GetKeyDown(KEY_W) then edPanY_ = edPanY_ + panSpeed end
    if input:GetKeyDown(KEY_S) and not ctrl then edPanY_ = edPanY_ - panSpeed end
    if input:GetKeyDown(KEY_A) then edPanX_ = edPanX_ - panSpeed end
    if input:GetKeyDown(KEY_D) then edPanX_ = edPanX_ + panSpeed end

    -- ── 贴图调整模式：移动/旋转/缩放（按住按键持续调整） ──
    if overlayAdjustMode_ and mapData_ then
        -- ── 方向键：持续移动 overlay（速度与 dt 关联，帧率无关） ──
        local MOVE_SPEED = 80  -- 屏幕像素/秒
        local dxPx = 0
        local dyPx = 0
        if input:GetKeyDown(KEY_LEFT)  then dxPx = -MOVE_SPEED * dt end
        if input:GetKeyDown(KEY_RIGHT) then dxPx =  MOVE_SPEED * dt end
        if input:GetKeyDown(KEY_UP)    then dyPx =  MOVE_SPEED * dt end
        if input:GetKeyDown(KEY_DOWN)  then dyPx = -MOVE_SPEED * dt end
        if dxPx ~= 0 or dyPx ~= 0 then
            local anyMoved = false
            if mapData_.groundOverlays then
                for _, ov in ipairs(mapData_.groundOverlays) do
                    if selectedOverlayIds_[ov.id] then
                        ov.offsetX = (ov.offsetX or 0) + dxPx
                        ov.offsetY = (ov.offsetY or 0) + dyPx
                        anyMoved = true
                    end
                end
            end
            if mapData_.freeOverlays then
                for _, fov in ipairs(mapData_.freeOverlays) do
                    if selectedOverlayIds_[fov.id] then
                        fov.x = fov.x + dxPx / PPU
                        fov.y = fov.y + dyPx / PPU
                        anyMoved = true
                    end
                end
            end
            if anyMoved then
                WorldRenderer.SetSceneOverlays(mapData_.groundOverlays or {})
                WorldRenderer.SetFreeOverlays(mapData_.freeOverlays or {})
                EditorUI.RefreshOverlayAdjust()
                markDirty()
            end
        end

        -- ── Delete / Backspace：删除选中的 freeOverlay ──
        -- 同时监听 KEY_BACKSPACE，因 WASM/浏览器环境 Delete 可能被 DOM 捕获
        if input:GetKeyPress(KEY_DELETE) or input:GetKeyPress(KEY_BACKSPACE) then
            local deleted = false
            if mapData_.freeOverlays then
                local kept = {}
                for _, fov in ipairs(mapData_.freeOverlays) do
                    if selectedOverlayIds_[fov.id] then
                        deleted = true
                    else
                        kept[#kept + 1] = fov
                    end
                end
                if deleted then
                    mapData_.freeOverlays = kept
                end
            end
            if deleted then
                selectedOverlayIds_ = {}
                WorldRenderer.SetFreeOverlays(mapData_.freeOverlays)
                EditorUI.UpdateState({ selectedOverlayCount = 0 })
                EditorUI.RefreshOverlayAdjust()
                markDirty()
                print("[MapEditor] Deleted selected freeOverlays")
            end
        end

        -- ── [ / ]：持续旋转 freeOverlay（90°/秒） ──
        local rotDelta = 0
        if input:GetKeyDown(KEY_LEFTBRACKET)  then rotDelta = rotDelta - 90 * dt end
        if input:GetKeyDown(KEY_RIGHTBRACKET) then rotDelta = rotDelta + 90 * dt end
        if rotDelta ~= 0 and mapData_.freeOverlays then
            local anyRot = false
            for _, fov in ipairs(mapData_.freeOverlays) do
                if selectedOverlayIds_[fov.id] then
                    fov.rotation = ((fov.rotation or 0) + rotDelta) % 360
                    anyRot = true
                end
            end
            if anyRot then
                WorldRenderer.SetFreeOverlays(mapData_.freeOverlays)
                EditorUI.RefreshOverlayAdjust()
                markDirty()
            end
        end

        -- ── - / =：持续缩放 freeOverlay（等比，约 1.5×/秒 增 / 0.67×/秒 减） ──
        local scaleDir = 0
        if input:GetKeyDown(KEY_MINUS)  then scaleDir = scaleDir - 1 end
        if input:GetKeyDown(KEY_EQUALS) then scaleDir = scaleDir + 1 end
        if scaleDir ~= 0 and mapData_.freeOverlays then
            local factor = scaleDir > 0 and (1.5 ^ dt) or ((1 / 1.5) ^ dt)
            local anyScaled = false
            for _, fov in ipairs(mapData_.freeOverlays) do
                if selectedOverlayIds_[fov.id] then
                    fov.w = math.max(0.1, (fov.w or 1) * factor)
                    -- 清除 _aspectFixed，下帧 DrawFreeOverlays 用新 w 和图片宽高比重算 h
                    fov._aspectFixed = nil
                    anyScaled = true
                end
            end
            if anyScaled then
                WorldRenderer.SetFreeOverlays(mapData_.freeOverlays)
                EditorUI.RefreshOverlayAdjust()
                markDirty()
            end
        end
    end

    -- 中键拖拽
    if input:GetMouseButtonPress(MOUSEB_MIDDLE) then
        midDrag_ = true
        midDragStartX_, midDragStartY_ = mouseToDesign()
        midDragPanStartX_ = edPanX_
        midDragPanStartY_ = edPanY_
    end
    if midDrag_ then
        if input:GetMouseButtonDown(MOUSEB_MIDDLE) then
            local mx, my = mouseToDesign()
            edPanX_ = midDragPanStartX_ - (mx - midDragStartX_) / (PPU * edZoom_)
            edPanY_ = midDragPanStartY_ + (my - midDragStartY_) / (PPU * edZoom_)
        else
            midDrag_ = false
        end
    end

    -- ── 放置 / 删除 / 移动（跳过 UI 面板区域） ──
    if isMouseOverPanel() then
        mouseDown_ = false
        moveDragging_ = false
        return
    end

    -- ── 贴图调整模式：点击选中 overlay / 拖拽 freeOverlay，完全屏蔽网格操作 ──
    -- 所有视图模式下均可操作；逻辑视图(1)用"all"角色命中所有贴图
    if overlayAdjustMode_ then
        local curRole = viewModeIdx_ >= 2
            and EditorConst.VIEW_MODES[viewModeIdx_]
            or "all"

        -- ── 鼠标左键按下：命中检测 + 开始拖拽 ──
        -- justAddedOverlayFrame_：当帧内刚通过 UI 按钮添加了贴图，跳过命中测试
        -- 避免 UI onClick（鼠标松开）和 GetMouseButtonPress 同帧触发，清除新贴图的选中状态
        if justAddedOverlayFrame_ then
            justAddedOverlayFrame_ = false  -- 消费标记，仅跳过一帧
        elseif input:GetMouseButtonPress(MOUSEB_LEFT) and not (freeDragArmed_ and not freeDragArmedWaitRelease_) then
            -- 优先检测 freeOverlay，再检测 gridOverlay
            -- 注：当 freeDragArmed_=true 且已就绪（waitRelease=false）时跳过此块，
            --   避免单击处理器把 freeDragArmed_ 清掉，让 armed→active 块处理激活。
            local hitFov = hitTestFreeOverlayAtMouse(curRole)
            local hitOv  = (not hitFov) and hitTestOverlayAtMouse(curRole) or nil
            local hitId  = hitFov and hitFov.id or (hitOv and hitOv.id or nil)
            local now    = time:GetElapsedTime()

            if hitId then
                if ctrl then
                    -- Ctrl+Click：切换选中状态
                    if selectedOverlayIds_[hitId] then
                        selectedOverlayIds_[hitId] = nil
                    else
                        selectedOverlayIds_[hitId] = true
                    end
                else
                    -- 单击：选中目标贴图（保留多选组，以便双击后整组拖拽）
                    if not selectedOverlayIds_[hitId] then
                        selectedOverlayIds_ = { [hitId] = true }
                    end
                end

                -- 双击检测：同一 freeOverlay 在间隔内再次点击 → 启动拖拽
                local timeDiff = now - lastClickTime_
                print(string.format("[MapEditor] click check: hitFov=%s sel=%s sameId=%s dt=%.3f/%.3f",
                    tostring(hitFov ~= nil),
                    tostring(selectedOverlayIds_[hitId] == true),
                    tostring(hitId == lastClickOvId_),
                    timeDiff, DOUBLE_CLICK_INTERVAL_))
                if hitFov and selectedOverlayIds_[hitId]
                    and hitId == lastClickOvId_
                    and timeDiff <= DOUBLE_CLICK_INTERVAL_ then
                    -- 双击：进入拖拽待机，记录选中贴图的原始坐标
                    -- （不直接设 freeDragging_，因为双击第二击松手很快，
                    --   GetMouseButtonDown 同帧可能已经为 false 导致拖拽被立即取消）
                    freeDragArmed_ = true
                    freeDragArmedWaitRelease_ = true   -- 等鼠标先松开，避免同帧立即激活
                    freeDragOriginals_ = {}
                    if mapData_.freeOverlays then
                        for _, fov in ipairs(mapData_.freeOverlays) do
                            if selectedOverlayIds_[fov.id] then
                                freeDragOriginals_[fov.id] = { x = fov.x, y = fov.y }
                            end
                        end
                    end
                    -- 消费双击记录，防止连续触发
                    lastClickOvId_ = nil
                    lastClickTime_ = 0
                    print("[MapEditor] drag armed")
                else
                    -- 单击：仅选中，记录本次点击用于双击检测
                    freeDragging_ = false
                    freeDragArmed_ = false
                    lastClickOvId_ = hitFov and hitId or nil
                    lastClickTime_ = now
                end
            else
                if not ctrl then
                    -- 点击空白区域取消全部选中
                    selectedOverlayIds_ = {}
                end
                freeDragging_  = false
                lastClickOvId_ = nil
            end
            local selCount = 0
            for _ in pairs(selectedOverlayIds_) do selCount = selCount + 1 end
            EditorUI.UpdateState({ selectedOverlayCount = selCount })
            EditorUI.RefreshOverlayAdjust()
        end

        -- ── 拖拽待机 → 激活：先等鼠标松开，再等下次按住才激活 ──
        if freeDragArmedWaitRelease_ then
            -- 双击同帧鼠标仍按住，等它松开后才允许激活
            if not input:GetMouseButtonDown(MOUSEB_LEFT) then
                freeDragArmedWaitRelease_ = false   -- 已松开，进入可激活状态
                print("[MapEditor] drag armed ready (released)")
            end
        elseif freeDragArmed_ then
            if input:GetMouseButtonDown(MOUSEB_LEFT) then
                -- 鼠标重新按住，正式激活拖拽
                freeDragArmed_ = false
                freeDragging_ = true
                freeDragStartMouseX_, freeDragStartMouseY_ = mouseToDesign()
                -- 重新记录原始坐标（待机期间坐标没变，但以当前鼠标位置为起点）
                freeDragOriginals_ = {}
                if mapData_.freeOverlays then
                    for _, fov in ipairs(mapData_.freeOverlays) do
                        if selectedOverlayIds_[fov.id] then
                            freeDragOriginals_[fov.id] = { x = fov.x, y = fov.y }
                        end
                    end
                end
                print("[MapEditor] drag activated")
            end
            -- 待机状态不做任何其他操作，等待鼠标按下
        end

        -- ── 鼠标左键持续按住：拖拽 freeOverlay ──
        if freeDragging_ and input:GetMouseButtonDown(MOUSEB_LEFT) then
            local mx, my = mouseToDesign()
            local ddx = (mx - freeDragStartMouseX_) / (PPU * edZoom_)
            local ddy = -(my - freeDragStartMouseY_) / (PPU * edZoom_)  -- Y轴向下转向上
            if mapData_.freeOverlays then
                for _, fov in ipairs(mapData_.freeOverlays) do
                    local orig = freeDragOriginals_[fov.id]
                    if orig then
                        fov.x = orig.x + ddx
                        fov.y = orig.y + ddy
                    end
                end
                WorldRenderer.SetFreeOverlays(mapData_.freeOverlays)
            end
        elseif freeDragging_ and not input:GetMouseButtonDown(MOUSEB_LEFT) then
            -- 松开：结束拖拽，写入 dirty
            freeDragging_ = false
            freeDragOriginals_ = {}
            markDirty()
        end

        return  -- 阻止后续所有网格操作
    end

    -- 退出贴图调整模式时重置拖拽状态
    freeDragging_ = false
    freeDragArmed_ = false
    freeDragArmedWaitRelease_ = false

    local gx, gy = mouseToGrid()
    local key = EditorTools.CellKey(gx, gy)

    -- ── MOVE 工具 ──
    -- 交互方式：
    --   1) 左键点击有元素的格子 → 选中（高亮）
    --   2) 选中状态下，左键点击空白格子 → 移动到该位置
    --   3) 选中状态下，左键点击另一个元素 → 切换选中
    --   4) 选中状态下，左键按住并拖拽 → 实时跟随拖拽
    --   5) 右键 → 取消选中
    if curTool_ == EditorConst.TOOL.MOVE then
        if input:GetMouseButtonPress(MOUSEB_LEFT) then
            local elem = findElemAt(gx, gy)
            print(string.format("[MOVE][DIAG] CLICK at (%g,%g) selectedElem_=%s elem=%s",
                gx, gy,
                selectedElem_ and (selectedElem_.gx..","..selectedElem_.gy.."/"..selectedElem_.layer) or "nil",
                elem and (elem.gx..","..elem.gy.."/"..elem.layer) or "nil"))
            if selectedElem_ then
                if elem then
                    if elem.gx == selectedElem_.gx and elem.gy == selectedElem_.gy
                       and elem.layer == selectedElem_.layer then
                        -- 点击已选中的元素，开始拖拽
                        print("[MOVE][DIAG]   → start drag")
                        moveDragging_ = true
                        moveDragStartGX_ = gx
                        moveDragStartGY_ = gy
                        EditorTools.PushUndo(mapData_, undoStack_)
                        redoStack_ = {}
                    else
                        -- 点击另一个元素，切换选中
                        print("[MOVE][DIAG]   → switch selection")
                        selectedElem_ = elem
                        moveDragging_ = false
                    end
                else
                    -- 已选中元素，点击空白格子 → 移动到目标位置
                    print(string.format("[MOVE][DIAG]   → click-to-move from (%g,%g) to (%g,%g)",
                        selectedElem_.gx, selectedElem_.gy, gx, gy))
                    if EditorTools.InBounds(mapData_, gx, gy) then
                        EditorTools.PushUndo(mapData_, undoStack_)
                        redoStack_ = {}
                        local ok = moveElement(selectedElem_.gx, selectedElem_.gy, gx, gy, selectedElem_)
                        print("[MOVE][DIAG]   → moveElement returned: " .. tostring(ok))
                        if ok then
                            selectedElem_.gx = gx
                            selectedElem_.gy = gy
                            markDirty()
                        end
                    end
                    -- 移动完成后保持选中（方便连续调整）
                end
            else
                if elem then
                    -- 没有选中元素，选中新元素
                    print("[MOVE][DIAG]   → select new elem")
                    selectedElem_ = elem
                    moveDragging_ = false
                end
            end
        elseif input:GetMouseButtonDown(MOUSEB_LEFT) and moveDragging_ and selectedElem_ then
            -- 拖拽中：实时移动元素
            if gx ~= selectedElem_.gx or gy ~= selectedElem_.gy then
                print(string.format("[MOVE][DIAG] DRAG from (%g,%g) to (%g,%g)",
                    selectedElem_.gx, selectedElem_.gy, gx, gy))
                if moveElement(selectedElem_.gx, selectedElem_.gy, gx, gy, selectedElem_) then
                    selectedElem_.gx = gx
                    selectedElem_.gy = gy
                    markDirty()
                end
            end
        elseif not input:GetMouseButtonDown(MOUSEB_LEFT) then
            if moveDragging_ then
                moveDragging_ = false
            end
        end
        -- 右键取消选择
        if input:GetMouseButtonPress(MOUSEB_RIGHT) then
            selectedElem_ = nil
            moveDragging_ = false
        end
        return
    end

    -- ── 其他工具：放置 / 删除 ──

    -- 左键放置
    if input:GetMouseButtonPress(MOUSEB_LEFT) then
        -- 诊断：左键点击时记录当前工具和坐标
        print(string.format("[DIAG-CLICK] LEFT_PRESS tool=%s gx=%g gy=%g inBounds=%s",
            curTool_, gx, gy, tostring(EditorTools.InBounds(mapData_, gx, gy))))
        EditorTools.PushUndo(mapData_, undoStack_)
        redoStack_ = {}
        placeBrush(gx, gy)
        lastPlacedKey_ = key
        mouseDown_ = true
        markDirty()
    elseif input:GetMouseButtonDown(MOUSEB_LEFT) and mouseDown_ then
        -- 道具(ladder/crate)、NPC、单例工具不支持拖动连续放置
        local isDragPaint = not EditorConst.IS_PROP[curTool_]
                        and not EditorTools.IsSingleton(curTool_)
                        and curTool_ ~= EditorConst.TOOL.NPC
                        and not EditorConst.IS_PORTAL[curTool_]
        if isDragPaint and key ~= lastPlacedKey_ then
            placeBrush(gx, gy)
            lastPlacedKey_ = key
            markDirty()
        end
    else
        mouseDown_ = false
        lastPlacedKey_ = ""
    end

    -- 右键删除
    if input:GetMouseButtonPress(MOUSEB_RIGHT) then
        EditorTools.PushUndo(mapData_, undoStack_)
        redoStack_ = {}
        eraseBrush(gx, gy)
        markDirty()
    elseif input:GetMouseButtonDown(MOUSEB_RIGHT) then
        eraseBrush(gx, gy)
        markDirty()
    end
end

-- ═══════════════════════════════════════════════
-- 主渲染（轻量覆盖层：网格线 + 边界 + 光标 + 选中高亮）
-- 实际游戏元素由 WorldRenderer.Draw 在编辑器相机下渲染
-- ═══════════════════════════════════════════════

--- NanoVG 渲染编辑器覆盖层
---@param vg userdata
---@param designW number
---@param designH number
function MapEditor.Render(vg, designW, designH)
    if not active_ or not mapData_ then return end

    local cs = EditorConst.CELL_SIZE

    -- ── 可见范围（世界坐标） ──
    local viewHalfW = designW * 0.5 / (PPU * edZoom_)
    local viewHalfH = designH * 0.5 / (PPU * edZoom_)
    local minWX = edPanX_ - viewHalfW
    local maxWX = edPanX_ + viewHalfW
    local minWY = edPanY_ - viewHalfH
    local maxWY = edPanY_ + viewHalfH

    local minGX = math.max(0, math.floor(minWX / cs))
    local maxGX = math.min(mapData_.gridW, math.ceil(maxWX / cs))
    local minGY = math.max(0, math.floor(minWY / cs))
    local maxGY = math.min(mapData_.gridH, math.ceil(maxWY / cs))

    -- 应用编辑器缩放变换（与 ClientGame 中的变换匹配）
    nvgSave(vg)
    local cxd, cyd = designW * 0.5, designH * 0.5
    nvgTranslate(vg, cxd, cyd)
    nvgScale(vg, edZoom_, edZoom_)
    nvgTranslate(vg, -cxd, -cyd)

    local cellPxSize = cs * PPU  -- 无需乘 edZoom_，NanoVG 变换已处理

    -- ── 网格线（淡色，便于对齐） ──
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 30))
    nvgStrokeWidth(vg, 0.5)
    for gx = minGX, maxGX do
        local sx = (gx * cs - edPanX_) * PPU + designW * 0.5
        local sy1 = (edPanY_ - minWY) * PPU + designH * 0.5
        local sy2 = (edPanY_ - maxWY) * PPU + designH * 0.5
        nvgBeginPath(vg)
        nvgMoveTo(vg, sx, sy2)
        nvgLineTo(vg, sx, sy1)
        nvgStroke(vg)
    end
    for gy = minGY, maxGY do
        local sy = designH * 0.5 - (gy * cs - edPanY_) * PPU
        local sx1 = (minWX - edPanX_) * PPU + designW * 0.5
        local sx2 = (maxWX - edPanX_) * PPU + designW * 0.5
        nvgBeginPath(vg)
        nvgMoveTo(vg, sx1, sy)
        nvgLineTo(vg, sx2, sy)
        nvgStroke(vg)
    end

    -- ── 地图边界（金色框） ──
    -- 在 NanoVG 缩放变换内部，使用不含 zoom 的坐标（NanoVG 处理缩放）
    local bx1, by1 = worldToScreenRaw(0, 0)
    local bx2, by2 = worldToScreenRaw(mapData_.gridW * cs, mapData_.gridH * cs)
    nvgStrokeColor(vg, nvgRGBA(255, 200, 50, 150))
    nvgStrokeWidth(vg, 2.0)
    nvgBeginPath(vg)
    nvgRect(vg, bx1, by2, bx2 - bx1, by1 - by2)
    nvgStroke(vg)

    -- ── MOVE 工具：选中元素高亮 ──
    if curTool_ == EditorConst.TOOL.MOVE and selectedElem_ then
        local sel = selectedElem_
        local wx, wy = sel.gx * cs, sel.gy * cs
        local sx, sy = worldToScreenRaw(wx, wy + cs)
        nvgBeginPath(vg)
        nvgRect(vg, sx - 1, sy - 1, cellPxSize + 2, cellPxSize + 2)
        nvgStrokeColor(vg, nvgRGBA(255, 180, 50, 220))
        nvgStrokeWidth(vg, 2.5)
        nvgStroke(vg)
        -- 半透明填充
        nvgBeginPath(vg)
        nvgRect(vg, sx, sy, cellPxSize, cellPxSize)
        nvgFillColor(vg, nvgRGBA(255, 180, 50, 40))
        nvgFill(vg)
    end

    -- ── 贴图调整模式：选中/悬停 overlay 高亮 ──
    if overlayAdjustMode_ and mapData_ then
        local curRole = viewModeIdx_ >= 2
            and EditorConst.VIEW_MODES[viewModeIdx_]
            or "all"
        local notOverUI = not isMouseOverPanel()
        local hoveredFov = notOverUI and hitTestFreeOverlayAtMouse(curRole) or nil
        local hoveredOv  = (notOverUI and not hoveredFov) and hitTestOverlayAtMouse(curRole) or nil

        -- grid overlay 高亮
        if mapData_.groundOverlays then
            for _, ov in ipairs(mapData_.groundOverlays) do
                if curRole == "all" or ov.role == curRole then
                    local wl, wb, wr, wt = getOverlayBounds(ov)
                    local sx1, sy1 = worldToScreenRaw(wl, wt)
                    local sx2, sy2 = worldToScreenRaw(wr, wb)
                    local pw = sx2 - sx1
                    local ph = sy2 - sy1
                    local isSelected = selectedOverlayIds_[ov.id]
                    local isHovered  = hoveredOv and hoveredOv.id == ov.id
                    if isSelected then
                        nvgBeginPath(vg); nvgRect(vg, sx1, sy1, pw, ph)
                        nvgFillColor(vg, nvgRGBAf(1.0, 0.85, 0.2, 0.15)); nvgFill(vg)
                        nvgBeginPath(vg); nvgRect(vg, sx1, sy1, pw, ph)
                        nvgStrokeColor(vg, nvgRGBA(255, 210, 50, 230))
                        nvgStrokeWidth(vg, 2.0); nvgStroke(vg)
                    elseif isHovered then
                        nvgBeginPath(vg); nvgRect(vg, sx1, sy1, pw, ph)
                        nvgStrokeColor(vg, nvgRGBA(80, 200, 255, 180))
                        nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
                    end
                end
            end
        end

        -- freeOverlay 高亮（AABB 矩形框）
        if mapData_.freeOverlays then
            for _, fov in ipairs(mapData_.freeOverlays) do
                if fov.role == curRole or fov.role == "all" then
                    local wl, wb, wr, wt = getFreeOverlayBounds(fov)
                    local sx1, sy1 = worldToScreenRaw(wl, wt)
                    local sx2, sy2 = worldToScreenRaw(wr, wb)
                    local pw = sx2 - sx1
                    local ph = sy2 - sy1
                    local isSelected = selectedOverlayIds_[fov.id]
                    local isHovered  = hoveredFov and hoveredFov.id == fov.id
                    if isSelected then
                        -- 青绿色边框 + 半透明填充
                        nvgBeginPath(vg); nvgRect(vg, sx1, sy1, pw, ph)
                        nvgFillColor(vg, nvgRGBAf(0.0, 0.9, 0.7, 0.12)); nvgFill(vg)
                        nvgBeginPath(vg); nvgRect(vg, sx1, sy1, pw, ph)
                        nvgStrokeColor(vg, nvgRGBA(0, 230, 180, 230))
                        nvgStrokeWidth(vg, 2.0); nvgStroke(vg)
                        -- 中心十字
                        local csx = (sx1 + sx2) * 0.5
                        local csy = (sy1 + sy2) * 0.5
                        nvgBeginPath(vg)
                        nvgMoveTo(vg, csx - 5, csy); nvgLineTo(vg, csx + 5, csy)
                        nvgMoveTo(vg, csx, csy - 5); nvgLineTo(vg, csx, csy + 5)
                        nvgStrokeColor(vg, nvgRGBA(0, 230, 180, 160))
                        nvgStrokeWidth(vg, 1.0); nvgStroke(vg)
                    elseif isHovered then
                        nvgBeginPath(vg); nvgRect(vg, sx1, sy1, pw, ph)
                        nvgStrokeColor(vg, nvgRGBA(80, 200, 255, 180))
                        nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
                    end
                end
            end
        end
    end

    nvgRestore(vg)

    -- ── 鼠标悬停 / 笔刷预览（在缩放变换外绘制，避免重复缩放） ──
    if not isMouseOverPanel() then
        local gx, gy = mouseToGrid()
        local cpxZoomed = cs * PPU * edZoom_

        if curTool_ == EditorConst.TOOL.MOVE then
            -- MOVE 模式：显示单格光标
            if EditorTools.InBounds(mapData_, gx, gy) then
                local wx, wy = gx * cs, gy * cs
                local psx, psy = worldToDesign(wx, wy + cs)
                nvgBeginPath(vg)
                nvgRect(vg, psx, psy, cpxZoomed, cpxZoomed)
                nvgStrokeColor(vg, nvgRGBA(255, 200, 80, 150))
                nvgStrokeWidth(vg, 1.5)
                nvgStroke(vg)
            end
        else
            -- 其他工具：笔刷预览
            local halfB = math.floor((brushSize_ - 1) / 2)
            for bx = 0, brushSize_ - 1 do
                for by = 0, brushSize_ - 1 do
                    local px = gx - halfB + bx
                    local py = gy - halfB + by
                    if EditorTools.InBounds(mapData_, px, py) then
                        local wx, wy = px * cs, py * cs
                        local psx, psy = worldToDesign(wx, wy + cs)
                        nvgBeginPath(vg)
                        nvgRect(vg, psx, psy, cpxZoomed, cpxZoomed)
                        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 120))
                        nvgStrokeWidth(vg, 1.0)
                        nvgStroke(vg)
                    end
                end
            end
        end

        -- 坐标标签（始终显示在鼠标附近）
        if EditorTools.InBounds(mapData_, gx, gy) then
            local dx, dy = mouseToDesign()
            nvgFontFace(vg, "sans")
            nvgFontSize(vg, 11)
            nvgFillColor(vg, nvgRGBA(255, 255, 200, 200))
            nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
            nvgText(vg, dx + 12, dy - 4, gx .. "," .. gy)
        end
    end
end

-- ═══════════════════════════════════════════════
-- 公共接口
-- ═══════════════════════════════════════════════

---@return table? mapData
function MapEditor.GetMapData()
    return mapData_
end

---@param name string
function MapEditor.SetMapName(name)
    mapName_ = name
    if mapData_ then mapData_.name = name end
end

---@return number
function MapEditor.GetCurSceneIdx()
    return curSceneIdx_
end

--- 获取编辑器相机参数（用于同步游戏渲染）
---@return number panX, number panY, number zoom
function MapEditor.GetEditorCamera()
    return edPanX_, edPanY_, edZoom_
end

--- 获取编辑器视角状态（viewMode + hideBgFg）
---@return number viewModeIdx 1=逻辑, 2=红鸟, 3=黑鸟
---@return boolean hideBgFg 是否隐藏背景/前景
function MapEditor.GetViewState()
    return viewModeIdx_, hideBgFg_
end

return MapEditor
