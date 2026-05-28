--- Editor/MapSerializer.lua
--- 地图编辑器：JSON 序列化、反序列化、转 LevelData 格式、反向转换

local EditorConst    = require("Editor.EditorConst")
local EditorTools    = require("Editor.EditorTools")
local LevelData      = require("Game.LevelData")
local AssetManifest  = require("Editor.AssetManifest")

-- 构建有效 imagePath 集合（懒初始化，加载地图时过滤失效 freeOverlays）
local validImagePaths_ = nil
local function getValidImagePaths()
    if validImagePaths_ then return validImagePaths_ end
    local set = {}
    local function collect(subPath)
        local files, dirs = AssetManifest.scan(subPath)
        for _, p in ipairs(files) do set[p] = true end
        for _, d in ipairs(dirs) do collect(d) end
    end
    collect("")
    validImagePaths_ = set
    return set
end

local MapSerializer = {}

-- ═══════════════════════════════════════════════
-- 保存 / 加载
-- ═══════════════════════════════════════════════

--- 保存地图到 JSON 文件（同时 print 到日志备份）
---@param mapData table
---@return boolean success
function MapSerializer.Save(mapData)
    local json = cjson.encode(mapData)

    -- 始终 print 到日志作为备份（WASM 文件刷新后丢失）
    print("[MapEditor] === MAP JSON START ===")
    print(json)
    print("[MapEditor] === MAP JSON END ===")

    -- 尝试写入文件（不用子目录，避免沙箱路径问题）
    local path = "map_" .. mapData.name .. ".json"
    local ok, err = pcall(function()
        local file = File:new(path, FILE_WRITE)
        if file:IsOpen() then
            file:WriteString(json)
            file:Close()
            print("[MapEditor] Saved to file: " .. path)
        else
            print("[MapEditor] WARN: File not writable: " .. path)
        end
    end)
    if not ok then
        print("[MapEditor] WARN: File save failed: " .. tostring(err))
        print("[MapEditor] JSON already printed to log above, copy from there.")
    end

    return true
end

--- 从 JSON 文件加载地图
---@param name string 地图名称（不含路径和后缀）
---@return table? mapData
function MapSerializer.Load(name)
    local path = "map_" .. name .. ".json"
    local openOk, file = pcall(File.new, File, path, FILE_READ)
    if not openOk or not file:IsOpen() then
        print("[MapEditor] Load failed: " .. path .. " not found")
        return nil
    end

    local content = file:ReadString()
    file:Close()

    if not content or #content == 0 then
        print("[MapEditor] Load failed: empty file")
        return nil
    end

    local ok, data = pcall(cjson.decode, content)
    if not ok then
        print("[MapEditor] Load failed: JSON parse error: " .. tostring(data))
        return nil
    end

    -- 基本验证
    if not data.gridW or not data.gridH or not data.cells then
        print("[MapEditor] Load failed: invalid map data structure")
        return nil
    end

    -- 确保 npcs / props 表存在
    data.npcs = data.npcs or {}
    data.props = data.props or {}
    data.cellSize = data.cellSize or EditorConst.CELL_SIZE

    -- 过滤掉已删除的 freeOverlay 图片（避免每帧尝试加载不存在的文件）
    if data.freeOverlays and #data.freeOverlays > 0 then
        local valid = getValidImagePaths()
        local kept = {}
        for _, fov in ipairs(data.freeOverlays) do
            if valid[fov.imagePath] then
                kept[#kept + 1] = fov
            else
                print(string.format("[MapSerializer] freeOverlay removed (invalid path): %s", fov.imagePath or "?"))
            end
        end
        data.freeOverlays = kept
    end

    print("[MapEditor] Loaded: " .. path .. " (" .. data.gridW .. "x" .. data.gridH .. ")")
    return data
end

-- ═══════════════════════════════════════════════
-- 转换为 LevelData 格式
-- ═══════════════════════════════════════════════

--- 将编辑器地图数据转换为 LevelData 场景格式
--- 返回的格式与 LevelData.scenes[n] 兼容
---@param mapData table
---@return table sceneData  { name, spawnX, spawnY, objects={...} }
function MapSerializer.ToLevelData(mapData)
    local cs = mapData.cellSize or EditorConst.CELL_SIZE
    local objects = {}
    local idCounter = 0

    local function nextId(prefix)
        idCounter = idCounter + 1
        return prefix .. "_" .. idCounter
    end

    -- ── 第一步：收集所有 ground 格子坐标，横向合并 ──
    -- 按行分组，每行内排序后合并连续同 visibleTo 的格子
    local groundRows = {}  -- gy -> sorted list of {gx, visibleTo}
    local slopeList = {}
    local waterList = {}
    local bridgeList = {}
    local ladderCols = {}  -- gx -> sorted list of {gy, visibleTo}  (按列纵向合并)
    local crateList = {}
    local checkpointList = {}
    local portalList = {}  -- {gx, gy, portalType, portalGroup, visibleTo}

    for key, cell in pairs(mapData.cells) do
        local gx, gy = EditorTools.ParseKey(key)
        if gx and gy then
            if cell.type == "ground" then
                if not groundRows[gy] then groundRows[gy] = {} end
                table.insert(groundRows[gy], { gx = gx, visibleTo = cell.visibleTo })
            elseif cell.type == "slope" then
                table.insert(slopeList, { gx = gx, gy = gy, angle = cell.angle, dir = cell.dir, half = cell.half, visibleTo = cell.visibleTo })
            elseif cell.type == "water" then
                if not waterList[gy] then waterList[gy] = {} end
                table.insert(waterList[gy], { gx = gx, visibleTo = cell.visibleTo })
            elseif cell.type == "bridge" then
                if not bridgeList[gy] then bridgeList[gy] = {} end
                table.insert(bridgeList[gy], { gx = gx, visibleTo = cell.visibleTo })
            elseif cell.type == "checkpoint" then
                table.insert(checkpointList, { gx = gx, gy = gy, visibleTo = cell.visibleTo })
            elseif cell.type == "portal_in" or cell.type == "portal_out" then
                table.insert(portalList, {
                    gx = gx, gy = gy,
                    portalType = cell.type,
                    portalGroup = cell.portalGroup or 1,
                    visibleTo = cell.visibleTo,
                })
            end
            -- spawn_red/spawn_black/exit 不生成物理实体（只是坐标标记）
        end
    end

    -- ── 收集道具层（ladder / crate） ──
    if mapData.props then
        for key, prop in pairs(mapData.props) do
            local gx, gy = EditorTools.ParseKey(key)
            if gx and gy then
                if prop.type == "ladder" then
                    if not ladderCols[gx] then ladderCols[gx] = {} end
                    table.insert(ladderCols[gx], { gy = gy, visibleTo = prop.visibleTo })
                elseif prop.type == "crate" then
                    table.insert(crateList, { gx = gx, gy = gy, visibleTo = prop.visibleTo })
                end
            end
        end
    end

    -- ── 合并 ground 行 ──
    for gy, row in pairs(groundRows) do
        table.sort(row, function(a, b) return a.gx < b.gx end)
        local i = 1
        while i <= #row do
            local startGx = row[i].gx
            local vis = row[i].visibleTo
            local endGx = startGx
            -- 向右合并连续且同 visibleTo 的格子
            while i + 1 <= #row and row[i + 1].gx == endGx + 1 and row[i + 1].visibleTo == vis do
                endGx = row[i + 1].gx
                i = i + 1
            end
            -- 生成 Platform
            local count = endGx - startGx + 1
            local w = count * cs
            local h = cs
            local cx = startGx * cs + w * 0.5
            local cy = gy * cs + h * 0.5
            table.insert(objects, {
                id = nextId("ground"),
                type = "platform",
                x = cx, y = cy, w = w, h = h,
                visibleTo = vis,
            })
            i = i + 1
        end
    end

    -- ── 斜坡 → 独立 Platform + slope 元数据 ──
    for _, s in ipairs(slopeList) do
        local wx, wy = EditorTools.GridToWorldOrigin(s.gx, s.gy)
        table.insert(objects, {
            id = nextId("slope"),
            type = "platform",
            x = wx, y = wy,  -- 左下角（斜坡特殊处理）
            w = cs, h = cs,
            visibleTo = s.visibleTo,
            slopeType = s.half
                and ("slope_" .. s.angle .. "_" .. s.dir .. "_" .. s.half)
                or  ("slope_" .. s.angle .. "_" .. s.dir),
        })
    end

    -- ── 水面合并（类似 ground） ──
    for gy, row in pairs(waterList) do
        table.sort(row, function(a, b) return a.gx < b.gx end)
        local i = 1
        while i <= #row do
            local startGx = row[i].gx
            local vis = row[i].visibleTo
            local endGx = startGx
            while i + 1 <= #row and row[i + 1].gx == endGx + 1 and row[i + 1].visibleTo == vis do
                endGx = row[i + 1].gx
                i = i + 1
            end
            local count = endGx - startGx + 1
            local w = count * cs
            local h = cs
            local cx = startGx * cs + w * 0.5
            local cy = gy * cs + h * 0.5
            table.insert(objects, {
                id = nextId("water"),
                type = "trigger",
                x = cx, y = cy, w = w, h = h,
                event = "water_death",
                visibleTo = vis,
            })
            i = i + 1
        end
    end

    -- ── 独木桥合并 ──
    for gy, row in pairs(bridgeList) do
        table.sort(row, function(a, b) return a.gx < b.gx end)
        local i = 1
        while i <= #row do
            local startGx = row[i].gx
            local vis = row[i].visibleTo
            local endGx = startGx
            while i + 1 <= #row and row[i + 1].gx == endGx + 1 and row[i + 1].visibleTo == vis do
                endGx = row[i + 1].gx
                i = i + 1
            end
            local count = endGx - startGx + 1
            local w = count * cs
            local h = cs * 0.4  -- 桥比普通平台薄
            local cx = startGx * cs + w * 0.5
            local cy = gy * cs + cs * 0.2  -- 靠近格子底部
            table.insert(objects, {
                id = nextId("bridge"),
                type = "platform",
                x = cx, y = cy, w = w, h = h,
                visibleTo = vis,
                bridgeWeight = EditorConst.BRIDGE_MAX_WEIGHT,
            })
            i = i + 1
        end
    end

    -- ── 梯子纵向合并（按列，合并连续同 visibleTo 的格子） ──
    for gx, col in pairs(ladderCols) do
        table.sort(col, function(a, b) return a.gy < b.gy end)
        local i = 1
        while i <= #col do
            local startGy = col[i].gy
            local vis = col[i].visibleTo
            local endGy = startGy
            while i + 1 <= #col and col[i + 1].gy == endGy + 1 and col[i + 1].visibleTo == vis do
                endGy = col[i + 1].gy
                i = i + 1
            end
            local count = endGy - startGy + 1
            local w = cs * 0.4          -- 梯子比格子窄
            local h = count * cs
            local cx = gx * cs + cs * 0.5
            local cy = startGy * cs + h * 0.5
            table.insert(objects, {
                id = nextId("ladder"),
                type = "ladder",
                x = cx, y = cy, w = w, h = h,
                visibleTo = vis,
            })
            i = i + 1
        end
    end

    -- ── 木箱（独立动态物体） ──
    for _, c in ipairs(crateList) do
        local wx, wy = EditorTools.GridToWorldCenter(c.gx, c.gy)
        table.insert(objects, {
            id = nextId("crate"),
            type = "crate",
            x = wx, y = wy, w = cs, h = cs,
            visibleTo = c.visibleTo,
        })
    end

    -- ── 存档点（触发器） ──
    for _, c in ipairs(checkpointList) do
        local wx, wy = EditorTools.GridToWorldCenter(c.gx, c.gy)
        table.insert(objects, {
            id = nextId("chkpt"),
            type = "trigger",
            x = wx, y = wy, w = cs, h = cs * 2,
            event = "checkpoint",
            visibleTo = c.visibleTo,
        })
    end

    -- ── NPC ──
    for _, npc in ipairs(mapData.npcs) do
        local wx, wy = EditorTools.GridToWorldCenter(npc.gx, npc.gy)
        table.insert(objects, {
            id = nextId("npc"),
            type = "npc",
            x = wx, y = wy,
            presetId = npc.presetId,
            name = npc.nameRed or npc.name or "NPC",
            nameAlt = npc.nameBlack or npc.nameAlt or "NPC",
            dialogueRed = { "..." },
            dialogueBlack = { "..." },
            visibleTo = npc.visibleTo or "all",
        })
    end

    -- ── 传送点（portal_in / portal_out → 触发器） ──
    for _, p in ipairs(portalList) do
        local wx, wy = EditorTools.GridToWorldCenter(p.gx, p.gy)
        local evName = (p.portalType == "portal_in") and "portal_enter" or "portal_exit"
        table.insert(objects, {
            id = nextId("portal"),
            type = "trigger",
            x = wx, y = wy, w = cs, h = cs * 2,
            event = evName,
            portalGroup = p.portalGroup,
            visibleTo = p.visibleTo,
        })
    end

    -- ── 场景出口 ──
    if mapData.exitPos then
        local wx, wy = EditorTools.GridToWorldCenter(mapData.exitPos.gx, mapData.exitPos.gy)
        table.insert(objects, {
            id = nextId("exit"),
            type = "trigger",
            x = wx, y = wy, w = cs * 2, h = cs * 4,
            event = "scene_transition",
        })
    end

    -- ── 组装场景数据 ──
    local spawnX, spawnY = 2.0, 2.0
    if mapData.spawnRed then
        spawnX, spawnY = EditorTools.GridToWorldCenter(mapData.spawnRed.gx, mapData.spawnRed.gy)
    end
    -- 防御 NaN（NaN ~= NaN 为 true），避免 JSON 编解码失败
    if spawnX ~= spawnX then spawnX = 2.0 end
    if spawnY ~= spawnY then spawnY = 2.0 end

    local result = {
        name = mapData.name or "custom_map",
        spawnX = spawnX,
        spawnY = spawnY,
        objects = objects,
        -- 透传 groundOverlays（编辑器不修改 overlay，仅保留来自 sceneData 的值）
        groundOverlays = mapData.groundOverlays or {},
        -- 透传 freeOverlays（自由贴图，带位置/尺寸/旋转）
        freeOverlays = mapData.freeOverlays or {},
    }

    -- 黑鸟独立出生点（如果编辑器中放置了 spawn_black）
    if mapData.spawnBlack then
        local bx, by = EditorTools.GridToWorldCenter(mapData.spawnBlack.gx, mapData.spawnBlack.gy)
        -- 防御 NaN
        if bx ~= bx then bx = 2.0 end
        if by ~= by then by = 2.0 end
        result.spawnBlackX = bx
        result.spawnBlackY = by
    end

    -- ── 诊断：打印 ToLevelData 输出统计 ──
    local objTypeCounts = {}
    for _, obj in ipairs(objects) do
        objTypeCounts[obj.type] = (objTypeCounts[obj.type] or 0) + 1
    end
    local objTypeStr = ""
    for t, c in pairs(objTypeCounts) do objTypeStr = objTypeStr .. t .. "=" .. c .. " " end
    print(string.format("[MapSerializer][DIAG] ToLevelData: %d objects | %s| spawn=(%.1f,%.1f)",
        #objects, objTypeStr, spawnX, spawnY))

    return result
end

-- ═══════════════════════════════════════════════
-- 反向转换：LevelData 场景 -> 编辑器 mapData
-- ═══════════════════════════════════════════════

--- 解析斜坡类型字符串
--- "slope_45_up" -> angle=45, dir="up", half=nil
--- "slope_30_up_left" -> angle=30, dir="up", half="left"
---@param slopeType string
---@return number angle, string dir, string|nil half
local function parseSlopeType(slopeType)
    -- 尝试匹配带 half 的格式: slope_30_up_left
    local angle, dir, half = slopeType:match("^slope_(%d+)_(%a+)_(%a+)$")
    if angle then
        return tonumber(angle), dir, half
    end
    -- 尝试匹配不带 half 的格式: slope_45_up
    angle, dir = slopeType:match("^slope_(%d+)_(%a+)$")
    if angle then
        return tonumber(angle), dir, nil
    end
    return 45, "up", nil  -- fallback
end

--- 将 LevelData 场景数据反向转换为编辑器 mapData 格式
--- 只转换"编辑器管理"的对象（平台、斜坡、水面、桥、梯子、箱子、存档点、出口、NPC、出生点）
--- 非地形对象（Monologue、ScreenText、Interactable、剧情Trigger）被跳过
---@param sceneData table LevelData 格式的场景数据
---@return table mapData 编辑器格式
function MapSerializer.FromLevelData(sceneData)
    local cs = EditorConst.CELL_SIZE
    local cells = {}
    local props = {}
    local npcs = {}
    ---@type {gx:number, gy:number}|nil
    local spawnRed = nil
    ---@type {gx:number, gy:number}|nil
    local spawnBlack = nil
    ---@type {gx:number, gy:number}|nil
    local exitPos = nil

    -- 追踪最大边界以计算 gridW/gridH
    local maxGx, maxGy = 0, 0

    local function trackBounds(gx, gy)
        if gx > maxGx then maxGx = gx end
        if gy > maxGy then maxGy = gy end
    end

    -- ── 遍历所有 objects ──
    for _, obj in ipairs(sceneData.objects or {}) do
        local vis = obj.visibleTo or "all"

        if obj.type == "platform" then
            if obj.slopeType then
                -- ── 斜坡 ──
                -- 斜坡的 x,y 是左下角（GridToWorldOrigin）
                local gx = math.floor(obj.x / cs + 0.01)
                local gy = math.floor(obj.y / cs + 0.01)
                local angle, dir, half = parseSlopeType(obj.slopeType)
                local key = EditorTools.CellKey(gx, gy)
                cells[key] = {
                    type = "slope",
                    angle = angle,
                    dir = dir,
                    half = half,
                    visibleTo = vis,
                }
                trackBounds(gx, gy)

            elseif obj.bridgeWeight then
                -- ── 独木桥 ──
                -- 桥的 cy = gy * cs + cs * 0.2, h = cs * 0.4
                -- 反推: gy = math.floor((cy - cs*0.2) / cs)
                -- 简化: 桥的 gx 从中心和宽度推算
                local halfW = obj.w * 0.5
                local startX = obj.x - halfW
                local count = math.floor(obj.w / cs + 0.5)
                local startGx = math.floor(startX / cs + 0.01)
                local gy = math.floor((obj.y) / cs + 0.01)
                for i = 0, count - 1 do
                    local gx = startGx + i
                    local key = EditorTools.CellKey(gx, gy)
                    cells[key] = { type = "bridge", visibleTo = vis }
                    trackBounds(gx, gy)
                end

            else
                -- ── 普通地面平台 ──
                -- 中心 (cx, cy), 宽 w, 高 h
                -- cx = startGx * cs + w * 0.5, cy = gy * cs + h * 0.5
                -- 反推: startGx = (cx - w/2) / cs
                local halfW = obj.w * 0.5
                local halfH = obj.h * 0.5
                local startX = obj.x - halfW
                local startY = obj.y - halfH
                local countW = math.floor(obj.w / cs + 0.5)
                local countH = math.floor(obj.h / cs + 0.5)
                local startGx = math.floor(startX / cs + 0.01)
                local startGy = math.floor(startY / cs + 0.01)
                for dy = 0, countH - 1 do
                    for dx = 0, countW - 1 do
                        local gx = startGx + dx
                        local gy = startGy + dy
                        local key = EditorTools.CellKey(gx, gy)
                        cells[key] = { type = "ground", visibleTo = vis }
                        trackBounds(gx, gy)
                    end
                end
            end

        elseif obj.type == "trigger" then
            if obj.event == "water_death" then
                -- ── 水面 ──
                local halfW = obj.w * 0.5
                local halfH = obj.h * 0.5
                local startX = obj.x - halfW
                local startY = obj.y - halfH
                local countW = math.floor(obj.w / cs + 0.5)
                local countH = math.floor(obj.h / cs + 0.5)
                local startGx = math.floor(startX / cs + 0.01)
                local startGy = math.floor(startY / cs + 0.01)
                for dy = 0, countH - 1 do
                    for dx = 0, countW - 1 do
                        local gx = startGx + dx
                        local gy = startGy + dy
                        local key = EditorTools.CellKey(gx, gy)
                        cells[key] = { type = "water", visibleTo = vis }
                        trackBounds(gx, gy)
                    end
                end

            elseif obj.event == "checkpoint" then
                -- ── 存档点 ──
                local gx = math.floor(obj.x / cs)
                local gy = math.floor(obj.y / cs)
                local key = EditorTools.CellKey(gx, gy)
                cells[key] = { type = "checkpoint", visibleTo = vis }
                trackBounds(gx, gy)

            elseif obj.event == "scene_transition" then
                -- ── 场景出口 ──
                local gx = math.floor(obj.x / cs)
                local gy = math.floor(obj.y / cs)
                local key = EditorTools.CellKey(gx, gy)
                cells[key] = { type = "exit", visibleTo = "all" }
                exitPos = { gx = gx, gy = gy }
                trackBounds(gx, gy)

            elseif obj.event == "portal_enter" or obj.event == "portal_exit" then
                -- ── 传送点 ──
                local gx = math.floor(obj.x / cs)
                local gy = math.floor(obj.y / cs)
                local key = EditorTools.CellKey(gx, gy)
                local cellType = (obj.event == "portal_enter") and "portal_in" or "portal_out"
                cells[key] = {
                    type = cellType,
                    visibleTo = vis,
                    portalGroup = obj.portalGroup or 1,
                }
                trackBounds(gx, gy)
            end
            -- 其他 trigger（剧情 trigger）跳过

        elseif obj.type == "ladder" then
            -- ── 梯子 ──
            -- 梯子 w = cs*0.4, 但 cx = gx*cs + cs*0.5
            local halfH = obj.h * 0.5
            local gx = math.floor(obj.x / cs)
            local startY = obj.y - halfH
            local count = math.floor(obj.h / cs + 0.5)
            local startGy = math.floor(startY / cs + 0.01)
            for i = 0, count - 1 do
                local gy = startGy + i
                local key = EditorTools.CellKey(gx, gy)
                props[key] = { type = "ladder", visibleTo = vis }
                trackBounds(gx, gy)
            end

        elseif obj.type == "crate" then
            -- ── 木箱 ──
            local gx = math.floor(obj.x / cs)
            local gy = math.floor(obj.y / cs)
            local key = EditorTools.CellKey(gx, gy)
            props[key] = { type = "crate", visibleTo = vis }
            trackBounds(gx, gy)

        elseif obj.type == "npc" then
            -- ── NPC ──
            local gx = math.floor(obj.x / cs)
            local gy = math.floor(obj.y / cs)
            -- 匹配预设 ID（优先使用 presetId，其次按名字匹配）
            local presetId = obj.presetId
            if not presetId then
                -- 按名字查找
                for _, p in ipairs(EditorConst.NPC_PRESETS) do
                    if p.nameRed == obj.name or p.nameBlack == obj.name
                       or p.nameRed == obj.nameAlt or p.nameBlack == obj.nameAlt then
                        presetId = p.presetId
                        break
                    end
                end
            end
            if presetId then
                -- 查找预设以获取双视角名
                local nameRed, nameBlack = obj.name or "NPC", obj.nameAlt or "NPC"
                for _, p in ipairs(EditorConst.NPC_PRESETS) do
                    if p.presetId == presetId then
                        nameRed = p.nameRed
                        nameBlack = p.nameBlack
                        break
                    end
                end
                table.insert(npcs, {
                    gx = gx, gy = gy,
                    presetId = presetId,
                    name = nameRed,
                    nameAlt = nameBlack,
                    visibleTo = vis,
                })
            end
            trackBounds(gx, gy)
        end
        -- monologue / screen_text / interactable 跳过
    end

    -- ── 出生点（红鸟） ──
    if sceneData.spawnX and sceneData.spawnY then
        local gx = math.floor(sceneData.spawnX / cs)
        local gy = math.floor(sceneData.spawnY / cs)
        spawnRed = { gx = gx, gy = gy }
        local key = EditorTools.CellKey(gx, gy)
        cells[key] = { type = "spawn_red", visibleTo = "all" }
        trackBounds(gx, gy)
    end

    -- ── 出生点（黑鸟，独立坐标） ──
    if sceneData.spawnBlackX and sceneData.spawnBlackY then
        local gx = math.floor(sceneData.spawnBlackX / cs)
        local gy = math.floor(sceneData.spawnBlackY / cs)
        spawnBlack = { gx = gx, gy = gy }
        local key = EditorTools.CellKey(gx, gy)
        cells[key] = { type = "spawn_black", visibleTo = "all" }
        trackBounds(gx, gy)
    end

    -- ── 计算 gridW / gridH（至少覆盖所有对象 + 余量） ──
    local gridW = math.max(EditorConst.DEFAULT_GRID_W, maxGx + 10)
    local gridH = math.max(EditorConst.DEFAULT_GRID_H, maxGy + 5)
    gridW = math.min(gridW, EditorConst.MAX_GRID_W)
    gridH = math.min(gridH, EditorConst.MAX_GRID_H)

    local mapData = {
        name     = sceneData.name or "scene",
        gridW    = gridW,
        gridH    = gridH,
        cellSize = cs,
        spawnRed   = spawnRed,
        spawnBlack = spawnBlack,  -- 黑鸟独立出生点（可选）
        exitPos    = exitPos,
        cells = cells,
        props = props,
        npcs  = npcs,
        -- 透传 groundOverlays（编辑器不拆解 overlay，保留原始数组）
        groundOverlays = sceneData.groundOverlays or {},
        -- 透传 freeOverlays（自由贴图）
        freeOverlays = sceneData.freeOverlays or {},
    }

    local cellCount = 0
    for _ in pairs(cells) do cellCount = cellCount + 1 end
    local propCount = 0
    for _ in pairs(props) do propCount = propCount + 1 end
    print(string.format("[MapSerializer] FromLevelData: %s -> %dx%d, cells=%d, props=%d, npcs=%d",
        sceneData.name or "?", gridW, gridH, cellCount, propCount, #npcs))

    return mapData
end

-- ═══════════════════════════════════════════════
-- 保存为场景文件（编辑器 -> LevelData 文件）
-- ═══════════════════════════════════════════════

--- 将编辑器 mapData 转换为 LevelData 格式并保存到对应场景文件
--- 同时更新 LevelData 缓存
---@param mapData table 编辑器格式
---@param sceneIdx number 场景索引
---@return boolean success
function MapSerializer.SaveAsScene(mapData, sceneIdx)
    -- 1. 转换为 LevelData 格式
    local sceneData = MapSerializer.ToLevelData(mapData)

    -- 2. 更新 LevelData 缓存并写文件
    LevelData.UpdateScene(sceneIdx, sceneData)

    -- 3. 将 LevelData 格式 JSON 打印到控制台（作为备份，防止 WASM 文件系统清除后丢失）
    local backupJson = cjson.encode(sceneData)
    print("[MapSerializer] === SCENE LEVELDATA JSON START (scene_" .. sceneIdx .. ") ===")
    print(backupJson)
    print("[MapSerializer] === SCENE LEVELDATA JSON END ===")

    print("[MapSerializer] SaveAsScene: scene " .. sceneIdx .. " (" .. (sceneData.name or "?") .. ")")
    return true
end

return MapSerializer
