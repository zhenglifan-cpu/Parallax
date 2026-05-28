--- Editor/AssetManifest.lua
--- 素材库贴图清单（手动维护）
---
--- 【新增图片说明】
---   1. 将图片文件放入 assets/image/贴图/ 目录（或其子目录）
---   2. 在下方 MANIFEST 对应位置添加一行 path 记录
---   3. path 格式：资源路径（相对于 assets/，不含 assets/ 前缀）
---
--- 【新增子目录说明】
---   在 dirs 表中添加一个条目：
---   { name = "子目录名", files = { "image/贴图/子目录名/图片.png", ... }, dirs = {} }

---@class AssetDir
---@field name string       目录显示名（相对于父目录的名称）
---@field files string[]    该目录下的图片资源路径列表
---@field dirs  AssetDir[]  子目录列表

---@type AssetDir
local MANIFEST = {
    name  = "贴图",           -- 根目录名（贴图调整素材库根）
    files = {},
    dirs = {
        {
            name  = "第一套",
            files = {
                "image/贴图/第一套/HD1_1.png",
                "image/贴图/第一套/HD2_1.png",
                "image/贴图/第一套/HD2_2.png",
                "image/贴图/第一套/HD3_1.png",
                "image/贴图/第一套/HD4_1.png",
                "image/贴图/第一套/HD4_2.png",
                "image/贴图/第一套/HD6_2.png",
                "image/贴图/第一套/HD8_2.png",
                "image/贴图/第一套/HXD2_2.5.png",
                "image/贴图/第一套/HXU2_2.5.png",
                "image/贴图/第一套/HXD4_3.5.png",
                "image/贴图/第一套/HXU4_3.5.png",
                "image/贴图/第一套/HXD6_4.png",
                "image/贴图/第一套/HXU6_4.png",
            },
            dirs = {},
        },
    },
}

--- 根据相对路径（相对于根目录，空串=""表示根）查找对应的 AssetDir 节点
---@param subPath string  e.g. "" | "地面" | "地面/草地"
---@return AssetDir|nil
local function findDir(subPath)
    if subPath == "" or subPath == nil then
        return MANIFEST
    end
    local parts = {}
    for seg in (subPath .. "/"):gmatch("([^/]+)/") do
        parts[#parts + 1] = seg
    end
    local cur = MANIFEST
    for _, seg in ipairs(parts) do
        local found = nil
        for _, d in ipairs(cur.dirs) do
            if d.name == seg then
                found = d
                break
            end
        end
        if not found then return nil end
        cur = found
    end
    return cur
end

--- 扫描指定子路径，返回 (imageList, dirNameList)
---@param subPath string  相对于根目录（image/贴图/）的子路径，根目录传 ""
---@return string[], string[]
local function scan(subPath)
    local node = findDir(subPath)
    if not node then
        return {}, {}
    end

    -- 收集子目录名
    local dirNames = {}
    for _, d in ipairs(node.dirs) do
        local rel = (subPath == "" or subPath == nil)
            and d.name
            or (subPath .. "/" .. d.name)
        dirNames[#dirNames + 1] = rel
    end

    return node.files, dirNames
end

return {
    scan = scan,
}
