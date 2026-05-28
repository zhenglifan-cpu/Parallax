--- Match/FriendCode.lua
--- 好友码模块：通过 clientCloud API 实现跨用户房间会合
---
--- 原理：
---   clientCloud:SetInt("room_ABCDEF", timestamp)   写入 Cloud key
---   clientCloud:GetRankList("room_ABCDEF", ...)     查询所有写入该 key 的用户
---   当 rankList 中出现 >= 2 人 → 双方都在匹配队列中
---   引擎 free_match 随机配对后，由服务端验证好友码是否一致

local Shared = require("Network.Shared")

local FriendCode = {}

-- ─── 状态定义 ───
FriendCode.STATE = {
    IDLE          = "idle",           -- 初始状态
    CREATING_ROOM = "creating_room",  -- 创建房间中（等待 Cloud 写入）
    WAITING       = "waiting",        -- 等待伙伴加入
    JOINING_ROOM  = "joining_room",   -- 加入房间中（验证中）
    QUEUING       = "queuing",        -- 在匹配队列中（等待引擎配对）
    CONNECTED     = "connected",      -- 已连接到服务器
}

-- ─── 好友码字符集（排除易混淆字符 0/O/1/I/L） ───
local CHARSET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

-- ─── 内部状态 ───
local state_ = FriendCode.STATE.IDLE
local currentCode_ = ""              -- 当前好友码
local pollTimer_ = 0                 -- 轮询计时器
local onStateChange_ = nil           -- 状态变更回调
local onError_ = nil                 -- 错误回调

--- 获取 clientCloud（延迟访问，background_match 模式下 Start() 时可能尚未注入）
---@return boolean ok  clientCloud 是否可用
local function EnsureCloud()
    if clientCloud then return true end
    print("[FriendCode] WARNING: clientCloud 尚未可用")
    return false
end

--- 初始化模块
---@param callbacks table { onStateChange: function(state, data), onError: function(msg) }
function FriendCode.Init(callbacks)
    onStateChange_ = callbacks and callbacks.onStateChange or nil
    onError_ = callbacks and callbacks.onError or nil
    state_ = FriendCode.STATE.IDLE
    currentCode_ = ""
    pollTimer_ = 0
    print("[FriendCode] Init (clientCloud " .. (clientCloud and "ready" or "pending") .. ")")
end

--- 获取当前状态
---@return string
function FriendCode.GetState()
    return state_
end

--- 获取当前好友码
---@return string
function FriendCode.GetCode()
    return currentCode_
end

--- 生成随机好友码
---@return string
function FriendCode.GenerateCode()
    local code = ""
    local len = Shared.FRIEND_CODE.LENGTH
    local charsetLen = #CHARSET
    for i = 1, len do
        local idx = math.random(1, charsetLen)
        code = code .. CHARSET:sub(idx, idx)
    end
    return code
end

--- 设置状态并通知
---@param newState string
---@param data any
local function SetState(newState, data)
    local oldState = state_
    state_ = newState
    print("[FriendCode] " .. oldState .. " -> " .. newState)
    if onStateChange_ then
        onStateChange_(newState, data)
    end
end

--- 报告错误
---@param msg string
local function ReportError(msg)
    print("[FriendCode] ERROR: " .. msg)
    if onError_ then
        onError_(msg)
    end
end

--- Cloud key 名
---@param code string
---@return string
local function CloudKey(code)
    return Shared.FRIEND_CODE.CLOUD_PREFIX .. code
end

--- 创建房间（生成好友码，写入 Cloud，等待伙伴加入）
---@param code string|nil  可选，不传则自动生成
function FriendCode.CreateRoom(code)
    if state_ ~= FriendCode.STATE.IDLE then
        ReportError("无法创建房间：当前状态 " .. state_)
        return
    end
    if not EnsureCloud() then
        ReportError("云服务尚未就绪，请稍后再试")
        return
    end

    code = code or FriendCode.GenerateCode()
    currentCode_ = code
    SetState(FriendCode.STATE.CREATING_ROOM)

    local key = CloudKey(code)
    local timestamp = os.time()

    print("[FriendCode] 创建房间: code=" .. code .. " key=" .. key)

    clientCloud:SetInt(key, timestamp, {
        ok = function()
            print("[FriendCode] Cloud 写入成功, 开始等待伙伴")
            pollTimer_ = 0
            SetState(FriendCode.STATE.WAITING, { code = code })
        end,
        error = function(errCode, reason)
            ReportError("Cloud 写入失败: " .. tostring(reason))
            SetState(FriendCode.STATE.IDLE)
        end
    })
end

--- 加入房间（验证房间存在 → 写入自己的条目）
---@param code string 好友码
function FriendCode.JoinRoom(code)
    if state_ ~= FriendCode.STATE.IDLE then
        ReportError("无法加入房间：当前状态 " .. state_)
        return
    end
    if not EnsureCloud() then
        ReportError("云服务尚未就绪，请稍后再试")
        return
    end

    code = string.upper(code)
    currentCode_ = code
    SetState(FriendCode.STATE.JOINING_ROOM)

    local key = CloudKey(code)
    print("[FriendCode] 尝试加入房间: code=" .. code)

    -- 先查询房间是否存在
    clientCloud:GetRankList(key, 0, 10, {
        ok = function(rankList)
            if not rankList or #rankList == 0 then
                ReportError("房间不存在: " .. code)
                SetState(FriendCode.STATE.IDLE)
                return
            end

            -- 检查是否过期
            local hostEntry = rankList[1]
            local hostTimestamp = 0
            if hostEntry and hostEntry.iscore then
                hostTimestamp = hostEntry.iscore[key] or 0
            end

            local now = os.time()
            if hostTimestamp > 0 and (now - hostTimestamp) > Shared.FRIEND_CODE.EXPIRE_SEC then
                ReportError("房间已过期: " .. code)
                SetState(FriendCode.STATE.IDLE)
                return
            end

            -- 检查是否已满（2人）
            if #rankList >= 2 then
                ReportError("房间已满: " .. code)
                SetState(FriendCode.STATE.IDLE)
                return
            end

            -- 写入自己的条目
            print("[FriendCode] 房间存在，写入自己的条目")
            clientCloud:SetInt(key, now, {
                ok = function()
                    print("[FriendCode] 加入成功，进入匹配队列")
                    pollTimer_ = 0
                    SetState(FriendCode.STATE.QUEUING, { code = code })
                end,
                error = function(errCode, reason)
                    ReportError("Cloud 写入失败: " .. tostring(reason))
                    SetState(FriendCode.STATE.IDLE)
                end
            })
        end,
        error = function(errCode, reason)
            ReportError("Cloud 查询失败: " .. tostring(reason))
            SetState(FriendCode.STATE.IDLE)
        end
    })
end

--- 快速匹配（无好友码，直接排队）
function FriendCode.QuickMatch()
    if state_ ~= FriendCode.STATE.IDLE then
        ReportError("无法快速匹配：当前状态 " .. state_)
        return
    end

    currentCode_ = ""
    print("[FriendCode] 快速匹配：直接进入队列")
    SetState(FriendCode.STATE.QUEUING)
end

--- 轮询：检查是否有伙伴加入房间（仅在 WAITING 状态使用）
local function PollForJoiner()
    if not EnsureCloud() then return end

    local key = CloudKey(currentCode_)

    clientCloud:GetRankList(key, 0, 10, {
        ok = function(rankList)
            if state_ ~= FriendCode.STATE.WAITING then
                return  -- 状态已改变，忽略
            end

            if rankList and #rankList >= 2 then
                print("[FriendCode] 伙伴已加入！rankList 人数: " .. #rankList)
                SetState(FriendCode.STATE.QUEUING, { code = currentCode_ })
            end
        end,
        error = function(errCode, reason)
            print("[FriendCode] 轮询查询失败: " .. tostring(reason))
            -- 不改变状态，下次继续轮询
        end
    })
end

--- 每帧更新（在客户端 HandleUpdate 中调用）
---@param dt number 帧时间
function FriendCode.Update(dt)
    if state_ == FriendCode.STATE.WAITING then
        pollTimer_ = pollTimer_ + dt
        if pollTimer_ >= Shared.FRIEND_CODE.POLL_INTERVAL then
            pollTimer_ = 0
            PollForJoiner()
        end
    end
end

--- 取消当前操作，回到 IDLE
function FriendCode.Cancel()
    if state_ == FriendCode.STATE.IDLE then
        return
    end

    local oldCode = currentCode_
    print("[FriendCode] 取消操作, code=" .. oldCode)

    -- 清理 Cloud 条目
    if oldCode ~= "" then
        FriendCode.Cleanup(oldCode)
    end

    currentCode_ = ""
    pollTimer_ = 0
    SetState(FriendCode.STATE.IDLE)
end

--- 清理 Cloud 中的房间条目
---@param code string
function FriendCode.Cleanup(code)
    if code == "" then return end
    if not EnsureCloud() then return end

    local key = CloudKey(code)
    print("[FriendCode] 清理 Cloud key: " .. key)

    clientCloud:BatchSet()
        :Delete(key)
        :Save("清理好友码", {
            ok = function()
                print("[FriendCode] Cloud 清理完成: " .. key)
            end,
            error = function(errCode, reason)
                print("[FriendCode] Cloud 清理失败: " .. tostring(reason))
            end
        })
end

--- 标记为已连接
function FriendCode.SetConnected()
    SetState(FriendCode.STATE.CONNECTED)
end

--- 重置模块（用于 ReturnToLobby 后重新开始）
function FriendCode.Reset()
    local oldCode = currentCode_
    if oldCode ~= "" then
        FriendCode.Cleanup(oldCode)
    end
    currentCode_ = ""
    pollTimer_ = 0
    state_ = FriendCode.STATE.IDLE
    print("[FriendCode] 模块已重置")
end

return FriendCode
