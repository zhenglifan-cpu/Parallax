--- Editor/EditorConst.lua
--- 地图编辑器常量定义

local EditorConst = {}

-- ─── 网格常量 ───
EditorConst.CELL_SIZE       = 0.5    -- 每格 0.5 米
EditorConst.DEFAULT_GRID_W  = 150    -- 默认地图宽度（格子数）
EditorConst.DEFAULT_GRID_H  = 30     -- 默认地图高度（格子数）
EditorConst.MIN_GRID_W      = 50
EditorConst.MAX_GRID_W      = 300
EditorConst.MIN_GRID_H      = 15
EditorConst.MAX_GRID_H      = 50

-- ─── 笔刷 ───
EditorConst.BRUSH_MIN       = 1
EditorConst.BRUSH_MAX       = 10
EditorConst.DEFAULT_BRUSH   = 1

-- ─── 编辑器视图 ───
EditorConst.ZOOM_MIN        = 0.3
EditorConst.ZOOM_MAX        = 4.0
EditorConst.ZOOM_STEP       = 0.15
EditorConst.PAN_SPEED       = 8.0    -- WASD 平移速度（米/秒）

-- ─── Undo ───
EditorConst.MAX_UNDO        = 100

-- ─── 工具 ID ───
EditorConst.TOOL = {
    -- 地形（不可移动/更改的地形元素）
    GROUND        = "ground",
    SLOPE_30_UP   = "slope_30_up",
    SLOPE_45_UP   = "slope_45_up",
    SLOPE_30_DOWN = "slope_30_down",
    SLOPE_45_DOWN = "slope_45_down",
    WATER         = "water",
    BRIDGE        = "bridge",
    EXIT          = "exit",
    CHECKPOINT    = "checkpoint",
    -- 道具（可放置在地形上，不覆盖地形）
    LADDER        = "ladder",
    CRATE         = "crate",
    -- 玩家出生点
    SPAWN_RED     = "spawn_red",
    SPAWN_BLACK   = "spawn_black",
    -- NPC（按剧本预设）
    NPC           = "npc",
    -- 传送点
    PORTAL_IN     = "portal_in",
    PORTAL_OUT    = "portal_out",
    -- 选择移动
    MOVE          = "move",
    -- 橡皮
    ERASER        = "eraser",
}

-- ─── 工具分类（按 UI 栏目分组） ───

-- 地形工具
EditorConst.TERRAIN_DEFS = {
    { id = "ground",        label = "平地",     icon = "■" },
    { id = "slope_45_up",   label = "45上坡",   icon = "◣" },
    { id = "slope_45_down", label = "45下坡",   icon = "◢" },
    { id = "slope_30_up",   label = "30上坡",   icon = "⟋" },
    { id = "slope_30_down", label = "30下坡",   icon = "⟍" },
    { id = "water",         label = "水面",     icon = "≈" },
    { id = "bridge",        label = "独木桥",   icon = "━" },
    { id = "exit",          label = "出口",     icon = "⚷" },
    { id = "checkpoint",    label = "存档点",   icon = "⚑" },
}

-- 道具工具（可与地形重叠，不影响地面表皮）
EditorConst.PROP_DEFS = {
    { id = "ladder", label = "梯子", icon = "☰" },
    { id = "crate",  label = "木箱", icon = "☒", weight = 1 },  -- 可被玩家推动
}

-- NPC 预设列表（按剧本出场顺序，双视角名称）
-- npcPresetId 用于放置时标识具体 NPC
EditorConst.NPC_PRESETS = {
    { presetId = "npc_01", label = "NPC_01", nameRed = "山顶灯塔信使", nameBlack = "庇护所急报信使" },
    { presetId = "npc_02", label = "NPC_02", nameRed = "白羽长者",     nameBlack = "灰羽守卫" },
    { presetId = "npc_03", label = "NPC_03", nameRed = "小雀",         nameBlack = "小雀" },
}

-- 玩家出生点
EditorConst.PLAYER_DEFS = {
    { id = "spawn_red",   label = "红鸟", icon = "●" },
    { id = "spawn_black",  label = "黑鸟", icon = "■" },
}

-- 传送点工具
EditorConst.PORTAL_DEFS = {
    { id = "portal_in",  label = "传送入", icon = "传" },
    { id = "portal_out", label = "传送出", icon = "送" },
}

-- 传送组上限
EditorConst.PORTAL_MAX_GROUP = 9

-- 传送点集合（快速判断）
EditorConst.IS_PORTAL = {
    portal_in  = true,
    portal_out = true,
}

-- 选择移动
EditorConst.MOVE_DEF = { id = "move", label = "移动", icon = "✥" }

-- 橡皮（始终显示在末尾）
EditorConst.ERASER_DEF = { id = "eraser", label = "橡皮", icon = "✕" }

-- 合并所有工具 ID（用于遍历）——保留兼容的 TOOL_DEFS
EditorConst.TOOL_DEFS = {}
for _, v in ipairs(EditorConst.TERRAIN_DEFS) do EditorConst.TOOL_DEFS[#EditorConst.TOOL_DEFS + 1] = v end
for _, v in ipairs(EditorConst.PROP_DEFS)    do EditorConst.TOOL_DEFS[#EditorConst.TOOL_DEFS + 1] = v end
for _, v in ipairs(EditorConst.PORTAL_DEFS)  do EditorConst.TOOL_DEFS[#EditorConst.TOOL_DEFS + 1] = v end
for _, v in ipairs(EditorConst.PLAYER_DEFS)  do EditorConst.TOOL_DEFS[#EditorConst.TOOL_DEFS + 1] = v end
EditorConst.TOOL_DEFS[#EditorConst.TOOL_DEFS + 1] = EditorConst.ERASER_DEF

-- ─── 道具属性 ───
EditorConst.PROP_WEIGHT = {
    crate = 1,   -- 木箱重量=1，可被玩家推动
}

-- ─── 道具集合（快速判断是否为道具类工具） ───
EditorConst.IS_PROP = {
    ladder = true,
    crate  = true,
}

-- ─── 工具颜色 RGBA (0-255) ───
EditorConst.TOOL_COLORS = {
    ground        = {  70, 100, 120, 255 },  -- 铁蓝色（地块主体）
    ground_grass  = { 220, 195,  60, 255 },  -- 亮黄色（草皮层）
    slope_30_up   = {  80, 110, 130, 255 },
    slope_45_up   = {  75, 105, 125, 255 },
    slope_30_down = {  80, 110, 130, 255 },
    slope_45_down = {  75, 105, 125, 255 },
    water         = {  40, 130, 210, 160 },  -- 半透蓝
    bridge        = { 160, 120,  60, 255 },  -- 木色
    ladder        = { 180, 150,  80, 255 },  -- 浅木色
    crate         = { 180, 140,  60, 255 },  -- 箱子木色
    spawn_red     = { 224,  80,  80, 255 },  -- 红
    spawn_black   = {  80,  80, 112, 255 },  -- 暗紫
    exit          = { 255, 215,   0, 255 },  -- 金
    npc           = {  80, 200, 120, 255 },  -- 绿
    checkpoint    = { 100, 200, 255, 255 },  -- 天蓝
    portal_in     = { 120,  60, 220, 255 },  -- 紫色（传送入口）
    portal_out    = {  60, 180, 220, 255 },  -- 青色（传送出口）
    move          = { 255, 180,  50, 200 },  -- 橙黄（选中高亮）
    eraser        = { 200, 200, 200, 128 },  -- 半透灰
}

-- ─── UI 面板颜色（暗色主题） ───
EditorConst.UI_COLORS = {
    panelBg      = { 40, 36, 42, 240 },
    sectionTitle = { 220, 210, 200, 255 },
    btnNormal    = { 60, 55, 62, 255 },
    btnHover     = { 80, 74, 82, 255 },
    btnActive    = { 100, 80, 70, 255 },
    btnText      = { 200, 195, 190, 255 },
    inputBg      = { 50, 46, 52, 255 },
    inputText    = { 230, 225, 220, 255 },
    border       = { 80, 74, 76, 255 },
}

-- ─── 视角模式 ───
EditorConst.VIEW_MODES = { "all", "red", "black" }
EditorConst.VIEW_LABELS = { "逻辑", "红鸟", "黑鸟" }

-- ─── 独木桥承重 ───
EditorConst.BRIDGE_MAX_WEIGHT = 2

-- ─── 设计分辨率（与 GameConst 保持一致）───
EditorConst.DESIGN_WIDTH  = 960
EditorConst.DESIGN_HEIGHT = 540

-- ─── UI 面板宽度 ───
EditorConst.PANEL_WIDTH = 200

-- ─── 场景文件路径 ───
EditorConst.SCENE_FILE_PREFIX  = "scene_"         -- 场景文件名前缀 (scene_0.json, scene_1.json ...)
EditorConst.ACTS_META_FILE     = "acts_meta.json"  -- 幕元数据文件

return EditorConst
