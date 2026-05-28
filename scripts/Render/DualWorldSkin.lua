--- Render/DualWorldSkin.lua
--- 《同途 / Parallax》双世界配色方案
--- 红鸟世界 = 温暖/明亮/庆典风格
--- 黑鸟世界 = 冷色/暗沉/末日风格

local Shared = require("Network.Shared")

local DualWorldSkin = {}

-- ═══════════════════════════════════════════════
-- 调色板定义 { r, g, b, a }
-- ═══════════════════════════════════════════════

local palettes = {
    -- ─── 红鸟世界：温暖、充满希望的庆典之旅 ───
    [Shared.ROLE.RED] = {
        -- 天空渐变
        skyTop     = { 90, 140, 220, 255 },
        skyBottom  = { 180, 210, 245, 255 },

        -- 背景层（视差）
        mountainFar  = { 150, 170, 200, 100 },
        mountainMid  = { 130, 155, 185, 140 },
        mountainNear = { 110, 140, 170, 180 },

        -- 地面/平台
        ground         = { 80, 130, 70, 255 },   -- 草绿
        groundOutline  = { 55, 100, 50, 255 },
        platform       = { 140, 110, 70, 255 },   -- 泥土棕
        platformOutline= { 110, 85, 55, 255 },
        invisPlatform  = { 160, 200, 100, 180 },  -- 明亮绿（隐形阶梯-红鸟可见）

        -- 角色
        playerSelf   = { 220, 80, 60, 255 },   -- 鲜红
        playerPartner= { 150, 150, 150, 200 },  -- 灰色影子

        -- NPC
        npcBody      = { 220, 195, 130, 255 },  -- 暖黄
        npcOutline   = { 170, 140, 80, 255 },
        npcNameColor = { 240, 230, 200, 255 },

        -- 可交互物
        bellActive   = { 255, 220, 60, 255 },   -- 金色
        bellInactive = { 160, 150, 120, 255 },   -- 灰金
        itemGlow     = { 255, 240, 100, 200 },

        -- 触发区（调试用，正常不可见）
        triggerDebug = { 255, 255, 0, 40 },

        -- UI 文字
        dialogueBg    = { 30, 30, 50, 220 },
        dialogueText  = { 240, 235, 220, 255 },

        -- 斜坡
        slope        = { 120, 100, 65, 255 },   -- 深泥棕
        slopeOutline = { 95, 78, 50, 255 },

        -- 独木桥
        bridge        = { 160, 120, 60, 255 },   -- 木色
        bridgeOutline = { 120, 90, 45, 255 },
        bridgeBroken  = { 120, 80, 50, 150 },    -- 断裂后半透明

        -- 水面
        water        = { 60, 140, 220, 120 },    -- 半透明蓝
        waterSurface = { 80, 170, 240, 180 },    -- 水面线稍亮

        -- 触发器（出口/存档点）
        exit           = { 80, 200, 80, 180 },    -- 绿色
        exitOutline    = { 50, 160, 50, 220 },
        checkpoint     = { 220, 180, 50, 180 },   -- 金黄色
        checkpointOutline = { 180, 140, 30, 220 },

        -- 梯子
        ladder       = { 180, 140, 70, 255 },   -- 木色
        ladderOutline= { 140, 100, 45, 255 },

        -- 木箱
        crate        = { 170, 130, 60, 255 },   -- 深木色
        crateOutline = { 130, 95, 40, 255 },

        -- 传送点
        portalIn          = { 140,  80, 220, 180 },  -- 紫色（入口）
        portalInOutline   = { 110,  50, 190, 220 },
        portalOut         = {  80, 180, 220, 180 },  -- 青色（出口）
        portalOutOutline  = {  50, 150, 190, 220 },

        -- 前景粒子
        particle = { 255, 230, 150, 60 },    -- 暖光粒子
    },

    -- ─── 黑鸟世界：冷酷、压迫的末日逃亡 ───
    [Shared.ROLE.BLACK] = {
        skyTop     = { 20, 25, 45, 255 },
        skyBottom  = { 50, 55, 75, 255 },

        mountainFar  = { 45, 50, 70, 100 },
        mountainMid  = { 40, 45, 60, 140 },
        mountainNear = { 35, 40, 55, 180 },

        ground         = { 50, 55, 60, 255 },    -- 深灰岩
        groundOutline  = { 35, 38, 42, 255 },
        platform       = { 60, 65, 75, 255 },    -- 冷灰石
        platformOutline= { 42, 45, 55, 255 },
        invisPlatform  = { 80, 90, 110, 0 },     -- 全透明（黑鸟看不见隐形台）

        playerSelf   = { 40, 40, 45, 255 },    -- 深炭黑
        playerPartner= { 150, 150, 150, 200 },  -- 灰色影子

        npcBody      = { 100, 105, 120, 255 },  -- 冷灰
        npcOutline   = { 70, 72, 85, 255 },
        npcNameColor = { 190, 195, 210, 255 },

        bellActive   = { 140, 180, 220, 255 },  -- 冰蓝
        bellInactive = { 80, 85, 95, 255 },
        itemGlow     = { 100, 160, 220, 180 },

        triggerDebug = { 100, 100, 255, 40 },

        dialogueBg    = { 15, 15, 25, 230 },
        dialogueText  = { 190, 195, 210, 255 },

        -- 斜坡
        slope        = { 55, 58, 68, 255 },    -- 深冷灰
        slopeOutline = { 40, 42, 52, 255 },

        -- 独木桥
        bridge        = { 70, 72, 82, 255 },    -- 冷灰
        bridgeOutline = { 50, 52, 62, 255 },
        bridgeBroken  = { 60, 62, 72, 150 },

        -- 水面
        water        = { 30, 60, 100, 120 },    -- 深蓝半透明
        waterSurface = { 40, 80, 130, 180 },

        -- 触发器（出口/存档点）
        exit           = { 50, 140, 50, 180 },    -- 暗绿
        exitOutline    = { 35, 110, 35, 220 },
        checkpoint     = { 150, 130, 40, 180 },   -- 暗金色
        checkpointOutline = { 120, 100, 30, 220 },

        -- 梯子
        ladder       = { 80, 75, 65, 255 },    -- 暗木色
        ladderOutline= { 55, 50, 42, 255 },

        -- 木箱
        crate        = { 75, 70, 58, 255 },    -- 深暗木色
        crateOutline = { 52, 48, 38, 255 },

        -- 传送点
        portalIn          = { 100,  50, 180, 180 },  -- 暗紫色（入口）
        portalInOutline   = {  75,  30, 150, 220 },
        portalOut         = {  50, 130, 180, 180 },  -- 暗青色（出口）
        portalOutOutline  = {  30, 100, 150, 220 },

        particle = { 80, 120, 180, 40 },    -- 冷光粒子
    },
}

-- ═══════════════════════════════════════════════
-- 公开 API
-- ═══════════════════════════════════════════════

--- 获取指定角色的调色板
---@param role string "red" | "black"
---@return table palette
function DualWorldSkin.Get(role)
    return palettes[role] or palettes[Shared.ROLE.RED]
end

--- 将 {r,g,b,a} 应用到 NanoVG 颜色
---@param c table {r, g, b, a}
---@return userdata nvgColor
function DualWorldSkin.Color(c)
    return nvgRGBA(c[1], c[2], c[3], c[4] or 255)
end

--- 获取两端颜色（用于渐变）
---@param c1 table
---@param c2 table
---@return userdata, userdata
function DualWorldSkin.GradientColors(c1, c2)
    return DualWorldSkin.Color(c1), DualWorldSkin.Color(c2)
end

return DualWorldSkin
