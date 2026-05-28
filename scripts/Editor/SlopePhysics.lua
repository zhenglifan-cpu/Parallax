--- Editor/SlopePhysics.lua
--- 斜坡、水面、独木桥的 Box2D 碰撞体生成

local EditorConst = require("Editor.EditorConst")
local Shared      = require("Network.Shared")

local COL  = Shared.COLLISION
local VARS = Shared.VARS
local SlopePhysics = {}

-- ═══════════════════════════════════════════════
-- 斜坡顶点表
-- ═══════════════════════════════════════════════

local cs = EditorConst.CELL_SIZE  -- 0.5
local halfCs = cs * 0.5           -- 0.25 (30°斜坡每半格上升量)

--- 斜坡顶点定义（相对于格子左下角原点）
--- 45° 斜坡: 三角形 (3 顶点, 单格)
--- 30° 斜坡: 两格一组，left=三角形, right=四边形（或反之）
SlopePhysics.VERTICES = {
    -- ── 45° 上坡（左低右高） ◣ ──
    slope_45_up  = { Vector2(0, 0), Vector2(cs, 0), Vector2(cs, cs) },
    -- ── 45° 下坡（左高右低） ◢ ──
    slope_45_down = { Vector2(0, 0), Vector2(cs, 0), Vector2(0, cs) },

    -- ── 30° 上坡（两格一组, 总升高 = cs） ──
    -- left:  三角形，从 0 升至 halfCs
    slope_30_up_left  = { Vector2(0, 0), Vector2(cs, 0), Vector2(cs, halfCs) },
    -- right: 四边形，从 halfCs 升至 cs
    slope_30_up_right = { Vector2(0, 0), Vector2(cs, 0), Vector2(cs, cs), Vector2(0, halfCs) },

    -- ── 30° 下坡（两格一组, 总降低 = cs） ──
    -- left:  四边形，从 cs 降至 halfCs
    slope_30_down_left  = { Vector2(0, 0), Vector2(cs, 0), Vector2(cs, halfCs), Vector2(0, cs) },
    -- right: 三角形，从 halfCs 降至 0
    slope_30_down_right = { Vector2(0, 0), Vector2(cs, 0), Vector2(0, halfCs) },
}

-- ═══════════════════════════════════════════════
-- 斜坡创建
-- ═══════════════════════════════════════════════

--- 创建斜坡碰撞节点
--- 使用平滑 CollisionPolygon2D，friction=0.0
--- 防滑由 ServerGame 每帧强制覆写 X 速度实现，不依赖摩擦力
---@param scene userdata Scene
---@param id string 节点 ID
---@param wx number 格子左下角世界 X
---@param wy number 格子左下角世界 Y
---@param slopeType string "slope_45_up" 等
---@param visibleTo string "all"/"red"/"black"
---@return userdata node
function SlopePhysics.CreateSlope(scene, id, wx, wy, slopeType, visibleTo)
    local verts = SlopePhysics.VERTICES[slopeType]
    if not verts then
        print("[SlopePhysics] Unknown slope type: " .. tostring(slopeType))
        return nil
    end

    local node = scene:CreateChild("Slope_" .. id, REPLICATED)
    node.position = Vector3(wx, wy, 0)

    -- 节点变量（供渲染和碰撞识别用）
    node:SetVar(VARS.ENTITY_TYPE, Variant("slope"))
    node:SetVar(VARS.VISIBLE_TO,  Variant(visibleTo or "all"))
    node:SetVar("SLOPE_TYPE",     Variant(slopeType))

    -- 静态刚体
    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_STATIC

    -- 斜面多边形碰撞体
    -- 使用独立的 CAT_SLOPE 类别，玩家 maskBits 不包含此类别：
    --   → 玩家与斜坡不产生 Box2D 物理接触，彻底消除接触约束冲量导致的斜坡滑动
    --   → 射线检测仍可命中斜坡（射线 mask 包含 CAT_SLOPE）
    -- 箱子仍与斜坡物理接触（用于堆叠），所以 maskBits 保留 CAT_CRATE
    local poly = node:CreateComponent("CollisionPolygon2D")
    poly:SetVertexCount(#verts)
    for i = 1, #verts do
        poly:SetVertex(i - 1, verts[i])
    end
    poly.friction    = 0.0
    poly.restitution = 0.0
    poly.categoryBits = COL.CAT_SLOPE
    poly.maskBits     = COL.CAT_CRATE

    return node
end

-- ═══════════════════════════════════════════════
-- 水面创建（死亡传感器）
-- ═══════════════════════════════════════════════

--- 创建水面传感器（接触即死）
---@param scene userdata Scene
---@param id string
---@param cx number 中心 X
---@param cy number 中心 Y
---@param w number 宽度
---@param h number 高度
---@param visibleTo string
---@return userdata node
function SlopePhysics.CreateWater(scene, id, cx, cy, w, h, visibleTo)
    local node = scene:CreateChild("Water_" .. id, REPLICATED)
    node.position = Vector3(cx, cy, 0)

    node:SetVar(VARS.ENTITY_TYPE, Variant("water"))
    node:SetVar(VARS.VISIBLE_TO, Variant(visibleTo or "all"))
    node:SetVar("Width", Variant(w))
    node:SetVar("Height", Variant(h))

    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_STATIC

    local box = node:CreateComponent("CollisionBox2D")
    box:SetSize(w, h)
    box:SetCenter(0, 0)
    box.sensor = true  -- 传感器：触发碰撞事件但不产生物理力
    box.categoryBits = COL.CAT_SENSOR
    box.maskBits = COL.CAT_PLAYER

    return node
end

-- ═══════════════════════════════════════════════
-- 独木桥创建（可断裂平台）
-- ═══════════════════════════════════════════════

--- 创建可断裂的独木桥
---@param scene userdata Scene
---@param id string
---@param cx number 中心 X
---@param cy number 中心 Y
---@param w number 宽度
---@param h number 高度
---@param visibleTo string
---@param maxWeight? number 最大承重（默认2）
---@return userdata node
function SlopePhysics.CreateBridge(scene, id, cx, cy, w, h, visibleTo, maxWeight)
    local node = scene:CreateChild("Bridge_" .. id, REPLICATED)
    node.position = Vector3(cx, cy, 0)

    node:SetVar(VARS.ENTITY_TYPE, Variant("bridge"))
    node:SetVar(VARS.VISIBLE_TO, Variant(visibleTo or "all"))
    node:SetVar("Width", Variant(w))
    node:SetVar("Height", Variant(h))
    node:SetVar("BRIDGE_MAX_WEIGHT", Variant(maxWeight or EditorConst.BRIDGE_MAX_WEIGHT))
    node:SetVar("BRIDGE_CONTACTS", Variant(0))
    node:SetVar("BRIDGE_BROKEN", Variant(false))
    node:SetVar("BRIDGE_BREAK_TIMER", Variant(0.0))

    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_STATIC  -- 初始静止，断裂后切 BT_DYNAMIC

    local box = node:CreateComponent("CollisionBox2D")
    box:SetSize(w, h)
    box:SetCenter(0, 0)
    box.friction = 0.4
    box.restitution = 0.0
    box.density = 2.0
    box.categoryBits = COL.CAT_GROUND
    box.maskBits = COL.CAT_PLAYER + COL.CAT_CRATE

    return node
end

return SlopePhysics
