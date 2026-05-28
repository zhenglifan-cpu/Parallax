--- Game/LevelData.lua
--- 《同途 / Parallax》关卡数据管理
--- 所有场景数据通过编辑器创建和保存，无硬编码场景

local Shared = require("Network.Shared")
local ok_AM, AssetManifest = pcall(require, "Editor.AssetManifest")
if not ok_AM then AssetManifest = nil end

--- 构建有效 imagePath 集合（来自 AssetManifest 全量扫描）
--- 服务端/无编辑器上下文时返回 nil，表示不过滤
local function buildValidImagePaths()
    if not AssetManifest then return nil end  -- 服务端不过滤
    local set = {}
    local function collect(subPath)
        local files, dirs = AssetManifest.scan(subPath)
        for _, p in ipairs(files) do set[p] = true end
        for _, d in ipairs(dirs) do collect(d) end
    end
    collect("")
    return set
end
local validImagePaths_ = nil  -- 懒初始化

local LevelData = {}

-- ═══════════════════════════════════════════════
-- NPC 对话数据（编辑器不存储对话，此处为对话仓库）
-- key = presetId, value = { dialogueRed={...}, dialogueBlack={...} }
-- ═══════════════════════════════════════════════

LevelData.npcDialogues = {
    npc_01 = {
        dialogueRed = {
            "亲爱的旅者：",
            "Crownpeak 的山顶灯塔即将再次亮起。",
            "传说中，最先抵达山顶的冒险者，会得到沉睡已久的勇者徽章。",
            "沿途会有向导，也会有试炼。",
            "带上你的勇气，向山顶出发吧。",
            "—— 山顶灯塔的守望者",
        },
        dialogueBlack = {
            "最后的幸存者：",
            "山下家园已被暗潮吞没。",
            "Lastpeak 山顶的庇护所仍有灯光。",
            "如果你还能走，就立刻离开。",
            "路上可能还有其他逃难者。遇到他们，不要独自前进。",
            "—— 山顶庇护所管理员",
        },
    },
    npc_02 = {
        dialogueRed = {
            "年轻的冒险家，你来得正好。",
            "Crownpeak 很久没有迎来新的挑战者了。",
            "前方是第一道山门。",
            "门后的路会考验你的脚步，也会考验你是否愿意信任同行者。",
            "记住，徽章不会只回应最快的人。",
            "它也会回应那些愿意回头看一眼的人。",
        },
        dialogueBlack = {
            "又一个逃出来的……",
            "Lastpeak 的路还没完全断，但也撑不了太久。",
            "前方是第一道封锁门。",
            "门后的路不好走。",
            "你旁边那位也是从下面来的，别让谁落在后面。",
            "记住，庇护所不会等一个只顾自己跑的人。",
        },
    },
    npc_03 = {
        dialogueRed = {
            "你就是今年的登山者吗？",
            "我本来想在这里看勇者过第一道桥，可是……",
            "我的幸运羽毛掉到桥那边去了。",
            "没有它，我就不敢继续看了。",
            "你能帮我把它带回来吗？",
        },
        dialogueBlack = {
            "你也是去山顶的吗？",
            "我刚才和大家走散了……",
            "我的家门布条被风吹到裂谷那边去了。",
            "没有它，我会忘记我从哪里来的。",
            "你能帮我拿回来吗？",
        },
    },
}

-- ═══════════════════════════════════════════════
-- 硬编码场景已全部移除
-- 所有场景通过编辑器创建，保存为 scene_X.json 文件
-- ═══════════════════════════════════════════════

LevelData.scenes = {}  -- 空表，不再有硬编码场景

-- ═══════════════════════════════════════════════
-- 幕 & 场景管理
-- ═══════════════════════════════════════════════

local EditorConst = require("Editor.EditorConst")

-- ─── savedScenes 缓存（编辑器保存的场景数据） ───
local savedScenes_ = {}  -- idx -> sceneData (LevelData 格式)

-- ─── acts 元数据 ───
-- 每个 act: { name=string, sceneIndices={0,1,2,...} }
LevelData.acts = {
    { name = "第一幕", sceneIndices = {0} },
}

--- 默认场景 JSON 数据（14:08 编辑器保存，含 129 objects + 10 freeOverlays）
local DEFAULT_SCENE_JSON = '{"freeOverlays":[{"y":6.509229183618159,"_aspectFixed":true,"role":"red","w":3,"x":4.492602770512408,"imagePath":"image/贴图/第一套/HD6_2.png","h":1,"id":"fov_1","rotation":0},{"y":7.022141836889479,"_aspectFixed":true,"role":"red","w":2,"x":1.0092226345712312,"imagePath":"image/贴图/第一套/HD4_2.png","h":1,"id":"fov_2","rotation":0},{"y":6.885520679613684,"_aspectFixed":true,"role":"red","w":1,"x":2.503576282820601,"imagePath":"image/贴图/第一套/HXD2_2.5.png","h":1.25,"id":"fov_3","rotation":0},{"y":6.88810412185139,"_aspectFixed":true,"role":"red","w":1,"x":6.4903237857809599,"imagePath":"image/贴图/第一套/HXU2_2.5.png","h":1.25,"id":"fov_4","rotation":0},{"y":7.066416925571964,"_aspectFixed":true,"role":"red","w":4,"x":8.98722004419386,"imagePath":"image/贴图/第一套/HD8_2.png","h":1,"id":"fov_5","rotation":0},{"y":7.022624412813106,"_aspectFixed":true,"role":"red","w":3,"x":12.496939989944757,"imagePath":"image/贴图/第一套/HD6_2.png","h":1,"id":"fov_6","rotation":0},{"y":7.390523781694304,"_aspectFixed":true,"role":"red","w":1,"x":14.509085099846939,"imagePath":"image/贴图/第一套/HXU2_2.5.png","h":1.25,"id":"fov_7","rotation":0},{"y":7.510924448388573,"_aspectFixed":true,"role":"red","w":1,"x":15.513917726101964,"imagePath":"image/贴图/第一套/HD2_2.png","h":1,"id":"fov_8","rotation":0},{"y":7.376815673972118,"_aspectFixed":true,"role":"red","w":1,"x":16.499979682646499,"imagePath":"image/贴图/第一套/HXD2_2.5.png","h":1.25,"id":"fov_9","rotation":0},{"y":7.001482101783275,"_aspectFixed":true,"role":"red","w":3,"x":18.500383886070549,"imagePath":"image/贴图/第一套/HD6_2.png","h":1,"id":"fov_10","rotation":0}],"name":"scene_0","objects":[{"y":0.75,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_1","w":70},{"y":1.25,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_2","w":70},{"y":1.75,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_3","w":70},{"y":2.25,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_4","w":70},{"y":2.75,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_5","w":70},{"y":3.25,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_6","w":70},{"y":3.75,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_7","w":70},{"y":4.25,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_8","w":70},{"y":4.75,"visibleTo":"all","h":0.5,"type":"platform","x":29.75,"id":"ground_9","w":59.5},{"y":4.75,"visibleTo":"all","h":0.5,"type":"platform","x":65.75,"id":"ground_10","w":8.5},{"y":5.25,"visibleTo":"all","h":0.5,"type":"platform","x":28.5,"id":"ground_11","w":57},{"y":5.25,"visibleTo":"all","h":0.5,"type":"platform","x":65.75,"id":"ground_12","w":8.5},{"y":5.75,"visibleTo":"all","h":0.5,"type":"platform","x":28.5,"id":"ground_13","w":57},{"y":5.75,"visibleTo":"all","h":0.5,"type":"platform","x":58.25,"id":"ground_14","w":0.5},{"y":5.75,"visibleTo":"all","h":0.5,"type":"platform","x":65.75,"id":"ground_15","w":8.5},{"y":6.25,"visibleTo":"all","h":0.5,"type":"platform","x":28.25,"id":"ground_16","w":56.5},{"y":6.25,"visibleTo":"all","h":0.5,"type":"platform","x":58.25,"id":"ground_17","w":1.5},{"y":6.25,"visibleTo":"all","h":0.5,"type":"platform","x":65.75,"id":"ground_18","w":8.5},{"y":6.75,"visibleTo":"all","h":0.5,"type":"platform","x":28.25,"id":"ground_19","w":56.5},{"y":6.75,"visibleTo":"all","h":0.5,"type":"platform","x":58.5,"id":"ground_20","w":2},{"y":6.75,"visibleTo":"all","h":0.5,"type":"platform","x":65.75,"id":"ground_21","w":8.5},{"y":7.25,"visibleTo":"all","h":0.5,"type":"platform","x":1,"id":"ground_22","w":2},{"y":7.25,"visibleTo":"all","h":0.5,"type":"platform","x":27.75,"id":"ground_23","w":41.5},{"y":7.25,"visibleTo":"all","h":0.5,"type":"platform","x":52.5,"id":"ground_24","w":2},{"y":7.25,"visibleTo":"all","h":0.5,"type":"platform","x":66.5,"id":"ground_25","w":7},{"y":7.75,"visibleTo":"all","h":0.5,"type":"platform","x":15.5,"id":"ground_26","w":1},{"y":7.75,"visibleTo":"all","h":0.5,"type":"platform","x":23.25,"id":"ground_27","w":5.5},{"y":7.75,"visibleTo":"all","h":0.5,"type":"platform","x":28.5,"id":"ground_28","w":3},{"y":7.75,"visibleTo":"all","h":0.5,"type":"platform","x":41,"id":"ground_29","w":15},{"y":7.75,"visibleTo":"all","h":0.5,"type":"platform","x":52.5,"id":"ground_30","w":2},{"y":7.75,"visibleTo":"all","h":0.5,"type":"platform","x":66.5,"id":"ground_31","w":7},{"y":8.25,"visibleTo":"all","h":0.5,"type":"platform","x":23.5,"id":"ground_32","w":5},{"y":8.25,"visibleTo":"all","h":0.5,"type":"platform","x":28,"id":"ground_33","w":2},{"y":8.25,"visibleTo":"all","h":0.5,"type":"platform","x":41.5,"id":"ground_34","w":14},{"y":8.25,"visibleTo":"all","h":0.5,"type":"platform","x":52.5,"id":"ground_35","w":2},{"y":8.25,"visibleTo":"all","h":0.5,"type":"platform","x":69.25,"id":"ground_36","w":1.5},{"y":8.75,"visibleTo":"all","h":0.5,"type":"platform","x":22,"id":"ground_37","w":1},{"y":8.75,"visibleTo":"all","h":0.5,"type":"platform","x":24.5,"id":"ground_38","w":3},{"y":8.75,"visibleTo":"all","h":0.5,"type":"platform","x":27.5,"id":"ground_39","w":1},{"y":8.75,"visibleTo":"all","h":0.5,"type":"platform","x":35.75,"id":"ground_40","w":0.5},{"y":8.75,"visibleTo":"all","h":0.5,"type":"platform","x":42,"id":"ground_41","w":11},{"y":8.75,"visibleTo":"all","h":0.5,"type":"platform","x":69.25,"id":"ground_42","w":1.5},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":22.25,"id":"ground_43","w":0.5},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":23.75,"id":"ground_44","w":1.5},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":25.5,"id":"ground_45","w":1},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":38.75,"id":"ground_46","w":1.5},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":41,"id":"ground_47","w":1},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":45.75,"id":"ground_48","w":2.5},{"y":9.25,"visibleTo":"all","h":0.5,"type":"platform","x":69.5,"id":"ground_49","w":1},{"y":9.75,"visibleTo":"all","h":0.5,"type":"platform","x":23.5,"id":"ground_50","w":1},{"y":9.75,"visibleTo":"all","h":0.5,"type":"platform","x":38.75,"id":"ground_51","w":1.5},{"y":9.75,"visibleTo":"all","h":0.5,"type":"platform","x":41,"id":"ground_52","w":1},{"y":9.75,"visibleTo":"all","h":0.5,"type":"platform","x":45.25,"id":"ground_53","w":1.5},{"y":9.75,"visibleTo":"all","h":0.5,"type":"platform","x":48,"id":"ground_54","w":1},{"y":10.25,"visibleTo":"all","h":0.5,"type":"platform","x":23.25,"id":"ground_55","w":0.5},{"y":10.25,"visibleTo":"all","h":0.5,"type":"platform","x":45.25,"id":"ground_56","w":1.5},{"y":10.25,"visibleTo":"all","h":0.5,"type":"platform","x":47.75,"id":"ground_57","w":1.5},{"y":10.75,"visibleTo":"all","h":0.5,"type":"platform","x":47.75,"id":"ground_58","w":1.5},{"y":11.25,"visibleTo":"all","h":0.5,"type":"platform","x":47.75,"id":"ground_59","w":1.5},{"y":11.25,"visibleTo":"all","h":0.5,"type":"platform","x":65.75,"id":"ground_60","w":1.5},{"y":11.25,"visibleTo":"all","h":0.5,"type":"platform","x":68.75,"id":"ground_61","w":1.5},{"y":11.75,"visibleTo":"all","h":0.5,"type":"platform","x":47.75,"id":"ground_62","w":1.5},{"y":11.75,"visibleTo":"all","h":0.5,"type":"platform","x":67.5,"id":"ground_63","w":5},{"y":12.25,"visibleTo":"all","h":0.5,"type":"platform","x":67.25,"id":"ground_64","w":4.5},{"y":12.75,"visibleTo":"all","h":0.5,"type":"platform","x":67.75,"id":"ground_65","w":2.5},{"y":13.25,"visibleTo":"all","h":0.5,"type":"platform","x":68,"id":"ground_66","w":1},{"y":0.25,"visibleTo":"all","h":0.5,"type":"platform","x":35,"id":"ground_67","w":70},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":14.5,"id":"slope_68","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_down_right","type":"platform","x":16.5,"id":"slope_69","w":0.5},{"h":0.5,"y":10.5,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":23,"id":"slope_70","w":0.5},{"h":0.5,"y":7,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":6.5,"id":"slope_71","w":0.5},{"h":0.5,"y":13,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":68.5,"id":"slope_72","w":0.5},{"h":0.5,"y":7,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":6,"id":"slope_73","w":0.5},{"h":0.5,"y":7,"visibleTo":"all","slopeType":"slope_30_down_left","type":"platform","x":2,"id":"slope_74","w":0.5},{"h":0.5,"y":7,"visibleTo":"all","slopeType":"slope_30_down_right","type":"platform","x":2.5,"id":"slope_75","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_45_up","type":"platform","x":20,"id":"slope_76","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_down_left","type":"platform","x":30,"id":"slope_77","w":0.5},{"h":0.5,"y":8,"visibleTo":"all","slopeType":"slope_45_up","type":"platform","x":20.5,"id":"slope_78","w":0.5},{"h":0.5,"y":9,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":40,"id":"slope_79","w":0.5},{"h":0.5,"y":8.5,"visibleTo":"all","slopeType":"slope_30_down_right","type":"platform","x":28.5,"id":"slope_80","w":0.5},{"h":0.5,"y":8.5,"visibleTo":"all","slopeType":"slope_45_up","type":"platform","x":21,"id":"slope_81","w":0.5},{"h":0.5,"y":10,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":23.5,"id":"slope_82","w":0.5},{"h":0.5,"y":8.5,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":35,"id":"slope_83","w":0.5},{"h":0.5,"y":9.5,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":24,"id":"slope_84","w":0.5},{"h":0.5,"y":8.5,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":22.5,"id":"slope_85","w":0.5},{"h":0.5,"y":8.5,"visibleTo":"all","slopeType":"slope_30_down_left","type":"platform","x":28,"id":"slope_86","w":0.5},{"h":0.5,"y":12.5,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":66,"id":"slope_87","w":0.5},{"h":0.5,"y":9.5,"visibleTo":"all","slopeType":"slope_45_up","type":"platform","x":22,"id":"slope_88","w":0.5},{"h":0.5,"y":13,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":66.5,"id":"slope_89","w":0.5},{"h":0.5,"y":9,"visibleTo":"all","slopeType":"slope_45_up","type":"platform","x":21.5,"id":"slope_90","w":0.5},{"h":0.5,"y":8,"visibleTo":"all","slopeType":"slope_30_down_left","type":"platform","x":29,"id":"slope_91","w":0.5},{"h":0.5,"y":12,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":69.5,"id":"slope_92","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":32.5,"id":"slope_93","w":0.5},{"h":0.5,"y":12.5,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":65.5,"id":"slope_94","w":0.5},{"h":0.5,"y":12.5,"visibleTo":"all","slopeType":"slope_45_down","type":"platform","x":69,"id":"slope_95","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_down_right","type":"platform","x":30.5,"id":"slope_96","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_down_left","type":"platform","x":16,"id":"slope_97","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":14,"id":"slope_98","w":0.5},{"h":0.5,"y":8,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":33.5,"id":"slope_99","w":0.5},{"h":0.5,"y":8,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":34,"id":"slope_100","w":0.5},{"h":0.5,"y":8,"visibleTo":"all","slopeType":"slope_30_down_right","type":"platform","x":29.5,"id":"slope_101","w":0.5},{"h":0.5,"y":7.5,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":33,"id":"slope_102","w":0.5},{"h":0.5,"y":13,"visibleTo":"all","slopeType":"slope_30_up_right","type":"platform","x":67,"id":"slope_103","w":0.5},{"h":0.5,"y":8.5,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":34.5,"id":"slope_104","w":0.5},{"h":0.5,"y":9,"visibleTo":"all","slopeType":"slope_30_up_left","type":"platform","x":39.5,"id":"slope_105","w":0.5},{"visibleTo":"all","y":9.25,"event":"water_death","h":0.5,"type":"trigger","x":43,"id":"water_106","w":3},{"visibleTo":"all","y":8.25,"event":"water_death","h":0.5,"type":"trigger","x":26.5,"id":"water_107","w":1},{"visibleTo":"all","y":7.75,"event":"water_death","h":0.5,"type":"trigger","x":26.5,"id":"water_108","w":1},{"visibleTo":"all","y":4.75,"event":"water_death","h":0.5,"type":"trigger","x":60.5,"id":"water_109","w":2},{"bridgeWeight":2,"y":6.6,"visibleTo":"all","h":0.2,"type":"platform","x":60.5,"id":"bridge_110","w":2},{"bridgeWeight":2,"y":10.1,"visibleTo":"all","h":0.2,"type":"platform","x":46.5,"id":"bridge_111","w":1},{"bridgeWeight":2,"y":9.6,"visibleTo":"all","h":0.2,"type":"platform","x":43,"id":"bridge_112","w":3},{"y":9.25,"visibleTo":"all","h":0.5,"type":"crate","x":27.75,"id":"crate_113","w":0.5},{"y":7.25,"visibleTo":"all","h":0.5,"type":"crate","x":54.25,"id":"crate_114","w":0.5},{"y":7.75,"visibleTo":"all","h":0.5,"type":"crate","x":53.75,"id":"crate_115","w":0.5},{"y":8.75,"visibleTo":"all","h":0.5,"type":"crate","x":52.25,"id":"crate_116","w":0.5},{"y":5.25,"visibleTo":"all","h":0.5,"type":"crate","x":60.75,"id":"crate_117","w":0.5},{"y":4.75,"visibleTo":"all","h":0.5,"type":"crate","x":60.75,"id":"crate_118","w":0.5},{"y":7.25,"visibleTo":"all","h":0.5,"type":"crate","x":53.75,"id":"crate_119","w":0.5},{"y":5.25,"visibleTo":"all","h":0.5,"type":"crate","x":60.25,"id":"crate_120","w":0.5},{"y":4.75,"visibleTo":"all","h":0.5,"type":"crate","x":60.25,"id":"crate_121","w":0.5},{"y":7.75,"visibleTo":"all","h":0.5,"type":"crate","x":31.75,"id":"crate_122","w":0.5},{"y":7.25,"visibleTo":"all","h":0.5,"type":"crate","x":58.75,"id":"crate_123","w":0.5},{"y":7.75,"visibleTo":"all","h":0.5,"type":"crate","x":54.25,"id":"crate_124","w":0.5},{"visibleTo":"all","y":7.25,"event":"checkpoint","h":1,"type":"trigger","x":50.75,"id":"chkpt_125","w":0.5},{"visibleTo":"all","y":8.25,"event":"checkpoint","h":1,"type":"trigger","x":63.25,"id":"chkpt_126","w":0.5},{"visibleTo":"all","y":7.25,"event":"checkpoint","h":1,"type":"trigger","x":49.75,"id":"chkpt_127","w":0.5},{"visibleTo":"all","y":7.25,"event":"checkpoint","h":1,"type":"trigger","x":49.25,"id":"chkpt_128","w":0.5},{"visibleTo":"all","y":7.25,"event":"checkpoint","h":1,"type":"trigger","x":50.25,"id":"chkpt_129","w":0.5}],"spawnX":3.25,"spawnBlackX":4.25,"spawnBlackY":7.25,"spawnY":7.25,"groundOverlays":{}}'

--- 创建默认场景（第一幕 scene_0 的预置关卡 — 从编辑器 14:08 保存数据生成）
---@param name? string
---@return table sceneData
local function createDefaultScene(name)
    local data = cjson.decode(DEFAULT_SCENE_JSON)
    if name then data.name = name end
    -- groundOverlays 在 JSON 中是 {}（空 object），转为数组兼容格式
    if type(data.groundOverlays) == "table" and next(data.groundOverlays) == nil then
        data.groundOverlays = {}
    end
    return data
end

--- 保存幕元数据到文件
local function saveActsMeta()
    local json = cjson.encode({ acts = LevelData.acts })
    local ok, err = pcall(function()
        local file = File:new(EditorConst.ACTS_META_FILE, FILE_WRITE)
        if file:IsOpen() then
            file:WriteString(json)
            file:Close()
            print("[LevelData] Acts metadata saved")
        end
    end)
    if not ok then
        print("[LevelData] WARN: Acts meta save failed: " .. tostring(err))
    end
end

--- 初始化：从文件加载已保存的场景和幕元数据
--- @param isServer boolean? 是否在服务端运行（服务端沙盒禁止文件 I/O，直接跳过磁盘读取），默认 false
function LevelData.Init(isServer)
    if isServer then
        -- 服务端沙盒无法读取客户端文件系统，但需要默认场景数据保证首次 Init 能正常加载
        -- 后续 DebugReload 推送数据时会覆盖
        print("[LevelData] Server mode — loading default scene data")
        savedScenes_ = {}
        for _, act in ipairs(LevelData.acts) do
            for _, sceneIdx in ipairs(act.sceneIndices) do
                savedScenes_[sceneIdx] = createDefaultScene("场景" .. sceneIdx)
            end
        end
        return
    end

    -- 1. 加载幕元数据
    local metaPath = EditorConst.ACTS_META_FILE
    local hasActsMeta = fileSystem:FileExists(metaPath)
    if hasActsMeta then
        local metaFile = File(metaPath, FILE_READ)
        if metaFile:IsOpen() then
            local content = metaFile:ReadString()
            metaFile:Close()
            if content and #content > 0 then
                local decOk, meta = pcall(cjson.decode, content)
                if decOk and meta and meta.acts then
                    LevelData.acts = meta.acts
                    print("[LevelData] Loaded acts metadata: " .. #meta.acts .. " act(s)")
                end
            end
        end
    end

    -- 2. 加载已保存的场景文件
    --    仅在 acts_meta 存在时加载（说明是编辑器创建的新数据）
    --    如果 acts_meta 不存在，跳过旧场景文件（清除旧硬编码遗留数据）
    savedScenes_ = {}
    if hasActsMeta then
        local totalScenes = LevelData.GetTotalSceneCount()
        for idx = 0, totalScenes - 1 do
            local path = EditorConst.SCENE_FILE_PREFIX .. idx .. ".json"
            if fileSystem:FileExists(path) then
                local file = File(path, FILE_READ)
                if file:IsOpen() then
                    local content = file:ReadString()
                    file:Close()
                    if content and #content > 0 then
                        local decOk, data = pcall(cjson.decode, content)
                        if decOk and data then
                            savedScenes_[idx] = data
                            print("[LevelData] Loaded saved scene " .. idx .. ": " .. (data.name or "?"))
                        end
                    end
                end
            end
        end
    else
        print("[LevelData] No acts metadata found — starting fresh (ignoring old scene files)")
    end

    -- 3. 确保 acts 中的每个场景都有数据（没有则创建默认空白场景）
    for _, act in ipairs(LevelData.acts) do
        for _, sceneIdx in ipairs(act.sceneIndices) do
            if not savedScenes_[sceneIdx] then
                print("[LevelData] Creating default scene for index " .. sceneIdx)
                local defaultScene = createDefaultScene("场景" .. sceneIdx)
                LevelData.UpdateScene(sceneIdx, defaultScene)
            end
        end
    end
    -- 保存 acts 元数据（确保 acts_meta.json 存在，后续运行可正常加载）
    if not hasActsMeta then
        saveActsMeta()
    end
end

--- 获取场景数据（纯粹从已保存的网格数据返回）
---@param sceneIdx number
---@return table|nil
function LevelData.GetScene(sceneIdx)
    local saved = savedScenes_[sceneIdx]
    if saved then
        -- 为 NPC 回填对话数据（编辑器不存储对话）
        local result = {
            name     = saved.name,
            spawnX   = saved.spawnX,
            spawnY   = saved.spawnY,
            spawnBlackX = saved.spawnBlackX,
            spawnBlackY = saved.spawnBlackY,
            passHint = saved.passHint,
            objects  = {},
            groundOverlays = saved.groundOverlays or {},
            freeOverlays   = (function()
                -- 过滤掉不在当前素材库中的旧 freeOverlay，避免加载已删除图片引发错误
                -- 服务端无 AssetManifest 时 validImagePaths_ 为 nil，跳过过滤
                if validImagePaths_ == nil then
                    validImagePaths_ = buildValidImagePaths()
                end
                if not validImagePaths_ then
                    return saved.freeOverlays or {}
                end
                local filtered = {}
                for _, fov in ipairs(saved.freeOverlays or {}) do
                    if validImagePaths_[fov.imagePath] then
                        filtered[#filtered + 1] = fov
                    else
                        print(string.format("[LevelData] freeOverlay removed (invalid path): %s", fov.imagePath or "?"))
                    end
                end
                return filtered
            end)(),
        }
        for _, obj in ipairs(saved.objects or {}) do
            if obj.type == "npc" and obj.presetId then
                local dialogue = LevelData.npcDialogues[obj.presetId]
                if dialogue then
                    local enriched = {}
                    for k, v in pairs(obj) do enriched[k] = v end
                    enriched.dialogueRed = dialogue.dialogueRed
                    enriched.dialogueBlack = dialogue.dialogueBlack
                    table.insert(result.objects, enriched)
                else
                    table.insert(result.objects, obj)
                end
            else
                table.insert(result.objects, obj)
            end
        end
        return result
    end
    return nil
end

--- 更新场景缓存并保存到文件
---@param sceneIdx number
---@param sceneData table LevelData 格式
function LevelData.UpdateScene(sceneIdx, sceneData)
    savedScenes_[sceneIdx] = sceneData

    -- 写入文件
    local json = cjson.encode(sceneData)
    local path = EditorConst.SCENE_FILE_PREFIX .. sceneIdx .. ".json"

    local ok, err = pcall(function()
        local file = File:new(path, FILE_WRITE)
        if file:IsOpen() then
            file:WriteString(json)
            file:Close()
            print("[LevelData] Saved scene " .. sceneIdx .. " to " .. path)
        else
            print("[LevelData] WARN: Cannot write " .. path)
        end
    end)
    if not ok then
        print("[LevelData] WARN: Scene save failed: " .. tostring(err))
    end
end

--- 直接设置场景缓存（不写文件，供服务端通过网络接收数据时使用）
---@param sceneIdx number
---@param sceneData table LevelData 格式
function LevelData.SetScene(sceneIdx, sceneData)
    savedScenes_[sceneIdx] = sceneData
    print("[LevelData] SetScene " .. sceneIdx .. " (in-memory)")
end

--- 获取总场景数（所有幕中的场景总数）
---@return number
function LevelData.GetTotalSceneCount()
    local count = 0
    for _, act in ipairs(LevelData.acts) do
        count = count + #act.sceneIndices
    end
    return count
end

--- 获取场景数（兼容旧接口）
---@return number
function LevelData.GetSceneCount()
    local count = 0
    for _ in pairs(savedScenes_) do count = count + 1 end
    return count
end

-- ═══════════════════════════════════════════════
-- 幕 & 场景 CRUD
-- ═══════════════════════════════════════════════

--- 获取幕列表
---@return table[] acts
function LevelData.GetActs()
    return LevelData.acts
end

--- 获取指定幕的场景索引列表
---@param actIdx number 1-based
---@return number[]|nil
function LevelData.GetActScenes(actIdx)
    local act = LevelData.acts[actIdx]
    return act and act.sceneIndices or nil
end

--- 获取下一个可用的场景索引
---@return number
local function nextSceneIdx()
    local maxIdx = -1
    for _, act in ipairs(LevelData.acts) do
        for _, si in ipairs(act.sceneIndices) do
            if si > maxIdx then maxIdx = si end
        end
    end
    for idx in pairs(savedScenes_) do
        if idx > maxIdx then maxIdx = idx end
    end
    return maxIdx + 1
end

--- 添加幕
---@param name? string 幕名称
---@return number actIdx 新幕的 1-based 索引
function LevelData.AddAct(name)
    local actIdx = #LevelData.acts + 1
    LevelData.acts[actIdx] = {
        name = name or ("第" .. actIdx .. "幕"),
        sceneIndices = {},
    }
    saveActsMeta()
    print("[LevelData] Added act " .. actIdx .. ": " .. LevelData.acts[actIdx].name)
    return actIdx
end

--- 删除幕（不删除场景数据本身，只移除分组）
---@param actIdx number 1-based
---@return boolean
function LevelData.RemoveAct(actIdx)
    if #LevelData.acts <= 1 then
        print("[LevelData] Cannot remove last act")
        return false
    end
    if not LevelData.acts[actIdx] then return false end
    table.remove(LevelData.acts, actIdx)
    saveActsMeta()
    print("[LevelData] Removed act " .. actIdx)
    return true
end

--- 在指定幕中添加新场景
---@param actIdx number 1-based
---@param name? string 场景名称
---@return number sceneIdx 新场景的索引
function LevelData.AddScene(actIdx, name)
    local act = LevelData.acts[actIdx]
    if not act then
        print("[LevelData] Invalid actIdx: " .. tostring(actIdx))
        return -1
    end

    local sceneIdx = nextSceneIdx()
    table.insert(act.sceneIndices, sceneIdx)

    -- 创建空场景数据并保存
    local emptyScene = createDefaultScene(name or ("场景" .. sceneIdx))
    LevelData.UpdateScene(sceneIdx, emptyScene)
    saveActsMeta()

    print("[LevelData] Added scene " .. sceneIdx .. " to act " .. actIdx)
    return sceneIdx
end

--- 从指定幕中删除场景
---@param actIdx number 1-based
---@param sceneIdx number
---@return boolean
function LevelData.RemoveScene(actIdx, sceneIdx)
    local act = LevelData.acts[actIdx]
    if not act then return false end

    -- 从幕中移除
    local found = false
    for i, si in ipairs(act.sceneIndices) do
        if si == sceneIdx then
            table.remove(act.sceneIndices, i)
            found = true
            break
        end
    end
    if not found then return false end

    -- 清除缓存
    savedScenes_[sceneIdx] = nil

    saveActsMeta()
    print("[LevelData] Removed scene " .. sceneIdx .. " from act " .. actIdx)
    return true
end

--- 获取场景的已保存编辑器数据
---@param sceneIdx number
---@return table|nil
function LevelData.GetSavedScene(sceneIdx)
    return savedScenes_[sceneIdx]
end

return LevelData
