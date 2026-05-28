--- Editor/EditorTools.lua
--- 地图编辑器：工具操作、地图数据管理、Undo 栈

local EditorConst = require("Editor.EditorConst")

local EditorTools = {}

-- ═══════════════════════════════════════════════
-- 地图数据创建
-- ═══════════════════════════════════════════════

--- 创建空地图数据
---@param name string 地图名称
---@param gridW? number 宽度格子数 (默认100)
---@param gridH? number 高度格子数 (默认30)
---@return table mapData
function EditorTools.NewMap(name, gridW, gridH)
    gridW = math.max(EditorConst.MIN_GRID_W, math.min(EditorConst.MAX_GRID_W, gridW or EditorConst.DEFAULT_GRID_W))
    gridH = math.max(EditorConst.MIN_GRID_H, math.min(EditorConst.MAX_GRID_H, gridH or EditorConst.DEFAULT_GRID_H))
    return {
        name     = name or "untitled",
        gridW    = gridW,
        gridH    = gridH,
        cellSize = EditorConst.CELL_SIZE,
        spawnRed   = nil,  -- {gx, gy}
        spawnBlack = nil,
        exitPos    = nil,
        cells = {},        -- key "gx,gy" -> {type, visibleTo, angle?, dir?}  地形/出生点/出口
        props = {},        -- key "gx,gy" -> {type, visibleTo}  道具层（与地形重叠）
        npcs  = {},        -- array of {gx, gy, presetId, name, nameAlt, visibleTo}
    }
end

-- ═══════════════════════════════════════════════
-- 格子 key 工具
-- ═══════════════════════════════════════════════

--- 生成格子 key（支持半格坐标，如 "1.5,3"）
---@param gx number
---@param gy number
---@return string
function EditorTools.CellKey(gx, gy)
    return string.format("%g,%g", gx, gy)
end

--- 解析格子 key（支持半格坐标）
---@param key string
---@return number gx, number gy
function EditorTools.ParseKey(key)
    local a, b = key:match("^([^,]+),(.+)$")
    if not a then return nil, nil end
    return tonumber(a), tonumber(b)
end

-- ═══════════════════════════════════════════════
-- 网格坐标 <-> 世界坐标
-- ═══════════════════════════════════════════════

--- 世界坐标 -> 网格坐标
---@param wx number 世界 X (米)
---@param wy number 世界 Y (米)
---@param halfGrid? boolean 为true时返回0.5步进值（半格精度）
---@return number gx, number gy
function EditorTools.WorldToGrid(wx, wy, halfGrid)
    local cs = EditorConst.CELL_SIZE
    if halfGrid then
        -- 半格精度：吸附到0.5步进
        return math.floor(wx / cs * 2 + 0.5) / 2,
               math.floor(wy / cs * 2 + 0.5) / 2
    end
    return math.floor(wx / cs), math.floor(wy / cs)
end

--- 网格坐标 -> 世界坐标（格子中心）
---@param gx number
---@param gy number
---@return number wx, number wy
function EditorTools.GridToWorldCenter(gx, gy)
    local cs = EditorConst.CELL_SIZE
    return gx * cs + cs * 0.5, gy * cs + cs * 0.5
end

--- 网格坐标 -> 世界坐标（格子左下角）
---@param gx number
---@param gy number
---@return number wx, number wy
function EditorTools.GridToWorldOrigin(gx, gy)
    local cs = EditorConst.CELL_SIZE
    return gx * cs, gy * cs
end

-- ═══════════════════════════════════════════════
-- 格子判定
-- ═══════════════════════════════════════════════

--- 检查格子是否在地图范围内
---@param mapData table
---@param gx number
---@param gy number
---@return boolean
function EditorTools.InBounds(mapData, gx, gy)
    return gx >= 0 and gx < mapData.gridW and gy >= 0 and gy < mapData.gridH
end

--- 判断工具是否是斜坡类
---@param toolId string
---@return boolean
function EditorTools.IsSlope(toolId)
    return toolId:find("^slope_") ~= nil
end

--- 从工具 ID 提取斜坡角度和方向
---@param toolId string
---@return number? angle, string? dir  ("up"/"down")
function EditorTools.ParseSlope(toolId)
    local angle, dir = toolId:match("^slope_(%d+)_(%a+)$")
    if angle then
        return tonumber(angle), dir
    end
    return nil, nil
end

--- 判断是否是单例工具（全图只能放一个）
---@param toolId string
---@return boolean
function EditorTools.IsSingleton(toolId)
    local TOOL = EditorConst.TOOL
    return toolId == TOOL.SPAWN_RED or toolId == TOOL.SPAWN_BLACK or toolId == TOOL.EXIT
end

--- 判断是否是传送点工具
---@param toolId string
---@return boolean
function EditorTools.IsPortal(toolId)
    return EditorConst.IS_PORTAL[toolId] == true
end

-- ═══════════════════════════════════════════════
-- 格子操作
-- ═══════════════════════════════════════════════

--- 设置格子
---@param mapData table
---@param gx number
---@param gy number
---@param toolId string
---@param visibleTo string "all"/"red"/"black"
---@param npcPresetId? string NPC 预设 ID（仅 toolId=="npc" 时需要）
---@param portalGroup? number 传送组号 1-9（仅 portal_in/portal_out 时需要）
---@return boolean changed 是否有实际变化
function EditorTools.SetCell(mapData, gx, gy, toolId, visibleTo, npcPresetId, portalGroup)
    if not EditorTools.InBounds(mapData, gx, gy) then
        print(string.format("[DIAG-PROP] SetCell OUT_OF_BOUNDS gx=%g gy=%g gridW=%d gridH=%d tool=%s",
            gx, gy, mapData.gridW, mapData.gridH, toolId))
        return false
    end
    visibleTo = visibleTo or "all"

    local key = EditorTools.CellKey(gx, gy)
    local TOOL = EditorConst.TOOL

    -- 特殊工具：出生点/出口（单例）
    if toolId == TOOL.SPAWN_RED then
        mapData.spawnRed = { gx = gx, gy = gy }
        for k, v in pairs(mapData.cells) do
            if v.type == TOOL.SPAWN_RED then mapData.cells[k] = nil end
        end
        mapData.cells[key] = { type = TOOL.SPAWN_RED, visibleTo = "all" }
        return true
    elseif toolId == TOOL.SPAWN_BLACK then
        mapData.spawnBlack = { gx = gx, gy = gy }
        for k, v in pairs(mapData.cells) do
            if v.type == TOOL.SPAWN_BLACK then mapData.cells[k] = nil end
        end
        mapData.cells[key] = { type = TOOL.SPAWN_BLACK, visibleTo = "all" }
        return true
    elseif toolId == TOOL.EXIT then
        mapData.exitPos = { gx = gx, gy = gy }
        for k, v in pairs(mapData.cells) do
            if v.type == TOOL.EXIT then mapData.cells[k] = nil end
        end
        mapData.cells[key] = { type = TOOL.EXIT, visibleTo = "all" }
        return true
    elseif toolId == TOOL.NPC then
        -- NPC 不放在 cells 里，放在 npcs 列表；需要 presetId
        if not npcPresetId then return false end
        -- 同一格不能放两个 NPC
        for _, npc in ipairs(mapData.npcs) do
            if npc.gx == gx and npc.gy == gy then return false end
        end
        -- 查找预设数据
        local preset = nil
        for _, p in ipairs(EditorConst.NPC_PRESETS) do
            if p.presetId == npcPresetId then preset = p; break end
        end
        if not preset then return false end
        table.insert(mapData.npcs, {
            gx = gx, gy = gy,
            presetId = preset.presetId,
            name = preset.nameRed,
            nameAlt = preset.nameBlack,
            visibleTo = visibleTo,
        })
        return true
    -- ── 传送点（portal_in / portal_out）：存入 cells 层，每格一个 ──
    elseif EditorConst.IS_PORTAL[toolId] then
        portalGroup = portalGroup or 1
        local old = mapData.cells[key]
        if old and old.type == toolId and old.visibleTo == visibleTo and old.portalGroup == portalGroup then
            return false  -- 无变化
        end
        mapData.cells[key] = { type = toolId, visibleTo = visibleTo, portalGroup = portalGroup }
        return true

    elseif toolId == TOOL.ERASER then
        return EditorTools.EraseCell(mapData, gx, gy)
    end

    -- ── 道具（ladder / crate）：存入 props 层，不覆盖地形 ──
    if EditorConst.IS_PROP[toolId] then
        local old = mapData.props[key]
        if old and old.type == toolId and old.visibleTo == visibleTo then
            print(string.format("[DIAG-PROP] SetCell SKIP (no change) key=%s tool=%s", key, toolId))
            return false  -- 无变化
        end
        mapData.props[key] = { type = toolId, visibleTo = visibleTo }
        print(string.format("[DIAG-PROP] SetCell OK key=%s tool=%s old=%s", key, toolId, old and old.type or "nil"))
        return true
    end

    -- ── 普通地形工具 ──
    local cellData = { type = toolId, visibleTo = visibleTo }

    -- 斜坡附加数据
    local angle, dir = EditorTools.ParseSlope(toolId)
    if angle then
        cellData.type = "slope"
        cellData.angle = angle
        cellData.dir = dir

        -- 30° 斜坡占2格：放置时自动创建 left + right 两个半格
        if angle == 30 then
            local lgx, rgx = gx, gx + 1  -- left=当前格, right=右邻格
            if not EditorTools.InBounds(mapData, rgx, gy) then return false end
            local lKey = EditorTools.CellKey(lgx, gy)
            local rKey = EditorTools.CellKey(rgx, gy)
            mapData.cells[lKey] = { type = "slope", angle = 30, dir = dir, half = "left", visibleTo = visibleTo }
            mapData.cells[rKey] = { type = "slope", angle = 30, dir = dir, half = "right", visibleTo = visibleTo }
            return true
        end
    end

    -- 检查是否有变化
    local old = mapData.cells[key]
    if old and old.type == cellData.type and old.visibleTo == cellData.visibleTo
       and old.angle == cellData.angle and old.dir == cellData.dir then
        return false
    end

    mapData.cells[key] = cellData
    return true
end

--- 删除格子（优先删道具层，其次删地形层，最后删 NPC）
---@param mapData table
---@param gx number
---@param gy number
---@return boolean changed
function EditorTools.EraseCell(mapData, gx, gy)
    local key = EditorTools.CellKey(gx, gy)
    -- 优先删除道具层（道具在地形之上）
    if mapData.props and mapData.props[key] then
        mapData.props[key] = nil
        return true
    end
    -- 删除地形层
    if mapData.cells[key] then
        local cell = mapData.cells[key]
        local cellType = cell.type
        mapData.cells[key] = nil
        -- 清理特殊标记
        if cellType == EditorConst.TOOL.SPAWN_RED then mapData.spawnRed = nil end
        if cellType == EditorConst.TOOL.SPAWN_BLACK then mapData.spawnBlack = nil end
        if cellType == EditorConst.TOOL.EXIT then mapData.exitPos = nil end
        return true
    end
    -- 检查 NPC
    for i, npc in ipairs(mapData.npcs) do
        if npc.gx == gx and npc.gy == gy then
            table.remove(mapData.npcs, i)
            return true
        end
    end
    return false
end

--- 检查上方相邻格是否有实体地形（ground 或 slope），用于判断是否需要画表皮
---@param mapData table
---@param gx number
---@param gy number
---@return boolean hasSolidAbove
function EditorTools.HasSolidAbove(mapData, gx, gy)
    local key = EditorTools.CellKey(gx, gy + 1)
    local cell = mapData.cells[key]
    if not cell then return false end
    return cell.type == "ground" or cell.type == "slope"
end

-- ═══════════════════════════════════════════════
-- Undo / Redo 系统
-- ═══════════════════════════════════════════════

--- 深拷贝 cells / props / npcs 用于 undo
---@param mapData table
---@return table snapshot
local function snapshot(mapData)
    local snap = {
        cells = {},
        props = {},
        npcs = {},
        spawnRed = mapData.spawnRed and { gx = mapData.spawnRed.gx, gy = mapData.spawnRed.gy } or nil,
        spawnBlack = mapData.spawnBlack and { gx = mapData.spawnBlack.gx, gy = mapData.spawnBlack.gy } or nil,
        exitPos = mapData.exitPos and { gx = mapData.exitPos.gx, gy = mapData.exitPos.gy } or nil,
    }
    for k, v in pairs(mapData.cells) do
        snap.cells[k] = { type = v.type, visibleTo = v.visibleTo, angle = v.angle, dir = v.dir, half = v.half, portalGroup = v.portalGroup }
    end
    if mapData.props then
        for k, v in pairs(mapData.props) do
            snap.props[k] = { type = v.type, visibleTo = v.visibleTo }
        end
    end
    for i, npc in ipairs(mapData.npcs) do
        snap.npcs[i] = { gx = npc.gx, gy = npc.gy, presetId = npc.presetId, name = npc.name, nameAlt = npc.nameAlt, visibleTo = npc.visibleTo }
    end
    return snap
end

--- 保存当前状态到 undo 栈
---@param mapData table
---@param undoStack table
function EditorTools.PushUndo(mapData, undoStack)
    table.insert(undoStack, snapshot(mapData))
    while #undoStack > EditorConst.MAX_UNDO do
        table.remove(undoStack, 1)
    end
end

--- 从 undo 栈恢复
---@param mapData table
---@param undoStack table
---@param redoStack table
---@return boolean success
function EditorTools.PopUndo(mapData, undoStack, redoStack)
    if #undoStack == 0 then return false end
    if redoStack then
        table.insert(redoStack, snapshot(mapData))
    end
    local snap = table.remove(undoStack)
    mapData.cells = snap.cells
    mapData.props = snap.props or {}
    mapData.npcs = snap.npcs
    mapData.spawnRed = snap.spawnRed
    mapData.spawnBlack = snap.spawnBlack
    mapData.exitPos = snap.exitPos
    return true
end

--- 从 redo 栈前进
---@param mapData table
---@param undoStack table
---@param redoStack table
---@return boolean success
function EditorTools.PopRedo(mapData, undoStack, redoStack)
    if not redoStack or #redoStack == 0 then return false end
    table.insert(undoStack, snapshot(mapData))
    local snap = table.remove(redoStack)
    mapData.cells = snap.cells
    mapData.props = snap.props or {}
    mapData.npcs = snap.npcs
    mapData.spawnRed = snap.spawnRed
    mapData.spawnBlack = snap.spawnBlack
    mapData.exitPos = snap.exitPos
    return true
end

--- 获取地图统计信息
---@param mapData table
---@return table stats
function EditorTools.GetStats(mapData)
    local counts = {}
    for _, cell in pairs(mapData.cells) do
        local t = cell.type
        if cell.angle then t = "slope" end
        counts[t] = (counts[t] or 0) + 1
    end
    if mapData.props then
        for _, prop in pairs(mapData.props) do
            counts[prop.type] = (counts[prop.type] or 0) + 1
        end
    end
    counts.npc = #mapData.npcs
    return counts
end

return EditorTools
