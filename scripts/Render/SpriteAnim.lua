--- Render/SpriteAnim.lua
--- 精灵图表动画播放器（NanoVG）
--- 从 JSON 描述文件加载帧数据，播放精灵动画

local cjson = require("cjson")

local SpriteAnim = {}
SpriteAnim.__index = SpriteAnim

--- 从 JSON 文件加载精灵图表定义
---@param vg userdata NanoVG context
---@param sheetPath string 精灵图表 PNG 路径（相对资源根目录）
---@param jsonPath string JSON 描述文件路径（相对资源根目录）
---@return table|nil SpriteAnim 实例
function SpriteAnim.Load(vg, sheetPath, jsonPath)
    -- 加载图片
    local img = nvgCreateImage(vg, sheetPath, 0)
    if img <= 0 then
        print("[SpriteAnim] Failed to load sheet: " .. sheetPath)
        return nil
    end

    -- 读取 JSON
    local jsonFile = cache:GetFile(jsonPath)
    if not jsonFile then
        print("[SpriteAnim] Failed to open JSON: " .. jsonPath)
        return nil
    end
    local jsonStr = jsonFile:ReadString()
    jsonFile:Close()

    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or not data then
        print("[SpriteAnim] Failed to parse JSON: " .. jsonPath)
        return nil
    end

    -- 解析帧数据
    local frames = {}
    for i, f in ipairs(data.frames) do
        frames[i] = {
            x = f.x,
            y = f.y,
            w = f.w,
            h = f.h,
            t = f.t,  -- 该帧的起始时间（归一化前）
        }
    end

    -- 归一化时间戳：将第一帧偏移量减去，使第一帧 t=0
    -- 避免 DrawAtTime 在 elapsed%totalDuration 接近 0 时找不到帧（产生停顿）
    local firstT = (frames[1] and frames[1].t) or 0
    if firstT > 0 then
        for _, f in ipairs(frames) do
            f.t = f.t - firstT
        end
    end

    -- 推算帧间隔和总时长
    -- frames[1].t 已归零，frames 末尾 t = 原始末帧 t - firstT
    local frameInterval = 0
    if #frames >= 2 then
        frameInterval = frames[2].t - frames[1].t  -- frames[1].t == 0 after normalize
    end
    local totalDuration = (#frames > 0) and (frames[#frames].t + frameInterval) or 0

    local self = setmetatable({
        vg = vg,
        img = img,
        frames = frames,
        frameCount = #frames,
        sheetW = data.sheet_size.w,
        sheetH = data.sheet_size.h,
        frameW = data.frame_size.w,
        frameH = data.frame_size.h,
        totalDuration = totalDuration,
        elapsed = 0,
        currentFrame = 1,
    }, SpriteAnim)

    print(string.format("[SpriteAnim] Loaded: %s (%d frames, %.2fs)",
        sheetPath, #frames, totalDuration))
    return self
end

--- 更新动画计时器（循环播放）
---@param dt number 帧时间
function SpriteAnim:Update(dt)
    self.elapsed = self.elapsed + dt
    -- 循环
    if self.totalDuration > 0 then
        while self.elapsed >= self.totalDuration do
            self.elapsed = self.elapsed - self.totalDuration
        end
    end

    -- 找到当前帧（二分或线性查找，帧数少用线性即可）
    local t = self.elapsed
    local frame = 1
    for i = #self.frames, 1, -1 do
        if t >= self.frames[i].t then
            frame = i
            break
        end
    end
    self.currentFrame = frame
end

--- 内部：根据帧数据绘制到屏幕（被 Draw / DrawAtTime 共用）
local function DrawFrame(vg, f, sheetW, sheetH, img, cx, cy, drawH, flipX)
    -- 按高度等比缩放，保持宽高比
    local scale = drawH / f.h
    local drawW = f.w * scale

    local patternW = sheetW * scale
    local patternH = sheetH * scale

    local drawLeft = cx - drawW * 0.5
    local drawTop  = cy - drawH * 0.5

    local offsetX = f.x * scale
    local offsetY = f.y * scale

    nvgSave(vg)

    if flipX then
        nvgTranslate(vg, cx, 0)
        nvgScale(vg, -1, 1)
        nvgTranslate(vg, -cx, 0)
    end

    local paint = nvgImagePattern(vg,
        drawLeft - offsetX,
        drawTop  - offsetY,
        patternW, patternH,
        0, img, 1.0)

    nvgBeginPath(vg)
    nvgRect(vg, drawLeft, drawTop, drawW, drawH)
    nvgFillPaint(vg, paint)
    nvgFill(vg)

    nvgRestore(vg)
end

--- 在指定位置绘制当前帧（使用内部 elapsed 驱动的帧索引）
---@param cx number 绘制中心 X（屏幕坐标）
---@param cy number 绘制中心 Y（屏幕坐标）
---@param drawH number 目标绘制高度（像素）
---@param flipX boolean|nil 是否水平翻转
function SpriteAnim:Draw(cx, cy, drawH, flipX)
    local f = self.frames[self.currentFrame]
    if not f then return end
    DrawFrame(self.vg, f, self.sheetW, self.sheetH, self.img, cx, cy, drawH, flipX)
end

--- 在指定位置绘制指定时刻的帧（不依赖内部 elapsed，适合逐玩家独立计时）
--- 超过 totalDuration 后自动循环
---@param cx number 绘制中心 X（屏幕坐标）
---@param cy number 绘制中心 Y（屏幕坐标）
---@param drawH number 目标绘制高度（像素）
---@param flipX boolean|nil 是否水平翻转
---@param elapsed number 该玩家的动画已播放时长（秒）
function SpriteAnim:DrawAtTime(cx, cy, drawH, flipX, elapsed)
    local t = (self.totalDuration > 0) and (elapsed % self.totalDuration) or 0
    local frameIdx = 1
    for i = #self.frames, 1, -1 do
        if t >= self.frames[i].t then
            frameIdx = i
            break
        end
    end
    local f = self.frames[frameIdx]
    if not f then return end
    DrawFrame(self.vg, f, self.sheetW, self.sheetH, self.img, cx, cy, drawH, flipX)
end

return SpriteAnim
