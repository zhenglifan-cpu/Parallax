--- Game/ServerGame.lua
--- 《同途 / Parallax》服务端游戏逻辑
--- 管理物理世界、玩家节点、关卡加载、输入处理

local Shared = require("Network.Shared")
local GameConst = require("Game.GameConst")
local LevelData = require("Game.LevelData")
local SlopePhysics = require("Editor.SlopePhysics")

local VARS = Shared.VARS
local CTRL = Shared.CTRL
local COL  = Shared.COLLISION

local ServerGame = {}

-- ═══════════════════════════════════════════════
-- 数据结构
-- ═══════════════════════════════════════════════

-- 每个 pairId 对应一个 GameInstance
-- GameInstance = {
--   scene,                      -- Scene 引用
--   pairId,                     -- 配对 ID
--   sceneIdx,                   -- 当前场景索引 (0-7)
--   players = {                 -- connKey → PlayerData
--     [connKey] = {
--       connection, role, node, body,
--       groundContacts, onGround,
--     }
--   },
--   levelNodes = {},            -- 当前关卡的实体节点列表
--   bellStates = {},            -- 双铃谜题状态
-- }

---@type table<number, table>
local instances_ = {}

-- 已触发的一次性事件（避免重复触发）
-- key = pairId .. "_" .. connKey .. "_" .. triggerId
---@type table<string, boolean>
local firedTriggers_ = {}

-- 传送冷却追踪：connKey → 剩余冷却秒数
---@type table<string, number>
local portalCooldowns_ = {}
local PORTAL_COOLDOWN = 0.5   -- 传送冷却时间（秒）

-- ═══════════════════════════════════════════════
-- 关卡加载
-- ═══════════════════════════════════════════════

--- 创建玩家物理节点（REPLICATED，客户端可见）
---@param inst table GameInstance
---@param connKey string
---@param role string
---@param connection Connection
---@param spawnX number
---@param spawnY number
---@return table PlayerData
local function CreatePlayer(inst, connKey, role, connection, spawnX, spawnY)
    local scene = inst.scene
    local node = scene:CreateChild("Player_" .. role, REPLICATED)
    node.position = Vector3(spawnX, spawnY, 0)
    node:SetVar(VARS.ENTITY_TYPE, Variant("player"))
    node:SetVar(VARS.ROLE, Variant(role))
    node:SetVar(VARS.CONN_KEY, Variant(connKey))
    node:SetVar(VARS.PAIR_ID, Variant(inst.pairId))

    -- 物理刚体
    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_DYNAMIC
    body.fixedRotation = true
    body.linearDamping = 0.0
    body.gravityScale = 1.0

    -- 主碰撞体（8 顶点修长椭圆多边形，贴合鸟型轮廓）
    -- 全高 0.45m = 0.9格（CELL_SIZE=0.5m），可通过 1格净高通道（余量 0.05m）
    -- 半宽 hx=0.1362m，半高 hy=0.225m
    -- Box2D 要求顶点逆时针（CCW）排列，从右侧 0° 逆时针到 315°
    -- friction=0.0：防滑由 Update/PostPhysicsCorrect 覆写速度实现
    local hx = GameConst.PLAYER_HX      -- 0.1362
    local hy = GameConst.PLAYER_RADIUS  -- 0.225
    local c45 = math.cos(math.pi * 0.25)  -- cos(45°) ≈ 0.7071
    local ovalVerts = {
        Vector2( hx,         0       ),   -- 0°   右中
        Vector2( hx * c45,   hy * c45),   -- 45°  右上
        Vector2( 0,          hy      ),   -- 90°  顶
        Vector2(-hx * c45,   hy * c45),   -- 135° 左上
        Vector2(-hx,         0       ),   -- 180° 左中
        Vector2(-hx * c45,  -hy * c45),   -- 225° 左下
        Vector2( 0,         -hy      ),   -- 270° 底
        Vector2( hx * c45,  -hy * c45),   -- 315° 右下
    }
    local shape = node:CreateComponent("CollisionPolygon2D")
    shape:SetVertexCount(8)
    for i = 1, 8 do
        shape:SetVertex(i - 1, ovalVerts[i])
    end
    shape.friction = 0.0
    shape.restitution = 0.0
    shape.density = 1.0
    shape.categoryBits = COL.CAT_PLAYER
    -- CAT_SLOPE 不在 maskBits 中：玩家与斜坡不产生物理接触（无约束冲量 → 无滑动）
    -- 斜坡检测改由射线（mask 含 CAT_SLOPE）负责
    shape.maskBits = COL.CAT_GROUND | COL.CAT_SENSOR | COL.CAT_CRATE

    -- 脚底传感器（地面检测）
    -- 椭圆底端 y = -hy = -0.225，传感器中心设在 -0.205（底面上方 0.02m）
    local foot = node:CreateComponent("CollisionCircle2D")
    foot.radius = GameConst.FOOT_SENSOR_RADIUS
    foot.center = Vector2(0, GameConst.FOOT_SENSOR_OFFSET_Y)
    foot.trigger = true
    foot.categoryBits = COL.CAT_SENSOR
    foot.maskBits = COL.CAT_GROUND | COL.CAT_CRATE

    local playerData = {
        connection = connection,
        role = role,
        node = node,
        body = body,
        groundContacts = 0,
        onGround = false,
        lastGroundY = spawnY,   -- 最后一次站在地面时的 Y 坐标（用于摔落伤害计算）
        -- ── 蔚蓝风格跳跃手感 ──
        coyoteTimer    = 0,     -- 土狼跳计时器：离地后倒计时，>0 时仍可起跳
        jumpBufferTimer= 0,     -- 起跳缓冲计时器：按键时若在空中则缓冲，>0 且触地即起跳
        airJumpsLeft   = 0,     -- 剩余空中跳次数（落地时恢复）
        prevJump       = false, -- 上一帧跳跃键状态（边沿检测，防连跳）
        jumpInitiated  = false, -- 主动起跳标志（豁免当次落地的摔落伤害检测）
        prevMoveLeft   = false, -- 上一帧左键状态（边沿检测，用于"最后按下的键"逻辑）
        prevMoveRight  = false, -- 上一帧右键状态
        lastDirLeft    = false, -- 最后一次按下的方向键（true=左，false=右）
        -- ── 离地防抖 ──
        offGroundFrames = 0,    -- 连续离地帧计数；达到阈值后才设 onGround=false
        -- ── 推箱子 ──
        pushingCrate = false,   -- 是否正在推/拉箱子（用于碰撞过滤和渲染）
        pushTarget = nil,       -- 当前推/拉的箱子节点
        pushDir = 0,            -- 推方向 -1/0/1（视觉用）
        -- ── 短跳/长跳状态 ──
        isShortJump = false,    -- JumpCut 后置 true，使用 SHORT_JUMP_GRAVITY_SCALE；落地后重置
        longJumpSignaled = false, -- 长跳确认信号已发送标志；防止重复发送；落地/起跳后重置
        jumpHoldTimer  = 0,     -- 本次跳跃已按住跳键的累计时长（秒）；起跳时归零
        jumpCommitted  = false, -- 本次跳跃类型已确认（短/长）；确认后不再触发另一种类型
        -- ── 二段跳解锁 ──
        doubleJumpUnlocked = false,  -- 通过第一幕第0场景后解锁；解锁前不允许二段跳
    }

    inst.players[connKey] = playerData
    print(string.format("[ServerGame] Created player: role=%s at (%.1f, %.1f)",
        role, spawnX, spawnY))

    return playerData
end

--- 加载关卡实体到场景
---@param inst table GameInstance
---@param sceneIdx number
local function LoadLevel(inst, sceneIdx)
    -- ═══════════════════════════════════════════════════════
    -- 双重清理策略：
    --   1) 先按 inst.levelNodes 列表删除（快速路径）
    --   2) 再扫描场景树，删除所有属于本实例的非 player 节点（兜底）
    -- 这样即使 DoInteract 等地方提前 Remove 了某些节点导致
    -- levelNodes 中存在悬空引用，也能保证彻底清理。
    -- ═══════════════════════════════════════════════════════

    -- 第 1 步：按 levelNodes 列表删除（服务端场景树清理）
    for _, n in ipairs(inst.levelNodes) do
        if n then pcall(function() n:Remove() end) end
    end

    -- 第 2 步：扫描场景树兜底，删除残留的非 player 实体节点
    for sweep = 1, 3 do
        local children = inst.scene:GetChildren(false)
        local foundAny = false
        for i = 1, #children do
            local c = children[i]
            if c then
                -- 检查正确 key（"EntityType"）
                local ok, etVar = pcall(function() return c:GetVar(VARS.ENTITY_TYPE) end)
                if ok and etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty() then
                    if etVar:GetString() ~= "player" then
                        pcall(function() c:Remove() end)
                        foundAny = true
                    end
                else
                    -- 兼容旧 key（"ENTITY_TYPE"）：清除早期创建的残留节点
                    local ok2, etVar2 = pcall(function() return c:GetVar("ENTITY_TYPE") end)
                    if ok2 and etVar2 and type(etVar2.IsEmpty) == "function" and not etVar2:IsEmpty() then
                        pcall(function() c:Remove() end)
                        foundAny = true
                    end
                end
            end
        end
        if not foundAny then break end
    end
    inst.levelNodes = {}
    inst.bellStates = {}
    inst.textTriggers = {}
    inst.triggers = {}            -- trigger 类型（scene_transition 等）
    inst.exitReady = {}           -- connKey → bool，用于场景切换双人确认
    inst.npcTalkedBy = {}         -- npcId → { red=bool, black=bool }，NPC 对话跟踪
    inst.itemsPickedUp = {}       -- itemId → true，道具拾取跟踪

    -- 清除该实例的已触发标记
    local prefix = tostring(inst.pairId) .. "_"
    for k in pairs(firedTriggers_) do
        if k:sub(1, #prefix) == prefix then
            firedTriggers_[k] = nil
        end
    end

    local levelDef = LevelData.GetScene(sceneIdx)
    if not levelDef then
        print("[ServerGame] WARNING: No level data for scene " .. sceneIdx)
        return
    end

    inst.sceneIdx = sceneIdx
    print("[ServerGame] Loading level: Scene " .. sceneIdx .. " - " .. levelDef.name)

    -- ── 诊断：详细打印 GetScene 返回的全部对象 ──
    local diagObjCounts = {}
    for _, obj in ipairs(levelDef.objects or {}) do
        local key = obj.type or "nil"
        if obj.slopeType then key = key .. "(slope:" .. obj.slopeType .. ")" end
        if obj.bridgeWeight then key = key .. "(bridge)" end
        if obj.event then key = key .. "(ev:" .. obj.event .. ")" end
        diagObjCounts[key] = (diagObjCounts[key] or 0) + 1
    end
    local diagStr = ""
    for k, v in pairs(diagObjCounts) do diagStr = diagStr .. k .. "=" .. v .. " " end
    print(string.format("[ServerGame][DIAG] GetScene returned %d objects: %s",
        #(levelDef.objects or {}), diagStr))
    print(string.format("[ServerGame][DIAG] Spawn: red=(%.1f,%.1f) black=(%.1f,%.1f)",
        levelDef.spawnX or -1, levelDef.spawnY or -1,
        levelDef.spawnBlackX or -1, levelDef.spawnBlackY or -1))

    local diagCreated, diagSkipped = 0, 0
    for objIdx, obj in ipairs(levelDef.objects) do
        print(string.format("[ServerGame][DIAG] Processing obj[%d]: type=%s id=%s x=%.1f y=%.1f slopeType=%s event=%s",
            objIdx, tostring(obj.type), tostring(obj.id),
            obj.x or 0, obj.y or 0, tostring(obj.slopeType), tostring(obj.event)))
        if obj.type == "platform" then
            -- 检查是否是斜坡
            if obj.slopeType then
                local node = SlopePhysics.CreateSlope(
                    inst.scene, obj.id, obj.x, obj.y,
                    obj.slopeType, obj.visibleTo or "all"
                )
                if node then
                    table.insert(inst.levelNodes, node)
                end
            -- 检查是否是独木桥
            elseif obj.bridgeWeight then
                local node = SlopePhysics.CreateBridge(
                    inst.scene, obj.id, obj.x, obj.y,
                    obj.w, obj.h, obj.visibleTo or "all", obj.bridgeWeight
                )
                if node then
                    table.insert(inst.levelNodes, node)
                end
            else
                -- 普通平台
                local node = inst.scene:CreateChild("Plat_" .. obj.id, REPLICATED)
                node.position = Vector3(obj.x, obj.y, 0)
                node:SetVar(VARS.ENTITY_TYPE, Variant("platform"))
                node:SetVar(VARS.VISIBLE_TO, Variant(obj.visibleTo or "all"))

                local body = node:CreateComponent("RigidBody2D")
                body.bodyType = BT_STATIC

                local shape = node:CreateComponent("CollisionBox2D")
                shape:SetSize(obj.w, obj.h)
                shape.friction = 0.3
                shape.restitution = 0.0
                shape.categoryBits = COL.CAT_GROUND

                node:SetVar("Width", Variant(obj.w))
                node:SetVar("Height", Variant(obj.h))

                table.insert(inst.levelNodes, node)
            end

        elseif obj.type == "npc" then
            local node = inst.scene:CreateChild("NPC_" .. obj.id, REPLICATED)
            node.position = Vector3(obj.x, obj.y, 0)
            node:SetVar(VARS.ENTITY_TYPE, Variant("npc"))
            node:SetVar(VARS.VISIBLE_TO, Variant("all"))
            node:SetVar("NpcId", Variant(obj.id))
            node:SetVar("NameRed", Variant(obj.name))
            node:SetVar("NameBlack", Variant(obj.nameAlt))

            table.insert(inst.levelNodes, node)

        elseif obj.type == "interactable" then
            local node = inst.scene:CreateChild("Inter_" .. obj.id, REPLICATED)
            node.position = Vector3(obj.x, obj.y, 0)
            node:SetVar(VARS.ENTITY_TYPE, Variant("interactable"))
            node:SetVar(VARS.VISIBLE_TO, Variant(obj.visibleTo or "all"))
            node:SetVar("Kind", Variant(obj.kind))

            if obj.kind == "bell" then
                node:SetVar("Activated", Variant(false))
                inst.bellStates[obj.id] = false
            end
            if obj.itemName then
                node:SetVar("ItemName", Variant(obj.itemName))
            end
            if obj.target then
                node:SetVar("Target", Variant(obj.target))
            end

            -- 交互区域碰撞（触发器）
            local body = node:CreateComponent("RigidBody2D")
            body.bodyType = BT_STATIC
            local trigShape = node:CreateComponent("CollisionCircle2D")
            trigShape.radius = 1.0
            trigShape.trigger = true
            trigShape.categoryBits = COL.CAT_GROUND
            trigShape.maskBits = COL.CAT_PLAYER

            table.insert(inst.levelNodes, node)

        elseif obj.type == "trigger" then
            -- 水面死亡触发器：使用物理传感器碰撞检测
            if obj.event == "water_death" then
                local node = SlopePhysics.CreateWater(
                    inst.scene, obj.id, obj.x, obj.y,
                    obj.w, obj.h, obj.visibleTo or "all"
                )
                if node then
                    table.insert(inst.levelNodes, node)
                end
            else
                local node = inst.scene:CreateChild("Trig_" .. obj.id, REPLICATED)
                node.position = Vector3(obj.x, obj.y, 0)
                node:SetVar(VARS.ENTITY_TYPE, Variant("trigger"))
                node:SetVar(VARS.VISIBLE_TO, Variant("all"))
                node:SetVar("TrigEvent", Variant(obj.event))
                node:SetVar("Width", Variant(obj.w))
                node:SetVar("Height", Variant(obj.h))
                -- 传送点组号
                if obj.portalGroup then
                    node:SetVar("PortalGroup", Variant(obj.portalGroup))
                end

                table.insert(inst.levelNodes, node)
            end

            -- 存储到 triggers 列表以便 Update 中做 AABB 检测
            table.insert(inst.triggers, {
                id = obj.id,
                event = obj.event,
                x = obj.x, y = obj.y, w = obj.w, h = obj.h,
                portalGroup = obj.portalGroup,
            })

        elseif obj.type == "ladder" then
            -- 梯子（传感器，玩家接触时可攀爬）
            local node = inst.scene:CreateChild("Ladder_" .. obj.id, REPLICATED)
            node.position = Vector3(obj.x, obj.y, 0)
            node:SetVar(VARS.ENTITY_TYPE, Variant("ladder"))
            node:SetVar(VARS.VISIBLE_TO, Variant(obj.visibleTo or "all"))
            node:SetVar("Width", Variant(obj.w))
            node:SetVar("Height", Variant(obj.h))

            local body = node:CreateComponent("RigidBody2D")
            body.bodyType = BT_STATIC

            local box = node:CreateComponent("CollisionBox2D")
            box:SetSize(obj.w, obj.h)
            box:SetCenter(0, 0)
            box.sensor = true
            box.categoryBits = COL.CAT_SENSOR
            box.maskBits = COL.CAT_PLAYER

            table.insert(inst.levelNodes, node)

        elseif obj.type == "crate" then
            -- 木箱（动态物体，可推动）
            -- 先以 KINEMATIC 创建，延迟后切 DYNAMIC
            -- 防止 reload 时旧/新 REPLICATED 节点短暂共存产生物理挤压
            local node = inst.scene:CreateChild("Crate_" .. obj.id, REPLICATED)
            node.position = Vector3(obj.x, obj.y, 0)
            node:SetVar(VARS.ENTITY_TYPE, Variant("crate"))
            node:SetVar(VARS.VISIBLE_TO, Variant(obj.visibleTo or "all"))
            node:SetVar("Width", Variant(obj.w))
            node:SetVar("Height", Variant(obj.h))
            -- 随机渲染层：50% 概率在玩家前方绘制
            node:SetVar("RenderFront", Variant(math.random() < 0.5))

            local body = node:CreateComponent("RigidBody2D")
            body.bodyType = BT_DYNAMIC
            body.fixedRotation = false  -- 允许旋转，使箱子能自然贴合斜坡面
            body.angularDamping = 8.0  -- 高角阻尼：防止旋转过快/抖动
            body.linearDamping = 8.0
            body.linearVelocity = Vector2(0, 0)

            -- 使用方形碰撞体：box 在斜坡上可以自然旋转贴合，比 circle 更真实
            local crateHalfSize = math.min(obj.w, obj.h) * 0.42
            local shape = node:CreateComponent("CollisionBox2D")
            shape.size = Vector2(crateHalfSize * 2, crateHalfSize * 2)
            shape.center = Vector2(0, 0)
            shape.friction = 3.0   -- 高摩擦：防止箱子在斜坡上自滑（combined = sqrt(3.0*0.6) ≈ 1.34 > tan45°）
            shape.restitution = 0.0
            shape.density = 50.0
            shape.categoryBits = COL.CAT_CRATE
            shape.maskBits = COL.CAT_PLAYER + COL.CAT_GROUND + COL.CAT_SENSOR + COL.CAT_SLOPE

            table.insert(inst.levelNodes, node)

        elseif obj.type == "monologue" or obj.type == "screen_text" then
            -- 存储到 inst 的触发列表中（不创建物理节点，用 AABB 检测）
            if not inst.textTriggers then inst.textTriggers = {} end
            table.insert(inst.textTriggers, {
                id = obj.id,
                kind = obj.type, -- "monologue" or "screen_text"
                x = obj.x, y = obj.y, w = obj.w, h = obj.h,
                textRed = obj.textRed,
                textBlack = obj.textBlack,
            })
        end
    end

    -- ── 诊断：打印最终创建的节点统计 ──
    local diagFinalCounts = {}
    for _, n in ipairs(inst.levelNodes) do
        if n then
            local ok3, et3 = pcall(function() return n:GetVar(VARS.ENTITY_TYPE) end)
            local etKey = "(unknown)"
            if ok3 and et3 and type(et3.IsEmpty) == "function" and not et3:IsEmpty() then
                etKey = et3:GetString()
            end
            diagFinalCounts[etKey] = (diagFinalCounts[etKey] or 0) + 1
        end
    end
    local diagFinalStr = ""
    for k, v in pairs(diagFinalCounts) do diagFinalStr = diagFinalStr .. k .. "=" .. v .. " " end
    print(string.format("[ServerGame][DIAG] Final: %d nodes created: %s",
        #inst.levelNodes, diagFinalStr))

    -- 诊断：打印场景树中所有节点
    local allCh = inst.scene:GetChildren(false)
    print(string.format("[ServerGame][DIAG] Scene tree has %d children total", #allCh))
    for i = 1, math.min(#allCh, 20) do
        local c = allCh[i]
        if c then
            pcall(function()
                local et = c:GetVar(VARS.ENTITY_TYPE)
                local etStr = (et and type(et.IsEmpty) == "function" and not et:IsEmpty()) and et:GetString() or "(none)"
                print(string.format("[ServerGame][DIAG]   child[%d] name=%s ET=%s pos=(%.1f,%.1f)",
                    i, c.name, etStr, c.position.x, c.position.y))
            end)
        end
    end

    -- 为所有关卡节点统一设置 PairId（多对玩家共享场景时靠此变量隔离）
    for _, n in ipairs(inst.levelNodes) do
        if n then
            n:SetVar(VARS.PAIR_ID, Variant(inst.pairId))
        end
    end

    print(string.format("[ServerGame] Loaded %d objects for Scene %d",
        #inst.levelNodes, sceneIdx))
end

-- ═══════════════════════════════════════════════
-- 公开 API
-- ═══════════════════════════════════════════════

--- 初始化游戏实例（配对双方确认角色后调用）
---@param pairId number
---@param scene Scene
---@param playerA table { connKey, connection, role }
---@param playerB table { connKey, connection, role }
function ServerGame.Init(pairId, scene, playerA, playerB)
    -- 确保物理世界已配置
    local physWorld = scene:GetComponent("PhysicsWorld2D")
    if physWorld then
        physWorld.gravity = Vector2(0, -GameConst.GRAVITY)
    end

    local inst = {
        scene = scene,
        pairId = pairId,
        sceneIdx = 0,
        players = {},
        levelNodes = {},
        bellStates = {},
    }
    instances_[pairId] = inst

    -- 加载第一个场景
    LoadLevel(inst, 0)
    local levelDef = LevelData.GetScene(0)
    local spawnRedX  = levelDef and levelDef.spawnX or 2.0
    local spawnRedY  = levelDef and levelDef.spawnY or 2.0
    local spawnBlkX  = levelDef and levelDef.spawnBlackX or (spawnRedX + 1.0)
    local spawnBlkY  = levelDef and levelDef.spawnBlackY or spawnRedY

    -- 根据角色分配各自出生点
    for _, p in ipairs({playerA, playerB}) do
        if p.role == Shared.ROLE.BLACK then
            CreatePlayer(inst, p.connKey, p.role, p.connection, spawnBlkX, spawnBlkY)
        else
            CreatePlayer(inst, p.connKey, p.role, p.connection, spawnRedX, spawnRedY)
        end
    end

    -- 诊断：确认节点已创建（独立 pcall，不影响 Init 成功与否）
    local allChildren = scene:GetChildren(false)
    print(string.format("[ServerGame] Init complete: pairId=%d, %s=%s, %s=%s | scene children=%d",
        pairId, playerA.connKey, playerA.role, playerB.connKey, playerB.role, #allChildren))
    pcall(function()
        for i = 1, #allChildren do
            local c = allChildren[i]
            if c and type(c.GetVar) == "function" then
                local ok2, et = pcall(function() return c:GetVar(VARS.ENTITY_TYPE) end)
                local etStr = "(none)"
                if ok2 and et and type(et.IsEmpty) == "function" and not et:IsEmpty() then
                    etStr = et:GetString()
                end
                print(string.format("  [Server] child[%d] name=%s et=%s pos=(%.1f,%.1f,%.1f)",
                    i, c.name, etStr, c.position.x, c.position.y, c.position.z))
            end
        end
    end)
end

--- 检查玩家附近是否有可交互物，返回最近的一个
---@param inst table GameInstance
---@param playerPos Vector3
---@return Node|nil
local function FindNearbyInteractable(inst, playerPos)
    local bestNode = nil
    local bestDist = GameConst.INTERACT_RADIUS or 1.5  -- 交互距离阈值

    for _, n in ipairs(inst.levelNodes) do
        if n then
            local ok, etVar = pcall(function() return n:GetVar(VARS.ENTITY_TYPE) end)
            if ok and etVar and not etVar:IsEmpty() then
                local et = etVar:GetString()
                if et == "interactable" or et == "npc" then
                    local dx = n.position.x - playerPos.x
                    local dy = n.position.y - playerPos.y
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist < bestDist then
                        bestDist = dist
                        bestNode = n
                    end
                end
            end
        end
    end
    return bestNode
end

--- 处理交互操作（铃铛、道具等）
---@param inst table GameInstance
---@param pd table PlayerData
---@param target Node
local function DoInteract(inst, pd, target)
    local etVar = target:GetVar(VARS.ENTITY_TYPE)
    if not etVar or etVar:IsEmpty() then return end
    local et = etVar:GetString()

    if et == "interactable" then
        local kindVar = target:GetVar("Kind")
        local kind = kindVar and not kindVar:IsEmpty() and kindVar:GetString() or ""

        if kind == "bell" then
            -- 铃铛激活
            local npcId = target.name:gsub("Inter_", "")
            if not inst.bellStates[npcId] then
                inst.bellStates[npcId] = true
                target:SetVar("Activated", Variant(true))
                print(string.format("[ServerGame] Bell %s activated by %s", npcId, pd.role))

                -- 检查是否所有铃铛都已激活（双铃谜题）
                local allActivated = true
                for id, state in pairs(inst.bellStates) do
                    if not state then
                        allActivated = false
                        break
                    end
                end
                if allActivated then
                    print("[ServerGame] All bells activated! Gate opened.")
                    -- 移除门节点（如果存在）
                    local targetVar = target:GetVar("Target")
                    if targetVar and not targetVar:IsEmpty() then
                        local gateId = targetVar:GetString()
                        local gateName = "Plat_" .. gateId
                        for idx = #inst.levelNodes, 1, -1 do
                            local n = inst.levelNodes[idx]
                            if n and n.name == gateName then
                                n:Remove()
                                table.remove(inst.levelNodes, idx)
                                print("[ServerGame] Gate node removed: " .. gateId)
                                break
                            end
                        end
                    end
                end
            end

        elseif kind == "item" then
            -- 道具拾取：从 levelNodes 中移除引用，再删除节点
            local itemNameVar = target:GetVar("ItemName")
            local itemName = itemNameVar and not itemNameVar:IsEmpty() and itemNameVar:GetString() or "unknown"
            print(string.format("[ServerGame] %s picked up: %s", pd.role, itemName))

            -- 记录道具拾取（任务跟踪）
            local interIdFromName = target.name:gsub("Inter_", "")
            inst.itemsPickedUp[interIdFromName] = true

            for idx = #inst.levelNodes, 1, -1 do
                if inst.levelNodes[idx] == target then
                    table.remove(inst.levelNodes, idx)
                    break
                end
            end
            target:Remove()

        elseif kind == "switch" then
            print(string.format("[ServerGame] Switch toggled by %s", pd.role))
        end

    elseif et == "npc" then
        -- NPC 对话：从 LevelData 查找对话内容，发送给客户端
        local npcIdVar = target:GetVar("NpcId")
        local npcId = npcIdVar and not npcIdVar:IsEmpty() and npcIdVar:GetString() or ""

        -- 根据角色选择对应的 NPC 名字和对话
        local nameVar = (pd.role == Shared.ROLE.RED)
            and target:GetVar("NameRed")
            or  target:GetVar("NameBlack")
        local npcName = (nameVar and not nameVar:IsEmpty()) and nameVar:GetString() or "???"

        -- 从 LevelData 查找对话行
        local levelDef = LevelData.GetScene(inst.sceneIdx)
        local dialogueLines = {}
        if levelDef then
            for _, obj in ipairs(levelDef.objects) do
                if obj.id == npcId then
                    dialogueLines = (pd.role == Shared.ROLE.RED)
                        and obj.dialogueRed or obj.dialogueBlack
                    break
                end
            end
        end

        print(string.format("[ServerGame] %s talks to NPC: %s (%d lines)",
            pd.role, npcId, #dialogueLines))

        -- 记录 NPC 对话完成（任务跟踪）
        if not inst.npcTalkedBy[npcId] then
            inst.npcTalkedBy[npcId] = {}
        end
        inst.npcTalkedBy[npcId][pd.role] = true

        -- 通过 GAME_EVENT 通知客户端显示对话
        if pd.connection and #dialogueLines > 0 then
            local data = VariantMap()
            data["Type"] = Variant("npc_talk")
            data["NpcId"] = Variant(npcId)
            data["NpcName"] = Variant(npcName)
            data["LineCount"] = Variant(#dialogueLines)
            for i, line in ipairs(dialogueLines) do
                data["Line" .. i] = Variant(line)
            end
            pd.connection:SendRemoteEvent(Shared.EVENTS.GAME_EVENT, true, data)
        end
    end
end

--- 判断当前场景的任务是否全部完成
---@param inst table GameInstance
---@return boolean
local function AreTasksComplete(inst)
    local idx = inst.sceneIdx

    if idx == 0 then
        -- Scene 0: 双方都与信使 NPC (s0_courier) 对话过
        local t = inst.npcTalkedBy["s0_courier"]
        return t ~= nil and t[Shared.ROLE.RED] == true and t[Shared.ROLE.BLACK] == true

    elseif idx == 1 then
        -- Scene 1: 无特殊任务，只需到达出口
        return true

    elseif idx == 2 then
        -- Scene 2: 无可交互任务（独白是自动触发），到达出口即可
        return true

    elseif idx == 3 then
        -- Scene 3: 双方都与守门人 NPC (s3_gatekeeper) 对话过
        local t = inst.npcTalkedBy["s3_gatekeeper"]
        return t ~= nil and t[Shared.ROLE.RED] == true and t[Shared.ROLE.BLACK] == true

    elseif idx == 4 then
        -- Scene 4: 所有铃铛已激活（bellStates 中无 false）
        for _, state in pairs(inst.bellStates) do
            if not state then return false end
        end
        return true

    elseif idx == 5 then
        -- Scene 5: 两个道具都被拾取
        return inst.itemsPickedUp["s5_item_red"] == true
           and inst.itemsPickedUp["s5_item_black"] == true

    elseif idx == 6 then
        -- Scene 6: 无特殊可交互任务，到达出口即可
        return true

    elseif idx == 7 then
        -- Scene 7: 终章，到达出口即可
        return true
    end

    -- 未知场景，默认允许通过
    return true
end

--- 每帧更新：读取输入、驱动物理
---@param pairId number
---@param dt number
function ServerGame.Update(pairId, dt)
    local inst = instances_[pairId]
    if not inst then return end

    for connKey, pd in pairs(inst.players) do
        local conn = pd.connection
        local body = pd.body
        if not conn or not body then goto continue end

        -- 读取输入
        local buttons = conn.controls.buttons
        local moveLeft  = (buttons & CTRL.MOVE_LEFT) ~= 0
        local moveRight = (buttons & CTRL.MOVE_RIGHT) ~= 0
        local jump      = (buttons & CTRL.JUMP) ~= 0
        local interact  = (buttons & CTRL.INTERACT) ~= 0

        -- ═══════════════════════════════════════════
        -- 蔚蓝风格跳跃手感系统
        -- 五要素：土狼跳 · 起跳缓冲 · 短按截断 · 顶点悬停 · 二段跳
        -- ═══════════════════════════════════════════

        local currentVel = body.linearVelocity
        local jumpPressed  = jump and not pd.prevJump  -- 本帧按下跳跃键（上升沿）
        local jumpReleased = not jump and pd.prevJump  -- 本帧松开跳跃键（下降沿）
        pd.prevJump = jump

        -- ── 方向键边沿检测：以"最后按下的键"决定有效方向 ──
        --    双键同按时，最后按下的那个键赢（避免"倒着跑"BUG）
        local leftPressed  = moveLeft  and not pd.prevMoveLeft
        local rightPressed = moveRight and not pd.prevMoveRight
        if leftPressed  then pd.lastDirLeft = true  end
        if rightPressed then pd.lastDirLeft = false end
        pd.prevMoveLeft  = moveLeft
        pd.prevMoveRight = moveRight

        -- effectiveMoveLeft/Right：实际生效的移动方向（双键同按时以 lastDirLeft 为准）
        local effectiveMoveLeft, effectiveMoveRight
        if moveLeft and moveRight then
            effectiveMoveLeft  = pd.lastDirLeft
            effectiveMoveRight = not pd.lastDirLeft
        else
            effectiveMoveLeft  = moveLeft
            effectiveMoveRight = moveRight
        end

        -- 记录本帧起点位置和时间步，供 PostPhysicsCorrect X 轴修正使用
        pd.prePhysicsX = pd.node.position.x
        pd.lastDt      = dt

        -- ── 0. 下向射线检测地面（替代脚底传感器接触计数） ──
        --    射线：脚底中心上方 0.05m → 下方 0.30m，覆盖高速移动时的漂移量。
        --    掩码：CAT_GROUND | CAT_CRATE，与脚底传感器原始 maskBits 一致。
        --    落地条件：速度判断替代 jumpInitiated 判断：
        --      isAscending = jumpInitiated 且 vy > 1.0 m/s（仍在明显上升）
        --      → 上升途中射线命中地面属正常（刚离地），不触发落地逻辑
        --      → 下降/平飞时命中地面 = 真正落地
        local SERVER_OFFGROUND_FRAMES = 4
        local physW2ForRay = inst.scene:GetComponent("PhysicsWorld2D")
        local rayHit   = false
        local groundHitY = nil   -- 本帧射线命中的地面 Y（用于摔落伤害检测）
        if physW2ForRay then
            local px = pd.node.position.x
            local py = pd.node.position.y
            -- 固定 0.10m 短射线：仅检测脚底 10cm 内的地面，防止下落时过早触发落地。
            -- 斜坡瓦片缝隙（约 0.77m）的桥接由 PostPhysicsCorrect 的 0.30m 射线负责，
            -- 命中时重置 offGroundFrames=0，从而维持 onGround=true 穿越整个缝隙。
            local rStart = Vector2(px, py + GameConst.FOOT_SENSOR_OFFSET_Y + 0.02)
            local rEnd   = Vector2(px, py + GameConst.FOOT_SENSOR_OFFSET_Y - 0.10)
            local hit = physW2ForRay:RaycastSingle(rStart, rEnd,
                                                   COL.CAT_GROUND | COL.CAT_CRATE | COL.CAT_SLOPE)
            if hit and hit.body then
                rayHit    = true
                groundHitY = hit.position.y
            end
        end

        -- 速度判断：仍在明显上升时不触发落地（避免起跳后射线立即重设 onGround）
        local vyNow = body.linearVelocity.y
        local isAscending = pd.jumpInitiated and (vyNow > 1.0)

        if rayHit then
            pd.offGroundFrames = 0
            if not isAscending then
                -- 落地条件满足（非上升期）
                local actualLandY = groundHitY + GameConst.PLAYER_RADIUS + 0.002
                if not pd.onGround then
                    -- 刚落地：检测摔落伤害
                    if pd.lastGroundY ~= nil and not pd.jumpInitiated then
                        local fallDist = pd.lastGroundY - actualLandY
                        if fallDist > GameConst.FALL_DEATH_HEIGHT then
                            local levelDef = LevelData.GetScene(inst.sceneIdx)
                            if levelDef then
                                pd.node.position = Vector3(levelDef.spawnX, levelDef.spawnY + 1, 0)
                                pd.body.linearVelocity = Vector2(0, 0)
                                pd.groundContacts  = 0
                                pd.onGround        = false
                                pd.offGroundFrames = 0
                                pd.lastGroundY     = levelDef.spawnY + 1
                                pd.coyoteTimer     = 0
                                pd.jumpBufferTimer = 0
                                pd.airJumpsLeft    = 0
                                pd.jumpInitiated   = false
                                print(string.format("[ServerGame] Player %s died from fall damage (%.1fm)", pd.role, fallDist))
                                goto skip_ground_state
                            end
                        end
                    end
                    -- 正常落地
                    pd.onGround      = true
                    pd.airJumpsLeft  = GameConst.AIR_JUMP_COUNT
                    pd.jumpInitiated = false
                    pd.coyoteTimer   = 0
                    pd.lastGroundY      = actualLandY
                    pd.isShortJump      = false  -- 落地后恢复长跳重力模式
                    pd.longJumpSignaled = false  -- 落地后重置，下次跳跃才重新检测
                    pd.jumpCommitted    = false  -- 落地后重置，下次跳跃重新确认类型
                else
                    -- 持续在地面：更新站立高度（缓坡下行时保持最新 Y）
                    pd.lastGroundY = actualLandY
                end
            end
        else
            -- 射线未命中：检查上帧 PostPhysicsCorrect 是否成功吸附地面
            -- 若是（groundFromSnap=true）且未跳跃，视为"虚拟命中"，继续维持 onGround=true。
            -- 这解决了斜坡瓦片水平缝隙（约 0.77m）期间 Step 0 短射线（0.10m）
            -- 无法探到任何地面，而 PostPhysicsCorrect 的 0.30m 射线可在下帧贴合到
            -- 下一块瓦片的场景，彻底消除缝隙内短暂离地→重力→滑动/速度不对称。
            if pd.groundFromSnap and pd.onGround and not pd.jumpInitiated then
                -- 虚拟命中：重置计数器，不切换状态
                pd.offGroundFrames = 0
                rayHit = true  -- 供后续逻辑使用（如 lastGroundY 更新）
            else
                -- 累计离地帧，防抖后才切换状态
                pd.offGroundFrames = (pd.offGroundFrames or 0) + 1
                if pd.offGroundFrames >= SERVER_OFFGROUND_FRAMES and pd.onGround then
                    pd.onGround = false
                    pd.lastGroundY = pd.node.position.y
                    if not pd.jumpInitiated then
                        pd.coyoteTimer = GameConst.COYOTE_TIME
                    end
                end
            end
        end
        ::skip_ground_state::

        -- ── 1. 计时器递减 ──
        if pd.coyoteTimer     > 0 then pd.coyoteTimer     = pd.coyoteTimer     - dt end
        if pd.jumpBufferTimer > 0 then pd.jumpBufferTimer = pd.jumpBufferTimer - dt end

        -- ── 2. 判断"可以起跳"来源 ──
        --    · 在地面
        --    · 土狼跳：刚离地不超过 COYOTE_TIME 秒
        local canJumpFromGround = pd.onGround or pd.coyoteTimer > 0
        local canAirJump        = (not canJumpFromGround) and (pd.airJumpsLeft > 0) and pd.doubleJumpUnlocked

        -- ── 3. 起跳缓冲：空中按键时存储 ──
        if jumpPressed and not canJumpFromGround then
            pd.jumpBufferTimer = GameConst.JUMP_BUFFER_TIME
        end

        -- ── 4. 执行起跳 ──
        --    触发条件：
        --    a) 按下跳键 且 可从地面起跳（含土狼跳）
        --    b) 已缓冲的跳键 且 本帧刚落地（jumpBufferTimer > 0 且 onGround）
        --    c) 空中按下跳键 且 有剩余二段跳次数
        local doJump      = false
        local doAirJump   = false

        if jumpPressed and canJumpFromGround then
            doJump = true
        elseif pd.onGround and pd.jumpBufferTimer > 0 and not jumpPressed then
            -- 缓冲落地起跳（本帧才落地，jumpPressed 已消耗）
            doJump = true
            pd.jumpBufferTimer = 0
        elseif jumpPressed and canAirJump then
            doAirJump = true
        end

        if doJump then
            local v0 = GameConst.PLAYER_JUMP_SPEED
            body.linearVelocity = Vector2(currentVel.x, v0)
            body.awake = true
            pd.coyoteTimer     = 0
            pd.jumpBufferTimer = 0
            pd.onGround        = false
            pd.jumpInitiated   = true
            pd.isShortJump     = false  -- 起跳时重置，松键后再切换为 true
            pd.longJumpSignaled = false -- 新跳重置，确认长跳后置 true
            pd.jumpHoldTimer   = 0     -- 重置按键计时器
            pd.jumpCommitted   = false -- 重置确认标志，等待本次跳跃的类型确认
            -- 落地时 airJumpsLeft 恢复，起跳后不重置（防止原地跳立刻再二段跳）
        elseif doAirJump then
            local v0 = GameConst.PLAYER_JUMP_SPEED * GameConst.AIR_JUMP_SPEED_RATIO
            body.linearVelocity = Vector2(currentVel.x, v0)
            body.awake = true
            pd.airJumpsLeft  = pd.airJumpsLeft - 1
            pd.jumpInitiated = true
            -- 同步给渲染端：触发二段跳动画重置信号
            pd.node:SetVar("AirJump", Variant(true))
        end

        -- ── 5. 跳跃类型确认（计时器：按住≥LONG_JUMP_HOLD_TIME → 长跳，松键 → 短跳） ──
        --    空中 + 尚未确认类型时：
        --      • 每帧累加按键时长；达到阈值 → 确认长跳，发送 LongJumpConfirmed
        --      • 检测松键下降沿 → 确认短跳，截断速度，发送 JumpCut
        if not pd.onGround and not pd.jumpCommitted then
            if jump then
                -- 按住中：累加计时
                pd.jumpHoldTimer = pd.jumpHoldTimer + dt
                if pd.jumpHoldTimer >= GameConst.LONG_JUMP_HOLD_TIME then
                    -- ── 长跳确认 ──
                    pd.jumpCommitted   = true
                    pd.longJumpSignaled = true
                    -- 估算长跳剩余空中时间（含 apex-boost 修正），供客户端调整动画速率
                    local g_eff   = GameConst.GRAVITY * GameConst.PLAYER_AIR_GRAVITY_SCALE
                    local g_fall  = g_eff * GameConst.FALL_GRAVITY_MULT
                    local apex_th = GameConst.JUMP_APEX_THRESHOLD
                    local apex_g  = math.max(1.0, g_eff * (1.0 - GameConst.JUMP_APEX_BOOST_RATIO))
                    local vy_cur  = math.max(0.0, body.linearVelocity.y)
                    local t_rise_rem
                    if vy_cur >= apex_th then
                        t_rise_rem = (vy_cur - apex_th) / g_eff + apex_th / apex_g
                    else
                        t_rise_rem = vy_cur / apex_g
                    end
                    local h_rise_rem
                    if vy_cur >= apex_th then
                        h_rise_rem = (vy_cur*vy_cur - apex_th*apex_th) / (2.0*g_eff)
                                  + apex_th*apex_th / (2.0*apex_g)
                    else
                        h_rise_rem = vy_cur*vy_cur / (2.0*apex_g)
                    end
                    local h_apex   = pd.node.position.y + h_rise_rem
                    local h_fall   = math.max(0.0, h_apex - (pd.lastGroundY or 0.0))
                    local t_f_apex = apex_th / apex_g
                    local disc     = apex_th*apex_th + 2.0*g_fall*h_fall
                    local t_f_free = (-apex_th + math.sqrt(math.max(0.0, disc))) / g_fall
                    local t_remain = t_rise_rem + t_f_apex + t_f_free
                    pd.node:SetVar("LongJumpConfirmed",     Variant(true))
                    pd.node:SetVar("LongJumpRemainingTime", Variant(t_remain))
                end
            elseif jumpReleased then
                -- ── 短跳确认：松键时截断上升速度 + 切换高重力 ──
                pd.jumpCommitted = true
                pd.isShortJump   = true
                local vy = body.linearVelocity.y
                if vy > GameConst.JUMP_CUT_MIN_VY then
                    body.linearVelocity = Vector2(body.linearVelocity.x, GameConst.JUMP_CUT_MIN_VY)
                end
                -- 估算截断后剩余空中时间，供客户端动态调整动画速率
                local vy_cut  = math.min(math.max(0.0, vy), GameConst.JUMP_CUT_MIN_VY)
                local g_eff   = GameConst.GRAVITY * GameConst.PLAYER_SHORT_JUMP_GRAVITY_SCALE
                local g_fall  = g_eff * GameConst.FALL_GRAVITY_MULT
                local t_up    = vy_cut / g_eff
                local h_extra = vy_cut * vy_cut / (2.0 * g_eff)
                local h_total = pd.node.position.y + h_extra
                local h_fall  = math.max(0.0, h_total - (pd.lastGroundY or 0.0))
                local t_down  = math.sqrt(2.0 * h_fall / g_fall)
                local t_remain = t_up + t_down
                pd.node:SetVar("JumpCut",              Variant(true))
                pd.node:SetVar("JumpCutRemainingTime", Variant(t_remain))
            end
        end

        -- ── 6. 顶点悬停（按住跳键时大幅削减顶点重力） ──
        --    条件：空中 + 按住跳键 + |vy| < APEX_THRESHOLD
        --    实现：本帧施加向上补偿加速度，使净重力 = effectiveG × (1 - APEX_BOOST_RATIO)
        local airScale   = pd.isShortJump and GameConst.PLAYER_SHORT_JUMP_GRAVITY_SCALE
                                           or  GameConst.PLAYER_AIR_GRAVITY_SCALE
        local effectiveG = GameConst.GRAVITY * airScale
        local inApex = not pd.onGround and jump
                       and math.abs(currentVel.y) < GameConst.JUMP_APEX_THRESHOLD
        if inApex then
            local apexBoost = effectiveG * GameConst.JUMP_APEX_BOOST_RATIO * dt
            local vy = body.linearVelocity.y + apexBoost
            body.linearVelocity = Vector2(body.linearVelocity.x, vy)
        end

        -- ── 6.5. 下落加速（蔚蓝非对称重力：下坠比上升更快） ──
        --    条件：空中 + vy < 0（正在下落）+ 不在顶点区间
        --    实现：额外施加向下冲量，使等效下落重力 = effectiveG × FALL_GRAVITY_MULT
        if not pd.onGround and not inApex and currentVel.y < 0 then
            local extraDown = effectiveG * (GameConst.FALL_GRAVITY_MULT - 1.0) * dt
            local vy = body.linearVelocity.y - extraDown
            body.linearVelocity = Vector2(body.linearVelocity.x, vy)
        end

        -- ── 7. 水平速度控制（全程可控，空中有速度上限） ──
        -- 短跳确认后（isShortJump=true）使用更高的水平速度，确保能跨越2格（1.0m）
        local airMaxSpeed = (not pd.onGround and pd.isShortJump)
                            and GameConst.PLAYER_SPEED_AIR_SHORT
                            or  GameConst.PLAYER_SPEED_AIR
        local groundSpeed = pd.onGround and GameConst.PLAYER_SPEED or airMaxSpeed

        local desiredVelX = 0
        if effectiveMoveLeft  then desiredVelX = -groundSpeed end
        if effectiveMoveRight then desiredVelX =  groundSpeed end

        -- 空中速度上限（绝对值钳制，防止其他力导致超速）
        if not pd.onGround then
            desiredVelX = math.max(-airMaxSpeed, math.min(airMaxSpeed, desiredVelX))
        end

        -- 记录期望速度，供 PostPhysicsCorrect 在物理步后使用
        pd.desiredVelX = desiredVelX

        -- 速度覆写 + 重力切换：
        --   地面：禁用重力（gravityScale=0），阻断斜坡/桥面法向力分解导致的滑动
        --   空中：使用缩减重力（PLAYER_AIR_GRAVITY_SCALE），延长跳跃时长至约 2× 原版
        if pd.onGround then
            body.gravityScale = 0.0
            body.linearVelocity = Vector2(desiredVelX, 0)
        else
            -- 短跳（JumpCut 后）使用低重力维持较长滞空；长跳用高重力压缩时长
            body.gravityScale = pd.isShortJump and GameConst.PLAYER_SHORT_JUMP_GRAVITY_SCALE
                                                or  GameConst.PLAYER_AIR_GRAVITY_SCALE
            body.linearVelocity = Vector2(desiredVelX, body.linearVelocity.y)
        end

        -- 互动
        if interact then
            local target = FindNearbyInteractable(inst, pd.node.position)
            if target then
                DoInteract(inst, pd, target)
            end
        end

        -- ─── 推/拉箱子（速度锁定模式） ───
        local push = (buttons & CTRL.PUSH) ~= 0
        -- 已锁定时允许短暂离地（如走上斜坡过渡），但主动跳跃则中断
        local canPush = pd.onGround or (pd.pushingCrate and not jump)
        if push and canPush then
            local px = pd.node.position.x
            local py = pd.node.position.y

            if not pd.pushingCrate then
                -- 尝试获取推/拉目标：寻找最近的箱子
                local bestCrate = nil
                local bestDist = GameConst.CRATE_PUSH_RANGE
                for _, ln in ipairs(inst.levelNodes) do
                    if ln then
                        local etVar = ln:GetVar(VARS.ENTITY_TYPE)
                        if etVar and not etVar:IsEmpty() and etVar:GetString() == "crate" then
                            local cp = ln.position
                            local dx = math.abs(cp.x - px)
                            local dy = math.abs(cp.y - py)
                            -- 水平范围内且垂直差不超过箱高（防止搜到头顶/脚底的箱子）
                            local crateH = 0.5
                            local hVar = ln:GetVar("Height")
                            if hVar and not hVar:IsEmpty() then crateH = hVar:GetFloat() end
                            if dx < bestDist and dy < 1.5 then
                                bestDist = dx
                                bestCrate = ln
                            end
                        end
                    end
                end
                if bestCrate then
                    pd.pushingCrate = true
                    pd.pushTarget = bestCrate
                    -- 推/拉方向：基于有效移动方向，没按则用相对位置
                    if effectiveMoveRight then pd.pushDir = 1
                    elseif effectiveMoveLeft then pd.pushDir = -1
                    else
                        local dx = bestCrate.position.x - px
                        pd.pushDir = (dx >= 0) and 1 or -1
                    end
                    -- 同步视觉状态
                    pd.node:SetVar(VARS.PUSHING_CRATE, Variant(true))
                    pd.node:SetVar(VARS.PUSH_DIR, Variant(pd.pushDir))
                end
            end

            -- 已锁定箱子 → 速度同步
            if pd.pushingCrate and pd.pushTarget then
                local crateNode = pd.pushTarget
                local crateBody = crateNode:GetComponent("RigidBody2D")
                if crateBody then
                    -- 检查距离是否在拉箱子最大距离内
                    local dx = math.abs(crateNode.position.x - px)
                    if dx > GameConst.CRATE_PULL_RANGE then
                        -- 超出拉距离 → 解除锁定
                        pd.pushingCrate = false
                        pd.pushTarget = nil
                        pd.pushDir = 0
                        pd.node:SetVar(VARS.PUSHING_CRATE, Variant(false))
                        pd.node:SetVar(VARS.PUSH_DIR, Variant(0))
                    else
                        -- 更新方向（跟随有效移动方向）
                        if effectiveMoveRight then pd.pushDir = 1
                        elseif effectiveMoveLeft then pd.pushDir = -1
                        end
                        -- 速度锁定：玩家和箱子以相同速度移动
                        -- 获取箱子当前斜坡角度，沿坡面方向推动
                        local slopeAngle = 0.0
                        local caVar = crateNode:GetVar(VARS.CRATE_ANGLE)
                        if caVar and not caVar:IsEmpty() then slopeAngle = caVar:GetFloat() end

                        -- 若当前角度接近0，向推进方向做下向射线预判斜坡
                        -- （处理箱子从平地推向斜坡时的过渡，CRATE_ANGLE 尚未更新的情况）
                        if math.abs(slopeAngle) < 0.01 then
                            local physW2 = inst.scene:GetComponent("PhysicsWorld2D")
                            if physW2 then
                                local cp = crateNode.position
                                local probeX = cp.x + pd.pushDir * 0.5
                                local fHit = physW2:RaycastSingle(
                                    Vector2(probeX, cp.y + 0.1),
                                    Vector2(probeX, cp.y - 1.0),
                                    COL.CAT_GROUND
                                )
                                if fHit and fHit.body then
                                    local ang = -math.atan(fHit.normal.x, fHit.normal.y)
                                    if math.abs(ang) > 0.01 then slopeAngle = ang end
                                end
                            end
                        end

                        local pushSpeed = pd.pushDir * GameConst.CRATE_PUSH_SPEED
                        if math.abs(slopeAngle) > 0.01 then
                            -- 沿斜面方向：velocity = speed * (cos(α), sin(α))
                            local sVelX = pushSpeed * math.cos(slopeAngle)
                            local sVelY = pushSpeed * math.sin(slopeAngle)
                            crateBody.linearVelocity = Vector2(sVelX, sVelY)
                            body.linearVelocity = Vector2(sVelX, body.linearVelocity.y)
                        else
                            crateBody.linearVelocity = Vector2(pushSpeed, crateBody.linearVelocity.y)
                            body.linearVelocity = Vector2(pushSpeed, body.linearVelocity.y)
                        end
                        -- 推动过程中清零角速度，防止 box 在接触点产生旋转干扰
                        crateBody.angularVelocity = 0
                        crateBody.awake = true
                    end
                else
                    -- 箱子刚体丢失 → 解除
                    pd.pushingCrate = false
                    pd.pushTarget = nil
                    pd.pushDir = 0
                    pd.node:SetVar(VARS.PUSHING_CRATE, Variant(false))
                    pd.node:SetVar(VARS.PUSH_DIR, Variant(0))
                end
            end
        else
            -- 松开 PUSH 键或离地 → 解除推箱子状态
            if pd.pushingCrate then
                pd.pushingCrate = false
                pd.pushTarget = nil
                pd.pushDir = 0
                pd.node:SetVar(VARS.PUSHING_CRATE, Variant(false))
                pd.node:SetVar(VARS.PUSH_DIR, Variant(0))
            end
        end

        -- 文本触发器检测（内心独白 / 屏幕文字）
        if inst.textTriggers then
            local px = pd.node.position.x
            local py = pd.node.position.y
            for _, trig in ipairs(inst.textTriggers) do
                local trigKey = inst.pairId .. "_" .. connKey .. "_" .. trig.id
                if not firedTriggers_[trigKey] then
                    local halfW = trig.w * 0.5
                    local halfH = trig.h * 0.5
                    if px >= trig.x - halfW and px <= trig.x + halfW
                       and py >= trig.y - halfH and py <= trig.y + halfH then
                        -- 玩家进入触发区域
                        firedTriggers_[trigKey] = true
                        local text = (pd.role == Shared.ROLE.RED) and trig.textRed or trig.textBlack
                        if pd.connection and text and text ~= "" then
                            local data = VariantMap()
                            data["Type"] = Variant(trig.kind) -- "monologue" or "screen_text"
                            data["Text"] = Variant(text)
                            data["TriggerId"] = Variant(trig.id)
                            pd.connection:SendRemoteEvent(Shared.EVENTS.GAME_EVENT, true, data)
                            print(string.format("[ServerGame] %s triggered %s: %s", pd.role, trig.kind, trig.id))
                        end
                    end
                end
            end
        end

        -- 掉落死亡检测（包括 NaN 位置，NaN < x 永远为 false）
        local py = pd.node.position.y
        if py < GameConst.SCENE_FLOOR_Y or py ~= py then
            local levelDef = LevelData.GetScene(inst.sceneIdx)
            local spawnRedX  = levelDef and levelDef.spawnX or 2.0
            local spawnRedY  = levelDef and levelDef.spawnY or 2.0
            local spawnX, spawnY
            if pd.role == Shared.ROLE.BLACK then
                spawnX = levelDef and levelDef.spawnBlackX or (spawnRedX + 1.0)
                spawnY = levelDef and levelDef.spawnBlackY or spawnRedY
            else
                spawnX = spawnRedX
                spawnY = spawnRedY
            end
            pd.node.position = Vector3(spawnX, spawnY, 0)
            body.linearVelocity = Vector2(0, 0)
            pd.groundContacts  = 0
            pd.onGround        = false
            pd.offGroundFrames = 0
            pd.lastGroundY    = spawnY
            pd.coyoteTimer    = 0
            pd.jumpBufferTimer= 0
            pd.airJumpsLeft   = 0
            pd.jumpInitiated  = false
            if py ~= py then
                print(string.format("[ServerGame] Player %s respawned (NaN position)", pd.role))
            else
                print(string.format("[ServerGame] Player %s respawned (fell off)", pd.role))
            end
        end

        -- ══ [DEBUG] 每60帧打印一次地面状态 ══
        pd._dbgFrame = (pd._dbgFrame or 0) + 1
        if pd._dbgFrame % 60 == 0 then
            local vel = body.linearVelocity
            print(string.format("[DBG-Server][%s] onGround=%s groundContacts=%d vel=(%.2f,%.2f) pos=(%.2f,%.2f)",
                pd.role, tostring(pd.onGround), pd.groundContacts or 0,
                vel.x, vel.y,
                pd.node.position.x, pd.node.position.y))
        end

        -- 同步动画所需状态到节点变量，供客户端动画系统读取
        -- （每帧写入，REPLICATED 节点变量自动同步到所有客户端）
        if pd.node then
            -- OnGround：地面状态（避免斜坡上 Y 位移被误判为在空中）
            pd.node:SetVar(VARS.ON_GROUND, Variant(pd.onGround))
            -- IsMoving：玩家是否正在按方向键（比客户端用位置差推断更准确）
            local isMoving = effectiveMoveLeft or effectiveMoveRight
            pd.node:SetVar(VARS.IS_MOVING, Variant(isMoving))
            -- FacingLeft：朝向与有效移动方向保持一致（双键同按时以最后按下的键为准）
            if effectiveMoveLeft then
                pd.node:SetVar(VARS.FACING_LEFT, Variant(true))
            elseif effectiveMoveRight then
                pd.node:SetVar(VARS.FACING_LEFT, Variant(false))
            end
            -- 注：无输入时不更新 FACING_LEFT，保持上一次朝向
        end

        ::continue::
    end

    -- ─── 独木桥破碎计时器 ───
    for _, n in ipairs(inst.levelNodes) do
        if n then
            local ok, brokenVar = pcall(function() return n:GetVar("BRIDGE_BROKEN") end)
            if ok and brokenVar and not brokenVar:IsEmpty() and brokenVar:GetBool() then
                local timerVar = n:GetVar("BRIDGE_BREAK_TIMER")
                if timerVar and not timerVar:IsEmpty() then
                    local t = timerVar:GetFloat() - dt
                    if t <= 0 then
                        -- 桥梁坍塌：切换为动态刚体使其坠落
                        local body = n:GetComponent("RigidBody2D")
                        if body then
                            body.linearVelocity = Vector2(0, 0)
                            body.bodyType = BT_DYNAMIC
                            body.gravityScale = 1.0
                        end
                        n:SetVar("BRIDGE_BREAK_TIMER", Variant(0.0))
                        print("[ServerGame] Bridge collapsed: " .. n.name)
                    else
                        n:SetVar("BRIDGE_BREAK_TIMER", Variant(t))
                    end
                end
            end
        end
    end

    -- ─── 箱子角度同步（直接读取物理刚体旋转，box 会自然贴合斜坡面） ───
    for _, ln in ipairs(inst.levelNodes) do
        if ln then
            local etVar = ln:GetVar(VARS.ENTITY_TYPE)
            if etVar and not etVar:IsEmpty() and etVar:GetString() == "crate" then
                local bodyComp = ln:GetComponent("RigidBody2D")
                if bodyComp then
                    -- 使用节点的 worldRotation2D（度数）替代 bodyComp.rotation（Lua 未绑定）
                    -- 物理步结束后节点角度已与 Box2D body 同步
                    local angleRad = ln.worldRotation2D * math.pi / 180.0
                    ln:SetVar(VARS.CRATE_ANGLE, Variant(angleRad))
                end
            end
        end
    end

    -- ─── 传送点检测（portal_enter → 查找同组 portal_exit → 传送） ───
    if inst.triggers then
        -- 更新冷却计时器
        for key, cd in pairs(portalCooldowns_) do
            cd = cd - dt
            if cd <= 0 then
                portalCooldowns_[key] = nil
            else
                portalCooldowns_[key] = cd
            end
        end

        for connKey, pd in pairs(inst.players) do
            if pd.node and not portalCooldowns_[connKey] then
                local px = pd.node.position.x
                local py = pd.node.position.y
                for _, trig in ipairs(inst.triggers) do
                    if trig.event == "portal_enter" and trig.portalGroup then
                        local halfW = trig.w * 0.5
                        local halfH = trig.h * 0.5
                        local inside = px >= trig.x - halfW and px <= trig.x + halfW
                                   and py >= trig.y - halfH and py <= trig.y + halfH
                        if inside then
                            -- 查找同组 portal_exit
                            for _, dest in ipairs(inst.triggers) do
                                if dest.event == "portal_exit" and dest.portalGroup == trig.portalGroup then
                                    -- 传送玩家
                                    pd.node.position = Vector3(dest.x, dest.y, 0)
                                    pd.body.linearVelocity = Vector2(0, 0)
                                    portalCooldowns_[connKey] = PORTAL_COOLDOWN
                                    print(string.format("[ServerGame] Portal teleport: %s group=%d (%.1f,%.1f) → (%.1f,%.1f)",
                                        pd.role, trig.portalGroup, trig.x, trig.y, dest.x, dest.y))
                                    break
                                end
                            end
                            break  -- 一次只处理一个传送入口
                        end
                    end
                end
            end
        end
    end

    -- ─── 出口区域检测（独立于 connection，所有玩家参与） ───
    if inst.triggers then
        for connKey, pd in pairs(inst.players) do
            if pd.node then
                local px = pd.node.position.x
                local py = pd.node.position.y
                for _, trig in ipairs(inst.triggers) do
                    if trig.event == "scene_transition" then
                        local halfW = trig.w * 0.5
                        local halfH = trig.h * 0.5
                        local inside = px >= trig.x - halfW and px <= trig.x + halfW
                                   and py >= trig.y - halfH and py <= trig.y + halfH
                        inst.exitReady[connKey] = inside
                    end
                end
            end
        end
    end

    -- ─── 场景切换检测：所有玩家都在出口区域 + 任务完成 ───
    if inst.exitReady then
        local allReady = true
        local playerCount = 0
        for _, ready in pairs(inst.exitReady) do
            playerCount = playerCount + 1
            if not ready then
                allReady = false
                break
            end
        end
        -- 至少有 1 名玩家且全部就位 + 本场景任务完成
        if playerCount > 0 and allReady and AreTasksComplete(inst) then
            local nextIdx = inst.sceneIdx + 1
            local nextDef = LevelData.GetScene(nextIdx)
            if nextDef then
                print(string.format("[ServerGame] Scene transition: %d → %d (%s)",
                    inst.sceneIdx, nextIdx, nextDef.name))

                -- 加载下一关
                LoadLevel(inst, nextIdx)

                -- 重置玩家位置到新场景各自出生点
                local spawnRedX = nextDef.spawnX or 2.0
                local spawnRedY = nextDef.spawnY or 2.0
                local spawnBlkX = nextDef.spawnBlackX or (spawnRedX + 1.0)
                local spawnBlkY = nextDef.spawnBlackY or spawnRedY
                for _, pd in pairs(inst.players) do
                    if pd.role == Shared.ROLE.BLACK then
                        pd.node.position = Vector3(spawnBlkX, spawnBlkY, 0)
                    else
                        pd.node.position = Vector3(spawnRedX, spawnRedY, 0)
                    end
                    pd.body.linearVelocity = Vector2(0, 0)
                    pd.groundContacts = 0
                    pd.onGround = false
                    pd.offGroundFrames = 0
                    pd.isShortJump   = false
                    pd.jumpCommitted = false  -- 场景切换重置
                    -- 通过第0场景（第一幕第0关）后解锁二段跳
                    if nextIdx >= 1 then
                        pd.doubleJumpUnlocked = true
                        print(string.format("[ServerGame] Double jump unlocked for %s (scene %d → %d)",
                            pd.role, nextIdx - 1, nextIdx))
                    end

                    -- 通知客户端场景已切换
                    if pd.connection then
                        local data = VariantMap()
                        data["SceneIdx"] = Variant(nextIdx)
                        data["SceneName"] = Variant(nextDef.name)
                        pd.connection:SendRemoteEvent(Shared.EVENTS.SCENE_CHANGE, true, data)
                    end
                end
            else
                print(string.format("[ServerGame] No more scenes after %d — game complete!",
                    inst.sceneIdx))
                -- 最后一个场景，通知完成
                for _, pd in pairs(inst.players) do
                    if pd.connection then
                        local data = VariantMap()
                        data["Type"] = Variant("game_complete")
                        pd.connection:SendRemoteEvent(Shared.EVENTS.GAME_EVENT, true, data)
                    end
                end
                -- 重置 exitReady 防止重复触发
                for k in pairs(inst.exitReady) do
                    inst.exitReady[k] = false
                end
            end
        end
    end
end

--- 处理物理碰撞开始（地面检测）
---@param pairId number
---@param nodeA Node
---@param nodeB Node
---@param shapeA CollisionShape2D|nil
---@param shapeB CollisionShape2D|nil
function ServerGame.OnBeginContact(pairId, nodeA, nodeB, shapeA, shapeB)
    local inst = instances_[pairId]
    if not inst then return end

    -- 查找哪个是玩家节点
    for _, pd in pairs(inst.players) do
        if pd.node == nodeA or pd.node == nodeB then
            local otherNode = (pd.node == nodeA) and nodeB or nodeA
            -- 确定玩家侧的 shape（用于判断是否为 foot sensor）
            local playerShape = (pd.node == nodeA) and shapeA or shapeB
            local otherType = otherNode:GetVar(VARS.ENTITY_TYPE)
            if otherType and not otherType:IsEmpty() then
                local et = otherType:GetString()
                -- 地面接触：platform、slope、bridge、crate 都算地面
                if et == "platform" or et == "slope" or et == "bridge" or et == "crate" then
                    -- 只有 foot sensor（trigger=true）触发的接触才算落地
                    -- 主体椭圆侧面碰墙时 trigger=false，直接跳过，防止"粘墙"BUG
                    if playerShape and not playerShape.trigger then
                        goto continue_contact
                    end
                    -- 注意：摔落伤害检测已移至 Update Step 0（射线落地检测处），
                    -- 此处不再重复检测，避免 onGround 顺序导致的检测失效问题。

                    pd.groundContacts = pd.groundContacts + 1
                    -- [DEBUG] 打印每次落地接触事件
                    print(string.format("[DBG-BeginContact][%s] et=%s node=%s contacts_after=%d pos=(%.2f,%.2f)",
                        pd.role, et, otherNode.name, pd.groundContacts,
                        pd.node.position.x, pd.node.position.y))
                    pd.onGround = true
                    pd.offGroundFrames = 0   -- 落地：重置离地防抖计数
                    -- 落地：恢复二段跳、清空豁免标志
                    pd.airJumpsLeft  = GameConst.AIR_JUMP_COUNT
                    pd.jumpInitiated = false
                    pd.coyoteTimer   = 0
                    pd.isShortJump      = false  -- 落地后恢复长跳重力模式
                    pd.longJumpSignaled = false  -- 落地后重置，下次跳跃才重新检测
                    pd.jumpCommitted    = false  -- 落地后重置，下次跳跃重新确认类型
                    -- 更新最后站立高度
                    pd.lastGroundY = pd.node.position.y

                    -- 独木桥：增加接触计数
                    if et == "bridge" then
                        local contacts = otherNode:GetVar("BRIDGE_CONTACTS")
                        local broken = otherNode:GetVar("BRIDGE_BROKEN")
                        if contacts and not contacts:IsEmpty() and broken and not broken:IsEmpty() then
                            if not broken:GetBool() then
                                local c = contacts:GetInt() + 1
                                otherNode:SetVar("BRIDGE_CONTACTS", Variant(c))
                                -- 检查是否超重
                                local maxW = otherNode:GetVar("BRIDGE_MAX_WEIGHT")
                                if maxW and not maxW:IsEmpty() and c >= maxW:GetInt() then
                                    otherNode:SetVar("BRIDGE_BROKEN", Variant(true))
                                    otherNode:SetVar("BRIDGE_BREAK_TIMER", Variant(0.5))
                                    print("[ServerGame] Bridge overloaded: " .. otherNode.name)
                                end
                            end
                        end
                    end

                -- 水面死亡
                elseif et == "water" then
                    -- 重生玩家
                    local levelDef = LevelData.GetScene(inst.sceneIdx)
                    if levelDef then
                        pd.node.position = Vector3(levelDef.spawnX, levelDef.spawnY + 1, 0)
                        pd.body:SetLinearVelocity(Vector2(0, 0))
                        pd.groundContacts = 0
                        pd.onGround = false
                        pd.offGroundFrames = 0
                        pd.lastGroundY = levelDef.spawnY + 1
                        print("[ServerGame] Player drowned, respawning: " .. pd.role)
                    end
                end
            end
            ::continue_contact::
        end
    end
end

--- 处理物理碰撞结束
---@param pairId number
---@param nodeA Node
---@param nodeB Node
---@param shapeA CollisionShape2D|nil
---@param shapeB CollisionShape2D|nil
function ServerGame.OnEndContact(pairId, nodeA, nodeB, shapeA, shapeB)
    local inst = instances_[pairId]
    if not inst then return end

    for _, pd in pairs(inst.players) do
        if pd.node == nodeA or pd.node == nodeB then
            local otherNode = (pd.node == nodeA) and nodeB or nodeA
            local playerShape = (pd.node == nodeA) and shapeA or shapeB
            local otherType = otherNode:GetVar(VARS.ENTITY_TYPE)
            if otherType and not otherType:IsEmpty() then
                local et = otherType:GetString()
                if et == "platform" or et == "slope" or et == "bridge" or et == "crate" then
                    -- 只处理 foot sensor 的离地事件，与 OnBeginContact 保持对称
                    if playerShape and not playerShape.trigger then
                        goto continue_end_contact
                    end
                    pd.groundContacts = pd.groundContacts - 1
                    if pd.groundContacts < 0 then pd.groundContacts = 0 end
                    -- [DEBUG] 打印每次离地接触事件
                    print(string.format("[DBG-EndContact][%s] et=%s node=%s contacts_after=%d pos=(%.2f,%.2f)",
                        pd.role, et, otherNode.name, pd.groundContacts,
                        pd.node.position.x, pd.node.position.y))
                    -- 注：onGround=false 和 coyoteTimer 的设置已移至 Update 的防抖逻辑
                    -- 此处不再直接修改 onGround，避免瓦片缝隙触发误判

                    -- 独木桥：减少接触计数
                    if et == "bridge" then
                        local contacts = otherNode:GetVar("BRIDGE_CONTACTS")
                        if contacts and not contacts:IsEmpty() then
                            local c = math.max(0, contacts:GetInt() - 1)
                            otherNode:SetVar("BRIDGE_CONTACTS", Variant(c))
                        end
                    end
                end
            end
            ::continue_end_contact::
        end
    end
end

--- 从碰撞节点中提取 PairId，用于全局路由
---@param nodeA Node
---@param nodeB Node
---@return number|nil
local function GetPairIdFromNodes(nodeA, nodeB)
    -- 优先从玩家节点获取 PairId
    if nodeA then
        local pv = nodeA:GetVar(VARS.PAIR_ID)
        if pv and not pv:IsEmpty() then return pv:GetInt() end
    end
    if nodeB then
        local pv = nodeB:GetVar(VARS.PAIR_ID)
        if pv and not pv:IsEmpty() then return pv:GetInt() end
    end
    return nil
end

--- 全局碰撞路由（由 Server.lua 的全局事件处理函数调用）
function ServerGame.OnBeginContactGlobal(nodeA, nodeB, shapeA, shapeB)
    local pairId = GetPairIdFromNodes(nodeA, nodeB)
    if pairId then
        ServerGame.OnBeginContact(pairId, nodeA, nodeB, shapeA, shapeB)
    end
end

function ServerGame.OnEndContactGlobal(nodeA, nodeB, shapeA, shapeB)
    local pairId = GetPairIdFromNodes(nodeA, nodeB)
    if pairId then
        ServerGame.OnEndContact(pairId, nodeA, nodeB, shapeA, shapeB)
    end
end

--- 单向平台穿透碰撞：玩家从侧面/下方穿过箱子，仅从上方站立时保留碰撞
--- 逻辑：每帧检测，如果玩家脚底 < 箱顶 + margin 且没按住 PUSH，则禁用该碰撞对
---@param pairId number
---@param nodeA Node
---@param nodeB Node
---@param shapeA CollisionShape2D
---@param shapeB CollisionShape2D
---@return boolean  -- true = 保留碰撞, false = 禁用碰撞
function ServerGame.OnUpdateContact(pairId, nodeA, nodeB, shapeA, shapeB)
    local inst = instances_[pairId]
    if not inst then return true end

    -- 识别哪个是玩家节点、哪个是箱子节点
    local playerNode, crateNode, playerShape
    for _, pd in pairs(inst.players) do
        if pd.node == nodeA then
            playerNode = nodeA
            crateNode = nodeB
            playerShape = shapeA
            break
        elseif pd.node == nodeB then
            playerNode = nodeB
            crateNode = nodeA
            playerShape = shapeB
            break
        end
    end
    if not playerNode or not crateNode then return true end

    -- 确认另一个是 crate 类型
    local otherType = crateNode:GetVar(VARS.ENTITY_TYPE)
    if not otherType or otherType:IsEmpty() or otherType:GetString() ~= "crate" then
        return true
    end

    -- 如果碰撞涉及的是 foot sensor（trigger=true），始终保留（用于地面检测）
    if playerShape.trigger then
        return true
    end

    -- 检查玩家是否正在推箱子（按住 PUSH 键）
    local isPushing = false
    for _, pd in pairs(inst.players) do
        if pd.node == playerNode then
            isPushing = pd.pushingCrate or false
            break
        end
    end

    -- 如果正在推 → 保留碰撞
    if isPushing then
        return true
    end

    -- 单向平台逻辑：仅当玩家脚底高于箱顶 + margin 时保留碰撞
    local playerY = playerNode.position.y
    local playerRadius = GameConst.PLAYER_RADIUS
    local playerBottom = playerY + GameConst.FOOT_SENSOR_OFFSET_Y  -- foot sensor 位于玩家下方

    local crateY = crateNode.position.y
    local crateH = 0.5  -- 默认
    local hVar = crateNode:GetVar("Height")
    if hVar and not hVar:IsEmpty() then crateH = hVar:GetFloat() end
    local crateTop = crateY + crateH * 0.5

    -- 玩家脚底须高于箱顶 + margin 才保留碰撞（从上方落下站稳）
    if playerBottom >= crateTop - GameConst.CRATE_ONEWAY_MARGIN then
        return true  -- 玩家在箱顶上方，保留碰撞（可以站上去）
    end

    -- 否则禁用碰撞（允许穿过）
    return false
end

--- 全局 OnUpdateContact 路由
---@param nodeA Node
---@param nodeB Node
---@param shapeA CollisionShape2D
---@param shapeB CollisionShape2D
---@return boolean
function ServerGame.OnUpdateContactGlobal(nodeA, nodeB, shapeA, shapeB)
    local pairId = GetPairIdFromNodes(nodeA, nodeB)
    if pairId then
        return ServerGame.OnUpdateContact(pairId, nodeA, nodeB, shapeA, shapeB)
    end
    return true
end

--- 销毁游戏实例
---@param pairId number
function ServerGame.Destroy(pairId)
    local inst = instances_[pairId]
    if not inst then return end

    -- 清理关卡节点
    for _, n in ipairs(inst.levelNodes) do
        if n then
            pcall(function() n:Remove() end)
        end
    end

    -- 清理玩家节点
    for _, pd in pairs(inst.players) do
        if pd.node then
            pcall(function() pd.node:Remove() end)
        end
    end

    instances_[pairId] = nil
    print("[ServerGame] Destroyed instance: pairId=" .. pairId)
end

--- 重载当前场景（编辑器保存后调用）
--- 重新加载 LevelData 并重建关卡节点，玩家位置重置到出生点
---@param pairId number
---@param sceneIdx number|nil  如不传则使用实例当前 sceneIdx
function ServerGame.ReloadLevel(pairId, sceneIdx)
    local inst = instances_[pairId]
    if not inst then return end

    local idx = sceneIdx or inst.sceneIdx
    print(string.format("[ServerGame] ReloadLevel: pairId=%d, scene=%d", pairId, idx))

    LoadLevel(inst, idx)

    -- 重置玩家位置到各自出生点
    local levelDef = LevelData.GetScene(idx)
    local spawnRedX  = levelDef and levelDef.spawnX or 2.0
    local spawnRedY  = levelDef and levelDef.spawnY or 2.0
    local spawnBlkX  = levelDef and levelDef.spawnBlackX or (spawnRedX + 1.0)
    local spawnBlkY  = levelDef and levelDef.spawnBlackY or spawnRedY
    for _, pd in pairs(inst.players) do
        if pd.role == Shared.ROLE.BLACK then
            pd.node.position = Vector3(spawnBlkX, spawnBlkY, 0)
        else
            pd.node.position = Vector3(spawnRedX, spawnRedY, 0)
        end
        pd.body.linearVelocity = Vector2(0, 0)
        pd.groundContacts  = 0
        pd.onGround        = false
        pd.offGroundFrames = 0
        pd.coyoteTimer     = 0
        pd.jumpBufferTimer = 0
        pd.airJumpsLeft    = 0
        pd.jumpInitiated   = false
    end
end

--- 立即传送指定角色的玩家到目标位置（编辑器放置出生点时调用）
---@param pairId number
---@param role string  "red" 或 "black"
---@param x number  世界坐标 X
---@param y number  世界坐标 Y
function ServerGame.TeleportPlayer(pairId, role, x, y)
    local inst = instances_[pairId]
    if not inst then return end
    for _, pd in pairs(inst.players) do
        if pd.role == role then
            pd.node.position = Vector3(x, y, 0)
            pd.body.linearVelocity = Vector2(0, 0)
            pd.groundContacts  = 0
            pd.onGround        = false
            pd.offGroundFrames = 0
            pd.coyoteTimer     = 0
            pd.jumpBufferTimer = 0
            pd.airJumpsLeft    = 0
            pd.jumpInitiated   = false
            print(string.format("[ServerGame] TeleportPlayer: role=%s → (%.2f, %.2f)", role, x, y))
            return
        end
    end
    print(string.format("[ServerGame] TeleportPlayer: role=%s NOT FOUND in pairId=%d", role, pairId))
end

--- 获取实例（供外部查询）
---@param pairId number
---@return table|nil
function ServerGame.GetInstance(pairId)
    return instances_[pairId]
end

--- 物理步后速度纠正 + 位置贴地：彻底消除斜坡/桥面滑动和漂浮
---
--- 防滑原理（三重保障）：
---   ① Update 中设 gravityScale=0（在地时）→ 物理步内无重力施加 → 斜坡法向约束无来源速度 → 不滑动
---   ② PostPhysicsCorrect 再次确认 gravityScale=0，并将速度清零 → 消除任何残余
---   ③ 位置 snap：利用 Update 中缓存的 groundHitY，将玩家中心贴到地面正上方 → 斜坡漂浮/下陷全消除
---
--- snap 公式推导：
---   snapY = groundHitY + PLAYER_RADIUS + 0.002
---   body.bottom = snapY - PLAYER_RADIUS = groundHitY + 0.002（距地面 2mm，不穿入）
---
--- X 轴修正（斜坡等速）：
---   玩家主体在上坡时会轻微压入斜面 → Box2D 约束 → vel.x 衰减 → 速度低于平地
---   修正：直接用"理论位移"覆写 X = prePhysicsX + desiredVelX * dt
---   但如果有墙壁则不修正（水平射线检测到障碍物时保持物理结果）
function ServerGame.PostPhysicsCorrect()
    for _, inst in pairs(instances_) do
        local physW2 = inst.scene:GetComponent("PhysicsWorld2D")
        for _, pd in pairs(inst.players) do
            if pd.body and pd.desiredVelX ~= nil then
                if pd.onGround then
                    pd.body.gravityScale = 0.0
                    local px = pd.node.position.x
                    local py = pd.node.position.y
                    local wantX = pd.desiredVelX

                    -- ── Step A: 计算目标 X ──
                    -- • 静止（wantX=0）：强制回到帧起点，消除 Box2D 残余漂移（含斜坡微滑）
                    -- • 移动且有墙：保持物理结果（Box2D 正确阻挡）
                    -- • 移动且无墙：理论位移覆写（消除斜坡约束对 vel.x 的衰减，上/下坡等速）
                    local snapX
                    local preX = pd.prePhysicsX
                    if preX == nil then
                        snapX = px  -- 首帧无缓存，原地
                    elseif wantX == 0 then
                        snapX = preX  -- 静止：回到帧起点
                    else
                        -- 壁障检测（水平射线，仅检测实体地面，不检测传感器）
                        local wallDist = GameConst.PLAYER_HX + 0.02
                        local dirX     = (wantX > 0) and wallDist or -wallDist
                        -- 双高度 wall 检测：
                        --   1. 中心射线：检测玩家身体中部的竖直障碍
                        --   2. 底部射线：检测台阶侧面（台阶顶面低于玩家中心时，中心射线打不到侧面）
                        local wHit  = physW2 and physW2:RaycastSingle(
                            Vector2(px, py), Vector2(px + dirX, py), COL.CAT_GROUND)
                        local footY = py - GameConst.PLAYER_RADIUS + 0.05
                        local wHitFoot = physW2 and physW2:RaycastSingle(
                            Vector2(px, footY), Vector2(px + dirX, footY), COL.CAT_GROUND)
                        -- normal.y > 0.5：法线有较大向上分量 → 可行走斜坡，不是墙
                        -- normal.y ≤ 0.5：表面接近竖直 → 真实墙壁/超陡障碍，物理阻挡生效
                        local isWall = (wHit and wHit.normal and (wHit.normal.y < 0.5))
                            or (wHitFoot and wHitFoot.normal and (wHitFoot.normal.y < 0.5))
                        if isWall then
                            -- 台阶攀越（step-up）：检测正前方台阶顶面是否在可攀越高度内
                            -- 若台阶顶面相对玩家中心高度差 < MAX_STEP_HEIGHT，则允许通过
                            -- （Y 吸附射线 Step B 会自动把玩家抬到台阶顶面）
                            local MAX_STEP_HEIGHT = 0.60  -- 最大可攀越台阶高度（米）
                            local stepX = px + dirX       -- 台阶前方 X
                            local stepCheckTop = py + MAX_STEP_HEIGHT
                            local stepRayS = Vector2(stepX, stepCheckTop)
                            -- 下终点需延伸到玩家底部以下，否则台阶顶面低于玩家中心时射线打不到
                            local stepRayE = Vector2(stepX, py - GameConst.PLAYER_RADIUS - 0.10)
                            local stepHit  = physW2 and physW2:RaycastSingle(
                                stepRayS, stepRayE, COL.CAT_GROUND)
                            if stepHit and stepHit.body then
                                local stepTopY = stepHit.position.y
                                local heightDiff = stepTopY - (py - GameConst.PLAYER_RADIUS)
                                if heightDiff > 0 and heightDiff < MAX_STEP_HEIGHT then
                                    -- 台阶顶面在可攀越范围内：允许 X 移动（Y 由 Step B 吸附）
                                    snapX = preX + wantX * (pd.lastDt or 0)
                                else
                                    snapX = px  -- 台阶过高或探测位置无地面：不移动
                                end
                            else
                                snapX = px  -- 无法探到台阶顶面：真实墙壁，不移动
                            end
                        else
                            snapX = preX + wantX * (pd.lastDt or 0)  -- 斜坡/无障碍：理论位移
                        end
                    end

                    -- ── Step B: 在目标 X 处重新射线，获取准确地面 Y ──
                    -- 在新 X 位置射线，而非旧位置缓存的 groundHitY，
                    -- 这样上坡（地面升高）和下坡（地面降低）都能正确贴地，
                    -- 彻底消除上坡身体插入斜面 / 下坡浮空的问题。
                    local snapY = py
                    if physW2 then
                        local rS = Vector2(snapX, py + GameConst.FOOT_SENSOR_OFFSET_Y + 0.05)
                        local rE = Vector2(snapX, py + GameConst.FOOT_SENSOR_OFFSET_Y - 0.30)
                        local hit = physW2:RaycastSingle(rS, rE, COL.CAT_GROUND | COL.CAT_CRATE | COL.CAT_SLOPE)
                        if hit and hit.body then
                            -- 玩家底部 = 地面 + 5mm 间隙（不穿入 → 无 Box2D 接触力 → 无滑动）
                            snapY = hit.position.y + GameConst.PLAYER_RADIUS + 0.005
                            -- PostPhysicsCorrect 射线（0.30m）命中地面：
                            -- 1. 重置离地帧计数器（但状态切换仍需 Step 0 或 groundFromSnap 维持）
                            -- 2. 记录上帧吸附成功（供 Step 0 跨缝隙时维持 onGround=true）
                            pd.offGroundFrames = 0
                            pd.groundFromSnap  = true
                        else
                            -- 本帧 Y 吸附失败：清除反馈标志，下帧 Step 0 无法借助此标志
                            pd.groundFromSnap = false
                        end
                    end

                    pd.node.position = Vector3(snapX, snapY, 0)
                    pd.body.linearVelocity = Vector2(wantX, 0)
                else
                    pd.body.gravityScale = pd.isShortJump and GameConst.PLAYER_SHORT_JUMP_GRAVITY_SCALE
                                                          or  GameConst.PLAYER_AIR_GRAVITY_SCALE
                    -- 空中/离地：X = desiredVelX（含空中速度上限），Y 保持（跳跃/下落）
                    local vel = pd.body.linearVelocity
                    pd.body.linearVelocity = Vector2(pd.desiredVelX, vel.y)
                end
            end
        end
    end
end

--- 返回所有活跃实例的 pairId 列表（供 Server.lua 遍历 Update）
---@return table pairIds
function ServerGame.GetAllPairIds()
    local ids = {}
    for pairId, _ in pairs(instances_) do
        ids[#ids + 1] = pairId
    end
    return ids
end

return ServerGame
