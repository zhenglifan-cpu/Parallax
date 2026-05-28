--- Editor/EditorUI.lua
--- 地图编辑器 UI 面板（左侧栏）
--- 使用 urhox-libs/UI 组件库构建

local UI = require("urhox-libs/UI")
local EditorConst = require("Editor.EditorConst")
local LevelData   = require("Game.LevelData")

local EditorUI = {}

-- ═══════════════════════════════════════════════
-- 内部引用
-- ═══════════════════════════════════════════════
local root_         = nil
local initialized_  = false
local visible_      = false

-- 回调表（由 MapEditor 设置）
local callbacks_ = {
    onToolSelect    = nil,  -- function(toolId, npcPresetId?)
    onViewMode      = nil,  -- function(modeIdx)
    onToggleBgFg    = nil,  -- function()
    onToggleOverlayAdjust = nil,  -- function()
    onBrushSize     = nil,  -- function(size)
    onBrushDelta    = nil,  -- function(delta) +1/-1
    onMapName       = nil,  -- function(name)
    onApplySize     = nil,  -- function(w, h)
    onSave          = nil,  -- function()
    onLoad          = nil,  -- function()
    onUndo          = nil,  -- function()
    onReset         = nil,  -- function() 清除地图数据
    onClear         = nil,  -- function()
    onPortalGroupChange = nil,  -- function(group) 传送组号改变
    onAddFreeOverlay    = nil,  -- function(imagePath) 从素材库添加自由贴图
    onNavigateAssetDir  = nil,  -- function(subPath) 导航到素材库子目录
    -- 场景切换回调
    onActSelect     = nil,  -- function(actIdx)
    onSceneSelect   = nil,  -- function(sceneIdx)
    onActAdd        = nil,  -- function()
    onActRemove     = nil,  -- function(actIdx)
    onSceneAdd      = nil,  -- function(actIdx)
    onSceneRemove   = nil,  -- function(actIdx, sceneIdx)
}

-- 状态引用（由 MapEditor 每帧更新）
local state_ = {
    mapName      = "custom_01",
    gridW        = 100,
    gridH        = 30,
    curTool      = "ground",
    npcPresetId  = nil,       -- 当前选中的 NPC 预设 ID（如 "npc_01"）
    viewMode     = 1,         -- 1=逻辑, 2=红鸟, 3=黑鸟
    brushSize    = 1,
    hideBgFg     = false,
    portalGroup  = 1,         -- 当前传送组号 1-9
    curActIdx    = 1,
    curSceneIdx  = 0,
    overlayAdjustMode  = false,  -- 贴图调整模式是否开启
    selectedOverlayCount = 0,    -- 当前已选中的 overlay 数量
    assetImages        = {},     -- 当前目录的图片路径列表
    assetDirs          = {},     -- 当前目录的子目录列表（相对于 image/贴图/）
    assetBrowserPath   = "",     -- 当前浏览路径（相对于 image/贴图/）
}

-- 尺寸是否锁定（确定后锁定，按"重做"解锁）
local sizeLocked_ = false

-- UI 控件引用
local refs_ = {
    nameField    = nil,
    widthField   = nil,
    heightField  = nil,
    brushLabel   = nil,
    toolBtns     = {},  -- toolId -> button widget
    npcBtns      = {},  -- presetId -> button widget
    viewBtns     = {},  -- modeIdx -> button widget
    bgFgBtn      = nil,
    applyBtn     = nil, -- 应用尺寸按钮
    sizeRow      = nil, -- 宽高输入行
}

-- ─── 颜色工具 ───
local CLR = EditorConst.UI_COLORS

local function rgba(t, aOverride)
    return { t[1], t[2], t[3], aOverride or t[4] }
end

-- ═══════════════════════════════════════════════
-- 构建 UI
-- ═══════════════════════════════════════════════

--- 创建分割线
local function Divider()
    return UI.Panel {
        width = "100%", height = 1,
        marginTop = 3, marginBottom = 3,
        backgroundColor = rgba(CLR.border),
    }
end

--- 创建区域标题
local function SectionTitle(text)
    return UI.Label {
        text = text,
        fontSize = 7,
        fontWeight = "bold",
        color = rgba(CLR.sectionTitle),
        marginBottom = 3,
    }
end

--- 创建小按钮
local function SmallBtn(text, onClick, widthPct)
    return UI.Button {
        text = text,
        fontSize = 6,
        width = widthPct or "48%",
        height = 16,
        paddingLeft = 2, paddingRight = 2,
        backgroundColor = rgba(CLR.btnNormal),
        color = rgba(CLR.btnText),
        borderRadius = 2,
        onClick = onClick,
    }
end

--- 创建工具按钮（2列网格中的一个）
local function ToolButton(def)
    local isActive = (state_.curTool == def.id)

    local btn = UI.Button {
        text = def.label,
        fontSize = 6,
        width = "48%",
        height = 16,
        paddingLeft = 3,
        borderRadius = 2,
        borderWidth = isActive and 1 or 0,
        borderColor = { 255, 200, 80, 255 },
        backgroundColor = isActive and rgba(CLR.btnActive) or rgba(CLR.btnNormal),
        color = rgba(CLR.btnText),
        onClick = function(self)
            if callbacks_.onToolSelect then
                callbacks_.onToolSelect(def.id)
            end
        end,
    }

    refs_.toolBtns[def.id] = btn
    return btn
end

--- 创建 NPC 预设按钮（选中时记录 presetId，工具切为 "npc"）
local function NpcButton(preset)
    local isActive = (state_.curTool == "npc" and state_.npcPresetId == preset.presetId)

    local btn = UI.Button {
        text = preset.label,
        fontSize = 6,
        width = "100%",
        height = 16,
        paddingLeft = 3,
        borderRadius = 2,
        borderWidth = isActive and 1 or 0,
        borderColor = { 255, 200, 80, 255 },
        backgroundColor = isActive and rgba(CLR.btnActive) or rgba(CLR.btnNormal),
        color = rgba(CLR.btnText),
        onClick = function(self)
            if callbacks_.onToolSelect then
                callbacks_.onToolSelect("npc", preset.presetId)
            end
        end,
    }

    -- NPC 按钮也注册到 toolBtns（用 presetId 作 key）
    refs_.npcBtns[preset.presetId] = btn
    return btn
end

--- 创建带双视角名称提示的 NPC 行
local function NpcRow(preset)
    return UI.Panel {
        width = "100%",
        flexDirection = "column",
        marginBottom = 2,
        children = {
            NpcButton(preset),
            UI.Label {
                text = preset.nameRed .. " / " .. preset.nameBlack,
                fontSize = 5,
                color = { 140, 140, 140, 200 },
                paddingLeft = 3,
            },
        },
    }
end

--- 创建视角按钮
local function ViewButton(label, modeIdx)
    local isActive = (state_.viewMode == modeIdx)
    local btn = UI.Button {
        text = label,
        fontSize = 6,
        width = "31%",
        height = 14,
        paddingLeft = 1, paddingRight = 1,
        backgroundColor = isActive and { 100, 80, 70, 255 } or rgba(CLR.btnNormal),
        color = isActive and { 255, 220, 100, 255 } or rgba(CLR.btnText),
        borderRadius = 2,
        borderWidth = isActive and 1 or 0,
        borderColor = { 255, 200, 80, 255 },
        onClick = function(self)
            if callbacks_.onViewMode then
                callbacks_.onViewMode(modeIdx)
            end
        end,
    }
    refs_.viewBtns[modeIdx] = btn
    return btn
end

--- 构建完整 UI 树
local function BuildUI()
    -- 重置控件引用（每次 BuildUI 都重建）
    refs_.toolBtns = {}
    refs_.npcBtns  = {}
    refs_.viewBtns = {}

    -- ─── 对应场景区域 ───
    local acts = LevelData.GetActs()
    local curAct = acts[state_.curActIdx]

    -- 幕选择按钮行
    local actBtns = {}
    for i, act in ipairs(acts) do
        local isActive = (i == state_.curActIdx)
        actBtns[#actBtns + 1] = UI.Button {
            text = act.name or ("幕" .. i),
            fontSize = 6,
            height = 14,
            paddingLeft = 3, paddingRight = 3,
            marginRight = 2, marginBottom = 2,
            backgroundColor = isActive and { 80, 100, 130, 255 } or rgba(CLR.btnNormal),
            color = isActive and { 255, 230, 120, 255 } or rgba(CLR.btnText),
            borderRadius = 2,
            borderWidth = isActive and 1 or 0,
            borderColor = { 120, 160, 220, 255 },
            onClick = function(self)
                if callbacks_.onActSelect then callbacks_.onActSelect(i) end
            end,
        }
    end

    -- 幕操作按钮
    local actOps = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 2,
        marginTop = 2,
        children = {
            SmallBtn("+幕", function()
                if callbacks_.onActAdd then callbacks_.onActAdd() end
            end, "30%"),
            SmallBtn("-幕", function()
                if callbacks_.onActRemove then callbacks_.onActRemove(state_.curActIdx) end
            end, "30%"),
        },
    }

    -- 场景选择按钮行
    local sceneBtns = {}
    if curAct then
        for _, sIdx in ipairs(curAct.sceneIndices) do
            local isActive = (sIdx == state_.curSceneIdx)
            sceneBtns[#sceneBtns + 1] = UI.Button {
                text = tostring(sIdx),
                fontSize = 6,
                width = 22, height = 16,
                marginRight = 2, marginBottom = 2,
                backgroundColor = isActive and { 90, 120, 80, 255 } or rgba(CLR.btnNormal),
                color = isActive and { 255, 255, 180, 255 } or rgba(CLR.btnText),
                borderRadius = 2,
                borderWidth = isActive and 1 or 0,
                borderColor = { 140, 200, 120, 255 },
                onClick = function(self)
                    if callbacks_.onSceneSelect then callbacks_.onSceneSelect(sIdx) end
                end,
            }
        end
    end

    -- 场景操作按钮
    local sceneOps = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 2,
        marginTop = 2,
        children = {
            SmallBtn("+场景", function()
                if callbacks_.onSceneAdd then callbacks_.onSceneAdd(state_.curActIdx) end
            end, "35%"),
            SmallBtn("-场景", function()
                if callbacks_.onSceneRemove then
                    callbacks_.onSceneRemove(state_.curActIdx, state_.curSceneIdx)
                end
            end, "35%"),
        },
    }

    local sceneSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 4, paddingBottom = 2,
        children = {
            SectionTitle("对应场景"),
            -- 当前场景指示
            UI.Label {
                text = string.format("场景 %d", state_.curSceneIdx),
                fontSize = 7,
                fontWeight = "bold",
                color = { 140, 200, 255, 255 },
                marginBottom = 3,
            },
            -- 幕选择
            UI.Label { text = "幕", fontSize = 5, color = { 160, 155, 150, 200 }, marginBottom = 1 },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                children = actBtns,
            },
            actOps,
            -- 场景选择
            UI.Label { text = "场景", fontSize = 5, color = { 160, 155, 150, 200 }, marginTop = 3, marginBottom = 1 },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                children = sceneBtns,
            },
            sceneOps,
        },
    }

    -- ─── 地图区域 ───
    local nameField = UI.TextField {
        value = state_.mapName,
        fontSize = 6,
        width = "100%",
        height = 14,
        backgroundColor = rgba(CLR.inputBg),
        color = rgba(CLR.inputText),
        borderRadius = 2,
        paddingLeft = 3,
        onSubmit = function(self, text)
            state_.mapName = text
            if callbacks_.onMapName then callbacks_.onMapName(text) end
        end,
    }
    refs_.nameField = nameField

    local lockedFieldBg = { 35, 32, 38, 255 }  -- 锁定时更暗
    local lockedFieldClr = { 120, 115, 110, 255 }  -- 锁定时文字变灰

    ---@type any
    local widthField
    ---@type any
    local heightField

    if sizeLocked_ then
        -- 锁定后用 Label 替代 TextField，彻底阻止输入
        widthField = UI.Label {
            text = tostring(state_.gridW),
            fontSize = 6,
            width = "45%",
            height = 14,
            backgroundColor = lockedFieldBg,
            color = lockedFieldClr,
            borderRadius = 2,
            paddingLeft = 3,
            paddingTop = 2,
        }
        heightField = UI.Label {
            text = tostring(state_.gridH),
            fontSize = 6,
            width = "45%",
            height = 14,
            backgroundColor = lockedFieldBg,
            color = lockedFieldClr,
            borderRadius = 2,
            paddingLeft = 3,
            paddingTop = 2,
        }
    else
        widthField = UI.TextField {
            value = tostring(state_.gridW),
            fontSize = 6,
            width = "45%",
            height = 14,
            backgroundColor = rgba(CLR.inputBg),
            color = rgba(CLR.inputText),
            borderRadius = 2,
            paddingLeft = 3,
            keyboardType = "number",
        }
        heightField = UI.TextField {
            value = tostring(state_.gridH),
            fontSize = 6,
            width = "45%",
            height = 14,
            backgroundColor = rgba(CLR.inputBg),
            color = rgba(CLR.inputText),
            borderRadius = 2,
            paddingLeft = 3,
            keyboardType = "number",
        }
    end
    refs_.widthField = widthField
    refs_.heightField = heightField

    local sizeRow = UI.Panel {
        width = "100%",
        flexDirection = "row",
        justifyContent = "space-between",
        marginTop = 3,
        children = {
            UI.Panel {
                width = "45%",
                children = {
                    UI.Label { text = "宽度", fontSize = 5, color = { 160, 155, 150, 200 }, marginBottom = 1 },
                    widthField,
                },
            },
            UI.Panel {
                width = "45%",
                children = {
                    UI.Label { text = "高度", fontSize = 5, color = { 160, 155, 150, 200 }, marginBottom = 1 },
                    heightField,
                },
            },
        },
    }
    refs_.sizeRow = sizeRow

    local applyBtn = UI.Button {
        text = sizeLocked_ and "尺寸已锁定" or "应用尺寸",
        fontSize = 6,
        width = "100%",
        height = 16,
        marginTop = 3,
        backgroundColor = sizeLocked_ and { 60, 60, 60, 255 } or { 80, 120, 100, 255 },
        color = sizeLocked_ and { 120, 120, 120, 255 } or { 230, 240, 235, 255 },
        borderRadius = 2,
        onClick = function(self)
            if sizeLocked_ then return end
            local w = tonumber(refs_.widthField:GetValue()) or state_.gridW
            local h = tonumber(refs_.heightField:GetValue()) or state_.gridH
            w = math.max(EditorConst.MIN_GRID_W, math.min(EditorConst.MAX_GRID_W, math.floor(w)))
            h = math.max(EditorConst.MIN_GRID_H, math.min(EditorConst.MAX_GRID_H, math.floor(h)))
            if callbacks_.onApplySize then callbacks_.onApplySize(w, h) end
            -- 锁定尺寸
            sizeLocked_ = true
            EditorUI.RefreshSizeLock()
        end,
    }
    refs_.applyBtn = applyBtn

    local mapSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 4, paddingBottom = 2,
        children = {
            SectionTitle("地图"),
            UI.Label { text = "名称", fontSize = 5, color = { 160, 155, 150, 200 }, marginBottom = 1 },
            nameField,
            sizeRow,
            applyBtn,
        },
    }

    -- ─── 视角区域 ───
    local bgFgBtn = UI.Button {
        text = state_.hideBgFg and "显示背景/前景" or "隐藏背景/前景",
        fontSize = 6,
        width = "100%",
        height = 14,
        marginTop = 3,
        backgroundColor = state_.hideBgFg and { 100, 80, 70, 255 } or rgba(CLR.btnNormal),
        color = state_.hideBgFg and { 255, 220, 100, 255 } or rgba(CLR.btnText),
        borderRadius = 2,
        onClick = function(self)
            if callbacks_.onToggleBgFg then callbacks_.onToggleBgFg() end
        end,
    }
    refs_.bgFgBtn = bgFgBtn

    -- "贴图调整"按钮：仅在红鸟/黑鸟视角下显示
    local viewSectionChildren = {
        SectionTitle("视角"),
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            justifyContent = "space-between",
            children = {
                ViewButton("红鸟", 2),
                ViewButton("黑鸟", 3),
                ViewButton("逻辑", 1),
            },
        },
        bgFgBtn,
    }

    if state_.viewMode >= 2 then
        local adjActive = state_.overlayAdjustMode
        local overlayAdjBtn = UI.Button {
            text = adjActive and "退出贴图调整" or "贴图调整",
            fontSize = 6,
            width = "100%",
            height = 14,
            marginTop = 3,
            backgroundColor = adjActive and { 60, 110, 180, 255 } or rgba(CLR.btnNormal),
            color = adjActive and { 180, 230, 255, 255 } or rgba(CLR.btnText),
            borderRadius = 2,
            borderWidth = adjActive and 1 or 0,
            borderColor = { 100, 180, 255, 255 },
            onClick = function(self)
                if callbacks_.onToggleOverlayAdjust then callbacks_.onToggleOverlayAdjust() end
            end,
        }
        viewSectionChildren[#viewSectionChildren + 1] = overlayAdjBtn
    end

    local viewSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = viewSectionChildren,
    }

    -- ─── 地形工具 ───
    local terrainChildren = {}
    for _, def in ipairs(EditorConst.TERRAIN_DEFS) do
        terrainChildren[#terrainChildren + 1] = ToolButton(def)
    end

    local terrainSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = {
            SectionTitle("地形"),
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 2,
                children = terrainChildren,
            },
        },
    }

    -- ─── 道具工具 ───
    local propChildren = {}
    for _, def in ipairs(EditorConst.PROP_DEFS) do
        propChildren[#propChildren + 1] = ToolButton(def)
    end

    local propSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = {
            SectionTitle("道具"),
            UI.Label {
                text = "可放置在地形上，不影响地面表皮",
                fontSize = 5, color = { 140, 140, 140, 180 }, marginBottom = 2,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 2,
                children = propChildren,
            },
        },
    }

    -- ─── NPC ───
    local npcSectionChildren = {
        SectionTitle("NPC"),
        UI.Label {
            text = "红鸟视角名 / 黑鸟视角名",
            fontSize = 5, color = { 140, 140, 140, 180 }, marginBottom = 2,
        },
    }
    for _, preset in ipairs(EditorConst.NPC_PRESETS) do
        npcSectionChildren[#npcSectionChildren + 1] = NpcRow(preset)
    end

    local npcSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = npcSectionChildren,
    }

    -- ─── 玩家出生点 ───
    local playerChildren = {}
    for _, def in ipairs(EditorConst.PLAYER_DEFS) do
        playerChildren[#playerChildren + 1] = ToolButton(def)
    end

    local playerSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = {
            SectionTitle("玩家"),
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 2,
                children = playerChildren,
            },
        },
    }

    -- ─── 传送点 ───
    local portalToolChildren = {}
    for _, def in ipairs(EditorConst.PORTAL_DEFS) do
        portalToolChildren[#portalToolChildren + 1] = ToolButton(def)
    end

    -- 组号选择按钮 1-9
    local groupBtns = {}
    for g = 1, EditorConst.PORTAL_MAX_GROUP do
        local isActive = (state_.portalGroup == g)
        groupBtns[#groupBtns + 1] = UI.Button {
            text = tostring(g),
            fontSize = 6,
            width = 18, height = 16,
            marginRight = 1, marginBottom = 1,
            backgroundColor = isActive and { 120, 60, 220, 255 } or rgba(CLR.btnNormal),
            color = isActive and { 255, 255, 255, 255 } or rgba(CLR.btnText),
            borderRadius = 2,
            borderWidth = isActive and 1 or 0,
            borderColor = { 180, 120, 255, 255 },
            onClick = function(self)
                if callbacks_.onPortalGroupChange then
                    callbacks_.onPortalGroupChange(g)
                end
            end,
        }
    end

    local portalSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = {
            SectionTitle("传送点"),
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 2,
                children = portalToolChildren,
            },
            UI.Label {
                text = "组号（同组配对）",
                fontSize = 5, color = { 140, 140, 140, 180 }, marginTop = 3, marginBottom = 2,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                children = groupBtns,
            },
        },
    }

    -- ─── 移动工具 + 橡皮 ───
    local utilSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = {
            SectionTitle("工具"),
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 2,
                children = {
                    ToolButton(EditorConst.MOVE_DEF),
                    ToolButton(EditorConst.ERASER_DEF),
                },
            },
        },
    }

    -- ─── 笔刷 ───
    local brushLabel = UI.Label {
        text = tostring(state_.brushSize),
        fontSize = 6,
        color = rgba(CLR.inputText),
        width = 20,
        textAlign = "center",
    }
    refs_.brushLabel = brushLabel

    local brushSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 2,
        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                children = {
                    UI.Label { text = "笔刷", fontSize = 6, color = { 160, 155, 150, 200 }, width = 20 },
                    UI.Button {
                        text = "-", fontSize = 7, width = 16, height = 14,
                        backgroundColor = rgba(CLR.btnNormal), color = rgba(CLR.btnText), borderRadius = 2,
                        onClick = function()
                            if callbacks_.onBrushDelta then callbacks_.onBrushDelta(-1) end
                        end,
                    },
                    brushLabel,
                    UI.Button {
                        text = "+", fontSize = 7, width = 16, height = 14,
                        backgroundColor = rgba(CLR.btnNormal), color = rgba(CLR.btnText), borderRadius = 2,
                        onClick = function()
                            if callbacks_.onBrushDelta then callbacks_.onBrushDelta(1) end
                        end,
                    },
                },
            },
        },
    }

    -- ─── 操作区域 ───
    local opsSection = UI.Panel {
        width = "100%",
        flexDirection = "column",
        paddingLeft = 5, paddingRight = 5, paddingTop = 2, paddingBottom = 5,
        children = {
            SectionTitle("操作"),
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 2,
                children = {
                    SmallBtn("撤销", function() if callbacks_.onUndo then callbacks_.onUndo() end end),
                    SmallBtn("重做", function()
                        if callbacks_.onReset then callbacks_.onReset() end
                        -- 解锁尺寸
                        sizeLocked_ = false
                        EditorUI.RefreshSizeLock()
                    end),
                    SmallBtn("清空", function() if callbacks_.onClear then callbacks_.onClear() end end),
                    SmallBtn("保存", function() if callbacks_.onSave then callbacks_.onSave() end end),
                },
            },
            UI.Button {
                text = "读取保存",
                fontSize = 6,
                width = "100%",
                height = 16,
                marginTop = 2,
                backgroundColor = rgba(CLR.btnNormal),
                color = rgba(CLR.btnText),
                borderRadius = 2,
                onClick = function()
                    if callbacks_.onLoad then callbacks_.onLoad() end
                end,
            },
        },
    }

    -- ─── 组装完整面板 ───
    local panelW = EditorConst.PANEL_WIDTH

    -- 贴图调整信息区块（贴图调整模式开启时显示选中计数 + 快捷键提示 + 素材浏览器）
    local overlaySection = nil
    if state_.overlayAdjustMode then
        local selCount = state_.selectedOverlayCount or 0
        local selText  = selCount > 0 and ("已选 " .. selCount .. " 个贴图") or "未选中贴图"

        -- 快捷键提示行列表
        local hintChildren = {
            SectionTitle("贴图调整"),
            UI.Label {
                text = selText,
                fontSize = 7,
                color = selCount > 0 and { 255, 220, 80, 255 } or { 160, 160, 160, 255 },
                marginBottom = 3,
            },
            UI.Label { text = "← → ↑ ↓  持续移动贴图",   fontSize = 6, color = { 200, 200, 200, 220 } },
            UI.Label { text = "[  ]  旋转 ±15°",          fontSize = 6, color = { 200, 200, 200, 220 }, marginTop = 1 },
            UI.Label { text = "-  =  缩放 ±10%",          fontSize = 6, color = { 200, 200, 200, 220 }, marginTop = 1 },
            UI.Label { text = "拖拽  移动贴图",            fontSize = 6, color = { 200, 200, 200, 220 }, marginTop = 1 },
            UI.Label { text = "Delete  删除选中贴图",        fontSize = 6, color = { 200, 200, 200, 220 }, marginTop = 1 },
            UI.Label { text = "Ctrl+C/V  复制/粘贴",       fontSize = 6, color = { 200, 200, 200, 220 }, marginTop = 1 },
        }

        -- 素材库浏览器
        local assetImages    = state_.assetImages    or {}
        local assetDirs      = state_.assetDirs      or {}
        local browserPath    = state_.assetBrowserPath or ""

        -- 分隔线
        hintChildren[#hintChildren+1] = UI.Panel {
            width = "100%", height = 1,
            backgroundColor = { 100, 130, 180, 80 },
            marginTop = 5, marginBottom = 3,
        }

        -- 路径栏（显示当前位置 + 返回按钮）
        local pathLabel = (browserPath == "" or browserPath == nil)
            and "贴图/"
            or ("贴图/" .. browserPath .. "/")
        local pathRow = UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            gap = 3,
            marginBottom = 3,
            children = {
                UI.Label {
                    text = pathLabel,
                    fontSize = 6,
                    color = { 120, 200, 255, 240 },
                    flexShrink = 1,
                },
            },
        }
        -- 如果不在根目录，加"返回"按钮
        if browserPath ~= "" and browserPath ~= nil then
            local parentPath = browserPath:match("^(.*)/[^/]+$") or ""
            pathRow.children[#pathRow.children+1] = UI.Button {
                text = "↑ 返回",
                fontSize = 5,
                width = 36, height = 14,
                backgroundColor = { 60, 80, 120, 200 },
                color = { 200, 220, 255, 255 },
                borderRadius = 2,
                onClick = function()
                    if callbacks_.onNavigateAssetDir then
                        callbacks_.onNavigateAssetDir(parentPath)
                    end
                end,
            }
        end
        hintChildren[#hintChildren+1] = pathRow

        -- 子目录按钮（全宽，每行1个）
        for _, dirRel in ipairs(assetDirs) do
            local dirName = dirRel:match("[^/]+$") or dirRel
            local capRel = dirRel
            hintChildren[#hintChildren+1] = UI.Button {
                text = "📁 " .. dirName,
                fontSize = 6,
                width = "100%",
                height = 18,
                marginBottom = 2,
                backgroundColor = { 50, 70, 110, 220 },
                color = { 180, 210, 255, 255 },
                borderRadius = 3,
                borderWidth = 1,
                borderColor = { 80, 110, 160, 150 },
                onClick = function()
                    if callbacks_.onNavigateAssetDir then
                        callbacks_.onNavigateAssetDir(capRel)
                    end
                end,
            }
        end

        -- 图片文件按钮（每行2个）
        if #assetImages > 0 then
            if #assetDirs > 0 then
                -- 目录与文件之间加细线
                hintChildren[#hintChildren+1] = UI.Panel {
                    width = "100%", height = 1,
                    backgroundColor = { 80, 100, 140, 60 },
                    marginBottom = 2,
                }
            end
            local rows = {}
            local rowItems = nil
            for i, imgPath in ipairs(assetImages) do
                if (i - 1) % 2 == 0 then
                    rowItems = {}
                    rows[#rows+1] = rowItems
                end
                local fname = imgPath:match("[^/\\]+$") or imgPath
                local label = fname:match("^(.+)%.[^%.]+$") or fname
                if #label > 8 then label = label:sub(1, 7) .. "…" end
                local capPath = imgPath
                rowItems[#rowItems+1] = UI.Button {
                    text = label,
                    fontSize = 5,
                    width = "48%",
                    height = 20,
                    backgroundColor = { 35, 60, 100, 220 },
                    color = { 210, 230, 255, 255 },
                    borderRadius = 3,
                    borderWidth = 1,
                    borderColor = { 80, 120, 180, 160 },
                    onClick = function()
                        if callbacks_.onAddFreeOverlay then
                            callbacks_.onAddFreeOverlay(capPath)
                        end
                    end,
                }
            end
            for _, rowArr in ipairs(rows) do
                hintChildren[#hintChildren+1] = UI.Panel {
                    width = "100%",
                    flexDirection = "row",
                    justifyContent = "space-between",
                    gap = 2,
                    marginBottom = 2,
                    children = rowArr,
                }
            end
        elseif #assetDirs == 0 then
            hintChildren[#hintChildren+1] = UI.Label {
                text = "（此目录为空）",
                fontSize = 6,
                color = { 150, 150, 150, 180 },
                marginTop = 2,
            }
        end

        overlaySection = UI.Panel {
            width = "100%",
            flexDirection = "column",
            paddingLeft = 6, paddingRight = 6,
            paddingTop = 4, paddingBottom = 6,
            backgroundColor = { 25, 45, 75, 210 },
            children = hintChildren,
        }
    end

    -- 基础子节点列表
    local panelChildren = {
        sceneSection,
        Divider(),
        mapSection,
        Divider(),
        viewSection,
        Divider(),
        utilSection,
        Divider(),
        terrainSection,
        Divider(),
        propSection,
        Divider(),
        npcSection,
        Divider(),
        playerSection,
        Divider(),
        portalSection,
        Divider(),
        brushSection,
        Divider(),
        opsSection,
    }
    -- 贴图调整模式信息面板：插到 viewSection 后面
    if overlaySection then
        -- panelChildren: 1=scene,2=Div,3=map,4=Div,5=view,6=Div,7=util,...
        table.insert(panelChildren, 6, Divider())
        table.insert(panelChildren, 7, overlaySection)
    end

    root_ = UI.Panel {
        width = panelW,
        height = "100%",
        position = "absolute",
        left = 0, top = 0,
        backgroundColor = rgba(CLR.panelBg),
        borderRightWidth = 1,
        borderColor = rgba(CLR.border),
        overflow = "scroll",
        children = panelChildren,
    }

    return root_
end

-- ═══════════════════════════════════════════════
-- 公共接口
-- ═══════════════════════════════════════════════

--- 初始化 UI（必须在 MapEditor.Init 之后调用一次）
function EditorUI.Init()
    if initialized_ then return end
    UI.Init({
        fonts = {
            { family = "sans", weights = { normal = "Fonts/NotoSansSC-Regular.otf" } }
        },
        scale = UI.Scale.DEFAULT,
    })

    -- 修复滚轮穿透 BUG：
    -- UI 库的 HandleWheel 内有一个 fallback 逻辑：当鼠标下没有悬停 widget 时，
    -- 直接将 root_ 作为滚动目标，导致在工具栏外滚轮也会滚动左侧工具栏。
    -- patch 后，只有鼠标在工具栏区域内时才允许 UI 处理滚轮事件。
    local _origHandleWheel = UI.HandleWheel
    UI.HandleWheel = function(dx, dy)
        local dpr = graphics:GetDPR()
        local logicalW = graphics:GetWidth() / dpr
        local designW  = EditorConst.DESIGN_WIDTH
        local viewScale = logicalW / designW
        -- PANEL_WIDTH 是设计像素，乘 viewScale 转为逻辑像素，再与逻辑鼠标坐标比较
        if (input.mousePosition.x / dpr) < EditorConst.PANEL_WIDTH * viewScale then
            _origHandleWheel(dx, dy)
        end
    end

    initialized_ = true
end

--- 设置回调
---@param cbs table 回调函数表
function EditorUI.SetCallbacks(cbs)
    for k, v in pairs(cbs) do
        callbacks_[k] = v
    end
end

--- 重建 UI（更新 state_ 后调用此函数刷新整个 UI 树）
local function RebuildUI()
    if not visible_ then return end
    local panel = BuildUI()
    UI.SetRoot(panel)
end

--- 显示编辑器面板
function EditorUI.Show()
    if not initialized_ then
        EditorUI.Init()
    end
    visible_ = true
    local panel = BuildUI()
    UI.SetRoot(panel)
end

--- 隐藏编辑器面板
function EditorUI.Hide()
    if visible_ then
        UI.SetRoot(nil)
        visible_ = false
        root_ = nil
    end
end

--- 是否可见
---@return boolean
function EditorUI.IsVisible()
    return visible_
end

--- 更新状态（由 MapEditor 每帧调用来同步数据）
---@param newState table
function EditorUI.UpdateState(newState)
    for k, v in pairs(newState) do
        state_[k] = v
    end
end

--- 刷新工具按钮高亮（工具切换时调用）
---@param curToolId string
---@param npcPresetId? string
function EditorUI.RefreshToolHighlight(curToolId, npcPresetId)
    state_.curTool = curToolId
    state_.npcPresetId = npcPresetId or nil
    RebuildUI()
end

--- 刷新视角按钮高亮
function EditorUI.RefreshViewHighlight(modeIdx)
    state_.viewMode = modeIdx
    RebuildUI()
end

--- 刷新隐藏背景/前景按钮
function EditorUI.RefreshBgFgBtn(hidden)
    state_.hideBgFg = hidden
    RebuildUI()
end

--- 刷新笔刷大小标签
function EditorUI.RefreshBrushLabel(size)
    state_.brushSize = size
    RebuildUI()
end

--- 刷新尺寸锁定状态
function EditorUI.RefreshSizeLock()
    RebuildUI()
end

--- 解锁尺寸（外部调用）
function EditorUI.UnlockSize()
    sizeLocked_ = false
    RebuildUI()
end

--- 同步宽高字段值（从 mapData 同步到 UI 输入框）
function EditorUI.SyncSizeFields(w, h)
    state_.gridW = w
    state_.gridH = h
    RebuildUI()
end

--- 获取面板宽度（供 MapEditor 计算画布偏移）
---@return number
function EditorUI.GetPanelWidth()
    return visible_ and EditorConst.PANEL_WIDTH or 0
end

--- 刷新贴图调整面板（模式切换 / 选中变化 / 粘贴后调用）
function EditorUI.RefreshOverlayAdjust()
    RebuildUI()
end

return EditorUI
