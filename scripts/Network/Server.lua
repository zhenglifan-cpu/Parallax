--- Network/Server.lua
--- 《同途 / Parallax》正式版服务端
--- persistent_world 模式：大厅 + 好友码配对 + 隔离 Scene

local Shared = require("Network.Shared")
local ServerGame = require("Game.ServerGame")
local LevelData = require("Game.LevelData")
local cjson = require("cjson")

-- ─── 场景管理 ───
---@type Scene
local lobbyScene_ = nil            -- 共享场景（大厅 + 所有游戏实例共存，靠 PairId 隔离）
local pairCounter_ = 0

-- ─── 玩家管理 ───
-- connKey → { connection, userId, identified, ready, state, pairId, partnerConnKey, role }
local players_ = {}
-- 短码（5位） → connKey（好友码快速查找）
local shortCodeIndex_ = {}

-- ─── 单人调试追踪 ───
-- connKey → { pairId, activeConnKey, inactiveConnKey, realConnection }
local soloInstances_ = {}

-- ═══════════════════════════════════════════════
-- 工具函数
-- ═══════════════════════════════════════════════

---@param connection Connection
---@return string
local function GetConnKey(connection)
    return tostring(connection:GetAddress()) .. ":" .. tostring(connection:GetPort())
end

--- 生成唯一的 5 位随机短码（10000-99999）
---@return string
local function GenerateShortCode()
    for _ = 1, 100 do
        local code = tostring(math.random(10000, 99999))
        if not shortCodeIndex_[code] then
            return code
        end
    end
    -- 极端情况：fallback 到 6 位
    return tostring(math.random(100000, 999999))
end

--- 通过短码查找玩家
---@param shortCode string
---@return table|nil player
---@return string|nil connKey
local function GetPlayerByShortCode(shortCode)
    local connKey = shortCodeIndex_[shortCode]
    if connKey then
        return players_[connKey], connKey
    end
    return nil, nil
end

--- 发送失败结果的辅助函数
---@param connection Connection
---@param reason string
local function SendPairFail(connection, reason)
    local data = VariantMap()
    data["Success"] = Variant(false)
    data["Reason"] = Variant(reason)
    connection:SendRemoteEvent(Shared.EVENTS.PAIR_RESULT, true, data)
end

-- ═══════════════════════════════════════════════
-- 场景创建/销毁
-- ═══════════════════════════════════════════════

local function CreateLobbyScene()
    local sc = Scene()
    sc.name = "Lobby"
    sc:CreateComponent("Octree")
    print("[Server] Lobby scene created")
    return sc
end

--- 在 lobbyScene_ 上确保物理世界存在（游戏实体需要）
local function EnsurePhysicsWorld()
    if lobbyScene_ and not lobbyScene_:GetComponent("PhysicsWorld2D") then
        lobbyScene_:CreateComponent("PhysicsWorld2D")
    end
end

--- 清理配对的游戏引用（ServerGame.Destroy 负责节点清理）
---@param pairId number
local function CleanupGameRef(pairId)
    -- 所有节点共存于 lobbyScene_，由 ServerGame.Destroy 删除；这里不需要销毁场景
end

-- ═══════════════════════════════════════════════
-- 双条件触发：identified + ready → 初始化玩家
-- ═══════════════════════════════════════════════

local function TryInitPlayer(connKey)
    local p = players_[connKey]
    if not p then return end
    if not p.ready or not p.identified then return end
    if p.state ~= "init" then return end

    p.state = "lobby"

    -- 分配到大厅场景
    p.connection.scene = lobbyScene_

    -- 生成 5 位短码并建立索引
    local shortCode = GenerateShortCode()
    p.shortCode = shortCode
    shortCodeIndex_[shortCode] = connKey

    print(string.format("[Server] Player init: connKey=%s userId=%s shortCode=%s → Lobby",
        connKey, tostring(p.userId), shortCode))

    -- 告知客户端好友码（短码）
    local data = VariantMap()
    data["UserId"] = Variant(shortCode)
    p.connection:SendRemoteEvent(Shared.EVENTS.PLAYER_INFO, true, data)
end

-- ═══════════════════════════════════════════════
-- 配对 / 解除配对
-- ═══════════════════════════════════════════════

--- 将两名玩家配对到隔离游戏场景，进入角色选择
---@param connKeyA string
---@param connKeyB string
local function DoPair(connKeyA, connKeyB)
    local pA = players_[connKeyA]
    local pB = players_[connKeyB]
    if not pA or not pB then return end

    pairCounter_ = pairCounter_ + 1
    local pairId = pairCounter_

    -- 所有配对共用 lobbyScene_，靠 PairId 节点变量隔离
    -- connection.scene 不变（初始化时已指向 lobbyScene_）

    -- 更新双方状态 → selecting（角色选择阶段）
    pA.state = "selecting"
    pA.pairId = pairId
    pA.partnerConnKey = connKeyB
    pA.role = Shared.ROLE.NONE

    pB.state = "selecting"
    pB.pairId = pairId
    pB.partnerConnKey = connKeyA
    pB.role = Shared.ROLE.NONE

    -- 配置脉冲按钮掩码
    pA.connection:SetPulseButtonMask(Shared.PULSE_MASK)
    pB.connection:SetPulseButtonMask(Shared.PULSE_MASK)

    -- 通知双方配对成功
    local dataA = VariantMap()
    dataA["Success"] = Variant(true)
    dataA["PartnerUserId"] = Variant(pB.shortCode or "")
    pA.connection:SendRemoteEvent(Shared.EVENTS.PAIR_RESULT, true, dataA)

    local dataB = VariantMap()
    dataB["Success"] = Variant(true)
    dataB["PartnerUserId"] = Variant(pA.shortCode or "")
    pB.connection:SendRemoteEvent(Shared.EVENTS.PAIR_RESULT, true, dataB)

    -- 通知双方进入角色选择
    local selectData = VariantMap()
    selectData["MyRole"] = Variant(Shared.ROLE.NONE)
    selectData["PartnerRole"] = Variant(Shared.ROLE.NONE)
    pA.connection:SendRemoteEvent(Shared.EVENTS.ENTER_SELECT, true, selectData)
    pB.connection:SendRemoteEvent(Shared.EVENTS.ENTER_SELECT, true, selectData)

    print(string.format("[Server] Paired! userId=%s <-> userId=%s → Game_%d → selecting",
        tostring(pA.userId), tostring(pB.userId), pairId))
end

--- 处理角色选择，验证冲突，通知双方
---@param connKey string
---@param role string  Shared.ROLE 值
local function HandleCharacterSelection(connKey, role)
    local p = players_[connKey]
    if not p or p.state ~= "selecting" then return end

    local partner = players_[p.partnerConnKey]
    if not partner then return end

    -- 验证角色值合法
    if role ~= Shared.ROLE.RED and role ~= Shared.ROLE.BLACK then
        print("[Server] Invalid role: " .. tostring(role))
        return
    end

    -- 设置自己的选择
    p.role = role

    -- 检查是否冲突
    local conflict = (partner.role ~= Shared.ROLE.NONE and partner.role == role)

    -- 检查是否双方都选好且不冲突
    local bothPicked = (p.role ~= Shared.ROLE.NONE and partner.role ~= Shared.ROLE.NONE)
    local confirmed = bothPicked and not conflict

    -- 通知双方当前状态
    local dataP = VariantMap()
    dataP["MyRole"] = Variant(p.role)
    dataP["PartnerRole"] = Variant(partner.role)
    dataP["Conflict"] = Variant(conflict)
    dataP["Confirmed"] = Variant(confirmed)
    p.connection:SendRemoteEvent(Shared.EVENTS.CHARACTER_RESULT, true, dataP)

    local dataPt = VariantMap()
    dataPt["MyRole"] = Variant(partner.role)
    dataPt["PartnerRole"] = Variant(p.role)
    dataPt["Conflict"] = Variant(conflict)
    dataPt["Confirmed"] = Variant(confirmed)
    partner.connection:SendRemoteEvent(Shared.EVENTS.CHARACTER_RESULT, true, dataPt)

    print(string.format("[Server] CharPick: userId=%s → %s (partner=%s, conflict=%s, confirmed=%s)",
        tostring(p.userId), role, partner.role, tostring(conflict), tostring(confirmed)))

    -- 双方确认 → 进入游戏
    if confirmed then
        p.state = "playing"
        partner.state = "playing"

        print(string.format("[Server] Both confirmed! %s=%s, %s=%s → playing",
            tostring(p.userId), p.role, tostring(partner.userId), partner.role))

        local currentPairId = p.pairId  -- 闭包捕获

        -- 确保 lobbyScene_ 有物理世界
        EnsurePhysicsWorld()

        -- (1) 在共享场景中创建所有 REPLICATED 节点（靠 PairId 变量隔离）
        local initOk, initErr = pcall(ServerGame.Init, currentPairId, lobbyScene_,
            { connKey = connKey, connection = p.connection, role = p.role },
            { connKey = p.partnerConnKey, connection = partner.connection, role = partner.role }
        )
        if not initOk then
            print("[Server] ERROR: ServerGame.Init failed: " .. tostring(initErr))
        end

        -- (2) 发送 ENTER_GAME 事件（客户端收到后开始渲染，PairId 用于过滤节点）
        local enterA = VariantMap()
        enterA["MyRole"] = Variant(p.role)
        enterA["PartnerRole"] = Variant(partner.role)
        enterA["PairId"] = Variant(currentPairId)
        p.connection:SendRemoteEvent(Shared.EVENTS.ENTER_GAME, true, enterA)

        local enterB = VariantMap()
        enterB["MyRole"] = Variant(partner.role)
        enterB["PartnerRole"] = Variant(p.role)
        enterB["PairId"] = Variant(currentPairId)
        partner.connection:SendRemoteEvent(Shared.EVENTS.ENTER_GAME, true, enterB)

        -- (4) 碰撞事件由全局 HandlePhysicsBeginContact / HandlePhysicsEndContact 路由
        --     （在 Start() 中一次性订阅，ServerGame 通过节点变量 PairId 自动分派）
    end
end

--- 解除配对，将存活方回到大厅
---@param connKey string       发起解除的一方
---@param reason string        LEAVE_REASON 常量
---@param isDisconnecting boolean  true=该连接正在断开，跳过对其操作
local function DoUnpair(connKey, reason, isDisconnecting)
    local p = players_[connKey]
    if not p then return end
    -- 允许从 selecting / playing / paired 任意状态解除
    if p.state ~= "selecting" and p.state ~= "playing" and p.state ~= "paired" then return end

    local partnerConnKey = p.partnerConnKey
    local pairId = p.pairId

    -- 重置自己状态（场景不变，始终共用 lobbyScene_）
    p.state = "lobby"
    p.pairId = nil
    p.partnerConnKey = nil
    p.role = nil

    -- 处理搭档
    local partner = players_[partnerConnKey]
    if partner and (partner.state == "paired" or partner.state == "selecting" or partner.state == "playing") then
        partner.state = "lobby"
        partner.pairId = nil
        partner.partnerConnKey = nil
        partner.role = nil

        -- 通知搭档
        local data = VariantMap()
        data["Reason"] = Variant(reason)
        partner.connection:SendRemoteEvent(Shared.EVENTS.PARTNER_LEFT, true, data)

        print(string.format("[Server] Notified partner userId=%s: %s",
            tostring(partner.userId), reason))
    end

    -- 清理单人调试追踪
    soloInstances_[connKey] = nil

    -- 销毁游戏实例中的节点（场景本身保留）
    if pairId then
        ServerGame.Destroy(pairId)
        CleanupGameRef(pairId)
    end
end

-- ═══════════════════════════════════════════════
-- 事件处理
-- ═══════════════════════════════════════════════

function Start()
    print("[Server] ======= Parallax Server (Persistent World) =======")

    Shared.RegisterServerEvents()
    LevelData.Init(true)
    lobbyScene_ = CreateLobbyScene()

    SubscribeToEvent("ClientConnected", "HandleClientConnected")
    SubscribeToEvent("ClientIdentity", "HandleClientIdentity")
    SubscribeToEvent(Shared.EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(Shared.EVENTS.PAIR_REQUEST, "HandlePairRequest")
    SubscribeToEvent(Shared.EVENTS.UNPAIR_REQUEST, "HandleUnpairRequest")
    SubscribeToEvent(Shared.EVENTS.CHARACTER_PICK, "HandleCharacterPick")
    SubscribeToEvent(Shared.EVENTS.DEBUG_SOLO, "HandleDebugSolo")
    SubscribeToEvent(Shared.EVENTS.DEBUG_SWITCH, "HandleDebugSwitch")
    SubscribeToEvent(Shared.EVENTS.DEBUG_RELOAD, "HandleDebugReload")
    SubscribeToEvent(Shared.EVENTS.SPAWN_TELEPORT, "HandleSpawnTeleport")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")
    SubscribeToEvent("Update", "HandleUpdate_Server")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate_Server")

    -- 全局订阅物理碰撞事件（不带 sender，避免重复订阅覆盖问题）
    SubscribeToEvent("PhysicsBeginContact2D", "HandlePhysicsBeginContact")
    SubscribeToEvent("PhysicsEndContact2D", "HandlePhysicsEndContact")
    SubscribeToEvent("PhysicsUpdateContact2D", "HandlePhysicsUpdateContact")

    print("[Server] Waiting for players...")
end

--- 每帧更新：驱动所有活跃的 ServerGame 实例
function HandleUpdate_Server(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 遍历所有活跃游戏实例，更新游戏逻辑
    for _, pairId in ipairs(ServerGame.GetAllPairIds()) do
        ServerGame.Update(pairId, dt)
    end
end

--- 物理步后纠正：消除斜坡法向力在本帧物理步中引入的横向滑动分量
--- 使用 PostUpdate（在物理步之后触发，比 PhysicsPostStep2D 更可靠）
function HandlePostUpdate_Server(eventType, eventData)
    ServerGame.PostPhysicsCorrect()
end

function HandleClientConnected(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)

    players_[connKey] = {
        connection     = connection,
        userId         = nil,
        identified     = false,
        ready          = false,
        state          = "init",     -- init → lobby → selecting → playing
        pairId         = nil,
        partnerConnKey = nil,
        role           = nil,
    }

    print("[Server] ClientConnected: " .. connKey)
end

function HandleClientIdentity(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)

    local p = players_[connKey]
    if not p then
        p = {
            connection = connection, userId = nil,
            identified = false, ready = false, state = "init",
            pairId = nil, partnerConnKey = nil,
        }
        players_[connKey] = p
    end

    p.userId = connection.identity["user_id"]:GetInt64()
    p.identified = true

    print(string.format("[Server] ClientIdentity: connKey=%s userId=%s",
        connKey, tostring(p.userId)))

    TryInitPlayer(connKey)
end

function HandleClientReady(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)

    local p = players_[connKey]
    if not p then
        p = {
            connection = connection, userId = nil,
            identified = false, ready = false, state = "init",
            pairId = nil, partnerConnKey = nil,
        }
        players_[connKey] = p
    end

    p.ready = true
    print("[Server] ClientReady: " .. connKey)

    TryInitPlayer(connKey)
end

--- 处理配对请求：验证 → 配对
function HandlePairRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)
    local p = players_[connKey]
    if not p then return end

    local targetIdStr = eventData["TargetUserId"]:GetString()
    print(string.format("[Server] PairRequest: userId=%s → target=%s",
        tostring(p.userId), targetIdStr))

    -- 验证 1：无效 ID
    if not targetIdStr or targetIdStr == "" then
        SendPairFail(connection, Shared.PAIR_FAIL.INVALID_ID)
        return
    end

    -- 验证 2：自我配对（用短码比较）
    if targetIdStr == p.shortCode then
        SendPairFail(connection, Shared.PAIR_FAIL.SELF_PAIR)
        return
    end

    -- 验证 3：自己已配对
    if p.state == "paired" then
        SendPairFail(connection, Shared.PAIR_FAIL.ALREADY_PAIRED)
        return
    end

    -- 验证 4：目标不在线（通过短码查找）
    local target, targetConnKey = GetPlayerByShortCode(targetIdStr)
    if not target then
        SendPairFail(connection, Shared.PAIR_FAIL.TARGET_OFFLINE)
        return
    end

    -- 验证 5：目标已配对
    if target.state == "paired" then
        SendPairFail(connection, Shared.PAIR_FAIL.TARGET_PAIRED)
        return
    end

    -- 全部通过 → 配对
    DoPair(connKey, targetConnKey)
end

--- 处理解除配对请求
function HandleUnpairRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)
    local p = players_[connKey]

    if not p then return end
    if p.state ~= "selecting" and p.state ~= "playing" and p.state ~= "paired" then return end

    print(string.format("[Server] UnpairRequest: userId=%s", tostring(p.userId)))
    DoUnpair(connKey, Shared.LEAVE_REASON.UNPAIRED, false)
end

--- 处理角色选择
function HandleCharacterPick(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)
    local role = eventData["Role"]:GetString()

    print(string.format("[Server] CharacterPick: connKey=%s role=%s", connKey, role))
    HandleCharacterSelection(connKey, role)
end

--- 处理单人调试请求：跳过配对和角色选择，直接进入游戏
function HandleDebugSolo(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)
    local p = players_[connKey]
    if not p or p.state ~= "lobby" then return end

    print(string.format("[Server] DebugSolo: userId=%s", tostring(p.userId)))

    pairCounter_ = pairCounter_ + 1
    local pairId = pairCounter_
    local dummyConnKey = connKey .. "_solo"

    -- 确保 lobbyScene_ 有物理世界（所有配对共用）
    EnsurePhysicsWorld()

    -- 更新玩家状态 → playing（跳过 selecting）
    p.state = "playing"
    p.pairId = pairId
    p.partnerConnKey = dummyConnKey
    p.role = Shared.ROLE.RED
    connection:SetPulseButtonMask(Shared.PULSE_MASK)

    -- 创建游戏实例：真实玩家控制红鸟，黑鸟 connection=nil（无输入，静止）
    local initOk, initErr = pcall(ServerGame.Init, pairId, lobbyScene_,
        { connKey = connKey, connection = connection, role = Shared.ROLE.RED },
        { connKey = dummyConnKey, connection = nil, role = Shared.ROLE.BLACK }
    )
    if not initOk then
        print("[Server] ERROR: ServerGame.Init (solo) failed: " .. tostring(initErr))
        -- 清理可能已创建的游戏实例节点
        pcall(ServerGame.Destroy, pairId)
        p.state = "lobby"
        p.pairId = nil
        p.partnerConnKey = nil
        p.role = nil
        return
    end

    -- 追踪单人实例（用于切换角色）
    soloInstances_[connKey] = {
        pairId = pairId,
        activeConnKey = connKey,
        inactiveConnKey = dummyConnKey,
        realConnection = connection,
    }

    -- 碰撞事件由全局 HandlePhysicsBeginContact / HandlePhysicsEndContact 路由

    -- 通知客户端进入游戏（附带 DebugSolo 标记和 PairId）
    local enterData = VariantMap()
    enterData["MyRole"] = Variant(Shared.ROLE.RED)
    enterData["PartnerRole"] = Variant(Shared.ROLE.BLACK)
    enterData["DebugSolo"] = Variant(true)
    enterData["PairId"] = Variant(pairId)
    connection:SendRemoteEvent(Shared.EVENTS.ENTER_GAME, true, enterData)

    print(string.format("[Server] Solo debug started: pairId=%d, controlling RED", pairId))
end

--- 处理单人调试视角切换：交换 connection 到另一个角色
function HandleDebugSwitch(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)

    local solo = soloInstances_[connKey]
    if not solo then return end

    local inst = ServerGame.GetInstance(solo.pairId)
    if not inst then return end

    -- 获取当前活跃和非活跃的 PlayerData
    local activePD = inst.players[solo.activeConnKey]
    local inactivePD = inst.players[solo.inactiveConnKey]
    if not activePD or not inactivePD then return end

    -- 交换 connection：活跃→nil（停止输入），非活跃→真实连接（接管输入）
    activePD.connection = nil
    inactivePD.connection = solo.realConnection

    -- 更新追踪
    solo.activeConnKey, solo.inactiveConnKey = solo.inactiveConnKey, solo.activeConnKey

    -- 通知客户端切换渲染视角
    local newRole = inactivePD.role
    local data = VariantMap()
    data["NewRole"] = Variant(newRole)
    connection:SendRemoteEvent(Shared.EVENTS.DEBUG_SWITCHED, true, data)

    print(string.format("[Server] Solo switched → now controlling %s", newRole))
end

--- 处理调试模式场景重载（编辑器保存后）
function HandleDebugReload(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)

    local solo = soloInstances_[connKey]
    if not solo then return end

    local sceneIdx = nil
    local ok, v = pcall(function() return eventData["SceneIdx"] end)
    if ok and v and type(v.GetInt) == "function" then
        sceneIdx = v:GetInt()
    end

    -- 接收客户端附带的场景 JSON 数据并更新服务端 LevelData
    local jsonOk, jsonVar = pcall(function() return eventData["SceneJson"] end)
    if jsonOk and jsonVar and type(jsonVar.GetString) == "function" then
        local jsonStr = jsonVar:GetString()
        if jsonStr and #jsonStr > 0 then
            local decOk, sceneData = pcall(cjson.decode, jsonStr)
            if decOk and sceneData and sceneIdx then
                -- 诊断：打印接收到的场景数据
                local objCount = sceneData.objects and #sceneData.objects or 0
                print(string.format("[Server][DIAG] DebugReload received: scene=%d, objects=%d, jsonLen=%d",
                    sceneIdx, objCount, #jsonStr))
                -- 打印每个 object 的类型
                if sceneData.objects then
                    for idx, obj in ipairs(sceneData.objects) do
                        print(string.format("[Server][DIAG]   obj[%d]: type=%s id=%s slopeType=%s event=%s",
                            idx, tostring(obj.type), tostring(obj.id),
                            tostring(obj.slopeType), tostring(obj.event)))
                    end
                end
                LevelData.SetScene(sceneIdx, sceneData)
            else
                print(string.format("[Server][DIAG] DebugReload JSON decode FAILED: decOk=%s, sceneIdx=%s",
                    tostring(decOk), tostring(sceneIdx)))
                -- decode 失败 → 不执行 ReloadLevel，保持当前场景不变
                return
            end
        else
            print("[Server][DIAG] DebugReload: jsonStr is EMPTY!")
            return
        end
    else
        print(string.format("[Server][DIAG] DebugReload: SceneJson extraction failed: jsonOk=%s", tostring(jsonOk)))
        return
    end

    print(string.format("[Server] DebugReload: connKey=%s, sceneIdx=%s",
        connKey, tostring(sceneIdx)))
    ServerGame.ReloadLevel(solo.pairId, sceneIdx)
end

--- 处理编辑器放置出生点后立即传送玩家
function HandleSpawnTeleport(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)

    local solo = soloInstances_[connKey]
    if not solo then return end

    local role = eventData["Role"]:GetString()
    local posX = eventData["PosX"]:GetFloat()
    local posY = eventData["PosY"]:GetFloat()

    print(string.format("[Server] SpawnTeleport: connKey=%s role=%s pos=(%.2f, %.2f)",
        connKey, role, posX, posY))
    ServerGame.TeleportPlayer(solo.pairId, role, posX, posY)
end

--- 处理客户端断线
function HandleClientDisconnected(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = GetConnKey(connection)
    local p = players_[connKey]

    if not p then return end

    print(string.format("[Server] Disconnected: userId=%s state=%s",
        tostring(p.userId), p.state))

    -- 如果在配对/选择/游戏中，通知搭档并拆对
    if p.state == "selecting" or p.state == "playing" or p.state == "paired" then
        DoUnpair(connKey, Shared.LEAVE_REASON.DISCONNECTED, true)
    end

    -- 清理短码索引
    if p.shortCode then
        shortCodeIndex_[p.shortCode] = nil
    end
    players_[connKey] = nil
end

--- 全局物理碰撞路由：通过节点的 PairId 变量分派到对应 ServerGame 实例
function HandlePhysicsBeginContact(eventType, eventData)
    local nodeA  = eventData["NodeA"]:GetPtr("Node")
    local nodeB  = eventData["NodeB"]:GetPtr("Node")
    local shapeA = eventData["ShapeA"]:GetPtr("CollisionShape2D")
    local shapeB = eventData["ShapeB"]:GetPtr("CollisionShape2D")
    ServerGame.OnBeginContactGlobal(nodeA, nodeB, shapeA, shapeB)
end

function HandlePhysicsEndContact(eventType, eventData)
    local nodeA  = eventData["NodeA"]:GetPtr("Node")
    local nodeB  = eventData["NodeB"]:GetPtr("Node")
    local shapeA = eventData["ShapeA"]:GetPtr("CollisionShape2D")
    local shapeB = eventData["ShapeB"]:GetPtr("CollisionShape2D")
    ServerGame.OnEndContactGlobal(nodeA, nodeB, shapeA, shapeB)
end

function HandlePhysicsUpdateContact(eventType, eventData)
    local nodeA = eventData["NodeA"]:GetPtr("Node")
    local nodeB = eventData["NodeB"]:GetPtr("Node")
    local shapeA = eventData["ShapeA"]:GetPtr("CollisionShape2D")
    local shapeB = eventData["ShapeB"]:GetPtr("CollisionShape2D")
    local enabled = ServerGame.OnUpdateContactGlobal(nodeA, nodeB, shapeA, shapeB)
    if not enabled then
        eventData["Enabled"] = Variant(false)
    end
end

function Stop()
    print("[Server] Shutting down")
    -- 销毁所有游戏实例的节点
    for _, pairId in ipairs(ServerGame.GetAllPairIds()) do
        ServerGame.Destroy(pairId)
    end
    if lobbyScene_ then lobbyScene_:Remove() end
end
