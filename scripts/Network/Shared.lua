--- Network/Shared.lua
--- 《同途 / Parallax》正式版共享定义
--- 远程事件、常量、控制位、节点变量名、注册函数

local Shared = {}

-- ─── 远程事件名 ───
Shared.EVENTS = {
    -- 客户端 → 服务器
    CLIENT_READY    = "ClientReady",      -- 客户端就绪（场景已设置）
    PAIR_REQUEST    = "PairRequest",      -- 请求配对（携带目标 userId）
    UNPAIR_REQUEST  = "UnpairRequest",    -- 请求解除配对，返回大厅
    CHARACTER_PICK  = "CharacterPick",    -- 选择角色（携带 Role）
    DEBUG_SOLO      = "DebugSolo",        -- 单人调试（跳过配对，自动分配双角色）
    DEBUG_SWITCH    = "DebugSwitch",      -- 单人调试：请求切换控制角色
    DEBUG_RELOAD    = "DebugReload",      -- 单人调试：请求重载当前场景（编辑器保存后）
    SPAWN_TELEPORT  = "SpawnTeleport",    -- 编辑器：放置出生点后立即传送玩家到该位置

    -- 服务器 → 客户端
    PLAYER_INFO     = "PlayerInfo",       -- 告知客户端自己的 userId（好友码）
    PAIR_RESULT     = "PairResult",       -- 配对结果（成功/失败 + 原因）
    PARTNER_LEFT    = "PartnerLeft",      -- 搭档已离开
    ENTER_SELECT    = "EnterSelect",      -- 进入角色选择阶段（携带双方状态）
    CHARACTER_RESULT = "CharacterResult", -- 角色选择更新（携带双方选择 + 是否已确认）
    ENTER_GAME      = "EnterGame",       -- 双方选好，进入游戏（携带最终角色分配）
    GAME_EVENT      = "GameEvent",       -- 通用游戏事件（类型 + 数据）
    SCENE_CHANGE    = "SceneChange",     -- 场景切换通知（携带 SceneIdx + SceneName）
    DEBUG_SWITCHED  = "DebugSwitched",   -- 单人调试：视角已切换（携带 NewRole）
}

-- ─── 配对失败原因 ───
Shared.PAIR_FAIL = {
    SELF_PAIR       = "self_pair",        -- 不能和自己配对
    ALREADY_PAIRED  = "already_paired",   -- 你已经在游戏中
    TARGET_OFFLINE  = "target_offline",   -- 对方不在线
    TARGET_PAIRED   = "target_paired",    -- 对方已在游戏中
    INVALID_ID      = "invalid_id",       -- 无效的好友码
}

-- ─── 搭档离开原因 ───
Shared.LEAVE_REASON = {
    DISCONNECTED = "disconnected",        -- 搭档断线
    UNPAIRED     = "unpaired",            -- 搭档主动退出
}

-- ─── 角色常量 ───
Shared.ROLE = {
    NONE  = "",            -- 未选择
    RED   = "red",         -- 红鸟（乐观主义者）
    BLACK = "black",       -- 黑鸟（悲观主义者）
}

-- ─── 控制位掩码（controls.buttons） ───
Shared.CTRL = {
    MOVE_LEFT  = 1,     -- bit 0: 持续按键
    MOVE_RIGHT = 2,     -- bit 1: 持续按键
    JUMP       = 4,     -- bit 2: 脉冲按键
    INTERACT   = 8,     -- bit 3: 脉冲按键
    PUSH       = 16,    -- bit 4: 持续按键（按住E推箱子）
}
-- 脉冲掩码（需要 SetPulseButtonMask 的位）
-- JUMP 已改为持续键（按住=长跳，松开截断=短跳），不再是脉冲
Shared.PULSE_MASK = Shared.CTRL.INTERACT

-- ─── 节点变量名 ───
Shared.VARS = {
    ROLE        = "Role",         -- 角色类型 "red" / "black"
    CONN_KEY    = "ConnKey",      -- 所属连接 key
    ENTITY_TYPE = "EntityType",   -- 实体类型（"player" / "npc" / "platform" 等）
    VISIBLE_TO  = "VisibleTo",    -- 可见性过滤 "all" / "red" / "black"
    PAIR_ID     = "PairId",       -- 配对 ID
    SCENE_IDX   = "SceneIdx",     -- 当前场景索引（关卡）
    CRATE_ANGLE   = "CrateAngle",   -- 箱子斜坡角度 (弧度)
    PUSHING_CRATE = "PushingCrate", -- 玩家正在推箱子 (bool, 视觉用)
    PUSH_DIR      = "PushDir",      -- 推箱方向 -1/0/1 (视觉用)
    ON_GROUND     = "OnGround",     -- 玩家是否在地面（bool，供客户端动画判断）
    IS_MOVING     = "IsMoving",     -- 玩家是否在按方向键移动（bool，供客户端动画判断）
    FACING_LEFT   = "FacingLeft",   -- 玩家朝向（bool，true=朝左，供客户端动画判断）
}

-- ─── 碰撞分类位 ───
Shared.COLLISION = {
    CAT_GROUND = 1,    -- bit 0: 地面/平台（物理实体碰撞）
    CAT_PLAYER = 2,    -- bit 1: 玩家主体
    CAT_SENSOR = 4,    -- bit 2: 脚底传感器
    CAT_CRATE  = 8,    -- bit 3: 箱子（单独类别，用于单向平台过滤）
    CAT_SLOPE  = 16,   -- bit 4: 斜坡（仅射线检测，不与玩家产生物理接触，消除滑动）
}

-- ─── 服务端需要接收的远程事件 ───
Shared.SERVER_EVENTS = {
    Shared.EVENTS.CLIENT_READY,
    Shared.EVENTS.PAIR_REQUEST,
    Shared.EVENTS.UNPAIR_REQUEST,
    Shared.EVENTS.CHARACTER_PICK,
    Shared.EVENTS.DEBUG_SOLO,
    Shared.EVENTS.DEBUG_SWITCH,
    Shared.EVENTS.DEBUG_RELOAD,
    Shared.EVENTS.SPAWN_TELEPORT,
}

-- ─── 客户端需要接收的远程事件 ───
Shared.CLIENT_EVENTS = {
    Shared.EVENTS.PLAYER_INFO,
    Shared.EVENTS.PAIR_RESULT,
    Shared.EVENTS.PARTNER_LEFT,
    Shared.EVENTS.ENTER_SELECT,
    Shared.EVENTS.CHARACTER_RESULT,
    Shared.EVENTS.ENTER_GAME,
    Shared.EVENTS.GAME_EVENT,
    Shared.EVENTS.SCENE_CHANGE,
    Shared.EVENTS.DEBUG_SWITCHED,
}

--- 服务端调用：注册远程事件
function Shared.RegisterServerEvents()
    for _, name in ipairs(Shared.SERVER_EVENTS) do
        network:RegisterRemoteEvent(name)
    end
end

--- 客户端调用：注册远程事件
function Shared.RegisterClientEvents()
    for _, name in ipairs(Shared.CLIENT_EVENTS) do
        network:RegisterRemoteEvent(name)
    end
end

return Shared
