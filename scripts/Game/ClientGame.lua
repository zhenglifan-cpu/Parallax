--- Game/ClientGame.lua
--- 《同途 / Parallax》客户端游戏逻辑
--- NanoVG 渲染、输入采集、相机跟随
--- 由 Client.lua 在 STATE_PLAYING 时驱动

local Shared        = require("Network.Shared")
local GameConst     = require("Game.GameConst")
local LevelData     = require("Game.LevelData")
local WorldRenderer = require("Render.WorldRenderer")
local MapEditor     = require("Editor.MapEditor")
local MapSerializer = require("Editor.MapSerializer")
local SlopePhysics  = require("Editor.SlopePhysics")

local VARS = Shared.VARS
local CTRL = Shared.CTRL

local ClientGame = {}

-- ─── 内部状态 ───
local vg_         = nil      -- NanoVG 上下文
local scene_      = nil      -- Scene 引用
local serverConn_ = nil      -- Connection 引用
local myRole_     = ""
local fontLoaded_ = false
local debugSolo_  = false    -- 单人调试模式
local pairId_     = 0        -- 当前配对 ID（多对玩家共享场景时过滤节点）

-- 相机（逻辑位置，NanoVG 用）
local camX_ = 0
local camY_ = 0

-- 对话系统
local dialogue_ = {
    active    = false,   -- 是否正在显示对话
    npcName   = "",      -- NPC 名字
    lines     = {},      -- 对话行列表
    lineIndex = 0,       -- 当前显示的行索引（1-based）
}

-- 头顶气泡（内心独白）
local bubble_ = {
    active   = false,
    text     = "",
    timer    = 0,        -- 剩余显示时间 (秒)
    duration = 0,        -- 总显示时间
}
local BUBBLE_BASE_DURATION = 3.0   -- 基础显示时间
local BUBBLE_PER_CHAR     = 0.08   -- 每个字符增加的时间
local BUBBLE_FADE_TIME    = 0.5    -- 淡出时间

-- 场景切换过渡
local transition_ = {
    active   = false,
    fadeIn   = true,     -- true=淡入（黑→透明），false=不用
    timer    = 0,
    duration = 0.8,      -- 淡入持续时间
    sceneName = "",      -- 新场景名
    sceneIdx  = 0,
}
local TRANSITION_FADE_DURATION = 0.8
local TRANSITION_HOLD_DURATION = 0.6   -- 全黑停留时间
local TRANSITION_TOTAL = TRANSITION_FADE_DURATION + TRANSITION_HOLD_DURATION + TRANSITION_FADE_DURATION

-- 当前场景索引 & 名称（用于小地图显示）
local curSceneIdx_  = 0
local curSceneName_ = "来信"

-- 屏幕文字 / 任务提示
local screenText_ = {
    active   = false,
    text     = "",
    timer    = 0,
    duration = 0,
}
local SCREEN_TEXT_BASE_DURATION = 4.0
local SCREEN_TEXT_PER_CHAR     = 0.06
local SCREEN_TEXT_FADE_TIME    = 0.8

-- 3D 相机节点（仅用于驱动渲染管线，不实际渲染 3D）
local cameraNode_ = nil

-- 屏幕尺寸
local screenW_ = 0    -- 屏幕逻辑宽度
local screenH_ = 0    -- 屏幕逻辑高度
local dpr_     = 1.0

-- 16:9 适配参数（CONTAIN 模式，黑边填充）
local designW_ = GameConst.DESIGN_WIDTH    -- 设计分辨率宽
local designH_ = GameConst.DESIGN_HEIGHT   -- 设计分辨率高
local viewScale_  = 1.0   -- 设计区域到屏幕的缩放比
local viewOffX_   = 0     -- 设计区域在屏幕上的 X 偏移（pillarbox 左侧黑边宽度）
local viewOffY_   = 0     -- 设计区域在屏幕上的 Y 偏移（letterbox 顶部黑边高度）

-- HUD
local sceneLabel_ = ""

-- ═══════════════════════════════════════════════
-- 16:9 适配计算
-- ═══════════════════════════════════════════════

--- 根据当前屏幕逻辑尺寸计算 CONTAIN 模式适配参数
local function UpdateViewFit()
    local scaleX = screenW_ / designW_
    local scaleY = screenH_ / designH_
    viewScale_ = math.min(scaleX, scaleY)
    viewOffX_ = (screenW_ - designW_ * viewScale_) * 0.5
    viewOffY_ = (screenH_ - designH_ * viewScale_) * 0.5
end

-- ═══════════════════════════════════════════════
-- PairId 过滤辅助
-- ═══════════════════════════════════════════════

--- 判断节点是否属于当前配对
---@param node Node
---@return boolean
local function BelongsToMyPair(node)
    if pairId_ <= 0 then return true end  -- 未设置 pairId 时不过滤
    local ok, pidVar = pcall(function() return node:GetVar(VARS.PAIR_ID) end)
    if ok and pidVar and type(pidVar.IsEmpty) == "function" and not pidVar:IsEmpty() then
        return pidVar:GetInt() == pairId_
    end
    return true  -- 没有 PairId 标记的节点不过滤（如 Camera 等 LOCAL 节点）
end

-- ═══════════════════════════════════════════════
-- 初始化 / 销毁
-- ═══════════════════════════════════════════════

--- 初始化客户端游戏
---@param scene Scene     服务端同步的场景
---@param connection Connection
---@param myRole string   "red" | "black"
---@param pairId number   当前配对 ID（用于过滤共享场景中的节点）
function ClientGame.Init(scene, connection, myRole, pairId)
    scene_      = scene
    serverConn_ = connection
    myRole_     = myRole
    pairId_     = pairId or 0
    camX_       = 0
    camY_       = GameConst.CAM_Y_OFFSET
    camSplit_   = false
    camBlend_   = 0.0

    -- ── 禁用客户端物理模拟 ──
    -- 服务端的 PhysicsWorld2D 通过 REPLICATED 同步到客户端后，客户端会独立运行 Box2D，
    -- 导致斜坡等几何体触发 NaN 并传播到所有动态体。客户端是纯渲染端，不需要本地物理。
    local pw2d = scene_:GetComponent("PhysicsWorld2D")
    if pw2d then
        pw2d.updateEnabled = false
        print("[ClientGame] Disabled client-side PhysicsWorld2D")
    end

    -- 创建 Camera + Viewport（驱动渲染管线，NanoVGRender 才会触发）
    if not cameraNode_ then
        cameraNode_ = scene_:CreateChild("GameCamera", LOCAL)
        local camera = cameraNode_:CreateComponent("Camera")
        camera.orthographic = true
        camera.orthoSize = 6
        renderer:SetViewport(0, Viewport:new(scene_, camera))
    end

    -- NanoVG 上下文
    if not vg_ then
        vg_ = nvgCreate(1)  -- 1 = antialias
    end

    -- 字体
    if not fontLoaded_ then
        nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
        nvgCreateFont(vg_, "ui",   "Fonts/ZhuLangCreative.otf")
        fontLoaded_ = true
    end

    -- 屏幕信息
    dpr_ = graphics:GetDPR()
    screenW_ = graphics:GetWidth() / dpr_
    screenH_ = graphics:GetHeight() / dpr_

    -- 加载编辑器保存的场景数据（优先于硬编码）
    LevelData.Init()

    -- 同步初始场景 0 的 groundOverlays 和 freeOverlays（游戏启动时默认 scene 0）
    do
        local initScene = LevelData.GetScene(0)
        WorldRenderer.SetSceneOverlays(initScene and initScene.groundOverlays or {})
        WorldRenderer.SetFreeOverlays(initScene and initScene.freeOverlays or {})
    end

    -- 初始化地图编辑器（仅 debugSolo 时可用）
    MapEditor.Init(vg_, function()
        return screenW_, screenH_, dpr_, viewScale_, viewOffX_, viewOffY_,
               designW_, designH_, camX_, camY_, curSceneIdx_
    end, function()
        -- 返回红鸟和黑鸟的实际世界坐标 { red={x,y}, black={x,y} }
        local result = {}
        if not scene_ then return result end
        local children = scene_:GetChildren(false)
        for i = 1, #children do
            local child = children[i]
            if child then
                local ok, etVar = pcall(function() return child:GetVar(VARS.ENTITY_TYPE) end)
                if ok and etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty()
                   and etVar:GetString() == "player" and BelongsToMyPair(child) then
                    local pos = child.position
                    local roleVar = child:GetVar(VARS.ROLE)
                    local role = (roleVar and not roleVar:IsEmpty()) and roleVar:GetString() or ""
                    if role == Shared.ROLE.RED then
                        result.red = { x = pos.x, y = pos.y }
                    elseif role == Shared.ROLE.BLACK then
                        result.black = { x = pos.x, y = pos.y }
                    end
                end
            end
        end
        return result
    end)

    -- 设置编辑器防抖同步回调（编辑操作后自动保存+重载）
    MapEditor.onSyncReload = function(scIdx)
        if serverConn_ then
            local sceneData = LevelData.GetSavedScene(scIdx)
            local data = VariantMap()
            data["SceneIdx"] = Variant(scIdx)
            if sceneData then
                local encOk, jsonStr = pcall(cjson.encode, sceneData)
                if not encOk then
                    print("[ClientGame] ERROR: cjson.encode failed in onSyncReload: " .. tostring(jsonStr))
                    return  -- 编码失败，中止同步，保持场景不变
                end
                data["SceneJson"] = Variant(jsonStr)
                -- 诊断：打印发送的 JSON 对象数量和大小
                local objCount = sceneData.objects and #sceneData.objects or 0
                print(string.format("[ClientGame][DIAG] onSyncReload: scene=%d, objects=%d, jsonLen=%d",
                    scIdx, objCount, #jsonStr))
            else
                print(string.format("[ClientGame][DIAG] onSyncReload: scene=%d, sceneData=NIL!", scIdx))
                return  -- 无数据，中止同步
            end
            serverConn_:SendRemoteEvent(Shared.EVENTS.DEBUG_RELOAD, true, data)
            print("[ClientGame] Auto-sync DEBUG_RELOAD for scene " .. scIdx)

            -- ── 客户端主动清理旧 REPLICATED 节点 ──
            -- 服务端 node:Remove() 对 REPLICATED 节点的删除不会传播到客户端,
            -- 因此每次 reload 后旧节点在客户端堆积。
            -- 这里在发送 DEBUG_RELOAD 后立即清理客户端侧的非 player 实体节点,
            -- 服务端 LoadLevel 创建的新 REPLICATED 节点会自动同步过来。
            if scene_ then
                local children = scene_:GetChildren(false)
                local cleaned = 0
                for i = #children, 1, -1 do
                    local c = children[i]
                    if c then
                        local ok2, et = pcall(function() return c:GetVar(VARS.ENTITY_TYPE) end)
                        if ok2 and et and type(et.IsEmpty) == "function" and not et:IsEmpty() then
                            if et:GetString() ~= "player" then
                                c:Remove()
                                cleaned = cleaned + 1
                            end
                        end
                    end
                end
                if cleaned > 0 then
                    print(string.format("[ClientGame] Cleaned %d old entity nodes before reload", cleaned))
                end
            end
        else
            print("[ClientGame][DIAG] onSyncReload: serverConn_ is NIL!")
        end
    end

    -- 编辑器放置出生点后立即传送玩家
    MapEditor.onSpawnTeleport = function(role, worldX, worldY)
        if serverConn_ then
            local data = VariantMap()
            data["Role"] = Variant(role)
            data["PosX"] = Variant(worldX)
            data["PosY"] = Variant(worldY)
            serverConn_:SendRemoteEvent(Shared.EVENTS.SPAWN_TELEPORT, true, data)
            print(string.format("[ClientGame] SpawnTeleport: role=%s pos=(%.2f, %.2f)", role, worldX, worldY))
        end
    end

    -- 注册渲染事件（绑定到 nvg 上下文对象）
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender_Game")

    -- 注册帧更新事件
    SubscribeToEvent("Update", "HandleUpdate_Game")

    WorldRenderer.ResetParticles()

    print(string.format("[ClientGame] Init: role=%s screen=%dx%d dpr=%.1f",
        myRole, math.floor(screenW_), math.floor(screenH_), dpr_))

    -- 即时诊断：Init 时场景中有什么
    local initChildren = scene_:GetChildren(false)
    print(string.format("[ClientGame] Init IMMEDIATE: scene children=%d", #initChildren))
    pcall(function()
        for i = 1, math.min(#initChildren, 10) do
            local c = initChildren[i]
            if c then
                local ok, et = pcall(function() return c:GetVar(VARS.ENTITY_TYPE) end)
                local etStr = "(none)"
                if ok and et and type(et.IsEmpty) == "function" and not et:IsEmpty() then
                    etStr = et:GetString()
                end
                print(string.format("  [Init][%d] name=%s et=%s", i, c.name or "(nil)", etStr))
            end
        end
    end)
end

--- 销毁客户端游戏
function ClientGame.Destroy()
    if vg_ then
        UnsubscribeFromEvent(vg_, "NanoVGRender")
    end
    UnsubscribeFromEvent("Update")

    if cameraNode_ then
        cameraNode_:Remove()
        cameraNode_ = nil
    end

    scene_      = nil
    serverConn_ = nil
    debugSolo_  = false
    pairId_     = 0
    clientPhysicsDisabled_ = false

    dialogue_.active = false
    dialogue_.lines  = {}
    dialogue_.lineIndex = 0

    bubble_.active = false
    bubble_.text = ""
    bubble_.timer = 0

    screenText_.active = false
    screenText_.text = ""
    screenText_.timer = 0

    print("[ClientGame] Destroyed")
end

--- 设置单人调试模式
---@param enabled boolean
function ClientGame.SetDebugSolo(enabled)
    debugSolo_ = enabled
end

--- 切换渲染视角角色（单人调试用）
---@param role string "red" | "black"
function ClientGame.SetRole(role)
    myRole_ = role
    print("[ClientGame] Role switched → " .. role)
end

-- ═══════════════════════════════════════════════
-- 对话系统
-- ═══════════════════════════════════════════════

--- 接收服务端发来的游戏事件
---@param eventData VariantMap
function ClientGame.OnGameEvent(eventData)
    local evType = eventData["Type"]:GetString()

    if evType == "npc_talk" then
        local npcName = eventData["NpcName"]:GetString()
        local lineCount = eventData["LineCount"]:GetInt()
        local lines = {}
        for i = 1, lineCount do
            local line = eventData["Line" .. i]:GetString()
            lines[i] = line
        end

        -- 开启对话
        dialogue_.active = true
        dialogue_.npcName = npcName
        dialogue_.lines = lines
        dialogue_.lineIndex = 1
        print(string.format("[ClientGame] Dialogue started: %s (%d lines)", npcName, lineCount))

    elseif evType == "monologue" then
        local text = eventData["Text"]:GetString()
        local charCount = utf8.len(text) or #text
        local dur = BUBBLE_BASE_DURATION + charCount * BUBBLE_PER_CHAR
        bubble_.active = true
        bubble_.text = text
        bubble_.duration = dur
        bubble_.timer = dur
        print(string.format("[ClientGame] Bubble: %s (%.1fs)", text, dur))

    elseif evType == "screen_text" then
        local text = eventData["Text"]:GetString()
        local charCount = utf8.len(text) or #text
        local dur = SCREEN_TEXT_BASE_DURATION + charCount * SCREEN_TEXT_PER_CHAR
        screenText_.active = true
        screenText_.text = text
        screenText_.duration = dur
        screenText_.timer = dur
        print(string.format("[ClientGame] ScreenText: %s (%.1fs)", text, dur))
    end
end

--- 接收服务端场景切换通知
---@param eventData VariantMap
function ClientGame.OnSceneChange(eventData)
    local sceneIdx  = eventData["SceneIdx"]:GetInt()
    local sceneName = eventData["SceneName"]:GetString()

    print(string.format("[ClientGame] Scene change → %d: %s", sceneIdx, sceneName))

    -- 启动过渡动画
    transition_.active    = true
    transition_.timer     = TRANSITION_TOTAL
    transition_.sceneName = sceneName
    transition_.sceneIdx  = sceneIdx

    -- 更新当前场景信息
    curSceneIdx_  = sceneIdx
    curSceneName_ = sceneName

    -- 同步 groundOverlays 和 freeOverlays 到 WorldRenderer（新场景的贴图覆盖层）
    local sceneData = LevelData.GetScene(sceneIdx)
    WorldRenderer.SetSceneOverlays(sceneData and sceneData.groundOverlays or {})
    WorldRenderer.SetFreeOverlays(sceneData and sceneData.freeOverlays or {})

    -- 重置粒子效果
    WorldRenderer.ResetParticles()

    -- 重置气泡和屏幕文字
    bubble_.active = false
    screenText_.active = false
    dialogue_.active = false

    -- ── 客户端主动清理旧场景节点 ──
    -- 服务端 Remove() REPLICATED 节点后删除信息可能未同步到客户端，
    -- 因此客户端在收到 SCENE_CHANGE 时主动清除不属于新场景的节点。
    if scene_ then
        local newTag = "_s" .. sceneIdx .. "_"   -- 例如 "_s1_"
        local children = scene_:GetChildren(false)
        local cleaned = 0
        -- 倒序遍历，因为 Remove 会改变 children
        for i = #children, 1, -1 do
            local c = children[i]
            if c then
                local name = c.name or ""
                -- 保留：玩家节点、相机节点、属于新场景的节点
                local keep = name:find("^Player_")
                           or name:find("^GameCamera")
                           or name:find(newTag, 1, true)  -- plain match
                if not keep and name ~= "" then
                    c:Remove()
                    cleaned = cleaned + 1
                end
            end
        end
        if cleaned > 0 then
            print(string.format("[ClientGame] Cleaned %d old nodes on scene change to %d",
                cleaned, sceneIdx))
        end
    end
end

--- 推进对话（E 键触发）
local function AdvanceDialogue()
    if not dialogue_.active then return end
    dialogue_.lineIndex = dialogue_.lineIndex + 1
    if dialogue_.lineIndex > #dialogue_.lines then
        dialogue_.active = false
        print("[ClientGame] Dialogue ended")
    end
end

-- ═══════════════════════════════════════════════
-- 输入采集 → controls.buttons
-- ═══════════════════════════════════════════════

local function GatherInput()
    if not serverConn_ then return end

    local buttons = 0

    -- 键盘
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.MOVE_LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.MOVE_RIGHT
    end
    -- JUMP = 持续键：按住=长跳，松开后服务端检测到 jump=false 触发 JumpCut（短跳）
    if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) or input:GetKeyDown(KEY_SPACE) then
        buttons = buttons | CTRL.JUMP
    end
    if not dialogue_.active then
        -- INTERACT = 脉冲（按下瞬间触发交互）
        if input:GetKeyPress(KEY_E) or input:GetKeyPress(KEY_RETURN) then
            buttons = buttons | CTRL.INTERACT
        end
        -- PUSH = 持续（按住期间推/拉箱子）
        if input:GetKeyDown(KEY_E) or input:GetKeyDown(KEY_RETURN) then
            buttons = buttons | CTRL.PUSH
        end
    end

    serverConn_.controls.buttons = buttons
end

-- ═══════════════════════════════════════════════
-- 相机跟随（双人中点 + 平滑）
-- ═══════════════════════════════════════════════

-- ─── 相机分离/合并状态 ───
-- 可视区域宽度(米) = designW / PPU，留出边距后作为分离阈值
local CAM_VIEW_W        = GameConst.DESIGN_WIDTH / GameConst.PIXELS_PER_UNIT  -- 19.2m
local CAM_SPLIT_DIST    = CAM_VIEW_W * 0.82   -- ~15.7m 超过此距离 → 分离
local CAM_MERGE_DIST    = CAM_VIEW_W * 0.70   -- ~13.4m 回到此距离 → 合并（迟滞）
local camSplit_         = false                -- 当前是否处于分离模式
local camBlend_         = 0.0                  -- 0=合并(中点) 1=分离(本地), 平滑过渡
local CAM_BLEND_SPEED   = 1.2                  -- 混合过渡速率 (每秒)

local function UpdateCamera(dt)
    if not scene_ then return end

    -- 收集所有玩家位置，同时找到本地玩家
    local myX, myY
    local sumX, sumY, count = 0, 0, 0
    local children = scene_:GetChildren(false)
    for i = 1, #children do
        local child = children[i]
        if child then
            local ok, etVar = pcall(function() return child:GetVar(VARS.ENTITY_TYPE) end)
            if ok and etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty()
               and etVar:GetString() == "player" and BelongsToMyPair(child) then
                local pos = child.position
                sumX = sumX + pos.x
                sumY = sumY + pos.y
                count = count + 1

                -- 识别本地玩家
                local roleVar = child:GetVar(VARS.ROLE)
                local roleStr = (roleVar and not roleVar:IsEmpty()) and roleVar:GetString() or ""
                if roleStr == myRole_ then
                    myX = pos.x
                    myY = pos.y
                end
            end
        end
    end

    if count <= 0 then return end

    -- 计算双人水平距离（仅 2 人时有意义）
    local dist = 0
    if count == 2 and myX then
        -- 另一位玩家坐标 = 总和 - 本地
        local otherX = sumX - myX
        dist = math.abs(myX - otherX)
    end

    -- 迟滞切换：分离/合并
    if count == 2 then
        if not camSplit_ and dist > CAM_SPLIT_DIST then
            camSplit_ = true
        elseif camSplit_ and dist < CAM_MERGE_DIST then
            camSplit_ = false
        end
    else
        camSplit_ = false  -- 单人直接跟随
    end

    -- 平滑过渡混合因子 camBlend_: 0=中点  1=本地玩家
    local blendTarget = camSplit_ and 1.0 or 0.0
    if camBlend_ < blendTarget then
        camBlend_ = math.min(camBlend_ + CAM_BLEND_SPEED * dt, blendTarget)
    elseif camBlend_ > blendTarget then
        camBlend_ = math.max(camBlend_ - CAM_BLEND_SPEED * dt, blendTarget)
    end

    -- 合并模式目标（双人中点）
    local midX = sumX / count
    local midY = math.max(sumY / count + GameConst.CAM_Y_OFFSET, GameConst.CAM_MIN_Y)

    -- 计算目标点：在中点和本地玩家之间按 camBlend_ 插值
    local targetX, targetY
    if myX then
        local localY = math.max(myY + GameConst.CAM_Y_OFFSET, GameConst.CAM_MIN_Y)
        targetX = midX + (myX - midX) * camBlend_
        targetY = midY + (localY - midY) * camBlend_
    else
        targetX = midX
        targetY = midY
    end

    local speed = GameConst.CAM_LERP_SPEED * dt
    camX_ = camX_ + (targetX - camX_) * speed
    camY_ = camY_ + (targetY - camY_) * speed

    -- 硬约束：确保本地玩家始终在画面 [2/9, 7/9] 垂直区间内
    -- 当玩家跳跃/快速移动时，lerp 可能滞后，用硬夹紧兜底
    if myY then
        local clamp = GameConst.CAM_Y_CLAMP
        camY_ = math.min(camY_, myY + clamp)  -- 玩家不低于 2/9 from bottom
        camY_ = math.max(camY_, myY - clamp)  -- 玩家不高于 2/9 from top
    end
end

-- ═══════════════════════════════════════════════
-- 场景节点收集
-- ═══════════════════════════════════════════════

-- ═══════════════════════════════════════════════
-- 屏幕诊断信息（直接画在游戏画面上）
-- ═══════════════════════════════════════════════

local diag_ = {
    totalChildren = 0,
    withET = 0,
    withoutET = 0,
    nodeLines = {},   -- 前 8 个子节点的文字描述
    frameCount = 0,
}

local function CollectSceneNodes()
    local result = {}
    if not scene_ then
        diag_.nodeLines = { "scene_ is NIL!" }
        return result
    end

    local children = scene_:GetChildren(false)
    local totalChildren = #children
    local withEntityType = 0
    local withoutEntityType = 0

    for i = 1, totalChildren do
        local child = children[i]
        if child then
            local ok, etVar = pcall(function() return child:GetVar(VARS.ENTITY_TYPE) end)
            if ok and etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty() then
                if BelongsToMyPair(child) then
                    withEntityType = withEntityType + 1
                    result[#result + 1] = child
                end
            else
                withoutEntityType = withoutEntityType + 1
            end
        end
    end

    -- 更新屏幕诊断数据
    diag_.totalChildren = totalChildren
    diag_.withET = withEntityType
    diag_.withoutET = withoutEntityType
    diag_.frameCount = diag_.frameCount + 1

    -- 每 120 帧输出一次详细控制台日志（约 2 秒一次）
    if diag_.frameCount % 120 == 1 then
        -- 按 EntityType 统计
        local etCounts = {}
        for _, node in ipairs(result) do
            pcall(function()
                local etVar = node:GetVar(VARS.ENTITY_TYPE)
                local etStr = (etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty()) and etVar:GetString() or "(unknown)"
                etCounts[etStr] = (etCounts[etStr] or 0) + 1
            end)
        end
        local etSummary = ""
        for k, v in pairs(etCounts) do etSummary = etSummary .. k .. "=" .. v .. " " end

        print(string.format("[ClientGame][DIAG] CollectSceneNodes: total=%d withET=%d noET=%d | %s",
            totalChildren, withEntityType, withoutEntityType, etSummary))

        -- 列出前 12 个子节点的详细信息
        diag_.nodeLines = {}
        local limit = math.min(totalChildren, 12)
        for i = 1, limit do
            local child = children[i]
            if child then
                pcall(function()
                    local etVar = child:GetVar(VARS.ENTITY_TYPE)
                    local etStr = (etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty()) and etVar:GetString() or "(no ET)"
                    local p = child.position
                    local line = string.format(
                        "#%d %s et=%s (%.1f,%.1f)", i, child.name or "?", etStr, p.x, p.y)
                    diag_.nodeLines[#diag_.nodeLines + 1] = line
                    print(string.format("[ClientGame][DIAG]   child[%d] name=%s ET=%s pos=(%.1f,%.1f)",
                        i, child.name or "?", etStr, p.x, p.y))
                end)
            end
        end
        if totalChildren == 0 then
            diag_.nodeLines[1] = "(no children in scene)"
            print("[ClientGame][DIAG]   (no children in scene)")
        end
    end

    return result
end

-- ═══════════════════════════════════════════════
-- HUD（角色、场景名、提示）
-- ═══════════════════════════════════════════════

-- ═══════════════════════════════════════════════
-- 地图预览：小地图 + 坐标标尺  (P 键切换)
-- ═══════════════════════════════════════════════
local mapPreviewOpen_ = false

--- 将世界坐标 (wx, wy) 映射到小地图像素坐标
--- mapRect: { x, y, w, h } 小地图面板在屏幕上的位置/尺寸
--- worldRect: { minX, maxX, minY, maxY } 世界空间包围盒
local function WorldToMinimap(wx, wy, mapRect, worldRect)
    local fx = (wx - worldRect.minX) / (worldRect.maxX - worldRect.minX)
    local fy = 1 - (wy - worldRect.minY) / (worldRect.maxY - worldRect.minY)  -- Y 轴翻转
    return mapRect.x + fx * mapRect.w, mapRect.y + fy * mapRect.h
end

--- 计算场景节点世界包围盒（只考虑平台/斜坡/触发器）
local function CalcWorldBounds(nodes)
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    for _, node in ipairs(nodes) do
        if node then
            local etVar = node:GetVar(VARS.ENTITY_TYPE)
            if etVar and not etVar:IsEmpty() then
                local et = etVar:GetString()
                if et == "platform" or et == "slope" or et == "trigger" or et == "water" then
                    local pos = node.position
                    local wv = node:GetVar("Width")
                    local hv = node:GetVar("Height")
                    local hw = (wv and not wv:IsEmpty()) and wv:GetFloat() * 0.5 or 1
                    local hh = (hv and not hv:IsEmpty()) and hv:GetFloat() * 0.5 or 1
                    if pos.x - hw < minX then minX = pos.x - hw end
                    if pos.x + hw > maxX then maxX = pos.x + hw end
                    if pos.y - hh < minY then minY = pos.y - hh end
                    if pos.y + hh > maxY then maxY = pos.y + hh end
                end
            end
        end
    end
    -- 保底：若无节点则给一个默认范围
    if minX == math.huge then minX, maxX, minY, maxY = -20, 20, -10, 10 end
    -- 各方向留 2m 边距
    return { minX = minX - 2, maxX = maxX + 2, minY = minY - 2, maxY = maxY + 2 }
end

local function DrawMapPreview(vg, w, h, nodes)
    -- ── 布局常量 ──
    local RULER_H     = 28   -- 底部水平标尺高度
    local RULER_W     = 28   -- 左侧垂直标尺宽度
    local MAP_MARGIN  = 10   -- 小地图距右上角边距
    local ppu         = GameConst.PIXELS_PER_UNIT

    -- ── 1. 小地图面板（右上角，缩小） ──
    local mapW = math.min(w * 0.22, 200)
    local mapH = math.min(h * 0.20, 140)
    local mapX = w - mapW - MAP_MARGIN
    local mapY = MAP_MARGIN
    local mapRect = { x = mapX, y = mapY, w = mapW, h = mapH }

    -- 计算世界包围盒
    local wb = CalcWorldBounds(nodes)
    local camHalfW = (designW_ / ppu) * 0.5
    local camHalfH = (designH_ / ppu) * 0.5

    -- 背景（不透明，避免游戏世界透出形成重叠感）
    nvgBeginPath(vg)
    nvgRoundedRect(vg, mapX - 1, mapY - 1, mapW + 2, mapH + 2, 4)
    nvgFillColor(vg, nvgRGBA(18, 20, 30, 255))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 80))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)

    -- 裁剪到小地图内
    nvgSave(vg)
    nvgIntersectScissor(vg, mapX, mapY, mapW, mapH)

    -- ── 绘制场景实体 ──
    for _, node in ipairs(nodes) do
        if node then
            local etVar = node:GetVar(VARS.ENTITY_TYPE)
            if etVar and not etVar:IsEmpty() then
                local et = etVar:GetString()

                if et == "platform" then
                    -- 平台：pos 是中心，有 Width/Height Var
                    local pos = node.position
                    local wv = node:GetVar("Width")
                    local hv = node:GetVar("Height")
                    if wv and not wv:IsEmpty() and hv and not hv:IsEmpty() then
                        local pw = wv:GetFloat()
                        local ph = hv:GetFloat()
                        local lx, top = WorldToMinimap(pos.x - pw * 0.5, pos.y + ph * 0.5, mapRect, wb)
                        local rx, bot = WorldToMinimap(pos.x + pw * 0.5, pos.y - ph * 0.5, mapRect, wb)
                        local bw = rx - lx
                        local bh = bot - top
                        if bw >= 0.5 and bh >= 0.5 then
                            nvgBeginPath(vg)
                            nvgRect(vg, lx, top, math.max(bw, 1), math.max(bh, 1))
                            nvgFillColor(vg, nvgRGBA(150, 160, 180, 255))
                            nvgFill(vg)
                        end
                    end

                elseif et == "slope" then
                    -- 斜坡：pos 是格子左下角，用 SLOPE_TYPE 查顶点表
                    local pos = node.position
                    local stVar = node:GetVar("SLOPE_TYPE")
                    if stVar and not stVar:IsEmpty() then
                        local verts = SlopePhysics.VERTICES[stVar:GetString()]
                        if verts and #verts >= 3 then
                            nvgBeginPath(vg)
                            for i, v in ipairs(verts) do
                                local mx, my = WorldToMinimap(pos.x + v.x, pos.y + v.y, mapRect, wb)
                                if i == 1 then nvgMoveTo(vg, mx, my)
                                else            nvgLineTo(vg, mx, my) end
                            end
                            nvgClosePath(vg)
                            nvgFillColor(vg, nvgRGBA(130, 140, 160, 255))
                            nvgFill(vg)
                        end
                    end

                elseif et == "water" then
                    local pos = node.position
                    local wv = node:GetVar("Width")
                    local hv = node:GetVar("Height")
                    if wv and not wv:IsEmpty() and hv and not hv:IsEmpty() then
                        local pw = wv:GetFloat()
                        local ph = hv:GetFloat()
                        local lx, top = WorldToMinimap(pos.x - pw * 0.5, pos.y + ph * 0.5, mapRect, wb)
                        local rx, bot = WorldToMinimap(pos.x + pw * 0.5, pos.y - ph * 0.5, mapRect, wb)
                        nvgBeginPath(vg)
                        nvgRect(vg, lx, top, math.max(rx - lx, 1), math.max(bot - top, 1))
                        nvgFillColor(vg, nvgRGBA(60, 140, 220, 180))
                        nvgFill(vg)
                    end

                elseif et == "trigger" then
                    local pos = node.position
                    local mx, my = WorldToMinimap(pos.x, pos.y, mapRect, wb)
                    nvgBeginPath(vg)
                    nvgCircle(vg, mx, my, 2.5)
                    nvgFillColor(vg, nvgRGBA(100, 220, 100, 230))
                    nvgFill(vg)
                end
            end
        end
    end

    -- 原点十字（黄色）
    local ox, oy = WorldToMinimap(0, 0, mapRect, wb)
    nvgBeginPath(vg)
    nvgMoveTo(vg, ox - 4, oy) nvgLineTo(vg, ox + 4, oy)
    nvgMoveTo(vg, ox, oy - 4) nvgLineTo(vg, ox, oy + 4)
    nvgStrokeColor(vg, nvgRGBA(255, 220, 50, 200))
    nvgStrokeWidth(vg, 1.0)
    nvgStroke(vg)

    -- 相机视野框（白色）
    local vl, vt = WorldToMinimap(camX_ - camHalfW, camY_ + camHalfH, mapRect, wb)
    local vr, vb = WorldToMinimap(camX_ + camHalfW, camY_ - camHalfH, mapRect, wb)
    nvgBeginPath(vg)
    nvgRect(vg, vl, vt, vr - vl, vb - vt)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 180))
    nvgStrokeWidth(vg, 1.0)
    nvgStroke(vg)

    -- 玩家点（遍历一次，不重复）
    for _, node in ipairs(nodes) do
        if node then
            local etVar = node:GetVar(VARS.ENTITY_TYPE)
            if etVar and not etVar:IsEmpty() and etVar:GetString() == "player" then
                local pos = node.position
                local px, py = WorldToMinimap(pos.x, pos.y, mapRect, wb)
                local roleVar = node:GetVar(VARS.ROLE)
                local pRole = (roleVar and not roleVar:IsEmpty()) and roleVar:GetString() or ""
                local pc = (pRole == Shared.ROLE.RED) and nvgRGBA(240, 80, 60, 255) or nvgRGBA(160, 170, 200, 255)
                nvgBeginPath(vg)
                nvgCircle(vg, px, py, 3.5)
                nvgFillColor(vg, pc)
                nvgFill(vg)
                nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 220))
                nvgStrokeWidth(vg, 1)
                nvgStroke(vg)
            end
        end
    end

    nvgRestore(vg)

    -- 小地图标题
    nvgFontFace(vg, "ui")
    nvgFontSize(vg, 11)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(200, 210, 230, 180))
    nvgText(vg, mapX + 4, mapY - 2, string.format("地图  [%.0f~%.0fm / %.0f~%.0fm]",
        wb.minX, wb.maxX, wb.minY, wb.maxY))

    -- ── 2. 底部水平标尺（X 轴：距原点距离） ──
    local rulerAreaX = RULER_W           -- 标尺从左侧标尺宽度开始
    local rulerAreaW = w - RULER_W
    local rulerY     = h - RULER_H

    -- 背景
    nvgBeginPath(vg)
    nvgRect(vg, 0, rulerY, w, RULER_H)
    nvgFillColor(vg, nvgRGBA(10, 10, 20, 200))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, 0, rulerY)
    nvgLineTo(vg, w, rulerY)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 60))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)

    -- 计算当前视野 X 范围（单位：米）
    local viewLeft  = camX_ - (designW_ / ppu) * 0.5
    local viewRight = camX_ + (designW_ / ppu) * 0.5

    -- 计算刻度间距：目标约 60~100px 一格，选最合适的整数/0.5m 步进
    local rawStep = (viewRight - viewLeft) * 60 / rulerAreaW
    local step
    if rawStep <= 0.5 then step = 0.5
    elseif rawStep <= 1 then step = 1
    elseif rawStep <= 2 then step = 2
    elseif rawStep <= 5 then step = 5
    elseif rawStep <= 10 then step = 10
    else step = math.ceil(rawStep / 10) * 10
    end

    nvgFontFace(vg, "ui")
    nvgFontSize(vg, 10)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)

    local firstTick = math.ceil(viewLeft / step) * step
    local wx = firstTick
    while wx <= viewRight + step do
        local sx = rulerAreaX + (wx - viewLeft) / (viewRight - viewLeft) * rulerAreaW
        if sx >= rulerAreaX and sx <= w then
            local isMajor = (math.abs(math.fmod(wx, step * 5)) < 0.001 or step >= 5)
            local tickH = isMajor and 10 or 5
            nvgBeginPath(vg)
            nvgMoveTo(vg, sx, rulerY)
            nvgLineTo(vg, sx, rulerY + tickH)
            nvgStrokeColor(vg, isMajor and nvgRGBA(255,255,255,160) or nvgRGBA(255,255,255,80))
            nvgStrokeWidth(vg, 1)
            nvgStroke(vg)
            if isMajor then
                nvgFillColor(vg, nvgRGBA(220, 230, 240, 200))
                -- 原点用不同颜色标记
                if math.abs(wx) < 0.001 then
                    nvgFillColor(vg, nvgRGBA(255, 220, 50, 220))
                end
                nvgText(vg, sx, rulerY + 11, string.format(step < 1 and "%.1f" or "%.0f", wx))
            end
        end
        wx = wx + step
    end

    -- X 轴标签
    nvgFontSize(vg, 10)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(180, 200, 220, 160))
    nvgText(vg, rulerAreaX + 2, rulerY + 1, "X(m)")

    -- ── 3. 左侧垂直标尺（Y 轴：高度） ──
    local rulerAreaH = h - RULER_H   -- 不与底部标尺重叠

    -- 背景
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, RULER_W, rulerAreaH)
    nvgFillColor(vg, nvgRGBA(10, 10, 20, 200))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, RULER_W, 0)
    nvgLineTo(vg, RULER_W, rulerAreaH)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 60))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)

    -- 当前视野 Y 范围（单位：米，Y 轴世界朝上 → 屏幕朝下需翻转）
    local viewBottom = camY_ - (designH_ / ppu) * 0.5
    local viewTop    = camY_ + (designH_ / ppu) * 0.5

    -- Y 轴刻度步进
    local rawStepY = (viewTop - viewBottom) * 60 / rulerAreaH
    local stepY
    if rawStepY <= 0.5 then stepY = 0.5
    elseif rawStepY <= 1 then stepY = 1
    elseif rawStepY <= 2 then stepY = 2
    elseif rawStepY <= 5 then stepY = 5
    elseif rawStepY <= 10 then stepY = 10
    else stepY = math.ceil(rawStepY / 10) * 10
    end

    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFontSize(vg, 10)

    local firstTickY = math.ceil(viewBottom / stepY) * stepY
    local wy = firstTickY
    while wy <= viewTop + stepY do
        -- 世界 Y 越大 → 屏幕 Y 越小
        local sy = rulerAreaH - (wy - viewBottom) / (viewTop - viewBottom) * rulerAreaH
        if sy >= 0 and sy <= rulerAreaH then
            local isMajorY = (math.abs(math.fmod(wy, stepY * 5)) < 0.001 or stepY >= 5)
            local tickW = isMajorY and 10 or 5
            nvgBeginPath(vg)
            nvgMoveTo(vg, RULER_W, sy)
            nvgLineTo(vg, RULER_W - tickW, sy)
            nvgStrokeColor(vg, isMajorY and nvgRGBA(255,255,255,160) or nvgRGBA(255,255,255,80))
            nvgStrokeWidth(vg, 1)
            nvgStroke(vg)
            if isMajorY then
                nvgFillColor(vg, nvgRGBA(220, 230, 240, 200))
                if math.abs(wy) < 0.001 then
                    nvgFillColor(vg, nvgRGBA(255, 220, 50, 220))
                end
                nvgText(vg, RULER_W - 12, sy, string.format(stepY < 1 and "%.1f" or "%.0f", wy))
            end
        end
        wy = wy + stepY
    end

    -- Y 轴标签
    nvgFontSize(vg, 10)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(180, 200, 220, 160))
    nvgText(vg, 2, 2, "Y")

    -- ── 4. 左下角相机坐标读数 ──
    nvgFontFace(vg, "ui")
    nvgFontSize(vg, 11)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(200, 220, 240, 200))
    nvgText(vg, RULER_W + 4, h - RULER_H - 2,
        string.format("cam (%.2f, %.2f)m", camX_, camY_))
end

local function DrawHUD(vg, w, h)
    nvgFontFace(vg, "ui")

    -- 左上：角色标识
    local roleLabel = (myRole_ == Shared.ROLE.RED) and "红鸟" or "黑鸟"
    nvgFontSize(vg, 16)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)

    -- 背景条
    nvgBeginPath(vg)
    nvgRoundedRect(vg, 8, 8, 80, 28, 6)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 120))
    nvgFill(vg)

    local roleColor = (myRole_ == Shared.ROLE.RED)
        and nvgRGBA(240, 100, 80, 255)
        or  nvgRGBA(160, 170, 200, 255)
    nvgFillColor(vg, roleColor)
    nvgText(vg, 16, 14, roleLabel)

    -- 右上：操作提示
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(200, 200, 220, 140))
    local controlHint = "AD/箭头:移动  空格/W:跳跃  E:互动  P:地图"
    if debugSolo_ then
        controlHint = controlHint .. "  Tab:切换视角"
    end
    nvgText(vg, w - 12, 12, controlHint)

    -- （诊断覆盖层已关闭）
end

-- ═══════════════════════════════════════════════
-- 对话框渲染（NanoVG）
-- ═══════════════════════════════════════════════

local function DrawDialogue(vg, w, h)
    if not dialogue_.active then return end

    local line = dialogue_.lines[dialogue_.lineIndex] or ""
    local name = dialogue_.npcName

    -- ─── 尺寸计算 ───
    local boxW   = math.min(w * 0.85, 500)
    local boxH   = 90
    local boxX   = (w - boxW) * 0.5
    local boxY   = h - boxH - 24
    local padX   = 16
    local padY   = 12
    local radius = 10

    -- ─── 半透明背景 ───
    nvgBeginPath(vg)
    nvgRoundedRect(vg, boxX, boxY, boxW, boxH, radius)
    nvgFillColor(vg, nvgRGBA(10, 10, 30, 210))
    nvgFill(vg)
    -- 边框
    nvgStrokeColor(vg, nvgRGBA(140, 180, 255, 160))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)

    -- ─── NPC 名字 ───
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 15)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(120, 200, 255, 255))
    nvgText(vg, boxX + padX, boxY + padY, name)

    -- ─── 对话文本 ───
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(240, 240, 250, 255))
    nvgText(vg, boxX + padX, boxY + padY + 22, line)

    -- ─── 提示（右下角） ───
    local hint = string.format("[E] %d/%d", dialogue_.lineIndex, #dialogue_.lines)
    if dialogue_.lineIndex >= #dialogue_.lines then
        hint = "[E] 关闭"
    end
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(180, 180, 200, 160))
    nvgText(vg, boxX + boxW - padX, boxY + boxH - 8, hint)
end

-- ═══════════════════════════════════════════════
-- 头顶气泡 渲染（内心独白）
-- ═══════════════════════════════════════════════

local PPU = GameConst.PIXELS_PER_UNIT

--- 查找本角色玩家节点并返回设计空间坐标
---@return number|nil sx, number|nil sy
local function GetMyPlayerScreenPos()
    if not scene_ then return nil, nil end
    local children = scene_:GetChildren(false)
    for i = 1, #children do
        local child = children[i]
        if child then
            local ok, etVar = pcall(function() return child:GetVar(VARS.ENTITY_TYPE) end)
            if ok and etVar and type(etVar.IsEmpty) == "function" and not etVar:IsEmpty()
               and etVar:GetString() == "player" and BelongsToMyPair(child) then
                local roleVar = child:GetVar(VARS.ROLE)
                local roleStr = (roleVar and not roleVar:IsEmpty()) and roleVar:GetString() or ""
                if roleStr == myRole_ then
                    local pos = child.position
                    -- 返回设计空间坐标（与 WorldToScreen 一致）
                    local sx = (pos.x - camX_) * PPU + designW_ * 0.5
                    local sy = designH_ * 0.5 - (pos.y - camY_) * PPU
                    return sx, sy
                end
            end
        end
    end
    return nil, nil
end

--- 绘制头顶气泡
local function DrawBubble(vg, w, h)
    if not bubble_.active then return end

    local sx, sy = GetMyPlayerScreenPos()
    if not sx then return end

    local t = bubble_.timer
    local d = bubble_.duration
    -- 计算淡入淡出 alpha
    local alpha = 1.0
    local fadeIn = d - t  -- 已过时间
    if fadeIn < BUBBLE_FADE_TIME then
        alpha = fadeIn / BUBBLE_FADE_TIME
    elseif t < BUBBLE_FADE_TIME then
        alpha = t / BUBBLE_FADE_TIME
    end
    alpha = math.max(0, math.min(1, alpha))
    local a = math.floor(alpha * 255)
    if a <= 0 then return end

    -- 文本尺寸
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 14)

    -- 测量文本宽度
    local bounds = {}
    local bubbleTxt = bubble_.text or ""
    if bubbleTxt == "" then return end
    nvgTextBounds(vg, 0, 0, bubbleTxt, bounds)
    if not bounds[3] or not bounds[1] then return end
    local textW = bounds[3] - bounds[1]
    local textH = 14

    local padX = 12
    local padY = 8
    local boxW = textW + padX * 2
    local boxH = textH + padY * 2
    local maxW = w * 0.7
    if boxW > maxW then boxW = maxW end

    local radius = GameConst.PLAYER_RADIUS * PPU
    local triH = 8   -- 三角尖高度
    local bubbleX = sx - boxW * 0.5
    local bubbleY = sy - radius - triH - boxH - 6

    -- 限制不超出屏幕
    if bubbleX < 4 then bubbleX = 4 end
    if bubbleX + boxW > w - 4 then bubbleX = w - 4 - boxW end
    if bubbleY < 4 then bubbleY = 4 end

    -- ─── 气泡背景（圆角矩形） ───
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bubbleX, bubbleY, boxW, boxH, 8)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
    nvgFill(vg)

    -- ─── 底部三角指针 ───
    local triX = sx  -- 三角指向角色中心
    -- 限制三角在气泡范围内
    if triX < bubbleX + 12 then triX = bubbleX + 12 end
    if triX > bubbleX + boxW - 12 then triX = bubbleX + boxW - 12 end

    nvgBeginPath(vg)
    nvgMoveTo(vg, triX - 6, bubbleY + boxH)
    nvgLineTo(vg, triX, bubbleY + boxH + triH)
    nvgLineTo(vg, triX + 6, bubbleY + boxH)
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
    nvgFill(vg)

    -- ─── 文本 ───
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(30, 30, 40, a))
    -- 如果文本太长需要截断
    local textX = bubbleX + boxW * 0.5
    local textY = bubbleY + boxH * 0.5
    nvgText(vg, textX, textY, bubble_.text)
end

-- ═══════════════════════════════════════════════
-- 屏幕文字 渲染（任务提示 / 场景描述）
-- ═══════════════════════════════════════════════

local function DrawScreenText(vg, w, h)
    if not screenText_.active then return end

    local t = screenText_.timer
    local d = screenText_.duration
    -- 淡入淡出
    local alpha = 1.0
    local fadeIn = d - t
    if fadeIn < SCREEN_TEXT_FADE_TIME then
        alpha = fadeIn / SCREEN_TEXT_FADE_TIME
    elseif t < SCREEN_TEXT_FADE_TIME then
        alpha = t / SCREEN_TEXT_FADE_TIME
    end
    alpha = math.max(0, math.min(1, alpha))
    local a = math.floor(alpha * 255)
    if a <= 0 then return end

    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 18)

    -- 测量文本宽度
    local bounds = {}
    local txt = screenText_.text or ""
    if txt == "" then return end
    nvgTextBounds(vg, 0, 0, txt, bounds)
    if not bounds[3] or not bounds[1] then return end
    local textW = bounds[3] - bounds[1]

    local padX = 20
    local padY = 10
    local boxW = textW + padX * 2
    local boxH = 18 + padY * 2

    local boxX = (w - boxW) * 0.5
    local boxY = h * 0.12  -- 屏幕上方 12% 位置

    -- 半透明黑底
    nvgBeginPath(vg)
    nvgRoundedRect(vg, boxX, boxY, boxW, boxH, 6)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(0.6 * a)))
    nvgFill(vg)

    -- 文字
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(240, 240, 250, a))
    nvgText(vg, w * 0.5, boxY + boxH * 0.5, screenText_.text)
end

-- ═══════════════════════════════════════════════
-- 场景切换过渡（淡入淡出 + 场景名）
-- ═══════════════════════════════════════════════

local function DrawTransition(vg, w, h)
    if not transition_.active then return end

    local t = transition_.timer
    local alpha = 0

    -- 3 阶段：淡出（变黑）→ 全黑停留 → 淡入（变透明）
    local fadeOut = TRANSITION_TOTAL - TRANSITION_FADE_DURATION  -- 淡出结束时刻
    local holdEnd = TRANSITION_FADE_DURATION                     -- 全黑停留结束时刻

    if t > fadeOut then
        -- 阶段1：淡出（透明→黑）
        local progress = (TRANSITION_TOTAL - t) / TRANSITION_FADE_DURATION
        alpha = progress
    elseif t > holdEnd then
        -- 阶段2：全黑停留
        alpha = 1.0
    else
        -- 阶段3：淡入（黑→透明）
        alpha = t / TRANSITION_FADE_DURATION
    end

    alpha = math.max(0, math.min(1, alpha))
    local a = math.floor(alpha * 255)
    if a <= 0 then return end

    -- 全屏黑色遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, a))
    nvgFill(vg)

    -- 在全黑阶段显示场景名
    if alpha > 0.8 then
        local textAlpha = math.min(1, (alpha - 0.8) / 0.2)
        local ta = math.floor(textAlpha * 255)

        nvgFontFace(vg, "ui")
        nvgFontSize(vg, 22)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(220, 230, 255, ta))
        nvgText(vg, w * 0.5, h * 0.5, transition_.sceneName)

        -- 小标题
        nvgFontSize(vg, 13)
        nvgFillColor(vg, nvgRGBA(160, 180, 220, math.floor(ta * 0.6)))
        local subtitle = string.format("第 %d 幕", transition_.sceneIdx)
        nvgText(vg, w * 0.5, h * 0.5 + 30, subtitle)
    end
end

-- ═══════════════════════════════════════════════
-- 全局事件处理函数（NanoVG 渲染 + Update）
-- ═══════════════════════════════════════════════

--- NanoVG 渲染帧（挂载在全局函数上）
function HandleNanoVGRender_Game(eventType, eventData)
    if not vg_ or not scene_ then return end

    -- 使用逻辑分辨率（模式 B）
    screenW_ = graphics:GetWidth() / dpr_
    screenH_ = graphics:GetHeight() / dpr_

    -- 计算 16:9 适配参数
    UpdateViewFit()

    nvgBeginFrame(vg_, screenW_, screenH_, dpr_)

    -- ── 1) 全屏黑底（letterbox / pillarbox 黑边） ──
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, screenW_, screenH_)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 255))
    nvgFill(vg_)

    -- ── 2) 进入设计空间（16:9 固定画布） ──
    nvgSave(vg_)
    nvgTranslate(vg_, viewOffX_, viewOffY_)
    nvgScale(vg_, viewScale_, viewScale_)

    -- 裁剪：仅在设计区域内绘制
    nvgScissor(vg_, 0, 0, designW_, designH_)

    -- 收集场景节点
    local nodes = CollectSceneNodes()

    local dt = time:GetTimeStep()
    local editorActive = MapEditor.IsActive()

    if editorActive then
        -- 编辑器模式：使用编辑器相机渲染游戏世界（带缩放）
        local edPanX, edPanY, edZoom = MapEditor.GetEditorCamera()
        local viewModeIdx, hideBgFg = MapEditor.GetViewState()

        -- 根据视角模式决定渲染角色：1=逻辑(用自身), 2=红鸟, 3=黑鸟
        local renderRole = myRole_
        if viewModeIdx == 2 then
            renderRole = "red"
        elseif viewModeIdx == 3 then
            renderRole = "black"
        end

        -- 在设计空间中心应用缩放变换
        nvgSave(vg_)
        local cx, cy = designW_ * 0.5, designH_ * 0.5
        nvgTranslate(vg_, cx, cy)
        nvgScale(vg_, edZoom, edZoom)
        nvgTranslate(vg_, -cx, -cy)

        -- 以编辑器相机位置渲染；hideBgFg 时跳过视差背景
        WorldRenderer.Draw(vg_, designW_, designH_, edPanX, edPanY, renderRole, nodes, dt, curSceneIdx_, hideBgFg)

        nvgRestore(vg_)

        -- 编辑器覆盖层
        MapEditor.Render(vg_, designW_, designH_)
    else
        -- 正常游戏渲染
        -- P 键开启时显示地形网格 + 地图预览；默认隐藏地形网格，只渲染贴图
        WorldRenderer.Draw(vg_, designW_, designH_, camX_, camY_, myRole_, nodes, dt, curSceneIdx_, nil, not mapPreviewOpen_)

        -- 地图预览（P 键切换，叠加在游戏世界之上、HUD 之下）
        if mapPreviewOpen_ then
            DrawMapPreview(vg_, designW_, designH_, nodes)
        end

        -- HUD
        DrawHUD(vg_, designW_, designH_)

        -- 对话框（叠加在 HUD 之上）
        DrawDialogue(vg_, designW_, designH_)

        -- 头顶气泡（内心独白）
        DrawBubble(vg_, designW_, designH_)

        -- 屏幕文字（任务提示 / 场景描述）
        DrawScreenText(vg_, designW_, designH_)
    end

    -- 场景切换过渡（最顶层，覆盖一切）
    DrawTransition(vg_, designW_, designH_)

    nvgResetScissor(vg_)
    nvgRestore(vg_)

    nvgEndFrame(vg_)
end

-- 客户端 PhysicsWorld2D 已禁用标记
local clientPhysicsDisabled_ = false

--- 帧更新（输入 + 相机）
function HandleUpdate_Game(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- ── 防御：确保客户端物理始终禁用 ──
    -- PhysicsWorld2D 可能在 Init 之后才通过 replication 同步到客户端
    if not clientPhysicsDisabled_ and scene_ then
        local pw2d = scene_:GetComponent("PhysicsWorld2D")
        if pw2d then
            pw2d.updateEnabled = false
            clientPhysicsDisabled_ = true
            print("[ClientGame] Disabled client-side PhysicsWorld2D (deferred)")
        end
    end

    -- 对话期间：E 键推进对话，不发送 INTERACT
    if dialogue_.active then
        if input:GetKeyPress(KEY_E) or input:GetKeyPress(KEY_RETURN) then
            AdvanceDialogue()
        end
    end

    -- 头顶气泡计时
    if bubble_.active then
        bubble_.timer = bubble_.timer - dt
        if bubble_.timer <= 0 then
            bubble_.active = false
        end
    end

    -- 屏幕文字计时
    if screenText_.active then
        screenText_.timer = screenText_.timer - dt
        if screenText_.timer <= 0 then
            screenText_.active = false
        end
    end

    -- 场景切换过渡计时
    if transition_.active then
        transition_.timer = transition_.timer - dt
        if transition_.timer <= 0 then
            transition_.active = false
        end
    end

    -- 地图编辑器：T 键切换（仅 debugSolo 模式）
    if debugSolo_ and input:GetKeyPress(KEY_T) then
        local wasActive = MapEditor.IsActive()
        MapEditor.Toggle()
        -- 编辑器刚关闭 → 自动保存地图 → 通知服务端重载场景
        if wasActive and not MapEditor.IsActive() then
            local scIdx = MapEditor.GetCurSceneIdx()
            local md = MapEditor.GetMapData()
            if md then
                MapSerializer.SaveAsScene(md, scIdx)
                print("[ClientGame] Auto-saved editor data for scene " .. scIdx)
            end
            if serverConn_ then
                local sceneData = LevelData.GetSavedScene(scIdx)
                local data = VariantMap()
                data["SceneIdx"] = Variant(scIdx)
                if sceneData then
                    local encOk, jsonStr = pcall(cjson.encode, sceneData)
                    if not encOk then
                        print("[ClientGame] ERROR: cjson.encode failed in T-key path: " .. tostring(jsonStr))
                        -- 编码失败不发送，保持场景不变
                    else
                        data["SceneJson"] = Variant(jsonStr)
                    end
                end
                serverConn_:SendRemoteEvent(Shared.EVENTS.DEBUG_RELOAD, true, data)
                print("[ClientGame] Sent DEBUG_RELOAD for scene " .. scIdx)

                -- 客户端主动清理旧 REPLICATED 节点（与 onSyncReload 同理）
                if scene_ then
                    local children = scene_:GetChildren(false)
                    local cleaned = 0
                    for ci = #children, 1, -1 do
                        local c = children[ci]
                        if c then
                            local ok2, et = pcall(function() return c:GetVar(VARS.ENTITY_TYPE) end)
                            if ok2 and et and type(et.IsEmpty) == "function" and not et:IsEmpty() then
                                if et:GetString() ~= "player" then
                                    c:Remove()
                                    cleaned = cleaned + 1
                                end
                            end
                        end
                    end
                    if cleaned > 0 then
                        print(string.format("[ClientGame] Cleaned %d old entity nodes before reload (T-key)", cleaned))
                    end
                end
            end
        end
        UpdateCamera(dt)
        return  -- toggle 帧不再处理其他输入
    end
    -- 编辑器激活时拦截所有输入
    if MapEditor.IsActive() then
        MapEditor.HandleInput(dt)
        UpdateCamera(dt)
        return
    end

    GatherInput()
    UpdateCamera(dt)

    -- P 键：切换地图预览
    if input:GetKeyPress(KEY_P) then
        mapPreviewOpen_ = not mapPreviewOpen_
    end

    -- 单人调试：Tab 键切换控制角色
    if debugSolo_ and serverConn_ and input:GetKeyPress(KEY_TAB) then
        serverConn_:SendRemoteEvent(Shared.EVENTS.DEBUG_SWITCH, true)
    end
end

return ClientGame
