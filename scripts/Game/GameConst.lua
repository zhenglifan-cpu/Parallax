--- Game/GameConst.lua
--- 《同途 / Parallax》游戏物理与显示常量

local GameConst = {}

-- ─── 物理常量 ───
GameConst.GRAVITY           = 30.0     -- 物理世界重力 (m/s²)，Box2D 世界重力加速度

-- ─── 计时器跳跃物理标定（按住≥0.3s=长跳，松键<0.3s=短跳）───
-- 身高 = 0.9格 = 0.45m（CELL_SIZE=0.5m）
--
-- 【长跳（按住≥0.3s）】v₀=14.0 m/s，g_scale=1.5 → g_eff=45 m/s²
--   t_rise = 14.0/45 = 0.311s（≥0.3s，玩家能在空中确认长跳）
--   h_apex = 14²/(2×45) = 2.178m（约 4.4格）
--   g_fall = 45×2.5 = 112.5 m/s²  t_fall ≈ 0.197s  total ≈ 0.508s ✓
--
-- 【短跳（松键<0.3s）】松键时截断速度到 JUMP_CUT_MIN_VY，切换至高重力（1.5×延长版）
--   g_eff_s = 30×2.64 = 79.2 m/s²，JUMP_CUT_MIN_VY = 8.4 m/s
--   t_up = 8.4/79.2 = 0.106s，h_apex = 8.4²/(2×79.2) = 0.446m（≈ 0.89格）
--   g_fall = 79.2×2.5 = 198 m/s²，t_down = √(2×0.446/198) = 0.067s
--   t_post_cut ≈ 0.173s（原 0.116s 的 1.5倍）
--   总时长 = t_rel + t_post < 0.3 + 0.173 ≈ 0.473s（仍短于长跳 0.508s）✓
--   水平：松键后 3.5 m/s × 0.173s ≈ 0.61m，极限持按(0.3s×1.2+0.173×3.5)≈1.0m=2格
GameConst.PLAYER_SPEED      = 2.0      -- 玩家水平移动速度 (m/s)
GameConst.PLAYER_JUMP_SPEED = 14.0     -- 跳跃初速度 (m/s)

-- ─── 蔚蓝风格跳跃手感 ───
GameConst.PLAYER_SPEED_AIR       = 1.2    -- 空中水平速度上限：长跳 / 起跳未确认时 (m/s)
GameConst.PLAYER_SPEED_AIR_SHORT = 3.5    -- 短跳确认后水平速度：极限(0.3s持按)才能跨2格，日常点按约1.2格 (m/s)
GameConst.JUMP_CUT_MIN_VY        = 8.4    -- 短跳截断速度 (m/s)：松键时将 vy 截为此值（1.5×延长）
-- 长跳/默认空中重力缩放：g_eff = 30×1.5 = 45 m/s²（中等，使起跳时长 ≈ 0.311s > 0.3s）
GameConst.PLAYER_AIR_GRAVITY_SCALE = 1.5    -- 长跳空中 gravityScale（松键前 / 确认长跳后）
-- 短跳截断后高重力：g_eff_s = 30×2.64 = 79.2 m/s²（使短跳快速落地，总时长 < 长跳）
GameConst.PLAYER_SHORT_JUMP_GRAVITY_SCALE = 2.64  -- 短跳空中 gravityScale（松键截断后）
-- 按住跳跃键超过此时长确认为长跳，否则松键触发短跳
GameConst.LONG_JUMP_HOLD_TIME = 0.3     -- 长跳确认阈值 (s)
-- 顶点悬停：小窗口（±1 m/s），主要在短跳中感受到自然悬浮
GameConst.JUMP_APEX_THRESHOLD   = 1.0    -- 顶点悬停触发窗口：|vy|<此值时进入悬浮 (m/s)
GameConst.JUMP_APEX_BOOST_RATIO = 0.75   -- 顶点重力补偿比例（向上补偿 = effectiveG × ratio × dt）
-- 下落加速：长跳等效下落重力 = 79.2×2.5 = 198 m/s²；短跳 = 15.9×2.5 = 39.75 m/s²
GameConst.FALL_GRAVITY_MULT     = 2.5    -- 下落阶段额外重力倍数（蔚蓝原版约 3×，取 2.5 保留手感余量）
-- 土狼跳：5帧=0.083s（蔚蓝官方原值）；起跳缓冲保持一致
GameConst.COYOTE_TIME           = 0.083  -- 土狼跳容错窗口 (s)（蔚蓝官方 5帧 = 5/60 ≈ 0.083s）
GameConst.JUMP_BUFFER_TIME      = 0.083  -- 起跳缓冲窗口 (s)
GameConst.AIR_JUMP_COUNT        = 1      -- 最多空中额外跳次数（二段跳）
GameConst.AIR_JUMP_SPEED_RATIO  = 0.85   -- 二段跳速度系数（× PLAYER_JUMP_SPEED）

-- ─── 摔落伤害 ───
GameConst.FALL_DEATH_HEIGHT = 3.0      -- 摔死高度阈值 (m)，即 6格
-- 玩家碰撞体：椭圆 hx=0.1362m, hy=0.225m → 全高 0.45m = 0.9格（CELL_SIZE=0.5m）
-- 缩小半高：0.2475→0.225（-0.0225m），使角色能通过 1格(0.5m)净高通道（余量 0.05m）
GameConst.PLAYER_RADIUS     = 0.225    -- 玩家碰撞椭圆半高 hy (m)
GameConst.PLAYER_HX         = 0.1362   -- 玩家碰撞椭圆半宽 hx (m)

-- ─── 脚底传感器（贴近椭圆底端上方 0.02m） ───
GameConst.FOOT_SENSOR_OFFSET_Y = -0.205  -- 传感器中心 Y 偏移 (m)  = -(hy - 0.02) = -(0.225-0.02)
GameConst.FOOT_SENSOR_RADIUS   = 0.08    -- 传感器半径 (m)，需足够大防止卡入斜坡瓷砖缝隙

-- ─── 交互常量 ───
GameConst.INTERACT_RADIUS   = 1.5      -- 交互检测距离 (m)

-- ─── 推箱子常量 ───
GameConst.CRATE_PUSH_SPEED    = 2.0    -- 推/拉速度 (m/s)
GameConst.CRATE_PUSH_RANGE    = 1.0    -- 推/拉检测距离 (m)
GameConst.CRATE_PULL_RANGE    = 1.2    -- 拉箱子最大距离 (m)
GameConst.CRATE_ONEWAY_MARGIN = 0.15   -- 单向平台：玩家脚底须高于箱顶此值才保留碰撞 (m)
GameConst.CRATE_SLOPE_RAY_LEN = 1.0    -- 斜坡检测射线长度 (m)
GameConst.CRATE_ANGLE_LERP    = 8.0    -- 角度平滑插值速度

-- ─── 网格常量 ───
GameConst.CELL_SIZE         = 0.5      -- 每格 0.5 米（与 EditorConst.CELL_SIZE 一致）

-- ─── 显示常量 ───
GameConst.PIXELS_PER_UNIT   = 90       -- 像素/米 缩放比

-- ─── 视差滚动因子（背景层） ───
GameConst.PARALLAX = {
    [0] = 0.0,   -- 天空（固定）
    [1] = 0.1,   -- 远山
    [2] = 0.3,   -- 中景
    [3] = 0.6,   -- 近景
    [4] = 1.2,   -- 前景粒子（比主层更快）
}

-- ─── 设计分辨率（16:9 固定比例） ───
GameConst.DESIGN_WIDTH  = 960     -- 设计宽度（逻辑像素）
GameConst.DESIGN_HEIGHT = 540     -- 设计高度（逻辑像素）= 960/16*9

-- ─── 相机 ───
-- CAM_Y_OFFSET: camY = myY + offset，offset=1.0 时本地玩家物理中心在屏幕 67% 处
--   玩家全高 0.99格(0.495m)，头顶 ≈ +0.2475m，脚部 ≈ -0.2475m（相对碰撞中心）
--   视觉中心（cy-20px）≈ 63%，头部 ≈ 56%，脚部 ≈ 70%，均在 2/9~7/9 安全区内
GameConst.CAM_Y_OFFSET   = 1.0    -- 相机中心相对双人中点的 Y 偏移 (m)
GameConst.CAM_MIN_Y      = 0.0    -- 相机最低 Y
GameConst.CAM_LERP_SPEED = 5.0    -- 相机平滑跟随速度
-- CAM_Y_CLAMP: 硬约束上限，保证本地玩家物理中心始终在 [2/9, 7/9] 区域内
-- = (DESIGN_HEIGHT/2 - 2/9*DESIGN_HEIGHT) / PPU = (270 - 120) / 90 = 1.667m
-- 注：此公式与玩家尺寸无关，玩家缩小至 0.99格后仍使用相同值
GameConst.CAM_Y_CLAMP    = 1.667  -- 相机与本地玩家 Y 的最大偏差 (m)

-- ─── 场景边界 ───
GameConst.SCENE_TRANSITION_X = 40.0  -- 触发场景切换的 X 坐标 (m)
GameConst.SCENE_FLOOR_Y      = -10.0 -- 掉落死亡线 Y (m)

return GameConst
