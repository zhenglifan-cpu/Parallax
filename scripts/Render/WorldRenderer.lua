--- Render/WorldRenderer.lua
--- 《同途 / Parallax》NanoVG 世界渲染器
--- 负责将服务端同步的 Node 数据绘制到屏幕上
--- 支持视差背景、平台、角色、NPC、可交互物

local GameConst     = require("Game.GameConst")
local Shared        = require("Network.Shared")
local DualWorldSkin = require("Render.DualWorldSkin")
local SlopePhysics  = require("Editor.SlopePhysics")

local VARS = Shared.VARS
local PPU  = GameConst.PIXELS_PER_UNIT   -- pixels per unit

local SpriteAnim    = require("Render.SpriteAnim")
local EditorConst   = require("Editor.EditorConst")

local WorldRenderer = {}

-- ═══════════════════════════════════════════════
-- 地面贴图覆盖层（groundOverlays）
-- 由外部调用 WorldRenderer.SetSceneOverlays 设置
-- ═══════════════════════════════════════════════
--- 当前场景的地面贴图覆盖层列表（每个 overlay 含 role/imagePath/gx1/gx2/gy1/gy2/offsetX/offsetY）
local sceneOverlays_ = {}

--- 当前场景的自由贴图列表（每个 freeOv 含 id/role/imagePath/x/y/w/h/rotation）
--- x/y 为世界坐标中心，w/h 为世界单位宽高，rotation 为角度（0~360）
local sceneFreeOverlays_ = {}

--- 设置当前场景的 groundOverlays（切换场景时由 ClientGame 调用）
---@param overlays table|nil
function WorldRenderer.SetSceneOverlays(overlays)
    sceneOverlays_ = overlays or {}
end

--- 设置当前场景的 freeOverlays（编辑器调用）
---@param freeOverlays table|nil
function WorldRenderer.SetFreeOverlays(freeOverlays)
    sceneFreeOverlays_ = freeOverlays or {}
end

--- 判断平台/斜坡（以世界坐标矩形表示）是否被某个 overlay 完全遮盖
--- 只有当 overlay.role == myRole 时才生效
---@param wxLeft  number 平台左边世界 X
---@param wxRight number 平台右边世界 X
---@param wyBot   number 平台底部世界 Y
---@param wyTop   number 平台顶部世界 Y
---@param myRole  string 当前观察者角色
---@return boolean
local function IsCoveredByOverlay(wxLeft, wxRight, wyBot, wyTop, myRole)
    local cs = EditorConst.CELL_SIZE
    for _, ov in ipairs(sceneOverlays_) do
        if ov.role == myRole then
            -- overlay 覆盖的世界矩形（注意 gy 用 CELL_SIZE 换算，Y 轴向上）
            local ovLeft  = ov.gx1 * cs
            local ovRight = (ov.gx2 + 1) * cs
            local ovBot   = ov.gy1 * cs
            local ovTop   = (ov.gy2 + 1) * cs
            -- 平台矩形必须完全位于 overlay 覆盖范围内
            if wxLeft  >= ovLeft  - 0.001 and wxRight <= ovRight + 0.001
            and wyBot  >= ovBot   - 0.001 and wyTop  <= ovTop   + 0.001 then
                return true
            end
        end
    end
    return false
end

-- 朝向跟踪（用于精灵翻转）和状态判定
local spriteLastPosX_    = {}
local spriteLastPosY_    = {}
local spriteFacingLeft_  = {}
local spriteIsRunning_   = {}   -- 是否在跑步（水平移动 + 在地面）
-- 跑步动画：位移驱动，每移动 RUN_STRIDE_LENGTH 米完成一个动画循环
-- 调大 → 步频变慢；调小 → 步频变快
-- 原值 1.5 → 2.25（降到 2/3）→ 4.5（再降到 1/2），使跑步动画帧速率为原始的 1/3
local RUN_STRIDE_LENGTH  = 4.5
local spriteRunElapsed_  = {}   -- 每玩家独立的跑步动画累计位移换算时长（秒）
local spriteWasOnGround_ = {}   -- 上一帧是否在地面（用于检测起跳瞬间）
local spriteJumpElapsed_ = {}  -- 每玩家独立的跳跃动画已播时长（秒）
local spriteJumpSpeed_   = {}  -- 跳跃动画匀速播放速率（animDuration / jumpAirTime）
-- 匀速原理：speed = animDuration / totalAirTime，末帧与落地精确对齐。
-- 起跳时以"默认短跳总时长"（≈0.575s）为基准设置初始速率；
-- 收到 JumpCut / LongJumpConfirmed 后用 remAnim / remTime 重校，消除网络延迟误差。
-- 动画播放时间相对物理时间的缩放倍数（>1 使动画播得更慢，可看到更完整的下落帧）
-- 1.5 意味着动画时间 = 物理空中时间 × 1.5；落地时动画约在 2/3 处，之后 clamp 至末帧
-- JUMP_ANIM_TIME_SCALE 已移除：动画时长直接对齐物理时长（1:1），不再人为拉伸
-- OnGround 防抖：斜坡过渡时 EndContact/BeginContact 之间有 1-2 帧空白，
-- OnGround 会短暂变为 false，导致奔跑/待机动画交叉闪烁。
-- 只有连续 OFFGROUND_DEBOUNCE_FRAMES 帧都是 false 才真正切换到"空中"。
local OFFGROUND_DEBOUNCE_FRAMES = 6  -- 约 6/60 ≈ 100ms，下坡顶点穿越比上坡多，需更长防抖
local spriteOffGroundFrames_ = {}    -- 每玩家连续"离地"帧计数

-- ═══════════════════════════════════════════════
-- 精灵动画资源（延迟加载）
-- 按 "观察者视角_目标角色" 双键映射
-- ═══════════════════════════════════════════════
---@type table<string, table>  -- "viewerRole_targetRole" → { idle = SpriteAnim, ... }
local spriteAnims_ = {}
local spriteAnimsInited_ = false

--- 构造精灵动画映射键
local function SpriteKey(viewerRole, targetRole)
    return viewerRole .. "_" .. targetRole
end

--- 初始化精灵动画（首次渲染时延迟加载）
local function EnsureSpriteAnims(vg)
    if spriteAnimsInited_ then return end
    spriteAnimsInited_ = true

    local RED   = Shared.ROLE.RED
    local BLACK = Shared.ROLE.BLACK

    -- 精灵配置表：{ viewerRole, targetRole, pngPath, jsonPath, gridHeight, offsetY_px, defaultFlipX }
    -- gridHeight: 绘制高度（网格单位），offsetY_px: 额外向下偏移（像素）
    -- defaultFlipX: true 表示原图朝向与游戏默认朝向相反，需要翻转
    -- 全部高度已按 0.99格身高同比缩放（原比例 × 0.6875 × 0.9）
    -- idle RED: 1.375→1.238, idle BLACK: 1.513→1.362
    local configs = {
        { RED,   RED,   "Sprites/RedBird/idle.png",            "Sprites/RedBird/idle.json",           1.238, 5, true },
        { RED,   BLACK, "Sprites/RedView_BlackBird/idle.png",  "Sprites/RedView_BlackBird/idle.json", 1.362, 6, false },
        { BLACK, BLACK, "Sprites/BlackView_BlackBird/idle.png","Sprites/BlackView_BlackBird/idle.json",1.362, 6, true },
        { BLACK, RED,   "Sprites/BlackView_RedBird/idle.png",  "Sprites/BlackView_RedBird/idle.json", 1.238, 5, false },
    }

    for _, cfg in ipairs(configs) do
        local viewer, target, png, json = cfg[1], cfg[2], cfg[3], cfg[4]
        local anim = SpriteAnim.Load(vg, png, json)
        if anim then
            local key = SpriteKey(viewer, target)
            spriteAnims_[key] = {
                idle = anim,
                drawGridH    = cfg[5],
                offsetY      = cfg[6],
                defaultFlipX = cfg[7] or false,
            }
            print(string.format("[WorldRenderer] Sprite loaded: %s viewing %s (h=%.1f grids, offY=%dpx)", viewer, target, cfg[5], cfg[6]))
        end
    end

    -- 跑步动画（仅部分角色有）
    -- { viewerRole, targetRole, pngPath, jsonPath, runDefaultFlipX }
    -- runDefaultFlipX: 跑步动画原图朝向是否与游戏默认朝向相反（独立于 idle 的 defaultFlipX）
    local runConfigs = {
        { RED,   RED,   "Sprites/RedBird/run.png",            "Sprites/RedBird/run.json",            true },
        { RED,   BLACK, "Sprites/RedView_BlackBird/run.png",  "Sprites/RedView_BlackBird/run.json",  true },
        { BLACK, BLACK, "Sprites/BlackView_BlackBird/run.png","Sprites/BlackView_BlackBird/run.json", true },
        { BLACK, RED,   "Sprites/BlackView_RedBird/run.png",  "Sprites/BlackView_RedBird/run.json",  false },
    }
    for _, rc in ipairs(runConfigs) do
        local viewer, target, png, json = rc[1], rc[2], rc[3], rc[4]
        local key = SpriteKey(viewer, target)
        local entry = spriteAnims_[key]
        if entry then
            local runAnim = SpriteAnim.Load(vg, png, json)
            if runAnim then
                -- 红鸟视角红鸟奔跑：跳过第 1、2、3 帧、倒数第 2 帧和最后一帧，仅循环中间帧
                if viewer == RED and target == RED then
                    local allFrames = runAnim.frames
                    local total = runAnim.frameCount
                    -- 保留第 4 帧到倒数第 3 帧（Lua 索引 4 .. total-2）
                    if total >= 6 then  -- 至少保留 1 帧才裁剪
                        -- 计算裁剪后的帧间隔（原始帧间隔保持不变）
                        local frameInterval = (total >= 2) and (allFrames[2].t - allFrames[1].t) or 0
                        local trimmed = {}
                        for i = 4, total - 2 do
                            trimmed[#trimmed + 1] = allFrames[i]
                        end
                        -- 重新归一化时间戳：从 0 开始，保持原帧间隔
                        local baseT = trimmed[1].t
                        for _, f in ipairs(trimmed) do
                            f.t = f.t - baseT
                        end
                        runAnim.frames        = trimmed
                        runAnim.frameCount    = #trimmed
                        runAnim.totalDuration = (#trimmed > 0) and (trimmed[#trimmed].t + frameInterval) or 0
                        print(string.format("[WorldRenderer] RED_RED run: trimmed to frames 4~%d (%d frames, %.2fs)",
                            total - 2, #trimmed, runAnim.totalDuration))
                    end
                end
                entry.run = runAnim
                entry.runDefaultFlipX = rc[5] or false
                print(string.format("[WorldRenderer] Run sprite loaded: %s viewing %s (flipX=%s)", viewer, target, tostring(entry.runDefaultFlipX)))
            end
        end
    end

    -- 跳跃动画
    -- { viewerRole, targetRole, pngPath, jsonPath, jumpDefaultFlipX, jumpDrawGridH }
    -- jumpDrawGridH: 跳跃帧内角色留白较多，需单独指定更大的渲染高度补偿视觉缩小问题
    -- 全部高度已按 0.99格身高同比缩放（原比例 × 0.6875 × 0.9）
    -- jump RED: 1.719→1.547, jump RED-BLACK: 2.063→1.857, jump BLACK-BLACK: 1.891→1.702
    local jumpConfigs = {
        { RED,   RED,   "Sprites/RedBird/jump.png",            "Sprites/RedBird/jump.json",            true,  1.547 },
        { RED,   BLACK, "Sprites/RedView_BlackBird/jump.png",  "Sprites/RedView_BlackBird/jump.json",  true,  1.857 },
        { BLACK, BLACK, "Sprites/BlackView_BlackBird/jump.png","Sprites/BlackView_BlackBird/jump.json", true,  1.702 },
        { BLACK, RED,   "Sprites/BlackView_RedBird/jump.png",  "Sprites/BlackView_RedBird/jump.json",  true,  1.547 },
    }
    for _, jc in ipairs(jumpConfigs) do
        local viewer, target, png, json = jc[1], jc[2], jc[3], jc[4]
        local key = SpriteKey(viewer, target)
        local entry = spriteAnims_[key]
        if entry then
            local jumpAnim = SpriteAnim.Load(vg, png, json)
            if jumpAnim then
                entry.jump = jumpAnim
                entry.jumpDefaultFlipX = jc[5] or false
                entry.jumpDrawGridH    = jc[6] or entry.drawGridH
                print(string.format("[WorldRenderer] Jump sprite loaded: %s viewing %s (flipX=%s, jumpGridH=%.2f)", viewer, target, tostring(entry.jumpDefaultFlipX), entry.jumpDrawGridH))
            end
        end
    end
end

-- ═══════════════════════════════════════════════
-- 背景图片资源（延迟加载）
-- ═══════════════════════════════════════════════
local bgImages_ = {}          -- 缓存已加载的 NanoVG 图片句柄
local bgImageSizes_ = {}      -- 缓存图片原始尺寸 {w, h}

--- 获取（或延迟加载）NanoVG 图片句柄
local bgImageFailed_ = {}  -- key → true 表示已尝试加载但失败
local function GetBgImage(vg, key, path)
    if bgImageFailed_[key] then return nil, nil end
    if bgImages_[key] then return bgImages_[key], bgImageSizes_[key] end
    local img = nvgCreateImage(vg, path, 0)
    if not img or img <= 0 then
        bgImageFailed_[key] = true
        return nil, nil
    end
    local iw, ih = nvgImageSize(vg, img)
    bgImages_[key] = img
    bgImageSizes_[key] = { w = iw, h = ih }
    return img, bgImageSizes_[key]
end

-- ═══════════════════════════════════════════════
-- freeOverlay 专用图片缓存
-- 使用 NVG_IMAGE_NEAREST(32) 保持像素锐利；
-- 用引擎 Image 资源获取真实原始尺寸，规避 nvgImageSize 返回 POT 纹理尺寸的问题。
-- ═══════════════════════════════════════════════
local freeOvImages_ = {}  -- key → { img, w, h }  w/h 为原始像素尺寸

--- 获取 freeOverlay 专用图片（NVG_IMAGE_NEAREST + 真实像素尺寸）
---@return number img, table|nil sz   sz = {w, h} 原始像素尺寸
local function GetFreeOvImage(vg, key, path)
    if freeOvImages_[key] then
        local cached = freeOvImages_[key]
        if cached.failed then return nil, nil end
        return cached.img, cached
    end
    -- NVG_IMAGE_NEAREST (32)：最近邻采样，保持贴图像素清晰不模糊
    local img = nvgCreateImage(vg, path, 32)
    if not img or img <= 0 then
        -- 缓存失败结果，避免每帧重试导致错误洪泛
        print("[WorldRenderer] nvgCreateImage FAILED for: " .. tostring(path) .. " key=" .. tostring(key))
        freeOvImages_[key] = { img = -1, w = 0, h = 0, failed = true }
        return nil, nil
    end
    print("[WorldRenderer] nvgCreateImage OK: " .. tostring(path))
    -- 优先从引擎 Image 资源获取原始像素尺寸（规避 nvgImageSize 可能返回 POT 扩展后的尺寸）
    local actualW, actualH = 0, 0
    local imgRes = cache:GetResource("Image", path)
    if imgRes and imgRes.width and imgRes.width > 0 then
        actualW = imgRes.width
        actualH = imgRes.height
    else
        actualW, actualH = nvgImageSize(vg, img)
    end
    freeOvImages_[key] = { img = img, w = actualW, h = actualH }
    return img, freeOvImages_[key]
end

-- ═══════════════════════════════════════════════
-- 坐标变换
-- ═══════════════════════════════════════════════

--- 世界坐标 → 屏幕坐标（Y 翻转）
---@param wx number 世界 X (m)
---@param wy number 世界 Y (m)
---@param camX number 相机世界 X
---@param camY number 相机世界 Y
---@param screenW number 屏幕宽
---@param screenH number 屏幕高
---@return number sx, number sy
local function WorldToScreen(wx, wy, camX, camY, screenW, screenH)
    local sx = (wx - camX) * PPU + screenW * 0.5
    local sy = screenH * 0.5 - (wy - camY) * PPU
    return sx, sy
end

-- ═══════════════════════════════════════════════
-- 绘制：天空 + 视差背景
-- ═══════════════════════════════════════════════

local function DrawSky(vg, w, h, skin)
    local c1, c2 = DualWorldSkin.GradientColors(skin.skyTop, skin.skyBottom)
    local paint = nvgLinearGradient(vg, 0, 0, 0, h, c1, c2)
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillPaint(vg, paint)
    nvgFill(vg)
end

--- 绘制简化视差山脉层
local function DrawParallaxLayer(vg, w, h, camX, factor, color, baseY, amplitude, waveLen)
    nvgBeginPath(vg)
    local offsetX = camX * factor * PPU
    local startY = h * baseY
    nvgMoveTo(vg, 0, h)
    for x = 0, w, 8 do
        local worldXPhase = (x + offsetX) / waveLen
        local peakY = startY - amplitude * (math.sin(worldXPhase) * 0.6 + math.sin(worldXPhase * 2.3) * 0.4)
        nvgLineTo(vg, x, peakY)
    end
    nvgLineTo(vg, w, h)
    nvgClosePath(vg)
    nvgFillColor(vg, DualWorldSkin.Color(color))
    nvgFill(vg)
end

--- 用图片绘制视差层（高度铺满画面，宽度严格按原图比例，水平视差滚动）
local function DrawParallaxImage(vg, w, h, camX, factor, imgKey, imgPath, origW, origH)
    local img, sz = GetBgImage(vg, imgKey, imgPath)
    if not img then return false end

    -- 使用原图真实尺寸计算宽高比（避免 nvgImageSize 返回 POT 纹理尺寸导致比例失真）
    local srcW = origW or sz.w
    local srcH = origH or sz.h

    -- 高度铺满画面，宽度按原图真实宽高比计算
    local drawH = h
    local drawW = drawH * (srcW / srcH)

    -- 视差偏移
    local offsetX = -camX * factor * PPU
    -- 步进宽度减 1 像素，让相邻图片左右重叠 1px 消除拼接线
    local step = drawW - 1
    -- 将偏移量规范到 [0, step) 以实现无缝水平循环
    local ox = offsetX % step
    if ox > 0 then ox = ox - step end  -- 确保从左侧开始

    -- 循环铺满屏幕宽度
    -- pattern 和 rect 大小一致 → NanoVG 将完整图片映射到矩形内
    nvgSave(vg)
    nvgIntersectScissor(vg, 0, 0, w, h)
    local x = ox
    while x < w do
        local paint = nvgImagePattern(vg, x, 0, drawW, drawH, 0, img, 1.0)
        nvgBeginPath(vg)
        nvgRect(vg, x, 0, drawW, drawH)
        nvgFillPaint(vg, paint)
        nvgFill(vg)
        x = x + step  -- 步进比图片窄 1px → 重叠 1px
    end
    nvgRestore(vg)
    return true
end

--- 用图片绘制视差近景条（水平无限平铺，保持宽高比不变形）
--- bottomRatio: 图片底边所在屏幕高度比例（0~1），默认 1.0 = 屏幕最底部
--- heightRatio: 指定图片显示高度占屏幕高度的比例；不传则以 DESIGN_HEIGHT 为基准等比缩放
local function DrawParallaxImageStrip(vg, w, h, camX, factor, imgKey, imgPath, origW, origH, bottomRatio, heightRatio)
    local img, sz = GetBgImage(vg, imgKey, imgPath)
    if not img then return false end

    local srcW = origW or sz.w
    local srcH = origH or sz.h

    local drawH, drawW
    if heightRatio then
        -- 按屏幕高度比例指定：宽度同比缩放，保持原宽高比
        drawH = h * heightRatio
        drawW = srcW * (drawH / srcH)
    else
        -- 以设计高度为参考缩放：保持原图在设计分辨率下的像素密度
        local scale = h / GameConst.DESIGN_HEIGHT
        drawH = srcH * scale
        drawW = srcW * scale
    end

    -- 底边锚点
    local bottom = h * (bottomRatio or 1.0)
    local top    = bottom - drawH

    -- 视差偏移（与 DrawParallaxImage 方向一致）
    local offsetX = -camX * factor * PPU
    -- 步进 = 内容宽度 - 1px，相邻 tile 重叠 1 像素消除拼接缝隙
    local step = drawW - 1
    if step < 1 then step = 1 end
    local ox = offsetX % step
    if ox > 0 then ox = ox - step end      -- 确保从左侧起始

    -- NanoVG 内部已处理 POT 纹理 UV，pattern 与 rect 保持同等尺寸，图片完整映射其中
    nvgSave(vg)
    nvgIntersectScissor(vg, 0, 0, w, h)
    local x = ox
    while x < w do
        local paint = nvgImagePattern(vg, x, top, drawW, drawH, 0, img, 1.0)
        nvgBeginPath(vg)
        nvgRect(vg, x, top, drawW, drawH)
        nvgFillPaint(vg, paint)
        nvgFill(vg)
        x = x + step
    end
    nvgRestore(vg)
    return true
end

local function DrawBackground(vg, w, h, camX, skin, myRole, sceneIdx)
    DrawSky(vg, w, h, skin)

    -- Layer 1（最远层）：红鸟第一章用图片替换
    local layer1Replaced = false
    if myRole == Shared.ROLE.RED and sceneIdx == 0 then
        layer1Replaced = DrawParallaxImage(vg, w, h, camX, 0.1,
            "ch1_layer1", "image/背景/bg_layer1_city.png", 1915, 821)
    end
    if not layer1Replaced then
        DrawParallaxLayer(vg, w, h, camX, 0.1, skin.mountainFar,  0.55, 40, 400)
    end

    -- Layer 2：红鸟视角隐藏
    if myRole ~= Shared.ROLE.RED then
        DrawParallaxLayer(vg, w, h, camX, 0.3, skin.mountainMid,  0.65, 55, 280)
    end

    -- Layer 3（近景：图片卷轴，底部对齐，保持原图比例）
    -- heightRatio=3/5：顶在屏幕1/5处，底在屏幕4/5处（drawH = h*3/5，bottomRatio=4/5）
    -- 原图 14146×1060，已缩至 4096×307（宽高比不变，WebGL 纹理宽度安全上限 4096）
    local layer3Replaced = DrawParallaxImageStrip(vg, w, h, camX, 0.6,
        "layer3_near", "image/背景/近景1.2.png", 4096, 307, 4/5, 3/5)
    if not layer3Replaced then
        DrawParallaxLayer(vg, w, h, camX, 0.6, skin.mountainNear, 0.75, 35, 200)
    end
end

-- ═══════════════════════════════════════════════
-- 砖石纹理辅助：在矩形区域内绘制砖缝线
-- left/top/pw/ph  屏幕像素坐标与尺寸
-- worldLeft/worldTop  该矩形对应的世界坐标左上角（用于跨平台砖缝对齐）
-- baseColor {r,g,b,a}  基底填充色
-- ═══════════════════════════════════════════════
local BRICK_ROW_H = GameConst.PIXELS_PER_UNIT * 0.5   -- 45px 一行砖 (= 0.5m)
local BRICK_COL_W = GameConst.PIXELS_PER_UNIT * 1.0   -- 90px 一列砖 (= 1.0m)
local MORTAR_A    = 55   -- 砖缝线 alpha（半透明暗纹）

local function DrawBrickSurface(vg, left, top, pw, ph, worldLeft, worldTop, baseColor, radius)
    radius = radius or 3
    local r, g, b, a = baseColor[1], baseColor[2], baseColor[3], (baseColor[4] or 255)

    -- 1. 渐变填充：顶部亮 (+16) → 底部暗 (-12)
    local rT, gT, bT = math.min(r+16,255), math.min(g+16,255), math.min(b+16,255)
    local rB, gB, bB = math.max(r-12,0),   math.max(g-12,0),   math.max(b-12,0)
    local grad = nvgLinearGradient(vg, left, top, left, top + ph,
        nvgRGBA(rT, gT, bT, a), nvgRGBA(rB, gB, bB, a))
    nvgBeginPath(vg)
    nvgRoundedRect(vg, left, top, pw, ph, radius)
    nvgFillPaint(vg, grad)
    nvgFill(vg)

    -- 2. 砖缝线（用 Scissor 裁剪到矩形内）
    nvgSave(vg)
    nvgIntersectScissor(vg, left, top, pw, ph)

    -- 世界坐标偏移转换为像素偏移，保证相邻平台砖缝连续
    local rowOffset = math.fmod(math.abs(worldTop) * PPU, BRICK_ROW_H)
    local colOffset = math.fmod(math.abs(worldLeft) * PPU, BRICK_COL_W)

    nvgBeginPath(vg)
    nvgStrokeColor(vg, nvgRGBA(0, 0, 0, MORTAR_A))
    nvgStrokeWidth(vg, 1.0)

    -- 水平砖缝（每行一条）
    local y = top + (BRICK_ROW_H - rowOffset)
    while y < top + ph do
        nvgMoveTo(vg, left, y)
        nvgLineTo(vg, left + pw, y)
        y = y + BRICK_ROW_H
    end

    -- 垂直砖缝（交错排列）
    local row = 0
    local yy = top + (BRICK_ROW_H - rowOffset)
    local prevYY = top
    while prevYY < top + ph do
        -- 奇偶行错位半块
        local stagger = (row % 2 == 0) and 0 or (BRICK_COL_W * 0.5)
        local x = left + math.fmod((BRICK_COL_W - colOffset + stagger), BRICK_COL_W)
        local bandTop    = prevYY
        local bandBottom = math.min(yy, top + ph)
        while x < left + pw do
            nvgMoveTo(vg, x, bandTop)
            nvgLineTo(vg, x, bandBottom)
            x = x + BRICK_COL_W
        end
        row = row + 1
        prevYY = yy
        yy = yy + BRICK_ROW_H
    end

    nvgStroke(vg)

    -- 3. 顶部高光条（模拟受光顶面）
    nvgBeginPath(vg)
    nvgRoundedRectVarying(vg, left, top, pw, 3, radius, radius, 0, 0)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 35))
    nvgFill(vg)

    nvgRestore(vg)
end

-- ═══════════════════════════════════════════════
-- 绘制：平台
-- ═══════════════════════════════════════════════

---@param vg userdata
---@param node Node
---@param camX number
---@param camY number
---@param sw number 屏幕宽
---@param sh number 屏幕高
---@param skin table
---@param myRole string
local function DrawPlatform(vg, node, camX, camY, sw, sh, skin, myRole)
    local pos = node.position
    local visibleTo = node:GetVar(VARS.VISIBLE_TO)
    local vis = (visibleTo and not visibleTo:IsEmpty()) and visibleTo:GetString() or "all"

    -- 可见性过滤
    if vis ~= "all" and vis ~= myRole then return end

    local w = node:GetVar("Width")
    local h = node:GetVar("Height")
    if not w or w:IsEmpty() or not h or h:IsEmpty() then return end
    local pw = w:GetFloat() * PPU
    local ph = h:GetFloat() * PPU

    -- 地面贴图覆盖检测（非逻辑视角下，被 overlay 完全覆盖的地形不渲染）
    if myRole ~= "all" then
        local ww = w:GetFloat()
        local wh = h:GetFloat()
        local wxLeft  = pos.x - ww * 0.5
        local wxRight = pos.x + ww * 0.5
        local wyBot   = pos.y - wh * 0.5
        local wyTop   = pos.y + wh * 0.5
        if IsCoveredByOverlay(wxLeft, wxRight, wyBot, wyTop, myRole) then return end
    end

    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local left = cx - pw * 0.5
    local top  = cy - ph * 0.5

    -- 选择颜色
    local fillColor, outlineColor
    if vis ~= "all" then
        fillColor = skin.invisPlatform
        outlineColor = skin.invisPlatform
    elseif node.name:find("ground") then
        fillColor = skin.ground
        outlineColor = skin.groundOutline
    else
        fillColor = skin.platform
        outlineColor = skin.platformOutline
    end

    if vis ~= "all" then
        -- 隐形平台：简单半透明填充，不加砖纹
        nvgBeginPath(vg)
        nvgRoundedRect(vg, left, top, pw, ph, 3)
        nvgFillColor(vg, DualWorldSkin.Color(fillColor))
        nvgFill(vg)
    else
        -- 世界左上角坐标（用于砖缝跨平台对齐）
        local worldLeft = pos.x - (w:GetFloat() * 0.5)
        local worldTop  = pos.y + (h:GetFloat() * 0.5)   -- Y 轴朝上，top = y+h/2
        DrawBrickSurface(vg, left, top, pw, ph, worldLeft, worldTop, fillColor, 3)
    end

    -- 外描边
    nvgBeginPath(vg)
    nvgRoundedRect(vg, left, top, pw, ph, 3)
    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)
end

-- ═══════════════════════════════════════════════
-- 绘制：斜坡
-- ═══════════════════════════════════════════════

---@param vg userdata
---@param node Node
---@param camX number
---@param camY number
---@param sw number 屏幕宽
---@param sh number 屏幕高
---@param skin table
---@param myRole string
local function DrawSlope(vg, node, camX, camY, sw, sh, skin, myRole)
    local visibleTo = node:GetVar(VARS.VISIBLE_TO)
    local vis = (visibleTo and not visibleTo:IsEmpty()) and visibleTo:GetString() or "all"
    if vis ~= "all" and vis ~= myRole then return end

    local slopeTypeVar = node:GetVar("SLOPE_TYPE")
    if not slopeTypeVar or slopeTypeVar:IsEmpty() then return end
    local slopeType = slopeTypeVar:GetString()

    local verts = SlopePhysics.VERTICES[slopeType]
    if not verts then return end

    local pos = node.position  -- 格子左下角
    local wx, wy = pos.x, pos.y

    -- 地面贴图覆盖检测（斜坡以 1×1 格子计算包围盒）
    if myRole ~= "all" then
        local cs = EditorConst.CELL_SIZE
        if IsCoveredByOverlay(wx, wx + cs, wy, wy + cs, myRole) then return end
    end

    -- 选择颜色
    local fillColor, outlineColor
    if vis ~= "all" then
        fillColor = skin.invisPlatform
        outlineColor = skin.invisPlatform
    else
        fillColor = skin.slope
        outlineColor = skin.slopeOutline
    end

    -- 计算斜坡屏幕包围盒（用于渐变方向）
    local minSY, maxSY = math.huge, -math.huge
    for _, v in ipairs(verts) do
        local _, sy = WorldToScreen(wx + v.x, wy + v.y, camX, camY, sw, sh)
        if sy < minSY then minSY = sy end
        if sy > maxSY then maxSY = sy end
    end

    -- 将顶点从局部坐标转换为屏幕坐标并绘制多边形（渐变填充）
    nvgBeginPath(vg)
    for i, v in ipairs(verts) do
        local sx, sy = WorldToScreen(wx + v.x, wy + v.y, camX, camY, sw, sh)
        if i == 1 then
            nvgMoveTo(vg, sx, sy)
        else
            nvgLineTo(vg, sx, sy)
        end
    end
    nvgClosePath(vg)

    if vis ~= "all" then
        nvgFillColor(vg, DualWorldSkin.Color(fillColor))
    else
        local fc = fillColor
        local r, g, b, a = fc[1], fc[2], fc[3], (fc[4] or 255)
        local rT, gT, bT = math.min(r+14,255), math.min(g+14,255), math.min(b+14,255)
        local rB, gB, bB = math.max(r-10,0),   math.max(g-10,0),   math.max(b-10,0)
        local grad = nvgLinearGradient(vg, 0, minSY, 0, maxSY,
            nvgRGBA(rT, gT, bT, a), nvgRGBA(rB, gB, bB, a))
        nvgFillPaint(vg, grad)
    end
    nvgFill(vg)

    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)
end

-- ═══════════════════════════════════════════════
-- 绘制：独木桥
-- ═══════════════════════════════════════════════

local function DrawBridge(vg, node, camX, camY, sw, sh, skin, myRole)
    local visibleTo = node:GetVar(VARS.VISIBLE_TO)
    local vis = (visibleTo and not visibleTo:IsEmpty()) and visibleTo:GetString() or "all"
    if vis ~= "all" and vis ~= myRole then return end

    local w = node:GetVar("Width")
    local h = node:GetVar("Height")
    if not w or w:IsEmpty() or not h or h:IsEmpty() then return end
    local pw = w:GetFloat() * PPU
    local ph = h:GetFloat() * PPU

    local pos = node.position  -- 中心位置
    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local left = cx - pw * 0.5
    local top  = cy - ph * 0.5

    -- 检查是否断裂
    local brokenVar = node:GetVar("BRIDGE_BROKEN")
    local broken = brokenVar and not brokenVar:IsEmpty() and brokenVar:GetBool()

    local fillColor, outlineColor
    if broken then
        fillColor = skin.bridgeBroken
        outlineColor = skin.bridgeOutline
    elseif vis ~= "all" then
        fillColor = skin.invisPlatform
        outlineColor = skin.invisPlatform
    else
        fillColor = skin.bridge
        outlineColor = skin.bridgeOutline
    end

    -- 绘制桥体（带圆角矩形）
    nvgBeginPath(vg)
    nvgRoundedRect(vg, left, top, pw, ph, 2)
    nvgFillColor(vg, DualWorldSkin.Color(fillColor))
    nvgFill(vg)

    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)

    -- 桥面木纹线条装饰
    if not broken then
        nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
        nvgStrokeWidth(vg, 0.8)
        local lineSpacing = 6
        for lx = left + lineSpacing, left + pw - 2, lineSpacing do
            nvgBeginPath(vg)
            nvgMoveTo(vg, lx, top + 1)
            nvgLineTo(vg, lx, top + ph - 1)
            nvgStroke(vg)
        end
    end
end

-- ═══════════════════════════════════════════════
-- 绘制：水面
-- ═══════════════════════════════════════════════

local function DrawWater(vg, node, camX, camY, sw, sh, skin, myRole)
    local visibleTo = node:GetVar(VARS.VISIBLE_TO)
    local vis = (visibleTo and not visibleTo:IsEmpty()) and visibleTo:GetString() or "all"
    if vis ~= "all" and vis ~= myRole then return end

    local w = node:GetVar("Width")
    local h = node:GetVar("Height")
    if not w or w:IsEmpty() or not h or h:IsEmpty() then return end
    local pw = w:GetFloat() * PPU
    local ph = h:GetFloat() * PPU

    local pos = node.position  -- 中心位置
    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local left = cx - pw * 0.5
    local top  = cy - ph * 0.5

    -- 水体（半透明矩形）
    nvgBeginPath(vg)
    nvgRect(vg, left, top, pw, ph)
    nvgFillColor(vg, DualWorldSkin.Color(skin.water))
    nvgFill(vg)

    -- 水面线（顶部高亮线）
    nvgBeginPath(vg)
    nvgMoveTo(vg, left, top)
    nvgLineTo(vg, left + pw, top)
    nvgStrokeColor(vg, DualWorldSkin.Color(skin.waterSurface))
    nvgStrokeWidth(vg, 2.5)
    nvgStroke(vg)

    -- 波纹装饰（水面上几条小波浪线）
    nvgStrokeColor(vg, DualWorldSkin.Color(skin.waterSurface))
    nvgStrokeWidth(vg, 1.0)
    local waveY = top + ph * 0.3
    for i = 0, 1 do
        nvgBeginPath(vg)
        local wy = waveY + i * ph * 0.25
        for x = left, left + pw, 4 do
            local dy = math.sin((x - left) * 0.15) * 2
            if x == left then
                nvgMoveTo(vg, x, wy + dy)
            else
                nvgLineTo(vg, x, wy + dy)
            end
        end
        nvgStroke(vg)
    end
end

-- ═══════════════════════════════════════════════
-- 绘制：触发器（出口/存档点）
-- ═══════════════════════════════════════════════

local function DrawTrigger(vg, node, camX, camY, sw, sh, skin, myRole)
    local w = node:GetVar("Width")
    local h = node:GetVar("Height")
    if not w or w:IsEmpty() or not h or h:IsEmpty() then return end
    local pw = w:GetFloat() * PPU
    local ph = h:GetFloat() * PPU

    local pos = node.position
    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local left = cx - pw * 0.5
    local top  = cy - ph * 0.5

    local trigEventVar = node:GetVar("TrigEvent")
    local trigEvent = (trigEventVar and not trigEventVar:IsEmpty()) and trigEventVar:GetString() or ""

    -- 读取传送组号（portal 触发器专用）
    local portalGroupVar = node:GetVar("PortalGroup")
    local portalGroup = (portalGroupVar and not portalGroupVar:IsEmpty()) and portalGroupVar:GetInt() or 0

    local fillColor, outlineColor, label
    if trigEvent == "scene_transition" then
        fillColor = skin.exit
        outlineColor = skin.exitOutline
        label = "EXIT"
    elseif trigEvent == "checkpoint" then
        fillColor = skin.checkpoint
        outlineColor = skin.checkpointOutline
        label = "CP"
    elseif trigEvent == "portal_enter" then
        fillColor = skin.portalIn or skin.exit
        outlineColor = skin.portalInOutline or skin.exitOutline
        label = "传" .. portalGroup
    elseif trigEvent == "portal_exit" then
        fillColor = skin.portalOut or skin.exit
        outlineColor = skin.portalOutOutline or skin.exitOutline
        label = "送" .. portalGroup
    else
        fillColor = skin.exit
        outlineColor = skin.exitOutline
        label = "?"
    end

    -- 半透明区域
    nvgBeginPath(vg)
    nvgRoundedRect(vg, left, top, pw, ph, 4)
    nvgFillColor(vg, DualWorldSkin.Color(fillColor))
    nvgFill(vg)
    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 2.0)
    nvgStroke(vg)

    -- 标签文字
    nvgFontFace(vg, "ui")
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
    nvgText(vg, cx, cy, label)
end

-- ═══════════════════════════════════════════════
-- 绘制：梯子
-- ═══════════════════════════════════════════════

local function DrawLadder(vg, node, camX, camY, sw, sh, skin, myRole)
    local visibleTo = node:GetVar(VARS.VISIBLE_TO)
    local vis = (visibleTo and not visibleTo:IsEmpty()) and visibleTo:GetString() or "all"
    if vis ~= "all" and vis ~= myRole then return end

    local w = node:GetVar("Width")
    local h = node:GetVar("Height")
    if not w or w:IsEmpty() or not h or h:IsEmpty() then return end
    local pw = w:GetFloat() * PPU
    local ph = h:GetFloat() * PPU

    local pos = node.position
    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local left = cx - pw * 0.5
    local top  = cy - ph * 0.5

    local fillColor = skin.ladder
    local outlineColor = skin.ladderOutline

    -- 两根竖杆
    local railW = pw * 0.15
    nvgBeginPath(vg)
    nvgRect(vg, left, top, railW, ph)
    nvgFillColor(vg, DualWorldSkin.Color(fillColor))
    nvgFill(vg)

    nvgBeginPath(vg)
    nvgRect(vg, left + pw - railW, top, railW, ph)
    nvgFillColor(vg, DualWorldSkin.Color(fillColor))
    nvgFill(vg)

    -- 横档
    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 2.0)
    local cs = GameConst.CELL_SIZE
    local rungSpacing = cs * PPU  -- 每格一个横档
    for ry = top + rungSpacing * 0.5, top + ph - 2, rungSpacing do
        nvgBeginPath(vg)
        nvgMoveTo(vg, left + railW, ry)
        nvgLineTo(vg, left + pw - railW, ry)
        nvgStroke(vg)
    end

    -- 外框
    nvgBeginPath(vg)
    nvgRect(vg, left, top, pw, ph)
    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 1.0)
    nvgStroke(vg)
end

-- ═══════════════════════════════════════════════
-- 绘制：木箱
-- ═══════════════════════════════════════════════

local function DrawCrate(vg, node, camX, camY, sw, sh, skin, myRole)
    local visibleTo = node:GetVar(VARS.VISIBLE_TO)
    local vis = (visibleTo and not visibleTo:IsEmpty()) and visibleTo:GetString() or "all"
    if vis ~= "all" and vis ~= myRole then return end

    local w = node:GetVar("Width")
    local h = node:GetVar("Height")
    if not w or w:IsEmpty() or not h or h:IsEmpty() then return end
    local pw = w:GetFloat() * PPU
    local ph = h:GetFloat() * PPU

    local pos = node.position
    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)

    -- 读取斜坡角度（弧度）
    local angleVar = node:GetVar(VARS.CRATE_ANGLE)
    local angle = 0.0
    if angleVar and not angleVar:IsEmpty() then angle = angleVar:GetFloat() end

    local fillColor = skin.crate
    local outlineColor = skin.crateOutline

    -- 保存 NanoVG 状态，应用旋转
    nvgSave(vg)
    nvgTranslate(vg, cx, cy)
    if math.abs(angle) > 0.0005 then
        nvgRotate(vg, angle)  -- NanoVG rotate 接受弧度
    end

    local left = -pw * 0.5
    local top  = -ph * 0.5

    -- 箱体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, left, top, pw, ph, 2)
    nvgFillColor(vg, DualWorldSkin.Color(fillColor))
    nvgFill(vg)

    -- 对角线装饰（X 形）
    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 1.5)
    nvgBeginPath(vg)
    nvgMoveTo(vg, left + 2, top + 2)
    nvgLineTo(vg, left + pw - 2, top + ph - 2)
    nvgStroke(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, left + pw - 2, top + 2)
    nvgLineTo(vg, left + 2, top + ph - 2)
    nvgStroke(vg)

    -- 外框
    nvgBeginPath(vg)
    nvgRoundedRect(vg, left, top, pw, ph, 2)
    nvgStrokeColor(vg, DualWorldSkin.Color(outlineColor))
    nvgStrokeWidth(vg, 2.0)
    nvgStroke(vg)

    nvgRestore(vg)
end

-- ═══════════════════════════════════════════════
-- 调试：碰撞体可视化（红框 + 黄色脚底传感器）
-- ═══════════════════════════════════════════════

--- 在玩家碰撞体中心 (cx, cy) 处绘制调试可视化
--- · 红色半透明矩形：椭圆碰撞体外包框（hx × hy，即真实碰撞宽高）
--- · 黄色小矩形：脚底传感器位置（radius × radius）
---@param vg userdata
---@param cx number 屏幕 X（碰撞体中心）
---@param cy number 屏幕 Y（碰撞体中心）
local function DrawPlayerDebug(vg, cx, cy)
    local hx_px = GameConst.PLAYER_HX     * PPU   -- 碰撞椭圆半宽（像素）
    local hy_px = GameConst.PLAYER_RADIUS * PPU   -- 碰撞椭圆半高（像素）
    local fr_px = GameConst.FOOT_SENSOR_RADIUS * PPU          -- 脚底传感器半径（像素）
    local fo_px = GameConst.FOOT_SENSOR_OFFSET_Y   * PPU      -- 脚底传感器 Y 偏移（像素，向下为正）

    -- 红色半透明矩形：碰撞体外包框
    nvgBeginPath(vg)
    nvgRect(vg, cx - hx_px, cy - hy_px, hx_px * 2, hy_px * 2)
    nvgFillColor(vg, nvgRGBA(255, 60, 60, 55))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(255, 60, 60, 200))
    nvgStrokeWidth(vg, 1.0)
    nvgStroke(vg)

    -- 黄色小矩形：脚底传感器（Y 轴翻转：UrhoX Y 向上，屏幕 Y 向下）
    local sensor_sy = cy - fo_px   -- fo_px 为负数（传感器在碰撞体下方），翻转后 sy 变大（向下）
    nvgBeginPath(vg)
    nvgRect(vg, cx - fr_px, sensor_sy - fr_px, fr_px * 2, fr_px * 2)
    nvgFillColor(vg, nvgRGBA(255, 220, 0, 70))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(255, 220, 0, 230))
    nvgStrokeWidth(vg, 1.0)
    nvgStroke(vg)
end

-- ═══════════════════════════════════════════════
-- 绘制：角色（圆形 + 小眼睛）
-- ═══════════════════════════════════════════════

---@param vg userdata
---@param node Node
---@param camX number
---@param camY number
---@param sw number
---@param sh number
---@param skin table
---@param myRole string
---@param dt number 帧时间（用于推进每玩家跳跃动画计时）
local function DrawPlayer(vg, node, camX, camY, sw, sh, skin, myRole, dt)
    local pos = node.position
    local role = node:GetVar(VARS.ROLE)
    local roleStr = (role and not role:IsEmpty()) and role:GetString() or ""

    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)

    -- 尝试使用精灵动画绘制（按 myRole 视角 × targetRole 查找）
    local anims = spriteAnims_[SpriteKey(myRole, roleStr)]
    if anims and anims.idle then
        -- 角色高度（网格单位）和额外 Y 偏移（像素）从配置读取
        local drawGridH = anims.drawGridH or 2.0
        local offsetYPx = anims.offsetY or 0
        local drawH = drawGridH * GameConst.CELL_SIZE * PPU

        -- 精灵中心 = 角色碰撞体中心（cy）
        -- 但精灵图通常脚部在底边，所以向上偏移半个绘制高度再往下移碰撞半径
        -- 使精灵脚部与碰撞体底部对齐
        -- offsetYPx > 0 → 屏幕坐标向下移动
        local spriteCenterY = cy - drawH * 0.5 + GameConst.PLAYER_RADIUS * PPU + offsetYPx

        -- 判断朝向和运动状态
        local nodeId = node:GetID()
        local lastX = spriteLastPosX_[nodeId]
        local lastY = spriteLastPosY_[nodeId]
        local facingLeft = spriteFacingLeft_[nodeId] or false
        local isMovingX = false
        local absDx = 0  -- 本帧水平位移绝对值（米），用于驱动跑步动画进度

        -- 优先读取服务端同步的按键状态（精确，不受斜坡位移差偏小影响）
        local isMovingVar  = node:GetVar("IsMoving")
        local facingLeftVar = node:GetVar("FacingLeft")
        local hasServerMoving  = isMovingVar  and not isMovingVar:IsEmpty()
        local hasServerFacing  = facingLeftVar and not facingLeftVar:IsEmpty()

        if hasServerMoving then
            -- 服务端已同步：直接使用
            isMovingX = isMovingVar:GetBool()
        end
        if hasServerFacing then
            -- 服务端已同步朝向：直接使用
            facingLeft = facingLeftVar:GetBool()
            spriteFacingLeft_[nodeId] = facingLeft
        end

        -- 无论哪种来源，都用位置差计算 absDx（驱动跑步动画帧进度）
        -- 同时作为服务端变量尚未到达时的退化回退
        if lastX then
            local dx = pos.x - lastX
            absDx = math.abs(dx)
            if not hasServerMoving then
                -- 退化：用位置差推断移动状态
                if dx < -0.01 then
                    facingLeft = true
                    spriteFacingLeft_[nodeId] = true
                    isMovingX = true
                elseif dx > 0.01 then
                    facingLeft = false
                    spriteFacingLeft_[nodeId] = false
                    isMovingX = true
                end
            end
        end

        -- 优先从服务端同步的节点变量读取地面状态，避免斜坡上 Y 位移被误判为在空中
        -- 读取服务端同步的原始 OnGround 值
        local rawOnGround = true  -- 默认假定在地面
        local onGroundVar = node:GetVar("OnGround")
        if onGroundVar and not onGroundVar:IsEmpty() then
            rawOnGround = onGroundVar:GetBool()
        elseif lastY then
            -- 节点变量尚未同步时（初始帧），退回 Y 位移推断
            local dy = math.abs(pos.y - lastY)
            if dy > 0.01 then
                rawOnGround = false
            end
        end

        -- OnGround 防抖：斜坡过渡时 EndContact/BeginContact 之间存在 1-3 帧空白，
        -- rawOnGround 会短暂变 false，但这不是真正起跳，不应切换到跳跃/待机动画。
        -- 策略：rawOnGround=false 需连续 OFFGROUND_DEBOUNCE_FRAMES 帧才生效。
        --       rawOnGround=true 立即生效（落地响应要即时）。
        local offFrames = spriteOffGroundFrames_[nodeId] or 0
        if rawOnGround then
            offFrames = 0
        else
            offFrames = offFrames + 1
        end
        spriteOffGroundFrames_[nodeId] = offFrames
        local isOnGround = (offFrames < OFFGROUND_DEBOUNCE_FRAMES)

        -- 上一帧地面状态（用于检测起跳瞬间——使用防抖后的值）
        local wasOnGround = spriteWasOnGround_[nodeId]
        if wasOnGround == nil then wasOnGround = true end
        spriteWasOnGround_[nodeId] = isOnGround

        spriteLastPosX_[nodeId] = pos.x
        spriteLastPosY_[nodeId] = pos.y

        -- 判定跳跃状态：不在地面（Y 在变化）+ 有跳跃动画
        local jumping = not isOnGround and anims.jump ~= nil

        -- ══ [DEBUG] 每60帧打印一次动画判定状态 ══
        local _dbgKey = "dbgFrame_" .. nodeId
        WorldRenderer[_dbgKey] = (WorldRenderer[_dbgKey] or 0) + 1
        if WorldRenderer[_dbgKey] % 60 == 0 then
            print(string.format("[DBG-Client][%s] rawOnGround=%s offFrames=%d isOnGround=%s jumping=%s isMovingX=%s anim=%s",
                nodeId, tostring(rawOnGround), offFrames, tostring(isOnGround),
                tostring(jumping), tostring(isMovingX),
                jumping and "JUMP" or (isMovingX and isOnGround and "RUN" or "IDLE")))
        end

        -- 判定跑步状态：水平移动 + 在地面 + 有跑步动画
        local running = isMovingX and isOnGround and anims.run ~= nil
        spriteIsRunning_[nodeId] = running

        -- 跑步动画独立计时（每玩家，位移驱动）
        -- 每移动 RUN_STRIDE_LENGTH 米，elapsed 推进 totalDuration，恰好完成一个循环
        if running and anims.run then
            local advance = absDx * anims.run.totalDuration / RUN_STRIDE_LENGTH
            spriteRunElapsed_[nodeId] = (spriteRunElapsed_[nodeId] or 0) + advance
        end

        -- 跳跃动画独立计时（匀速播放，末帧与落地精确对齐）
        -- speed = animDuration / jumpAirTime，使 elapsed 恰好在落地时等于 dur
        -- 信号修正：收到 JumpCut / LongJumpConfirmed 后，用 remAnim / remTime 重校速率
        if jumping then
            local dur = anims.jump.totalDuration

            -- 估算长跳总时长（v₀=14m/s, g_scale=1.5, g=45m/s², FALL_MULT=2.5）
            -- 用于起跳时设置初始匀速速率（默认长跳视角，等 JumpCut 信号到来再加速修正）
            local function CalcLongJumpAirTime()
                local g_eff   = GameConst.GRAVITY * GameConst.PLAYER_AIR_GRAVITY_SCALE
                local g_fall  = g_eff * GameConst.FALL_GRAVITY_MULT
                local apex_th = GameConst.JUMP_APEX_THRESHOLD
                local apex_g  = math.max(1.0, g_eff * (1.0 - GameConst.JUMP_APEX_BOOST_RATIO))
                local v0      = GameConst.PLAYER_JUMP_SPEED
                local t_rise_free = math.max(0.0, v0 - apex_th) / g_eff
                local t_rise_apex = apex_th / apex_g
                local h_free      = math.max(0.0, v0*v0 - apex_th*apex_th) / (2.0 * g_eff)
                local t_fall_apex = apex_th / apex_g
                local disc        = apex_th*apex_th + 2.0*g_fall*h_free
                local t_fall_free = (-apex_th + math.sqrt(math.max(0, disc))) / g_fall
                return t_rise_free + t_rise_apex + t_fall_apex + t_fall_free  -- ≈ 0.508s
            end

            -- 估算短跳总时长（松键截断到 JUMP_CUT_MIN_VY，切换高重力 g_scale=2.64）
            -- 仅供 JumpCut 信号的兜底默认值参考，实际以信号携带的 remTime 为准
            local function CalcShortJumpAirTime()
                local g_eff  = GameConst.GRAVITY * GameConst.PLAYER_SHORT_JUMP_GRAVITY_SCALE
                local g_fall = g_eff * GameConst.FALL_GRAVITY_MULT
                local vy     = GameConst.JUMP_CUT_MIN_VY
                local t_up   = vy / g_eff
                local h_up   = vy * vy / (2.0 * g_eff)
                local t_down = math.sqrt(2.0 * h_up / g_fall)
                return t_up + t_down  -- ≈ 0.116s（高重力快速坠落）
            end

            -- 估算二段跳总时长（含顶点提升修正，g_scale=1.5）
            local function CalcAirJumpAirTime()
                local g_eff   = GameConst.GRAVITY * GameConst.PLAYER_AIR_GRAVITY_SCALE
                local g_fall  = g_eff * GameConst.FALL_GRAVITY_MULT
                local apex_th = GameConst.JUMP_APEX_THRESHOLD
                local apex_g  = math.max(1.0, g_eff * (1.0 - GameConst.JUMP_APEX_BOOST_RATIO))
                local v0      = GameConst.PLAYER_JUMP_SPEED * GameConst.AIR_JUMP_SPEED_RATIO
                local t_rise_free = math.max(0.0, v0 - apex_th) / g_eff
                local t_rise_apex = apex_th / apex_g
                local h_free      = math.max(0.0, v0*v0 - apex_th*apex_th) / (2.0 * g_eff)
                local t_fall_apex = apex_th / apex_g
                local disc        = apex_th*apex_th + 2.0*g_fall*h_free
                local t_fall_free = (-apex_th + math.sqrt(math.max(0, disc))) / g_fall
                return t_rise_free + t_rise_apex + t_fall_apex + t_fall_free  -- ≈ 0.443s（g_scale=1.5）
            end

            if wasOnGround then
                -- 起跳：以长跳总时长为基准设置初始匀速速率
                -- 若玩家短跳（< 0.3s 松键），JumpCut 信号到来后会重校为更快速率
                spriteJumpElapsed_[nodeId] = 0
                spriteJumpSpeed_[nodeId]   = dur / math.max(0.01, CalcLongJumpAirTime())
            else
                -- 长跳确认：用剩余时间重校速率（不重置 elapsed，无缝衔接）
                local longConfVar = node:GetVar("LongJumpConfirmed")
                if longConfVar and not longConfVar:IsEmpty() and longConfVar:GetBool() then
                    local remTimeVar = node:GetVar("LongJumpRemainingTime")
                    local remTime    = (remTimeVar and not remTimeVar:IsEmpty())
                                      and remTimeVar:GetFloat() or 0.508  -- 长跳兜底（g_scale=1.5 总时长）
                    local curE    = spriteJumpElapsed_[nodeId] or 0
                    local remAnim = math.max(0.001, dur - curE)
                    spriteJumpSpeed_[nodeId] = remAnim / math.max(0.01, remTime)
                    node:SetVar("LongJumpConfirmed", Variant(false))
                end

                -- JumpCut：用剩余时间重校速率（不重置 elapsed，不会跳变）
                local jumpCutVar = node:GetVar("JumpCut")
                if jumpCutVar and not jumpCutVar:IsEmpty() and jumpCutVar:GetBool() then
                    local remTimeVar = node:GetVar("JumpCutRemainingTime")
                    local remTime    = (remTimeVar and not remTimeVar:IsEmpty())
                                      and remTimeVar:GetFloat() or 0.116  -- 短跳兜底（高重力约 0.116s）
                    if remTime > 0.01 then
                        local curE    = spriteJumpElapsed_[nodeId] or 0
                        local remAnim = math.max(0.001, dur - curE)
                        spriteJumpSpeed_[nodeId] = remAnim / math.max(0.01, remTime)
                    end
                    node:SetVar("JumpCut", Variant(false))
                end

                -- 二段跳：重置到第一帧，按二段跳时长设置匀速速率
                local airJumpVar = node:GetVar("AirJump")
                if airJumpVar and not airJumpVar:IsEmpty() and airJumpVar:GetBool() then
                    spriteJumpElapsed_[nodeId] = 0
                    spriteJumpSpeed_[nodeId]   = dur / math.max(0.01, CalcAirJumpAirTime())
                    node:SetVar("AirJump", Variant(false))
                end
            end

            -- 匀速推进，clamp 在末帧防止超出
            local curE = spriteJumpElapsed_[nodeId] or 0
            local spd  = spriteJumpSpeed_[nodeId] or 1.0
            spriteJumpElapsed_[nodeId] = math.min(curE + dt * spd, dur - 0.001)
        end

        -- 动画优先级：跳跃 > 跑步 > 待机
        local useFlip
        if jumping then
            useFlip = anims.jumpDefaultFlipX
        elseif running then
            useFlip = anims.runDefaultFlipX
        else
            useFlip = anims.defaultFlipX
        end

        -- useFlip: 原图朝向与默认朝向相反时，用异或翻转
        local flipX = facingLeft
        if useFlip then
            flipX = not flipX
        end

        if jumping then
            -- 跳跃：跳跃帧内留白较多，使用独立的 jumpDrawGridH 补偿视觉尺寸
            local jumpDrawGridH = anims.jumpDrawGridH or drawGridH
            local jumpDrawH = jumpDrawGridH * GameConst.CELL_SIZE * PPU
            local jumpCenterY = cy - jumpDrawH * 0.5 + GameConst.PLAYER_RADIUS * PPU + offsetYPx
            anims.jump:DrawAtTime(cx, jumpCenterY, jumpDrawH, flipX,
                spriteJumpElapsed_[nodeId] or 0)
        elseif running then
            anims.run:DrawAtTime(cx, spriteCenterY, drawH, flipX,
                spriteRunElapsed_[nodeId] or 0)
        else
            anims.idle:Draw(cx, spriteCenterY, drawH, flipX)
        end

        -- ─── 调试：碰撞体（红色半透明框）& 脚底传感器（黄框）───
        -- DrawPlayerDebug(vg, cx, cy)  -- 已关闭调试可视化

        return
    end

    -- ─── Fallback：原有圆形绘制 ───
    local radius = GameConst.PLAYER_RADIUS * PPU

    -- 身体颜色：自己用 playerSelf，搭档用 playerPartner
    local bodyColor
    if roleStr == myRole then
        bodyColor = skin.playerSelf
    else
        bodyColor = skin.playerPartner
    end

    -- 身体圆
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius)
    nvgFillColor(vg, DualWorldSkin.Color(bodyColor))
    nvgFill(vg)

    -- 轮廓
    nvgStrokeColor(vg, nvgRGBA(0, 0, 0, 120))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    -- 眼睛（两个小白点 + 瞳孔）
    local eyeOffY = -radius * 0.15
    local eyeSpacing = radius * 0.3
    local eyeR = radius * 0.18
    local pupilR = radius * 0.10

    for _, side in ipairs({-1, 1}) do
        local ex = cx + side * eyeSpacing
        local ey = cy + eyeOffY
        -- 眼白
        nvgBeginPath(vg)
        nvgCircle(vg, ex, ey, eyeR)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 230))
        nvgFill(vg)
        -- 瞳孔
        nvgBeginPath(vg)
        nvgCircle(vg, ex, ey + pupilR * 0.3, pupilR)
        nvgFillColor(vg, nvgRGBA(20, 20, 30, 255))
        nvgFill(vg)
    end

    -- 角色标签（脚下，小字）
    local labelText = (roleStr == Shared.ROLE.RED) and "红" or "黑"
    nvgFontFace(vg, "ui")
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 160))
    nvgText(vg, cx, cy + radius + 4, labelText)

    -- 调试：碰撞体 & 脚底传感器
    -- DrawPlayerDebug(vg, cx, cy)  -- 已关闭调试可视化
end

-- ═══════════════════════════════════════════════
-- 绘制：NPC
-- ═══════════════════════════════════════════════

local function DrawNPC(vg, node, camX, camY, sw, sh, skin, myRole)
    local pos = node.position
    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local size = 0.5 * PPU  -- NPC 方块大小

    -- 方块身体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - size * 0.5, cy - size * 0.5, size, size, 4)
    nvgFillColor(vg, DualWorldSkin.Color(skin.npcBody))
    nvgFill(vg)
    nvgStrokeColor(vg, DualWorldSkin.Color(skin.npcOutline))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)

    -- 名称标签
    local nameVar = (myRole == Shared.ROLE.RED)
        and node:GetVar("NameRed")
        or  node:GetVar("NameBlack")
    local nameStr = (nameVar and not nameVar:IsEmpty()) and nameVar:GetString() or "?"

    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 13)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, DualWorldSkin.Color(skin.npcNameColor))
    nvgText(vg, cx, cy - size * 0.5 - 6, nameStr)
end

-- ═══════════════════════════════════════════════
-- 绘制：可交互物
-- ═══════════════════════════════════════════════

local function DrawInteractable(vg, node, camX, camY, sw, sh, skin, myRole)
    local pos = node.position
    local vis = node:GetVar(VARS.VISIBLE_TO)
    local visStr = (vis and not vis:IsEmpty()) and vis:GetString() or "all"

    -- 可见性过滤
    if visStr ~= "all" and visStr ~= myRole then return end

    local cx, cy = WorldToScreen(pos.x, pos.y, camX, camY, sw, sh)
    local kindVar = node:GetVar("Kind")
    local kind = (kindVar and not kindVar:IsEmpty()) and kindVar:GetString() or ""

    if kind == "bell" then
        local activatedVar = node:GetVar("Activated")
        local active = activatedVar and not activatedVar:IsEmpty() and activatedVar:GetBool()
        local color = active and skin.bellActive or skin.bellInactive
        local r = 0.35 * PPU

        -- 铃铛形状（简化为梯形+圆弧）
        nvgBeginPath(vg)
        nvgCircle(vg, cx, cy, r)
        nvgFillColor(vg, DualWorldSkin.Color(color))
        nvgFill(vg)

        -- 发光（激活时）
        if active then
            nvgBeginPath(vg)
            nvgCircle(vg, cx, cy, r * 1.5)
            nvgFillColor(vg, DualWorldSkin.Color(skin.itemGlow))
            nvgFill(vg)
        end

    elseif kind == "item" then
        local r = 0.25 * PPU
        -- 菱形
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx, cy - r)
        nvgLineTo(vg, cx + r * 0.7, cy)
        nvgLineTo(vg, cx, cy + r)
        nvgLineTo(vg, cx - r * 0.7, cy)
        nvgClosePath(vg)
        nvgFillColor(vg, DualWorldSkin.Color(skin.itemGlow))
        nvgFill(vg)

        -- 物品名
        local itemNameVar = node:GetVar("ItemName")
        if itemNameVar and not itemNameVar:IsEmpty() then
            nvgFontFace(vg, "ui")
            nvgFontSize(vg, 11)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg, DualWorldSkin.Color(skin.npcNameColor))
            nvgText(vg, cx, cy - r - 4, itemNameVar:GetString())
        end
    end
end

-- ═══════════════════════════════════════════════
-- 绘制：前景粒子（装饰）
-- ═══════════════════════════════════════════════

---@type table[]
local particles_ = {}
local particlesInited_ = false

local function InitParticles(count)
    particles_ = {}
    for i = 1, count do
        particles_[i] = {
            x = math.random() * 2000 - 1000,
            y = math.random() * 800,
            vx = (math.random() - 0.5) * 20,
            vy = -math.random() * 15 - 5,
            r = math.random() * 3 + 1,
            life = math.random() * 6,
        }
    end
    particlesInited_ = true
end

local function UpdateAndDrawParticles(vg, dt, w, h, camX, skin)
    if not particlesInited_ then InitParticles(30) end

    local parallaxFactor = GameConst.PARALLAX[4] or 1.2
    local offsetX = camX * parallaxFactor * PPU

    for _, p in ipairs(particles_) do
        p.life = p.life - dt
        if p.life <= 0 then
            p.x = math.random() * 2000 - 1000
            p.y = h + 10
            p.vx = (math.random() - 0.5) * 20
            p.vy = -math.random() * 15 - 5
            p.r = math.random() * 3 + 1
            p.life = math.random() * 6 + 2
        end
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt

        local sx = p.x - offsetX % w
        if sx < -10 then sx = sx + w + 20 end
        if sx > w + 10 then sx = sx - w - 20 end

        local alpha = math.min(1, p.life / 2)
        local c = skin.particle
        nvgBeginPath(vg)
        nvgCircle(vg, sx, p.y, p.r)
        nvgFillColor(vg, nvgRGBA(c[1], c[2], c[3], math.floor(c[4] * alpha)))
        nvgFill(vg)
    end
end

-- ═══════════════════════════════════════════════
-- 公开 API
-- ═══════════════════════════════════════════════

-- 绘制：地面贴图覆盖层
-- ═══════════════════════════════════════════════

--- 将 sceneOverlays_ 中属于 myRole 的覆盖层绘制出来
--- 在 step2 地形之后、step3 玩家之前调用
--- isEditorRedView: true 时强制显示（编辑器红鸟视角），否则按 myRole 过滤
---@param vg userdata
---@param camX number
---@param camY number
---@param sw number
---@param sh number
---@param myRole string
local function DrawGroundOverlays(vg, camX, camY, sw, sh, myRole)
    if #sceneOverlays_ == 0 then return end
    local cs = EditorConst.CELL_SIZE

    for _, ov in ipairs(sceneOverlays_) do
        -- 仅绘制匹配当前角色的 overlay
        if ov.role == myRole then
            -- 基础网格矩形（设计像素，1× 缩放）
            local baseW = (ov.gx2 - ov.gx1 + 1) * cs  -- 世界单位宽
            local baseH = (ov.gy2 - ov.gy1 + 1) * cs  -- 世界单位高
            local basePW = baseW * PPU                  -- 1× 像素宽
            local basePH = baseH * PPU                  -- 1× 像素高

            -- extraTopPx：顶部额外扩展像素（1×），同时等比缩放宽度并水平居中
            local extraTop = (ov.extraTopPx or 0)
            local newPH = basePH + extraTop
            local newPW = basePW * (newPH / basePH)     -- 保持原始宽高比
            local centerShiftPx = (newPW - basePW) * 0.5  -- 水平居中补偿（1× 像素）

            -- 世界坐标（底部不变，顶部向上延伸）
            local worldLeft = ov.gx1 * cs
                              + (ov.offsetX or 0) / PPU
                              - centerShiftPx / PPU      -- 水平居中
            local worldBot  = ov.gy1 * cs + (ov.offsetY or 0) / PPU
            local worldW    = newPW / PPU
            local worldH    = newPH / PPU

            -- 世界左下角 → 屏幕坐标（Y 轴向上，top = worldBot + worldH）
            local sx, syTop = WorldToScreen(worldLeft, worldBot + worldH, camX, camY, sw, sh)
            local pw = worldW * PPU
            local ph = worldH * PPU

            local img, _ = GetBgImage(vg, "overlay_" .. (ov.id or ov.imagePath), ov.imagePath)
            if img and img > 0 then
                local pat = nvgImagePattern(vg, sx, syTop, pw, ph, 0, img, 1.0)
                nvgBeginPath(vg)
                nvgRect(vg, sx, syTop, pw, ph)
                nvgFillPaint(vg, pat)
                nvgFill(vg)
            else
                -- 图片加载失败时画半透明红色占位（便于调试）
                nvgBeginPath(vg)
                nvgRect(vg, sx, syTop, pw, ph)
                nvgFillColor(vg, nvgRGBAf(1, 0.2, 0.2, 0.35))
                nvgFill(vg)
            end
        end
    end
end

--- 绘制自由贴图覆盖层（支持任意位置、尺寸、旋转）
--- 在 groundOverlays 之后调用
---@param vg userdata
---@param camX number
---@param camY number
---@param sw number
---@param sh number
---@param myRole string
local function DrawFreeOverlays(vg, camX, camY, sw, sh, myRole)
    if #sceneFreeOverlays_ == 0 then return end

    for _, fov in ipairs(sceneFreeOverlays_) do
        if fov.role == myRole or fov.role == "all" then
            -- 世界中心 → 屏幕坐标
            local cx, cy = WorldToScreen(fov.x, fov.y, camX, camY, sw, sh)
            -- 世界尺寸 → 像素尺寸（1× PPU）
            local pw = (fov.w or 1) * PPU
            local ph = (fov.h or 1) * PPU

            local img, sz = GetFreeOvImage(vg, "freeov_" .. (fov.id or fov.imagePath), fov.imagePath)
            if img and img > 0 then
                if sz and sz.w and sz.w > 0 and sz.h and sz.h > 0 then
                    local aspect = sz.h / sz.w
                    if fov._pendingAspect then
                        -- 新添加的贴图：自动设为原始像素自然尺寸（1:1 像素映射，画质最清晰）
                        fov.w = sz.w / PPU
                        fov.h = sz.h / PPU
                        fov._pendingAspect = nil
                        fov._aspectFixed = true
                        pw = fov.w * PPU
                        ph = fov.h * PPU
                        print(string.format("[WorldRenderer] freeOverlay '%s' natural size: w=%.2f h=%.2f (img %dx%d)",
                            fov.id or "?", fov.w, fov.h, sz.w, sz.h))
                    elseif not fov._aspectFixed then
                        -- 旧存档：保留用户设置的 w，仅修正 h 的宽高比
                        fov.h = fov.w * aspect
                        fov._aspectFixed = true
                        ph = fov.h * PPU
                        print(string.format("[WorldRenderer] freeOverlay '%s' aspect fixed: w=%.2f h=%.2f (img %dx%d)",
                            fov.id or "?", fov.w, fov.h, sz.w, sz.h))
                    else
                        -- 正常渲染：直接使用存储的 fov.h（由文件名网格尺寸或上一次宽高比修正后确定）
                        ph = (fov.h or 1) * PPU
                    end
                end
                local rot = fov.rotation or 0
                if rot ~= 0 then
                    -- 旋转绘制：平移到中心 → 旋转 → 以 -pw/2,-ph/2 为左上角绘制
                    nvgSave(vg)
                    nvgTranslate(vg, cx, cy)
                    nvgRotate(vg, rot * math.pi / 180)
                    local pat = nvgImagePattern(vg, -pw * 0.5, -ph * 0.5, pw, ph, 0, img, 1.0)
                    nvgBeginPath(vg)
                    nvgRect(vg, -pw * 0.5, -ph * 0.5, pw, ph)
                    nvgFillPaint(vg, pat)
                    nvgFill(vg)
                    nvgRestore(vg)
                else
                    -- 无旋转：直接绘制
                    local pat = nvgImagePattern(vg, cx - pw * 0.5, cy - ph * 0.5, pw, ph, 0, img, 1.0)
                    nvgBeginPath(vg)
                    nvgRect(vg, cx - pw * 0.5, cy - ph * 0.5, pw, ph)
                    nvgFillPaint(vg, pat)
                    nvgFill(vg)
                end
            else
                -- 图片未加载时画占位框
                nvgBeginPath(vg)
                nvgRect(vg, cx - pw * 0.5, cy - ph * 0.5, pw, ph)
                nvgFillColor(vg, nvgRGBAf(0.2, 0.6, 1.0, 0.35))
                nvgFill(vg)
                nvgBeginPath(vg)
                nvgRect(vg, cx - pw * 0.5, cy - ph * 0.5, pw, ph)
                nvgStrokeColor(vg, nvgRGBA(100, 180, 255, 180))
                nvgStrokeWidth(vg, 1.0)
                nvgStroke(vg)
            end
        end
    end
end

---@param camY number 相机世界 Y
---@param myRole string 我的角色
---@param sceneNodes table Node 列表
---@param dt number 帧时间
---@param sceneIdx number|nil 当前场景索引（用于选择背景图）
---@param skipBg boolean|nil 是否跳过视差背景绘制
function WorldRenderer.Draw(vg, screenW, screenH, camX, camY, myRole, sceneNodes, dt, sceneIdx, skipBg, skipTerrain)
    local skin = DualWorldSkin.Get(myRole)

    -- 0) 初始化精灵动画（仅首次）& 更新动画帧
    EnsureSpriteAnims(vg)
    for _, roleAnims in pairs(spriteAnims_) do
        if roleAnims.idle then
            roleAnims.idle:Update(dt)
        end
        -- run / jump 动画不在此处统一更新：各玩家独立计时，由 DrawPlayer 驱动
    end

    -- 1) 背景
    if not skipBg then
        DrawBackground(vg, screenW, screenH, camX, skin, myRole, sceneIdx or 0)
    end

    -- 2) 场景实体（crate 除外，crate 分层绘制）
    -- skipTerrain=true 时跳过地形类（platform/slope/bridge/water/trigger/ladder），
    -- 但仍保留 crate、npc、interactable 等游戏对象的绘制
    local frontCrates = {}  -- RenderFront=true 的箱子延后绘制
    for _, node in ipairs(sceneNodes) do
        if node then
            local etVar = node:GetVar(VARS.ENTITY_TYPE)
            if etVar and not etVar:IsEmpty() then
                local et = etVar:GetString()
                if et == "platform" then
                    if not skipTerrain then
                        DrawPlatform(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "slope" then
                    if not skipTerrain then
                        DrawSlope(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "bridge" then
                    if not skipTerrain then
                        DrawBridge(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "water" then
                    if not skipTerrain then
                        DrawWater(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "trigger" then
                    if not skipTerrain then
                        DrawTrigger(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "ladder" then
                    if not skipTerrain then
                        DrawLadder(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "crate" then
                    -- 按 RenderFront Var 分层：false/nil → 背景层（此处绘制），true → 前景层（玩家之后）
                    local rfVar = node:GetVar("RenderFront")
                    local renderFront = rfVar and not rfVar:IsEmpty() and rfVar:GetBool()
                    if renderFront then
                        frontCrates[#frontCrates + 1] = node
                    else
                        DrawCrate(vg, node, camX, camY, screenW, screenH, skin, myRole)
                    end
                elseif et == "npc" then
                    DrawNPC(vg, node, camX, camY, screenW, screenH, skin, myRole)
                elseif et == "interactable" then
                    DrawInteractable(vg, node, camX, camY, screenW, screenH, skin, myRole)
                end
            end
        end
    end

    -- 2.5) 地面贴图覆盖层（在地形之后、玩家之前绘制）
    DrawGroundOverlays(vg, camX, camY, screenW, screenH, myRole)
    -- 2.6) 自由贴图覆盖层（在 groundOverlays 之后绘制）
    DrawFreeOverlays(vg, camX, camY, screenW, screenH, myRole)

    -- 3) 玩家
    for _, node in ipairs(sceneNodes) do
        if node then
            local etVar = node:GetVar(VARS.ENTITY_TYPE)
            if etVar and not etVar:IsEmpty() and etVar:GetString() == "player" then
                DrawPlayer(vg, node, camX, camY, screenW, screenH, skin, myRole, dt)
            end
        end
    end

    -- 4) 前景箱子（RenderFront=true，绘制在玩家之上）
    for _, node in ipairs(frontCrates) do
        DrawCrate(vg, node, camX, camY, screenW, screenH, skin, myRole)
    end

    -- 5) 前景粒子
    UpdateAndDrawParticles(vg, dt, screenW, screenH, camX, skin)
end

--- 重置粒子（切场景时调用）
function WorldRenderer.ResetParticles()
    particlesInited_ = false
end

return WorldRenderer
