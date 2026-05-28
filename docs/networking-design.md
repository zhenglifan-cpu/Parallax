# 《同途 / Parallax》联机方案

> 双人在线合作游戏的网络架构设计
>
> 游戏机制详见 [game-design-document.md](game-design-document.md) | 故事线详见 [story.md](story.md)


①描述场景：诉求+情境——棋牌室（大厅）+牌桌（对局）
②隔离对局：确保不同队伍之间进度互不干扰，至少显示不冲突
③单人调试：单人模式可以切换队友视角模拟对局


---

## 0. 方案摘要

| 项目 | 选型 |
|------|------|
| 网络模型 | UrhoX 权威服务器（Server-Authoritative） |
| 匹配模式 | `persistent_world`（常驻服），所有玩家连入同一个服务器实例 |
| 匹配方式 | 5 位短码（10000-99999 随机生成）配对，服务器内部管理 |
| 最大玩家数 | `max_players: 100`（服务器承载多对同时游戏） |
| 后台匹配 | `background_match=false`（使用平台默认连接流程） |
| 自定义菜单 | 自研大厅 UI（展示好友码 + 输入配对） |
| 房间隔离 | **共享 Scene + PairId 节点变量隔离**（所有配对共用 `lobbyScene_`，靠 PairId 变量过滤） |

---

## 1. 为什么选择 persistent_world

### 1.1 方案对比

| 方案 | 特点 | 适用场景 |
|------|------|---------|
| **`persistent_world`（当前方案）** | 所有玩家连入同一个常驻服务器，服务器内部管理配对 | 好友码即时配对、大厅社交 |
| `match_info` | 平台为每次匹配创建独立服务器实例 | 自动队列匹配（无好友码直连能力） |

### 1.2 选择 persistent_world 的原因

1. **好友码即时配对**：玩家 A 输入玩家 B 的好友码，服务器直接查找 B 是否在线并完成配对——无需 Cloud API 中转、无需重试循环
2. **用户体验简洁**：连接服务器 → 看到好友码 → 输入对方码 → 立刻配对，全程在同一个服务器内完成
3. **`match_info` 不支持好友码直连**：`free_match` 是全局随机队列，无法指定和谁配对。要实现好友码需要 Cloud API 协调 + 服务器验证 + RejectMatch 重试，复杂且不可靠

### 1.3 多对配对隔离方案：共享 Scene + PairId

`persistent_world` 的核心挑战是同一服务器内多对玩家的隔离。

#### 核心思路

所有配对共用一个 `lobbyScene_`。服务器为每对配对分配唯一 `pairId`（递增整数），并将该 ID 写入每个 REPLICATED 节点的 `PairId` 变量。客户端收到 `ENTER_GAME` 事件时获取自己的 PairId，在渲染/逻辑中只处理匹配该 PairId 的节点。

#### 架构图

```
服务器（persistent_world）
└── lobbyScene_（唯一共享场景）
    │
    ├── [PairId=1] Player_RED_1    ← A+B 的游戏节点
    ├── [PairId=1] Player_BLACK_1
    ├── [PairId=1] Platform_1_*
    ├── [PairId=1] Slope_1_*
    │
    ├── [PairId=2] Player_RED_2    ← C+D 的游戏节点
    ├── [PairId=2] Player_BLACK_2
    ├── [PairId=2] Platform_2_*
    │
    └── ...（更多配对）
```

#### 服务器端：写入 PairId

```lua
-- ServerGame.Init() 中为每个 REPLICATED 节点设置 PairId
local function CreateEntity(scene, pairId, entityType, ...)
    local node = scene:CreateChild("Entity", REPLICATED)
    node:SetVar(Shared.VARS.PAIR_ID, Variant(pairId))
    node:SetVar(Shared.VARS.ENTITY_TYPE, Variant(entityType))
    -- ...
    return node
end
```

#### 服务器端：ENTER_GAME 携带 PairId

```lua
-- DoPair / HandleDebugSolo 发送 ENTER_GAME 时附带 PairId
local enterData = VariantMap()
enterData["MyRole"]   = Variant(p.role)
enterData["PartnerRole"] = Variant(partner.role)
enterData["PairId"]   = Variant(pairId)
connection:SendRemoteEvent(Shared.EVENTS.ENTER_GAME, true, enterData)
```

#### 客户端：接收并存储 PairId

```lua
-- Client.lua: HandleEnterGame
function HandleEnterGame(eventType, eventData)
    -- ...角色分配...
    local pairIdVar = eventData["PairId"]
    myPairId_ = (pairIdVar and not pairIdVar:IsEmpty()) and pairIdVar:GetInt() or 0
    -- 传递给 ClientGame
    ClientGame.Init(scene_, serverConn_, myRole_, myPairId_)
end
```

#### 客户端：BelongsToMyPair 过滤

```lua
-- ClientGame.lua: 核心过滤函数
local function BelongsToMyPair(node)
    if pairId_ <= 0 then return true end  -- 未设置时不过滤
    local ok, pidVar = pcall(function() return node:GetVar(VARS.PAIR_ID) end)
    if ok and pidVar and type(pidVar.IsEmpty) == "function" and not pidVar:IsEmpty() then
        return pidVar:GetInt() == pairId_
    end
    return true  -- 无 PairId 的节点不过滤（Camera 等 LOCAL 节点）
end
```

该函数在以下关键路径调用：
- **CollectSceneNodes()**：遍历场景子节点时过滤，只收集属于自己配对的实体
- **UpdateCamera()**：检测玩家节点时过滤，相机只跟随自己配对的玩家
- **GetMyPlayerScreenPos()**：获取自己玩家屏幕位置时过滤
- **编辑器回调 (getBirdPositions)**：获取鸟位置时过滤

#### 为什么不用独立 Scene

> 见文末"踩坑记录"第 1 条。独立 Scene 方案因 UrhoX Replication 机制限制而失败。

---

## 2. 配置

```json
// .project/settings.json
{
  "@runtime": {
    "multiplayer": {
      "enabled": true,
      "max_players": 100,
      "background_match": false,
      "persistent_world": {
        "enabled": true
      }
    }
  }
}
```

| 字段 | 值 | 说明 |
|------|---|------|
| `max_players` | 100 | 服务器可承载多对同时游戏（每对 2 人） |
| `background_match` | `false` | 使用平台默认连接流程 |
| `persistent_world.enabled` | `true` | 常驻服模式，服务器持续运行 |

> **注意**：不使用 `match_info`。好友码配对完全由服务器内部逻辑管理，不依赖平台匹配队列。

---

## 3. 玩家体验流程

### 3.1 核心流程（persistent_world）

所有玩家连入同一个常驻服务器。服务器为每个玩家生成 5 位随机短码作为好友码，配对在服务器内部完成。

```
玩家打开游戏
  ↓
连接到常驻服务器 → ClientIdentity（获取 userId）→ ClientReady
  ↓
服务器生成 5 位短码 → 发送 PlayerInfo → 客户端显示大厅 UI
  ├── 展示"你的好友码: 38472"
  └── 输入框"输入搭档的好友码"
  ↓
玩家输入对方好友码 → 点击"开始配对"
  ↓
客户端发送 PairRequest（TargetUserId = "38472"）→ 服务器
  ↓
服务器通过 shortCodeIndex_ 查找 → 验证（在线？未配对？不是自己？）
  ├── 通过 → 双方配对成功 → 进入角色选择
  └── 失败 → 返回错误原因（"对方不在线" / "对方已在游戏中"）
  ↓
角色选择（双方各选红鸟/黑鸟，互斥选择）→ 双方确认
  ↓
服务器在 lobbyScene_ 创建 REPLICATED 节点（带 PairId 隔离）→ 发送 ENTER_GAME → 进入游戏
```

### 3.2 好友码配对详细流程

```
玩家 A                                   玩家 B
  │                                        │
  ├─ 连入服务器 → 大厅 UI                    ├─ 连入服务器 → 大厅 UI
  ├─ 显示好友码 "38472"                     ├─ 显示好友码 "61953"
  │                                        │
  │  （A 把码告诉 B，或 B 把码告诉 A）        │
  │                                        │
  │  输入 "61953" → 开始配对                 │
  │  PairRequest ──────────────────→ 服务器  │
  │                                        │
  │          服务器查找 shortCodeIndex_       │
  │          找到 B → 验证通过                │
  │                                        │
  │  ←── PairResult(success) ──────────────→│
  │                                        │
  │  进入角色选择                             │  进入角色选择
  │  选择红鸟                                │  选择黑鸟
  │                                        │
  │  ←── EnterGame(PairId=1) ──────────────→│
  │                                        │
  │  进入游戏（只渲染 PairId=1 的节点）        │  进入游戏（只渲染 PairId=1 的节点）
```

> **单方发起即可**：只需一方输入对方好友码并发起配对，另一方会自动收到配对成功通知。无需双方互相输入。

---

## 4. 代码架构

### 4.1 文件结构

```
scripts/
├── main.lua                     # 备用入口
│
├── Network/
│   ├── Shared.lua               # 共享常量（事件名、配对状态、角色定义、节点变量名）
│   ├── Server.lua               # 服务器逻辑（大厅管理、短码配对、角色选择、PairId 隔离）
│   └── Client.lua               # 客户端逻辑（大厅 UI、配对交互、角色选择、PairId 接收）
│
├── Game/
│   ├── ClientGame.lua           # 客户端游戏逻辑（NanoVG 渲染、输入、相机、PairId 过滤）
│   ├── ServerGame.lua           # 服务器游戏逻辑（权威计算、碰撞、PairId 节点创建）
│   ├── GameConst.lua            # 游戏常量（速度、重力、尺寸等）
│   └── LevelData.lua            # 关卡数据
│
├── Render/
│   ├── WorldRenderer.lua        # 双世界渲染：根据角色加载不同视觉皮肤
│   └── DualWorldSkin.lua        # 双世界皮肤定义（乐观/悲观世界的外观映射）
│
└── UI/
    └── CharSelectUI.lua         # 角色选择界面（红鸟/黑鸟）
```

### 4.2 入口文件

项目使用 `entry@client` / `entry@server` 分离入口模式（在 `.project/project.json` 中配置）：

```json
{
  "entry@client": "Network/Client.lua",
  "entry@server": "Network/Server.lua"
}
```

客户端和服务端各自独立的 `Start()` / `Stop()` 函数作为入口，无需在 `main.lua` 中判断模式。

### 4.3 共享定义

```lua
-- Network/Shared.lua（关键摘要）
local Shared = {}

-- ─── 远程事件名 ───
Shared.EVENTS = {
    -- 客户端 → 服务器
    CLIENT_READY    = "ClientReady",
    PAIR_REQUEST    = "PairRequest",
    UNPAIR_REQUEST  = "UnpairRequest",
    CHARACTER_PICK  = "CharacterPick",
    DEBUG_SOLO      = "DebugSolo",       -- 单人调试
    DEBUG_SWITCH    = "DebugSwitch",      -- 调试：切换控制角色
    DEBUG_RELOAD    = "DebugReload",      -- 调试：重载场景
    SPAWN_TELEPORT  = "SpawnTeleport",    -- 编辑器：传送到出生点

    -- 服务器 → 客户端
    PLAYER_INFO      = "PlayerInfo",
    PAIR_RESULT      = "PairResult",
    PARTNER_LEFT     = "PartnerLeft",
    ENTER_SELECT     = "EnterSelect",
    CHARACTER_RESULT = "CharacterResult",
    ENTER_GAME       = "EnterGame",      -- 携带 PairId
    GAME_EVENT       = "GameEvent",
    SCENE_CHANGE     = "SceneChange",
    DEBUG_SWITCHED   = "DebugSwitched",
}

-- ─── 节点变量名 ───
Shared.VARS = {
    ROLE        = "Role",
    CONN_KEY    = "ConnKey",
    ENTITY_TYPE = "EntityType",
    VISIBLE_TO  = "VisibleTo",
    PAIR_ID     = "PairId",       -- ← 多对隔离的关键变量
    SCENE_IDX   = "SceneIdx",
}

-- ─── 控制位掩码 ───
Shared.CTRL = {
    MOVE_LEFT  = 1,     -- bit 0: 持续
    MOVE_RIGHT = 2,     -- bit 1: 持续
    JUMP       = 4,     -- bit 2: 脉冲
    INTERACT   = 8,     -- bit 3: 脉冲
}
Shared.PULSE_MASK = Shared.CTRL.JUMP | Shared.CTRL.INTERACT
```

---

## 5. 同步策略

### 5.1 什么需要同步

本游戏的核心设计是"同逻辑层 + 异视觉层"。需要同步的都是**逻辑层**数据：

| 数据 | 同步方式 | 方向 | 频率 |
|------|---------|------|------|
| **玩家位置** | Scene Replication（自动） | 服务器 → 客户端 | 每帧 |
| **玩家输入** | `connection.controls` | 客户端 → 服务器 | 每帧 |
| **机关状态** (开关/门) | Node Vars (`SetVar`) | 服务器 → 客户端 | 事件触发 |
| **互动请求** | Remote Event (`Interact`) | 客户端 → 服务器 | 事件触发 |
| **谜题进度** | Remote Event (广播) | 服务器 → 客户端 | 事件触发 |
| **玩家死亡/重生** | Remote Event | 服务器 → 客户端 | 事件触发 |

### 5.2 什么不需要同步

| 数据 | 原因 |
|------|------|
| **视觉皮肤**（精灵/贴图/颜色） | 各端根据自己的角色本地加载 |
| **视差背景** | 各端本地计算滚动偏移 |
| **音效/粒子** | 各端本地播放对应世界的音效 |
| **NPC 外观/台词** | 同一个 NPC 节点，各端根据角色显示不同外观 |

### 5.3 位置同步流程

```
客户端                           服务器                          客户端
(红鸟)                                                         (黑鸟)
  │                                │                              │
  │  controls.buttons = LEFT       │                              │
  │  controls.yaw = ...            │                              │
  │  ─────────────────────────→    │                              │
  │                                │                              │
  │                                │  读取红鸟输入                  │
  │                                │  计算新位置（含碰撞检测）       │
  │                                │  更新红鸟 REPLICATED 节点      │
  │                                │                              │
  │  ←── 自动同步红鸟位置 ────────  │  ──── 自动同步红鸟位置 ─────→  │
  │                                │                              │
  │  渲染红鸟（冒险世界皮肤）       │      渲染红鸟（灰色鸟皮肤）     │
  │                                │                              │
```

### 5.4 REPLICATED vs LOCAL 节点划分

```
服务器创建的节点（REPLICATED，同步给所有连接到同一 Scene 的客户端）
├── [PairId=1] Player_RED       (红鸟逻辑实体)
├── [PairId=1] Player_BLACK     (黑鸟逻辑实体)
├── [PairId=1] Platform_*       (平台/地形)
├── [PairId=1] Switch_A         (开关，Var: SwitchState)
├── [PairId=1] Door_01          (门，Var: DoorState)
└── ...

客户端创建的节点（LOCAL，各端独立，无 PairId）
├── Camera           (相机)
├── Light            (光源)
└── ...（NanoVG 渲染不需要场景节点）
```

> **注意**：因为共享 Scene，所有配对的 REPLICATED 节点会同步到所有客户端。客户端通过 `BelongsToMyPair()` 过滤，只处理和渲染属于自己配对的节点，忽略其他配对的节点。

---

## 6. 关键实现细节

### 6.1 角色选择流程

配对成功后进入 `selecting` 状态。双方各自选择红鸟或黑鸟：

1. 客户端发送 `CHARACTER_PICK { Role = "red" }`
2. 服务器验证合法性，检测冲突（双方选了相同角色）
3. 服务器广播 `CHARACTER_RESULT` 给双方（含 MyRole、PartnerRole、Conflict、Confirmed）
4. 双方都选好且不冲突 → `Confirmed = true` → 自动进入游戏

### 6.2 双世界渲染（客户端）

客户端使用 NanoVG 渲染。同一个 REPLICATED 节点，红鸟玩家和黑鸟玩家看到不同的视觉效果：

- 红鸟玩家看到"冒险世界"（明亮、温暖的色调）
- 黑鸟玩家看到"求生世界"（阴暗、冷色调）
- 对方玩家始终显示为灰色鸟

### 6.3 输入同步

```lua
-- Client.lua: 每帧通过 controls.buttons 发送输入
-- 持续按键: MOVE_LEFT / MOVE_RIGHT（GetKeyDown）
-- 脉冲按键: JUMP / INTERACT（GetKeyPress，走 reliable 通道）
connection.controls.buttons = buttons

-- Server.lua: 每帧读取并处理
local buttons = connection.controls.buttons
if (buttons & Shared.CTRL.MOVE_LEFT) ~= 0 then ... end
if (buttons & Shared.CTRL.JUMP) ~= 0 then ... end  -- 脉冲，只触发一帧
```

### 6.4 客户端初始化时序（persistent_world）

persistent_world 模式下，客户端启动时服务器连接可能已经就绪，也可能尚未建立。
客户端通过 `HandleServerReady` 事件兜底处理后者情况。

```lua
function Start()
    Shared.RegisterClientEvents()
    BuildConnectingUI()
    -- 订阅所有远程事件...
    DoConnect()
    if not connected_ then
        SubscribeToEvent("ServerReady", "HandleServerReady")
    end
end

function DoConnect()
    local conn = network:GetServerConnection()
    if not conn then return end
    serverConn_ = conn
    connected_ = true
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    conn.scene = scene_
    local data = VariantMap()
    serverConn_:SendRemoteEvent(Shared.EVENTS.CLIENT_READY, true, data)
end
```

### 6.5 单人调试模式（DebugSolo）

支持单人测试：客户端发送 `DEBUG_SOLO` → 服务器创建虚拟双人游戏（红鸟受控，黑鸟 connection=nil 静止）。可通过 `DEBUG_SWITCH` 切换控制角色。

服务器用 `soloInstances_` 追踪单人实例，交换 connection 实现角色切换。

### 6.6 客户端状态机

```
  CONNECTING ──(DoConnect)──→ 等待 PLAYER_INFO
       │
  STATE_LOBBY ──(输入短码, 点击配对)──→ STATE_PAIRING
       │                                    │
       │                              PAIR_RESULT
       │                              ├── 失败 → STATE_LOBBY（显示错误）
       │                              └── 成功 → STATE_PAIRED
       │                                           │
       │                                     ENTER_SELECT
       │                                           │
       │                                     STATE_SELECTING ──(确认)──→ STATE_PLAYING
       │
  任何已配对状态 ──(PARTNER_LEFT)──→ STATE_LOBBY
```

---

## 7. 好友码配对（核心功能 · 已实现）

### 7.1 方案概述

采用 **persistent_world + 服务器内部短码配对**方案：

- **好友码 = 5 位随机短码**：每次玩家连入服务器时动态生成（如 `38472`），简短好记
- **服务器内部查找**：通过 `shortCodeIndex_[code] → connKey` 直接查找目标玩家
- **无需 Cloud API**：配对完全在服务器内存中完成，无外部依赖，零延迟
- **断线后重新分配**：玩家断线后短码释放，重连时获得新短码

### 7.2 短码生成

```lua
-- Server.lua
local shortCodeIndex_ = {}  -- 短码 → connKey

local function GenerateShortCode()
    for _ = 1, 100 do
        local code = tostring(math.random(10000, 99999))
        if not shortCodeIndex_[code] then
            return code
        end
    end
    return tostring(math.random(100000, 999999))  -- 极端情况 fallback 6 位
end
```

### 7.3 配对验证链

```
客户端发送 PairRequest { TargetUserId = "38472" }
  ↓
服务器验证链：
  ├── 空/无效 ID          → PAIR_FAIL: invalid_id
  ├── 等于自己的短码        → PAIR_FAIL: self_pair
  ├── 自己已配对           → PAIR_FAIL: already_paired
  ├── 目标不在 shortCodeIndex_ → PAIR_FAIL: target_offline
  ├── 目标已配对           → PAIR_FAIL: target_paired
  └── 全部通过 → DoPair()
```

### 7.4 优势与限制

**优势**：
- 零延迟配对：服务器内存查表
- 短码好记：5 位数字，比 10 位 userId 更友好
- 实现简单：无外部依赖

**限制**：
1. **短码临时性**：每次连接分配新码，不可持久使用（但双人合作游戏通常面对面/语音沟通，不需要持久码）
2. **无快速匹配**：当前只支持好友码配对，不支持随机匹配（可后续添加）

---

## 8. 断线处理

### 8.1 场景分析

| 场景 | 服务器行为 | 客户端行为 |
|------|----------|----------|
| 玩家 B 断线 | `DoUnpair()` 清理配对、销毁游戏节点 | 玩家 A 收到 `PARTNER_LEFT(disconnected)`，回到大厅 |
| 玩家 A 断线 | 同上 | 玩家 B 收到 `PARTNER_LEFT(disconnected)`，回到大厅 |
| 双方都断线 | 分别触发 `HandleClientDisconnected`，清理各自数据 | — |

### 8.2 断线清理流程

```lua
-- Server.lua: HandleClientDisconnected
function HandleClientDisconnected(eventType, eventData)
    local connKey = GetConnKey(connection)
    local p = players_[connKey]
    -- 如果在配对中 → 通知搭档 + 拆对 + 销毁游戏节点
    if p.state == "selecting" or p.state == "playing" then
        DoUnpair(connKey, Shared.LEAVE_REASON.DISCONNECTED, true)
    end
    -- 清理短码索引
    shortCodeIndex_[p.shortCode] = nil
    players_[connKey] = nil
end
```

### 8.3 进度保存（待实现）

使用 `serverCloud` 在存档点保存进度：

```lua
function OnCheckpointReached(checkpointId)
    serverCloud.Set("game_progress", {
        checkpoint = checkpointId,
        puzzle_states = GetAllPuzzleStates(),
    })
end
```

---

## 9. 同步时序图

### 9.1 开关谜题完整时序

```
客户端 A (悲观方·黑鸟)           服务器                     客户端 B (冒险方·红鸟)
  │                              │                              │
  │  按 E (拉下开关A)             │                              │
  │  controls.buttons |= INTERACT│                              │
  │  ──────────────────────────→ │                              │
  │                              │                              │
  │                              │  验证：                       │
  │                              │  - 黑鸟在开关A附近 ✅         │
  │                              │  - 开关A 可由 pessimist 操作 ✅│
  │                              │                              │
  │                              │  执行：                       │
  │                              │  switchA.SetVar(State, 1)    │
  │                              │  door01.SetVar(State, 1=half)│
  │                              │                              │
  │  ←── Var 自动同步 ───────────│───── Var 自动同步 ──────────→ │
  │                              │                              │
  │  本地渲染：                   │                              │
  │  拉杆动画 → 铁栅栏门半开      │     花蕊按钮无变化              │
  │                              │     花藤拱门半开                │
```

---

## 10. 技术要点清单

### 10.1 服务器端

| 要点 | 说明 |
|------|------|
| **权威计算** | 所有位置更新、碰撞检测、谜题验证都在服务器执行 |
| **PulseButtonMask** | `JUMP` 和 `INTERACT` 设为脉冲按键，走 reliable 通道 |
| **PairId 隔离** | 所有 REPLICATED 节点必须带 PairId 变量 |
| **全局碰撞路由** | `PhysicsBeginContact2D` 全局订阅，ServerGame 通过 PairId 分派 |
| **共享物理世界** | lobbyScene_ 上一个 PhysicsWorld2D，所有配对共用 |

### 10.2 客户端

| 要点 | 说明 |
|------|------|
| **PairId 过滤** | `BelongsToMyPair()` 在节点遍历、相机、渲染等所有路径调用 |
| **全部 LOCAL** | 客户端创建的所有节点和组件必须显式指定 `LOCAL` |
| **禁用客户端物理** | `PhysicsWorld2D.updateEnabled = false`，避免客户端独立运行 Box2D 产生 NaN |
| **相机直接跟随** | 不加额外 lerp，避免与 SmoothedTransform 冲突导致抖动 |

### 10.3 同步数据量估算

| 数据 | 每帧字节数 | 说明 |
|------|----------|------|
| 玩家位置 (×2) | ~24 bytes | Vector3 × 2 |
| 玩家输入 (×2) | ~12 bytes | yaw + buttons × 2 |
| 机关状态变化 | ~20 bytes | 仅事件触发时 |
| **合计（稳态）** | **~36 bytes/帧** | 极低带宽需求 |

---

## 11. 实现优先级

```
P0 (核心 · 已实现)
├── persistent_world 常驻服连接
├── 5 位短码配对（服务器内部 shortCodeIndex_ 查找）
├── 大厅 UI（好友码展示 + 输入配对 + Toast 提示）
├── 配对验证（5 项检查：invalid_id / self_pair / already_paired / target_offline / target_paired）
├── 角色选择 UI（红鸟 / 黑鸟，互斥选择）
├── 解除配对 + 搭档离开通知
├── 共享 Scene + PairId 节点变量隔离
├── 客户端 BelongsToMyPair() 节点过滤
└── 单人调试模式（DebugSolo + 角色切换）

P1 (下一步)
├── 断线重连（当前断线直接拆对回大厅）
├── 存档点进度保存（serverCloud）
├── 网络延迟显示（RTT）
└── 随机匹配（无好友码，自动配对）

P2 (可选)
└── 观战模式
```

---

## 附录 A：配置文件模板

### .project/project.json

```json
{
  "$schema": "../ai-dev-kit/schemas/project.schema.json",
  "project_id": "p_d8ld",
  "author": { "id": "1208546298" },
  "entry": "Network/Client.lua",
  "entry@client": "Network/Client.lua",
  "entry@server": "Network/Server.lua",

  "taptap_publish": {
    "title": "同途 Parallax",
    "category": "adventure",
    "screen_orientation": "landscape"
  }
}
```

### .project/settings.json（由构建工具管理）

```json
{
  "@runtime": {
    "multiplayer": {
      "enabled": true,
      "max_players": 100,
      "background_match": false,
      "persistent_world": {
        "enabled": true
      }
    }
  }
}
```

> **注意**：不要同时启用 `match_info` 和 `persistent_world`，否则 `match_info.player_number` 会导致平台将玩家分配到不同服务器实例，使得服务器内部的 `shortCodeIndex_` 查找失败。

---

## 附录 B：踩坑记录

### 踩坑 #1: 独立 Scene 隔离方案（失败）

**时间**：PairId 方案之前的第一版实现

**方案描述**：

最初的隔离方案是为每对配对创建独立的 `Scene()`，将双方的 `connection.scene` 切换到新 Scene：

```lua
-- 失败方案的代码（已移除）
local function DoPair(connKeyA, connKeyB)
    local gameScene = Scene()
    gameScene:CreateComponent("Octree")

    -- 将两名玩家切换到独立游戏场景
    pA.connection.scene = gameScene   -- ← 问题根源
    pB.connection.scene = gameScene
    -- 在 gameScene 中创建 REPLICATED 节点...
end
```

**期望效果**：不同 Scene 的 REPLICATED 节点互不同步，天然实现隔离。

**实际结果**：服务器 `connection.scene = gameScene` 后，客户端看不到任何 REPLICATED 节点。场景为空，所有实体消失。

**根因分析**：

UrhoX 的 Scene Replication 机制：
1. 客户端在 `DoConnect()` 时创建 `scene_ = Scene()` 并设置 `conn.scene = scene_`
2. 服务器向 connection 同步节点时，节点被复制到 **connection 当前关联的 Scene**
3. 但客户端的 `scene_` 引用（用于 Viewport、渲染、业务逻辑）始终指向 `DoConnect()` 时创建的那个 Scene
4. 当服务器把 `connection.scene` 切换到新 gameScene 时：
   - 服务器的新 REPLICATED 节点同步到了 gameScene 对应的客户端 Scene **副本**
   - 但客户端代码仍然在读取旧的 `scene_` → 看到的是空场景

```
服务器                                 客户端
  │                                      │
  │  lobbyScene_ (connection.scene)      │  scene_ = Scene() (DoConnect时创建)
  │          ↕ 同步                       │      ↕ 渲染/逻辑代码引用
  │                                      │
  │  ── DoPair: connection.scene = gameScene ──→
  │                                      │
  │  gameScene (新 connection.scene)      │  ??? (新同步目标，但客户端不知道)
  │  ├── Player_A (REPLICATED)           │      × 客户端代码仍读 scene_
  │  └── Player_B (REPLICATED)           │      → 什么都看不到
  │                                      │
  │                                      │  scene_ (仍指向旧 Scene)
  │                                      │      → 空，无任何节点
```

**核心矛盾**：服务器可以切换 `connection.scene`，但客户端无法感知这个切换，也无法获取到新 Scene 的本地引用。

**解决方案**：放弃独立 Scene，改用共享 Scene + PairId 节点变量隔离（即当前方案）。所有配对共用 `lobbyScene_`，通过节点变量 `PairId` 标记归属，客户端用 `BelongsToMyPair()` 过滤。

**教训**：
1. UrhoX 的 Scene Replication 不支持服务端单方面切换 `connection.scene` 后客户端自动跟随
2. 隔离需要在应用层实现（节点变量过滤），而非依赖引擎层（独立 Scene）
3. 共享 Scene 虽然所有节点对所有客户端可见，但通过 PairId 过滤后效果等价于隔离

---

*最后更新: 2025-05（PairId 隔离方案 + 5 位短码）*
