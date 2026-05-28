--- UI/CharSelectUI.lua
--- 《同途 / Parallax》角色选择界面
--- 双方各选红鸟或黑鸟，不能选同一个

local Shared = require("Network.Shared")
local UI = require("urhox-libs/UI")

local CharSelectUI = {}

-- ─── 颜色常量 ───
local COLOR = {
    BG         = { 18, 18, 32, 255 },
    CARD_RED   = { 45, 20, 20, 255 },
    CARD_BLACK = { 20, 20, 32, 255 },
    CARD_RED_SELECTED   = { 120, 40, 40, 255 },
    CARD_BLACK_SELECTED = { 40, 40, 80, 255 },
    CARD_RED_BORDER     = { 220, 80, 80, 255 },
    CARD_BLACK_BORDER   = { 100, 100, 200, 255 },
    CARD_DEFAULT_BORDER = { 60, 60, 80, 255 },
    TEXT_TITLE  = { 200, 210, 240, 255 },
    TEXT_SUB    = { 120, 125, 155, 255 },
    TEXT_RED    = { 240, 120, 120, 255 },
    TEXT_BLACK  = { 140, 140, 220, 255 },
    TEXT_STATUS = { 160, 170, 200, 255 },
    CONFLICT   = { 255, 180, 60, 255 },
    CONFIRM    = { 80, 220, 140, 255 },
    PARTNER_TAG = { 180, 180, 200, 120 },
}

-- ─── 状态 ───
local myRole_ = Shared.ROLE.NONE
local partnerRole_ = Shared.ROLE.NONE
local conflict_ = false
local confirmed_ = false

---@type function|nil  发送选择的回调
local onPickCallback_ = nil

-- ─── UI 引用 ───
---@type any
local rootWidget_ = nil
---@type any
local statusLabel_ = nil
---@type any
local redCard_ = nil
---@type any
local blackCard_ = nil
---@type any
local redPartnerTag_ = nil
---@type any
local blackPartnerTag_ = nil

-- ═══════════════════════════════════════════════
-- 内部：更新卡片视觉状态
-- ═══════════════════════════════════════════════

local function UpdateCardStyles()
    if not redCard_ or not blackCard_ then return end

    -- 红鸟卡片
    local redSelected = (myRole_ == Shared.ROLE.RED)
    local redPartner = (partnerRole_ == Shared.ROLE.RED)
    redCard_:SetStyle({
        backgroundColor = redSelected and COLOR.CARD_RED_SELECTED or COLOR.CARD_RED,
        borderColor = redSelected and COLOR.CARD_RED_BORDER or COLOR.CARD_DEFAULT_BORDER,
        borderWidth = redSelected and 3 or 1,
    })
    if redPartnerTag_ then
        redPartnerTag_:SetStyle({
            opacity = redPartner and 1.0 or 0.0,
        })
    end

    -- 黑鸟卡片
    local blackSelected = (myRole_ == Shared.ROLE.BLACK)
    local blackPartner = (partnerRole_ == Shared.ROLE.BLACK)
    blackCard_:SetStyle({
        backgroundColor = blackSelected and COLOR.CARD_BLACK_SELECTED or COLOR.CARD_BLACK,
        borderColor = blackSelected and COLOR.CARD_BLACK_BORDER or COLOR.CARD_DEFAULT_BORDER,
        borderWidth = blackSelected and 3 or 1,
    })
    if blackPartnerTag_ then
        blackPartnerTag_:SetStyle({
            opacity = blackPartner and 1.0 or 0.0,
        })
    end

    -- 状态文字
    if statusLabel_ then
        local statusText = ""
        local statusColor = COLOR.TEXT_STATUS

        if confirmed_ then
            statusText = "双方确认完毕，即将进入游戏..."
            statusColor = COLOR.CONFIRM
        elseif conflict_ then
            statusText = "选择冲突！请选另一个角色"
            statusColor = COLOR.CONFLICT
        elseif myRole_ == Shared.ROLE.NONE then
            statusText = "点击选择你的角色"
            statusColor = COLOR.TEXT_SUB
        else
            statusText = "等待搭档选择..."
            statusColor = COLOR.TEXT_STATUS
        end

        statusLabel_:SetStyle({
            text = statusText,
            fontColor = statusColor,
        })
    end
end

-- ═══════════════════════════════════════════════
-- 构建角色卡片
-- ═══════════════════════════════════════════════

local function BuildCharCard(role, emoji, name, desc, accentColor)
    local partnerTag = UI.Label {
        text = "搭档已选",
        fontSize = 11,
        fontColor = COLOR.PARTNER_TAG,
        opacity = 0.0,
        marginBottom = 4,
    }

    local card = UI.Panel {
        flex = 1,
        maxWidth = 220,
        flexDirection = "column",
        alignItems = "center",
        paddingTop = 24, paddingBottom = 24,
        paddingLeft = 16, paddingRight = 16,
        borderRadius = 16,
        borderWidth = 1,
        borderColor = COLOR.CARD_DEFAULT_BORDER,
        backgroundColor = (role == Shared.ROLE.RED) and COLOR.CARD_RED or COLOR.CARD_BLACK,
        transition = "all 0.25s easeOut",
        onClick = function(self)
            if confirmed_ then return end
            if onPickCallback_ then
                onPickCallback_(role)
            end
        end,
        children = {
            partnerTag,
            -- 角色 emoji
            UI.Label {
                text = emoji,
                fontSize = 48,
                marginBottom = 12,
            },
            -- 角色名
            UI.Label {
                text = name,
                fontSize = 22,
                fontWeight = "bold",
                fontColor = accentColor,
                marginBottom = 8,
            },
            -- 角色描述
            UI.Label {
                text = desc,
                fontSize = 13,
                fontColor = COLOR.TEXT_SUB,
                textAlign = "center",
                lineHeight = 1.5,
            },
        },
    }

    return card, partnerTag
end

-- ═══════════════════════════════════════════════
-- 公开 API
-- ═══════════════════════════════════════════════

--- 构建并显示角色选择 UI
---@param onPick fun(role: string)  选择回调，role 为 Shared.ROLE.RED 或 BLACK
function CharSelectUI.Show(onPick)
    onPickCallback_ = onPick
    myRole_ = Shared.ROLE.NONE
    partnerRole_ = Shared.ROLE.NONE
    conflict_ = false
    confirmed_ = false

    statusLabel_ = UI.Label {
        text = "点击选择你的角色",
        fontSize = 15,
        fontColor = COLOR.TEXT_SUB,
        marginBottom = 28,
        transition = "all 0.2s easeOut",
    }

    redCard_, redPartnerTag_ = BuildCharCard(
        Shared.ROLE.RED,
        "🐦",
        "红鸟",
        "乐观主义者\n看见温暖的世界\n花草、阳光、庆典",
        COLOR.TEXT_RED
    )

    blackCard_, blackPartnerTag_ = BuildCharCard(
        Shared.ROLE.BLACK,
        "🦇",
        "黑鸟",
        "悲观主义者\n看见冰冷的世界\n裂缝、废墟、求生",
        COLOR.TEXT_BLACK
    )

    rootWidget_ = UI.Panel {
        width = "100%", height = "100%",
        flexDirection = "column",
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = COLOR.BG,
        children = {
            -- 标题
            UI.Label {
                text = "选择你的角色",
                fontSize = 26,
                fontWeight = "bold",
                fontColor = COLOR.TEXT_TITLE,
                marginBottom = 8,
            },
            UI.Label {
                text = "两位玩家不能选择相同角色",
                fontSize = 13,
                fontColor = COLOR.TEXT_SUB,
                marginBottom = 12,
            },

            -- 状态文字
            statusLabel_,

            -- 双卡片区域
            UI.Panel {
                flexDirection = "row",
                gap = 24,
                paddingLeft = 24,
                paddingRight = 24,
                children = {
                    redCard_,
                    blackCard_,
                },
            },

            -- 返回大厅按钮
            UI.Panel {
                marginTop = 36,
                children = {
                    UI.Button {
                        text = "返回大厅",
                        variant = "ghost",
                        fontSize = 13,
                        onClick = function(self)
                            if onPickCallback_ then
                                -- 通过回调发 nil 表示返回大厅
                                onPickCallback_(nil)
                            end
                        end,
                    },
                },
            },
        },
    }

    UI.SetRoot(rootWidget_)
    print("[CharSelectUI] Shown")
end

--- 更新选择状态（收到服务器 CHARACTER_RESULT 后调用）
---@param myR string
---@param partnerR string
---@param isConflict boolean
---@param isConfirmed boolean
function CharSelectUI.UpdateState(myR, partnerR, isConflict, isConfirmed)
    myRole_ = myR
    partnerRole_ = partnerR
    conflict_ = isConflict
    confirmed_ = isConfirmed

    UpdateCardStyles()
    print(string.format("[CharSelectUI] Update: me=%s partner=%s conflict=%s confirmed=%s",
        myR, partnerR, tostring(isConflict), tostring(isConfirmed)))
end

--- 隐藏角色选择 UI
function CharSelectUI.Hide()
    rootWidget_ = nil
    statusLabel_ = nil
    redCard_ = nil
    blackCard_ = nil
    redPartnerTag_ = nil
    blackPartnerTag_ = nil
    onPickCallback_ = nil
    print("[CharSelectUI] Hidden")
end

return CharSelectUI
