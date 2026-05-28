--- Network/Client.lua
--- 《视差 / Parallax》正式版客户端
--- 大厅 UI（好友码展示 + 输入配对）+ 游戏占位

local Shared = require("Network.Shared")
local UI = require("urhox-libs/UI")
local CharSelectUI = require("UI.CharSelectUI")
local ClientGame = require("Game.ClientGame")
local GameConst = require("Game.GameConst")

-- ─── 客户端状态 ───
local STATE_CONNECTING = "connecting"
local STATE_LOBBY      = "lobby"
local STATE_PAIRING    = "pairing"
local STATE_PAIRED     = "paired"
local STATE_SELECTING  = "selecting"
local STATE_PLAYING    = "playing"

---@type string
local state_ = STATE_CONNECTING

-- ─── 网络 ───
---@type Connection
local serverConn_ = nil
---@type Scene
local scene_ = nil
local connected_ = false

-- ─── 数据 ───
local myUserId_ = ""           -- 自己的好友码
local partnerUserId_ = ""      -- 搭档的好友码
local inputValue_ = ""         -- 输入框当前值
local myRole_ = ""             -- 我的角色
local partnerRole_ = ""        -- 搭档的角色
local debugSolo_ = false       -- 单人调试模式
local myPairId_ = 0            -- 当前配对 ID（用于过滤场景节点）

-- ═══════════════════════════════════════════════
-- 大厅烟雾粒子效果（NanoVG）
-- ═══════════════════════════════════════════════

local smokeVg_ = nil          -- NanoVG 上下文
local smokeParticles_ = {}    -- 粒子列表
local smokeActive_ = false    -- 是否活跃
local SMOKE_MAX = 40          -- 最大粒子数
local smokeTimer_ = 0         -- 生成计时

--- 创建一个烟雾粒子
local function CreateSmokeParticle(w, h)
    local baseY = h + math.random(5, 30)
    return {
        x    = math.random() * w,
        y    = baseY,
        vx   = (math.random() - 0.5) * 15,   -- 水平漂移
        vy   = -(10 + math.random() * 20),    -- 向上飘
        r    = 20 + math.random() * 40,        -- 半径
        life = 3.0 + math.random() * 3.0,      -- 总寿命
        maxLife = 0,                            -- 填入 = life
        alpha = 0.15 + math.random() * 0.15,   -- 最大透明度
    }
end

--- 启动烟雾效果
function StartLobbySmoke()
    if smokeActive_ then return end
    smokeActive_ = true
    smokeParticles_ = {}
    smokeTimer_ = 0

    -- 创建 NanoVG 上下文（如未创建）
    if not smokeVg_ then
        smokeVg_ = nvgCreate(0)
        if not smokeVg_ then
            print("[Client] WARN: nvgCreate failed for smoke")
            smokeActive_ = false
            return
        end
    end

    -- 预生成一批粒子
    local gfx = GetGraphics()
    local dpr = gfx:GetDPR()
    local w = gfx:GetWidth() / dpr
    local h = gfx:GetHeight() / dpr
    for i = 1, math.floor(SMOKE_MAX * 0.6) do
        local p = CreateSmokeParticle(w, h)
        p.y = h - math.random() * (h * 0.35)  -- 分散在底部 35%
        p.life = math.random() * p.life         -- 随机初始生命
        p.maxLife = p.life
        smokeParticles_[#smokeParticles_ + 1] = p
    end

    SubscribeToEvent("Update", "HandleSmokeUpdate")
    SubscribeToEvent(smokeVg_, "NanoVGRender", "HandleSmokeRender")
end

--- 停止烟雾效果
function StopLobbySmoke()
    if not smokeActive_ then return end
    smokeActive_ = false
    if smokeVg_ then
        UnsubscribeFromEvent(smokeVg_, "NanoVGRender")
    end
    UnsubscribeFromEvent("Update")  -- 注意：只有大厅用 Update，进入游戏后由 ClientGame 管理
    smokeParticles_ = {}
end

--- 更新烟雾粒子
function HandleSmokeUpdate(eventType, eventData)
    if not smokeActive_ then return end
    local dt = eventData["TimeStep"]:GetFloat()

    local gfx = GetGraphics()
    local dpr = gfx:GetDPR()
    local w = gfx:GetWidth() / dpr
    local h = gfx:GetHeight() / dpr

    -- 更新已有粒子
    local alive = {}
    for _, p in ipairs(smokeParticles_) do
        p.life = p.life - dt
        if p.life > 0 then
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            -- 缓慢扩大
            p.r = p.r + dt * 3
            alive[#alive + 1] = p
        end
    end
    smokeParticles_ = alive

    -- 定期生成新粒子
    smokeTimer_ = smokeTimer_ + dt
    local spawnInterval = 0.12
    while smokeTimer_ >= spawnInterval and #smokeParticles_ < SMOKE_MAX do
        smokeTimer_ = smokeTimer_ - spawnInterval
        local p = CreateSmokeParticle(w, h)
        p.maxLife = p.life
        smokeParticles_[#smokeParticles_ + 1] = p
    end
end

--- 渲染烟雾粒子
function HandleSmokeRender(eventType, eventData)
    if not smokeActive_ or not smokeVg_ then return end

    local gfx = GetGraphics()
    local dpr = gfx:GetDPR()
    local w = gfx:GetWidth() / dpr
    local h = gfx:GetHeight() / dpr

    nvgBeginFrame(smokeVg_, w, h, dpr)

    for _, p in ipairs(smokeParticles_) do
        -- 淡入淡出
        local lifeRatio = p.life / p.maxLife
        local fadeIn  = math.min(1.0, (1.0 - lifeRatio) * 4.0)  -- 前 25% 淡入
        local fadeOut = math.min(1.0, lifeRatio * 3.0)            -- 后 33% 淡出
        local a = p.alpha * fadeIn * fadeOut

        if a > 0.005 then
            -- 径向渐变：中心微亮 → 边缘全透明
            local cx, cy = p.x, p.y
            local innerR = p.r * 0.1
            local outerR = p.r
            local innerA = math.floor(a * 255)
            local outerA = 0

            local paint = nvgRadialGradient(smokeVg_, cx, cy, innerR, outerR,
                nvgRGBA(140, 150, 200, innerA),
                nvgRGBA(100, 110, 160, outerA))

            nvgBeginPath(smokeVg_)
            nvgCircle(smokeVg_, cx, cy, outerR)
            nvgFillPaint(smokeVg_, paint)
            nvgFill(smokeVg_)
        end
    end

    nvgEndFrame(smokeVg_)
end

-- ─── 错误原因中文映射 ───
local FAIL_MESSAGES = {
    [Shared.PAIR_FAIL.SELF_PAIR]      = "不能和自己配对哦",
    [Shared.PAIR_FAIL.ALREADY_PAIRED] = "你已经在游戏中了",
    [Shared.PAIR_FAIL.TARGET_OFFLINE] = "对方不在线",
    [Shared.PAIR_FAIL.TARGET_PAIRED]  = "对方已在游戏中",
    [Shared.PAIR_FAIL.INVALID_ID]     = "无效的好友码",
}

local LEAVE_MESSAGES = {
    [Shared.LEAVE_REASON.DISCONNECTED] = "搭档已断线",
    [Shared.LEAVE_REASON.UNPAIRED]     = "搭档退出了游戏",
}

-- ═══════════════════════════════════════════════
-- UI 构建
-- ═══════════════════════════════════════════════

--- 连接中画面
local function BuildConnectingUI()
    local root = UI.Panel {
        width = "100%", height = "100%",
        flexDirection = "column",
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 12, 10, 24, 255 },
        children = {
            UI.Label {
                text = "视 差",
                fontSize = 42,
                fontWeight = "bold",
                fontColor = { 200, 210, 255, 255 },
                marginBottom = 6,
            },
            UI.Label {
                text = "P A R A L L A X",
                fontSize = 12,
                fontColor = { 100, 110, 160, 200 },
                marginBottom = 32,
            },
            UI.Label {
                text = "连接服务器中...",
                fontSize = 15,
                fontColor = { 100, 100, 140, 255 },
            },
        },
    }
    UI.SetRoot(root)
end

--- 大厅画面：展示好友码 + 输入框 + 配对按钮
local function BuildLobbyUI()
    -- 启动烟雾效果
    StartLobbySmoke()

    local root = UI.Panel {
        width = "100%", height = "100%",
        flexDirection = "column",
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 12, 10, 24, 255 },
        children = {
            -- ── 标题区 ──
            UI.Label {
                text = "视 差",
                fontSize = 42,
                fontWeight = "bold",
                fontColor = { 200, 210, 255, 255 },
                marginBottom = 4,
            },
            UI.Label {
                text = "P A R A L L A X",
                fontSize = 11,
                fontColor = { 100, 110, 160, 180 },
                marginBottom = 32,
            },

            -- ── 好友码展示卡片 ──
            UI.Panel {
                flexDirection = "column",
                alignItems = "center",
                paddingTop = 18, paddingBottom = 18,
                paddingLeft = 36, paddingRight = 36,
                marginBottom = 24,
                backgroundColor = { 22, 24, 44, 220 },
                borderRadius = 14,
                borderWidth = 1,
                borderColor = { 60, 65, 110, 120 },
                children = {
                    UI.Label {
                        text = "你的好友码",
                        fontSize = 12,
                        fontColor = { 110, 115, 150, 255 },
                        marginBottom = 8,
                    },
                    UI.Label {
                        text = myUserId_,
                        fontSize = 28,
                        fontWeight = "bold",
                        fontColor = { 80, 220, 170, 255 },
                        marginBottom = 6,
                    },
                    UI.Label {
                        text = "让搭档输入此码来配对",
                        fontSize = 10,
                        fontColor = { 80, 80, 110, 200 },
                    },
                },
            },

            -- ── 分隔装饰 ──
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "center",
                marginBottom = 22,
                children = {
                    UI.Panel { width = 60, height = 1, backgroundColor = { 50, 50, 85, 150 } },
                    UI.Label {
                        text = "  或输入搭档码  ",
                        fontSize = 10,
                        fontColor = { 80, 80, 115, 200 },
                    },
                    UI.Panel { width = 60, height = 1, backgroundColor = { 50, 50, 85, 150 } },
                },
            },

            -- ── 配对输入区 ──
            UI.TextField {
                value = "",
                placeholder = "输入好友码...",
                fontSize = 17,
                width = 280,
                marginBottom = 14,
                onChange = function(self, value)
                    inputValue_ = value
                end,
                onSubmit = function(self, value)
                    inputValue_ = value
                    OnPairButtonClick()
                end,
            },
            UI.Button {
                text = "开始配对",
                variant = "primary",
                width = 280,
                fontSize = 16,
                paddingTop = 10, paddingBottom = 10,
                onClick = function(self)
                    OnPairButtonClick()
                end,
            },

            -- ── 单人调试区 ──
            UI.Panel {
                width = 180, height = 1,
                backgroundColor = { 40, 40, 70, 100 },
                marginTop = 28, marginBottom = 14,
            },
            UI.Button {
                text = "单人测试",
                variant = "secondary",
                width = 200,
                fontSize = 13,
                onClick = function(self)
                    OnDebugSoloClick()
                end,
            },
            UI.Label {
                text = "Tab 切换视角",
                fontSize = 10,
                fontColor = { 70, 70, 100, 180 },
                marginTop = 5,
            },
        },
    }
    UI.SetRoot(root)
end

--- 配对等待画面
local function BuildPairingUI()
    StopLobbySmoke()
    local root = UI.Panel {
        width = "100%", height = "100%",
        flexDirection = "column",
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 12, 10, 24, 255 },
        children = {
            UI.Label {
                text = "配对中...",
                fontSize = 22,
                fontWeight = "bold",
                fontColor = { 180, 190, 255, 255 },
                marginBottom = 12,
            },
            UI.Label {
                text = "目标好友码: " .. inputValue_,
                fontSize = 14,
                fontColor = { 100, 100, 140, 255 },
            },
        },
    }
    UI.SetRoot(root)
end

--- 角色选择画面（通过 CharSelectUI 模块）
local function BuildSelectingUI()
    CharSelectUI.Show(function(role)
        if role == nil then
            -- 返回大厅
            OnUnpairButtonClick()
            return
        end
        -- 发送角色选择给服务器
        if serverConn_ then
            local data = VariantMap()
            data["Role"] = Variant(role)
            serverConn_:SendRemoteEvent(Shared.EVENTS.CHARACTER_PICK, true, data)
            print("[Client] CharacterPick → " .. role)
        end
    end)
end

--- 游戏进行画面：清除 UI，让 ClientGame（NanoVG）接管渲染
local function BuildPlayingUI()
    -- 清空 UI 根节点，NanoVG 渲染全屏游戏画面
    UI.SetRoot(nil)

    -- 初始化 ClientGame（NanoVG + 输入 + 相机）
    if scene_ and serverConn_ then
        ClientGame.Init(scene_, serverConn_, myRole_, myPairId_)
        ClientGame.SetDebugSolo(debugSolo_)
    end
end

-- ═══════════════════════════════════════════════
-- 状态机
-- ═══════════════════════════════════════════════

---@param newState string
local function SetState(newState)
    local oldState = state_
    state_ = newState
    print("[Client] State → " .. newState)

    -- 离开 lobby 状态时停止烟雾
    if oldState == STATE_LOBBY and newState ~= STATE_LOBBY then
        StopLobbySmoke()
    end

    -- 离开 selecting 状态时隐藏选择 UI
    if oldState == STATE_SELECTING and newState ~= STATE_SELECTING then
        CharSelectUI.Hide()
    end

    -- 离开 playing 状态时销毁 ClientGame
    if oldState == STATE_PLAYING and newState ~= STATE_PLAYING then
        ClientGame.Destroy()
    end

    if newState == STATE_CONNECTING then
        BuildConnectingUI()
    elseif newState == STATE_LOBBY then
        BuildLobbyUI()
    elseif newState == STATE_PAIRING then
        BuildPairingUI()
    elseif newState == STATE_PAIRED then
        -- 配对成功后立即跳转到 selecting（等待服务器 ENTER_SELECT）
        -- 先显示一个过渡
        BuildPairingUI()
    elseif newState == STATE_SELECTING then
        BuildSelectingUI()
    elseif newState == STATE_PLAYING then
        BuildPlayingUI()
    end
end

-- ═══════════════════════════════════════════════
-- 按钮事件（全局函数，闭包可引用）
-- ═══════════════════════════════════════════════

function OnPairButtonClick()
    if state_ ~= STATE_LOBBY then return end
    if not serverConn_ then return end

    local targetId = inputValue_
    if not targetId or targetId == "" then
        UI.Toast.Show("请输入好友码", { variant = "warning" })
        return
    end

    -- 发送配对请求
    local data = VariantMap()
    data["TargetUserId"] = Variant(targetId)
    serverConn_:SendRemoteEvent(Shared.EVENTS.PAIR_REQUEST, true, data)

    SetState(STATE_PAIRING)
    print("[Client] PairRequest → target=" .. targetId)
end

function OnDebugSoloClick()
    if state_ ~= STATE_LOBBY then return end
    if not serverConn_ then return end

    serverConn_:SendRemoteEvent(Shared.EVENTS.DEBUG_SOLO, true)
    print("[Client] DebugSolo request sent")
end

function OnUnpairButtonClick()
    if state_ ~= STATE_PAIRED and state_ ~= STATE_SELECTING and state_ ~= STATE_PLAYING then return end
    if not serverConn_ then return end

    serverConn_:SendRemoteEvent(Shared.EVENTS.UNPAIR_REQUEST, true)
    partnerUserId_ = ""
    myRole_ = ""
    partnerRole_ = ""
    debugSolo_ = false
    myPairId_ = 0
    SetState(STATE_LOBBY)
    print("[Client] UnpairRequest sent")
end

-- ═══════════════════════════════════════════════
-- 网络连接（persistent_world 模式）
-- ═══════════════════════════════════════════════

local function DoConnect()
    if connected_ then return end

    serverConn_ = network:GetServerConnection()
    if not serverConn_ then
        print("[Client] serverConnection nil, waiting for ServerReady")
        return
    end

    connected_ = true

    -- 创建本地 Scene 接收同步数据
    scene_ = Scene()
    scene_:CreateComponent("Octree")

    -- 关键步骤 1：设置场景（必须在发送 ClientReady 之前）
    serverConn_.scene = scene_

    -- 关键步骤 2：通知服务器就绪
    serverConn_:SendRemoteEvent(Shared.EVENTS.CLIENT_READY, true)

    print("[Client] Connected → scene set, ClientReady sent")
end

-- ═══════════════════════════════════════════════
-- 生命周期
-- ═══════════════════════════════════════════════

function Start()
    print("[Client] ======= Parallax Client =======")

    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/ZhuLangCreative.otf",
                bold   = "Fonts/ZhuLangCreative.otf",
            } },
        },
        scale = UI.Scale.DESIGN_RESOLUTION(GameConst.DESIGN_WIDTH, GameConst.DESIGN_HEIGHT),
    })

    -- 注册远程事件
    Shared.RegisterClientEvents()

    -- 订阅服务器事件
    SubscribeToEvent(Shared.EVENTS.PLAYER_INFO, "HandlePlayerInfo")
    SubscribeToEvent(Shared.EVENTS.PAIR_RESULT, "HandlePairResult")
    SubscribeToEvent(Shared.EVENTS.PARTNER_LEFT, "HandlePartnerLeft")
    SubscribeToEvent(Shared.EVENTS.ENTER_SELECT, "HandleEnterSelect")
    SubscribeToEvent(Shared.EVENTS.CHARACTER_RESULT, "HandleCharacterResult")
    SubscribeToEvent(Shared.EVENTS.ENTER_GAME, "HandleEnterGame")
    SubscribeToEvent(Shared.EVENTS.DEBUG_SWITCHED, "HandleDebugSwitched")
    SubscribeToEvent(Shared.EVENTS.GAME_EVENT, "HandleGameEvent")
    SubscribeToEvent(Shared.EVENTS.SCENE_CHANGE, "HandleSceneChange")
    SubscribeToEvent("ServerDisconnected", "HandleServerDisconnected")

    -- 初始状态
    SetState(STATE_CONNECTING)

    -- persistent_world: 脚本加载时连接可能已建立
    DoConnect()
    if not connected_ then
        SubscribeToEvent("ServerReady", "HandleServerReady")
        print("[Client] Waiting for ServerReady (fallback)...")
    end
end

-- ─── 网络事件处理 ───

function HandleServerReady(eventType, eventData)
    print("[Client] ServerReady event received")
    DoConnect()
end

--- 收到自己的 userId（好友码）
function HandlePlayerInfo(eventType, eventData)
    myUserId_ = eventData["UserId"]:GetString()
    print("[Client] My friend code: " .. myUserId_)
    SetState(STATE_LOBBY)
end

--- 收到配对结果
function HandlePairResult(eventType, eventData)
    local success = eventData["Success"]:GetBool()

    if success then
        partnerUserId_ = eventData["PartnerUserId"]:GetString()
        print("[Client] Paired with: " .. partnerUserId_)
        SetState(STATE_PAIRED)
    else
        local reason = eventData["Reason"]:GetString()
        local msg = FAIL_MESSAGES[reason] or ("配对失败: " .. reason)
        print("[Client] Pair failed: " .. reason)
        UI.Toast.Show(msg, { variant = "error", duration = 3 })
        SetState(STATE_LOBBY)
    end
end

--- 搭档离开
function HandlePartnerLeft(eventType, eventData)
    local reason = eventData["Reason"]:GetString()
    local msg = LEAVE_MESSAGES[reason] or "搭档已离开"
    print("[Client] Partner left: " .. reason)
    partnerUserId_ = ""
    myRole_ = ""
    partnerRole_ = ""
    myPairId_ = 0
    UI.Toast.Show(msg, { variant = "warning", duration = 3 })
    SetState(STATE_LOBBY)
end

--- 进入角色选择阶段
function HandleEnterSelect(eventType, eventData)
    print("[Client] EnterSelect received")
    SetState(STATE_SELECTING)
end

--- 角色选择状态更新
function HandleCharacterResult(eventType, eventData)
    local myR = eventData["MyRole"]:GetString()
    local partnerR = eventData["PartnerRole"]:GetString()
    local isConflict = eventData["Conflict"]:GetBool()
    local isConfirmed = eventData["Confirmed"]:GetBool()

    print(string.format("[Client] CharResult: me=%s partner=%s conflict=%s confirmed=%s",
        myR, partnerR, tostring(isConflict), tostring(isConfirmed)))

    -- 更新 CharSelectUI
    if state_ == STATE_SELECTING then
        CharSelectUI.UpdateState(myR, partnerR, isConflict, isConfirmed)
    end
end

--- 双方确认，进入游戏
function HandleEnterGame(eventType, eventData)
    myRole_ = eventData["MyRole"]:GetString()
    partnerRole_ = eventData["PartnerRole"]:GetString()

    -- 检查是否为单人调试模式
    local soloVar = eventData["DebugSolo"]
    debugSolo_ = soloVar and not soloVar:IsEmpty() and soloVar:GetBool() or false

    -- 读取 PairId（多对玩家共享场景时用于过滤节点）
    local pairIdVar = eventData["PairId"]
    myPairId_ = (pairIdVar and not pairIdVar:IsEmpty()) and pairIdVar:GetInt() or 0

    print(string.format("[Client] EnterGame! me=%s partner=%s solo=%s pairId=%d",
        myRole_, partnerRole_, tostring(debugSolo_), myPairId_))
    SetState(STATE_PLAYING)
end

--- 单人调试：服务端确认视角已切换
function HandleDebugSwitched(eventType, eventData)
    local newRole = eventData["NewRole"]:GetString()
    print("[Client] DebugSwitched → " .. newRole)
    myRole_ = newRole
    ClientGame.SetRole(newRole)
end

--- 场景切换通知
function HandleSceneChange(eventType, eventData)
    if state_ ~= STATE_PLAYING then return end
    ClientGame.OnSceneChange(eventData)
end

--- 通用游戏事件（对话、道具等）
function HandleGameEvent(eventType, eventData)
    if state_ ~= STATE_PLAYING then return end
    ClientGame.OnGameEvent(eventData)
end

--- 服务器断线
function HandleServerDisconnected(eventType, eventData)
    print("[Client] Server disconnected!")
    serverConn_ = nil
    connected_ = false
    myRole_ = ""
    partnerRole_ = ""
    partnerUserId_ = ""
    myPairId_ = 0
    UI.Toast.Show("与服务器断开连接", { variant = "error", duration = 5 })
    SetState(STATE_CONNECTING)
end

function Stop()
    print("[Client] Stopping")
end
