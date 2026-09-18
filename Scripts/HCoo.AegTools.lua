script_name = "Aegisub 工具集"
script_description = "将多个字幕工具和共享 Python 路径设置集中显示在“Aegisub 工具集”菜单下。"
script_author = "H.Coo"
script_version = "1.6.5"
script_namespace = "H.Coo.AegTools"

local REAL_AEGISUB = aegisub
local ROOT_MENU = "Aegisub 工具集"
local CAPTURED = {}
local LOAD_ERRORS = {}
local last_tool_name = nil

local TOOL_SPECS = {
    {
        id = 'pattern_fill',
        name = '文字内部图案填充',
        description = '在文字矢量遮罩内部铺设圆点、方块或自定义图案。',
        source = [==[

script_name = "文字内部图案填充"
script_description = "使用 Yutils 将文字转换为矢量遮罩，并在文字内部铺设圆点、方块或自定义 ASS 绘图。"
script_author = "OpenAI"
script_version = "0.2.1"

include("karaskel.lua")

local Yutils = nil
local OLD_TEMP_PREFIX = "PFILL_PREVIEW|"
local OUTPUT_PREFIX = "PFILL|"
local GENERATED_EXTRA_KEY = "_hcoo_aegtools_generated"
local MAX_SHAPES = 8000
local PATTERN_PADDING = 20

local last_config = {
    shape_type = "圆形",
    custom_shape = "m -10 -10 l 10 -10 10 10 -10 10",
    size = 7,
    gap_x = 8,
    gap_y = 8,
    offset_x = 0,
    offset_y = 0,
    jitter = 20,
    stagger = false,
    color = "#FFFFFF",
    alpha = "#00",
    replace_same = false
}

local function show_message(message, title)
    aegisub.dialog.display({
        {class="label", label=(title and (title .. "\n\n") or "") .. tostring(message), x=0, y=0, width=6, height=2}
    }, {"确定"}, {ok="确定"})
end

local function get_yutils()
    if Yutils then return Yutils end

    local ok, module_or_error = pcall(require, "Yutils")
    if ok then
        if type(module_or_error) == "table" then
            Yutils = module_or_error
        elseif type(_G.Yutils) == "table" then
            Yutils = _G.Yutils
        end
    end

    if not Yutils or type(Yutils.decode) ~= "table" or type(Yutils.shape) ~= "table" then
        show_message(
            "没有找到 Yutils。请先安装 Yutils，并确认 require(\"Yutils\") 可以在 Aegisub 自动化脚本中加载。\n\n" ..
            "原始错误：" .. tostring(module_or_error),
            "无法运行"
        )
        aegisub.cancel()
    end

    return Yutils
end

local function shallow_copy(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function copy_extra(extra)
    local target = {}
    for key, value in pairs(extra or {}) do
        target[key] = value
    end
    return target
end

local function generated_marker(line)
    if line and type(line.extra) == "table"
        and type(line.extra[GENERATED_EXTRA_KEY]) == "string" then
        return line.extra[GENERATED_EXTRA_KEY]
    end
    return line and type(line.effect) == "string" and line.effect or ""
end

local function set_generated_marker(line, marker)
    line.effect = ""
    line.extra = copy_extra(line.extra)
    line.extra[GENERATED_EXTRA_KEY] = marker
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function bool_value(value)
    if value == true then return true end
    if value == false or value == nil then return false end
    return (tonumber(value) or 0) ~= 0
end

local function fmt_number(value)
    local rounded
    if value >= 0 then
        rounded = math.floor(value * 1000 + 0.5) / 1000
    else
        rounded = math.ceil(value * 1000 - 0.5) / 1000
    end
    if math.abs(rounded) < 0.0005 then rounded = 0 end
    local text = string.format("%.3f", rounded)
    text = text:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
    return text
end

local function html_color_to_ass(value)
    local hex = tostring(value or "#FFFFFF"):gsub("#", "")
    if #hex ~= 6 then hex = "FFFFFF" end
    local rr = hex:sub(1, 2)
    local gg = hex:sub(3, 4)
    local bb = hex:sub(5, 6)
    return "&H" .. bb .. gg .. rr .. "&"
end

local function html_alpha_to_ass(value)
    local hex = tostring(value or "#00"):gsub("#", "")
    if #hex ~= 2 then hex = "00" end
    return "&H" .. hex .. "&"
end

local function style_color(style, key)
    local hex = style and tostring(style[key] or ""):upper():match("&H(%x+)")
    if not hex then return nil end
    if #hex < 8 then hex = string.rep("0", 8 - #hex) .. hex end
    return "&H" .. hex:sub(-6) .. "&"
end

local function style_alpha(style, key)
    local hex = style and tostring(style[key] or ""):upper():match("&H(%x+)")
    if not hex then return nil end
    if #hex < 8 then return "&H00&" end
    return "&H" .. hex:sub(#hex - 7, #hex - 6) .. "&"
end

local function differs(value, expected)
    value = tonumber(value)
    return value == nil or math.abs(value - expected) > 0.000001
end

local function source_style(styles, line)
    if type(line.styleref) == "table" then return line.styleref end
    return styles and styles[line.style] or nil
end

local function fingerprint(line)
    local source = table.concat({
        tostring(line.start_time or 0),
        tostring(line.end_time or 0),
        tostring(line.layer or 0),
        tostring(line.style or ""),
        tostring(line.actor or ""),
        tostring(line.text or "")
    }, "|")

    local hash = 5381
    for index = 1, #source do
        hash = (hash * 33 + source:byte(index)) % 2147483647
    end
    return tostring(hash)
end

local function effect_has_prefix(line, prefix)
    return line.class == "dialogue"
        and generated_marker(line):sub(1, #prefix) == prefix
end

local function clear_by_prefix(subtitles, prefix)
    for index = #subtitles, 1, -1 do
        local line = subtitles[index]
        if effect_has_prefix(line, prefix) then
            subtitles.delete(index)
        end
    end
end

local function remove_matching_outputs(subtitles, fingerprints)
    for index = #subtitles, 1, -1 do
        local line = subtitles[index]
        if effect_has_prefix(line, OUTPUT_PREFIX) then
            local id = generated_marker(line):sub(#OUTPUT_PREFIX + 1)
            if fingerprints[id] then
                subtitles.delete(index)
            end
        end
    end
end

local function extract_last_number(text, pattern)
    local result = nil
    for block in tostring(text or ""):gmatch("{([^}]*)}") do
        for value in block:gmatch(pattern) do
            result = tonumber(value)
        end
    end
    return result
end

local function extract_last_string(text, pattern)
    local result = nil
    for block in tostring(text or ""):gmatch("{([^}]*)}") do
        for value in block:gmatch(pattern) do
            result = trim(value)
        end
    end
    return result
end

local function extract_last_pos(text)
    local px, py = nil, nil
    for block in tostring(text or ""):gmatch("{([^}]*)}") do
        for x, y in block:gmatch("\\pos%s*%(%s*([%+%-]-[%d%.]+)%s*,%s*([%+%-]-[%d%.]+)%s*%)") do
            px, py = tonumber(x), tonumber(y)
        end
    end
    return px, py
end

local function contains_unsupported_tags(text)
    local lowered = tostring(text or ""):lower()
    local checks = {
        {"\\move%s*%(", "\\move"},
        {"\\t%s*%(", "\\t"},
        {"\\fr", "旋转标签"},
        {"\\fa[xy]", "透视/倾斜标签"},
        {"\\org%s*%(", "\\org"},
        {"\\clip%s*%(", "已有 \\clip"},
        {"\\iclip%s*%(", "已有 \\iclip"},
        {"\\fad%s*%(", "\\fad"},
        {"\\fade%s*%(", "\\fade"},
        {"\\k%d", "卡拉 OK 标签"},
        {"\\kf%d", "卡拉 OK 标签"},
        {"\\ko%d", "卡拉 OK 标签"},
        {"\\r", "\\r 样式重置"},
        {"\\p%d", "原行已经是绘图"}
    }

    for _, item in ipairs(checks) do
        if lowered:match(item[1]:lower()) then
            return item[2]
        end
    end

    if lowered:find("\\n", 1, true) then
        return "多行换行"
    end

    return nil
end

local function parse_font_settings(line)
    local style = line.styleref or {}
    local text = line.text or ""

    local settings = {
        family = style.fontname or "Arial",
        bold = bool_value(style.bold),
        italic = bool_value(style.italic),
        underline = bool_value(style.underline),
        strikeout = bool_value(style.strikeout),
        size = tonumber(style.fontsize) or 40,
        scale_x = tonumber(style.scale_x) or 100,
        scale_y = tonumber(style.scale_y) or 100,
        spacing = tonumber(style.spacing) or 0,
        align = tonumber(style.align or style.alignment) or 2,
        has_metric_override = false,
        has_alignment_override = false
    }

    local family = extract_last_string(text, "\\fn([^\\}]*)")
    if family and family ~= "" then
        settings.family = family
        settings.has_metric_override = true
    end

    local size = extract_last_number(text, "\\fs([%+%-]-[%d%.]+)")
    if size then
        settings.size = size
        settings.has_metric_override = true
    end

    local scale_x = extract_last_number(text, "\\fscx([%+%-]-[%d%.]+)")
    if scale_x then
        settings.scale_x = scale_x
        settings.has_metric_override = true
    end

    local scale_y = extract_last_number(text, "\\fscy([%+%-]-[%d%.]+)")
    if scale_y then
        settings.scale_y = scale_y
        settings.has_metric_override = true
    end

    local spacing = extract_last_number(text, "\\fsp([%+%-]-[%d%.]+)")
    if spacing then
        settings.spacing = spacing
        settings.has_metric_override = true
    end

    local bold = extract_last_number(text, "\\b([%+%-]-%d+)")
    if bold ~= nil then
        settings.bold = bold ~= 0
        settings.has_metric_override = true
    end

    local italic = extract_last_number(text, "\\i([01])")
    if italic ~= nil then
        settings.italic = italic ~= 0
        settings.has_metric_override = true
    end

    local underline = extract_last_number(text, "\\u([01])")
    if underline ~= nil then
        settings.underline = underline ~= 0
        settings.has_metric_override = true
    end

    local strikeout = extract_last_number(text, "\\s([01])")
    if strikeout ~= nil then
        settings.strikeout = strikeout ~= 0
        settings.has_metric_override = true
    end

    local align = extract_last_number(text, "\\an([1-9])")
    if align then
        settings.align = align
        settings.has_alignment_override = true
    end

    return settings
end

local function alignment_factors(align)
    local horizontal = 0.5
    local vertical = 1

    if align == 1 or align == 4 or align == 7 then
        horizontal = 0
    elseif align == 3 or align == 6 or align == 9 then
        horizontal = 1
    end

    if align >= 7 then
        vertical = 0
    elseif align >= 4 then
        vertical = 0.5
    end

    return horizontal, vertical
end

local function margin_anchor(line, meta, align)
    local horizontal, vertical = alignment_factors(align)
    local style = line.styleref or {}

    local margin_l = tonumber(line.eff_margin_l or line.margin_l or style.margin_l) or 0
    local margin_r = tonumber(line.eff_margin_r or line.margin_r or style.margin_r) or 0
    local margin_t = tonumber(line.eff_margin_t or line.margin_t or style.margin_t or style.margin_v) or 0
    local margin_b = tonumber(line.eff_margin_b or line.margin_b or style.margin_b or style.margin_v) or 0

    local x
    if horizontal == 0 then
        x = margin_l
    elseif horizontal == 1 then
        x = (tonumber(meta.res_x) or 384) - margin_r
    else
        x = (tonumber(meta.res_x) or 384) / 2
    end

    local y
    if vertical == 0 then
        y = margin_t
    elseif vertical == 1 then
        y = (tonumber(meta.res_y) or 288) - margin_b
    else
        y = (tonumber(meta.res_y) or 288) / 2
    end

    return x, y
end

local function shape_circle(size)
    local r = size / 2
    local k = r * 0.5522847498
    return table.concat({
        "m", fmt_number(r), "0",
        "b", fmt_number(r), fmt_number(k), fmt_number(k), fmt_number(r), "0", fmt_number(r),
        "b", fmt_number(-k), fmt_number(r), fmt_number(-r), fmt_number(k), fmt_number(-r), "0",
        "b", fmt_number(-r), fmt_number(-k), fmt_number(-k), fmt_number(-r), "0", fmt_number(-r),
        "b", fmt_number(k), fmt_number(-r), fmt_number(r), fmt_number(-k), fmt_number(r), "0"
    }, " ")
end

local function shape_polygon(points)
    local output = {"m", fmt_number(points[1][1]), fmt_number(points[1][2]), "l"}
    for index = 2, #points do
        output[#output + 1] = fmt_number(points[index][1])
        output[#output + 1] = fmt_number(points[index][2])
    end
    return table.concat(output, " ")
end

local function shape_square(size)
    local h = size / 2
    return shape_polygon({{-h, -h}, {h, -h}, {h, h}, {-h, h}})
end

local function shape_diamond(size)
    local h = size / 2
    return shape_polygon({{0, -h}, {h, 0}, {0, h}, {-h, 0}})
end

local function shape_triangle(size)
    local h = size / 2
    return shape_polygon({{0, -h}, {h, h}, {-h, h}})
end

local function shape_star(size)
    local outer = size / 2
    local inner = outer * 0.3819660113
    local points = {}
    for index = 0, 9 do
        local radius = (index % 2 == 0) and outer or inner
        local angle = -math.pi / 2 + index * math.pi / 5
        points[#points + 1] = {math.cos(angle) * radius, math.sin(angle) * radius}
    end
    return shape_polygon(points)
end

local function sanitize_custom_shape(text)
    local shape = tostring(text or "")
    shape = shape:gsub("{[^}]*}", " ")
    shape = shape:gsub("\\p%d+", " ")
    shape = shape:gsub("[\r\n\t]+", " ")
    shape = shape:gsub("%s+", " ")
    return trim(shape)
end

local function normalize_custom_shape(yutils, shape, size)
    local clean = sanitize_custom_shape(shape)
    if clean == "" then
        return nil, "自定义绘图代码为空。"
    end

    local ok_bounds, x0, y0, x1, y1 = pcall(yutils.shape.bounding, clean)
    if not ok_bounds or not x0 or not y0 or not x1 or not y1 then
        return nil, "无法解析自定义 ASS 绘图代码。"
    end

    local width = x1 - x0
    local height = y1 - y0
    local longest = math.max(width, height)
    if longest <= 0 then
        return nil, "自定义绘图没有有效面积。"
    end

    local scale = size / longest
    local center_x = (x0 + x1) / 2
    local center_y = (y0 + y1) / 2

    local ok_filter, normalized = pcall(yutils.shape.filter, clean, function(x, y)
        return (x - center_x) * scale, (y - center_y) * scale
    end)

    if not ok_filter or not normalized then
        return nil, "自定义绘图缩放失败。"
    end

    return normalized, nil
end

local function create_base_shape(yutils, config)
    if config.shape_type == "圆形" then
        return shape_circle(config.size)
    elseif config.shape_type == "方形" then
        return shape_square(config.size)
    elseif config.shape_type == "菱形" then
        return shape_diamond(config.size)
    elseif config.shape_type == "三角形" then
        return shape_triangle(config.size)
    elseif config.shape_type == "五角星" then
        return shape_star(config.size)
    elseif config.shape_type == "自定义绘图" then
        return normalize_custom_shape(yutils, config.custom_shape, config.size)
    end
    return nil, "未知图案类型：" .. tostring(config.shape_type)
end

local function deterministic_noise(row, column, salt)
    local value = (row * 92837111 + column * 689287499 + salt * 283923481) % 2147483647
    value = (value * 48271) % 2147483647
    return value / 2147483647
end

local function build_pattern(yutils, base_shape, clip_shape, config, salt)
    local ok_bounds, x0, y0, x1, y1 = pcall(yutils.shape.bounding, clip_shape)
    if not ok_bounds or not x0 then
        return nil, "无法计算文字遮罩范围。"
    end

    local ok_base_bounds, bx0, by0, bx1, by1 = pcall(yutils.shape.bounding, base_shape)
    if not ok_base_bounds or not bx0 then
        return nil, "无法计算基础图案范围。"
    end

    local step_x = config.size + config.gap_x
    local step_y = config.size + config.gap_y
    if step_x <= 0 or step_y <= 0 then
        return nil, "图案大小与间距相加后必须大于 0。"
    end

    -- 固定只在文字包围盒四周各外扩 20 像素的区域内生成图案。
    -- 每个图案还会经过边界检查，确保图案本身不会越过这 20 像素范围。
    local min_x = x0 - PATTERN_PADDING
    local max_x = x1 + PATTERN_PADDING
    local min_y = y0 - PATTERN_PADDING
    local max_y = y1 + PATTERN_PADDING

    local start_column = math.floor((min_x - config.offset_x - bx1) / step_x)
    local end_column = math.ceil((max_x - config.offset_x - bx0) / step_x)
    local start_row = math.floor((min_y - config.offset_y - by1) / step_y)
    local end_row = math.ceil((max_y - config.offset_y - by0) / step_y)

    local estimated = (end_column - start_column + 1) * (end_row - start_row + 1)
    if estimated > MAX_SHAPES then
        return nil, string.format(
            "预计检查 %d 个图案位置，超过安全上限 %d。请增大间距或缩小文字区域。",
            estimated,
            MAX_SHAPES
        )
    end

    local output = {}
    local count = 0
    local jitter_x = step_x * (config.jitter / 100) * 0.5
    local jitter_y = step_y * (config.jitter / 100) * 0.5

    for row = start_row, end_row do
        local row_shift = (config.stagger and (math.abs(row) % 2 == 1)) and step_x / 2 or 0
        for column = start_column, end_column do
            local x = config.offset_x + column * step_x + row_shift
            local y = config.offset_y + row * step_y

            if config.jitter > 0 then
                x = x + (deterministic_noise(row, column, salt) * 2 - 1) * jitter_x
                y = y + (deterministic_noise(column, row, salt + 17) * 2 - 1) * jitter_y
            end

            -- 以基础图案的真实包围盒做判断，最终绘图路径不会超过文字包围盒外 20 像素。
            if x + bx0 >= min_x and x + bx1 <= max_x
                and y + by0 >= min_y and y + by1 <= max_y then
                output[#output + 1] = yutils.shape.move(base_shape, x, y)
                count = count + 1
            end
        end
    end

    if count == 0 then
        return nil, "在固定外扩 20 像素的区域内没有可放置的图案。请减小图案或调整相位。"
    end

    return table.concat(output, " "), nil, count
end

local function create_text_clip(yutils, subtitles, meta, styles, source_line)
    local line = shallow_copy(source_line)
    karaskel.preproc_line(subtitles, meta, styles, line)

    local unsupported = contains_unsupported_tags(line.text)
    if unsupported then
        return nil, "包含暂不支持的 " .. unsupported
    end

    local plain_text = tostring(line.text_stripped or "")
    plain_text = plain_text:gsub("\\h", " ")
    if trim(plain_text) == "" then
        return nil, "文字为空"
    end

    local settings = parse_font_settings(line)
    if settings.size <= 0 or settings.scale_x <= 0 or settings.scale_y <= 0 then
        return nil, "字体大小或缩放值无效"
    end

    local ok_font, font_or_error = pcall(
        yutils.decode.create_font,
        settings.family,
        settings.bold,
        settings.italic,
        settings.underline,
        settings.strikeout,
        settings.size,
        settings.scale_x / 100,
        settings.scale_y / 100,
        settings.spacing
    )

    if not ok_font or not font_or_error then
        return nil, "无法创建字体：" .. tostring(font_or_error)
    end
    local font = font_or_error

    local ok_shape, text_shape = pcall(font.text_to_shape, plain_text)
    if not ok_shape or not text_shape or text_shape == "" then
        return nil, "文字转矢量失败：" .. tostring(text_shape)
    end

    local pos_x, pos_y = extract_last_pos(line.text)
    local left, top

    if not pos_x and not settings.has_alignment_override and not settings.has_metric_override then
        left = tonumber(line.left) or 0
        top = tonumber(line.top) or 0
    else
        local anchor_x, anchor_y
        if pos_x and pos_y then
            anchor_x, anchor_y = pos_x, pos_y
        elseif settings.has_alignment_override then
            anchor_x, anchor_y = margin_anchor(line, meta, settings.align)
        else
            anchor_x = tonumber(line.x) or 0
            anchor_y = tonumber(line.y) or 0
        end

        local width, height
        local ok_extents, extents = pcall(font.text_extents, plain_text)
        if ok_extents and type(extents) == "table" then
            width = tonumber(extents.width)
            height = tonumber(extents.height)
        end

        if not width or not height then
            local ok_bounds, sx0, sy0, sx1, sy1 = pcall(yutils.shape.bounding, text_shape)
            if not ok_bounds then
                return nil, "无法计算文字尺寸"
            end
            width = sx1 - sx0
            height = sy1 - sy0
        end

        local horizontal, vertical = alignment_factors(settings.align)
        left = anchor_x - width * horizontal
        top = anchor_y - height * vertical
    end

    local ok_move, clip_shape = pcall(yutils.shape.move, text_shape, left, top)
    if not ok_move or not clip_shape then
        return nil, "文字遮罩定位失败"
    end

    return clip_shape, nil
end

local function create_overlay(yutils, subtitles, meta, styles, source_line, config)
    local clip_shape, clip_error = create_text_clip(yutils, subtitles, meta, styles, source_line)
    if not clip_shape then
        return nil, clip_error
    end

    local base_shape, base_error = create_base_shape(yutils, config)
    if not base_shape then
        return nil, base_error
    end

    local id = fingerprint(source_line)
    local pattern_shape, pattern_error = build_pattern(yutils, base_shape, clip_shape, config, tonumber(id) or 1)
    if not pattern_shape then
        return nil, pattern_error
    end

    local overlay = shallow_copy(source_line)
    overlay.comment = false
    overlay.layer = (tonumber(source_line.layer) or 0) + 1
    set_generated_marker(overlay, OUTPUT_PREFIX .. id)
    local style = source_style(styles, source_line)
    local color = html_color_to_ass(config.color)
    local alpha = html_alpha_to_ass(config.alpha)
    local tags = {"\\pos(0,0)"}
    if not style or tonumber(style.align or style.alignment) ~= 7 then
        tags[#tags + 1] = "\\an7"
    end
    tags[#tags + 1] = "\\p1"
    if not style or differs(style.scale_x, 100) then tags[#tags + 1] = "\\fscx100" end
    if not style or differs(style.scale_y, 100) then tags[#tags + 1] = "\\fscy100" end
    if not style or differs(style.angle, 0) then tags[#tags + 1] = "\\frz0" end
    if not style or differs(style.outline, 0) then tags[#tags + 1] = "\\bord0" end
    if not style or differs(style.shadow, 0) then tags[#tags + 1] = "\\shad0" end
    if not style or style_color(style, "color1") ~= color then
        tags[#tags + 1] = "\\c" .. color
    end
    if not style or style_alpha(style, "color1") ~= alpha then
        tags[#tags + 1] = "\\1a" .. alpha
    end
    tags[#tags + 1] = "\\clip(" .. clip_shape .. ")"
    overlay.text = "{" .. table.concat(tags) .. "}" .. pattern_shape

    return overlay, nil
end

local function normalize_config(result)
    local config = {}
    for key, value in pairs(result) do config[key] = value end

    config.size = tonumber(config.size) or 7
    config.gap_x = tonumber(config.gap_x) or 8
    config.gap_y = tonumber(config.gap_y) or 8
    config.offset_x = tonumber(config.offset_x) or 0
    config.offset_y = tonumber(config.offset_y) or 0
    config.jitter = tonumber(config.jitter) or 0

    if config.size <= 0 then return nil, "图案大小必须大于 0。" end
    if config.gap_x < -config.size + 0.01 or config.gap_y < -config.size + 0.01 then
        return nil, "横向/纵向间距不能让中心步长变成 0 或负数。"
    end
    if config.jitter < 0 or config.jitter > 100 then
        return nil, "随机抖动必须在 0 到 100 之间。"
    end

    return config, nil
end

local function make_dialog(config)
    return {
        {class="label", label="【文字内部图案填充】\n在文字矢量范围内铺设图案，生成行位于源字幕正下方。", x=0, y=0, width=7, height=2},
        {class="label", label="基础外观", x=0, y=2, width=7, height=1},
        {class="label", label="图案类型", x=0, y=3, width=1, height=1},
        {class="dropdown", name="shape_type", items={"圆形", "方形", "菱形", "三角形", "五角星", "自定义绘图"}, value=config.shape_type, x=1, y=3, width=2, height=1},
        {class="label", label="颜色", x=3, y=3, width=1, height=1},
        {class="color", name="color", value=config.color, x=4, y=3, width=1, height=1},
        {class="label", label="透明度", x=5, y=3, width=1, height=1},
        {class="alpha", name="alpha", value=config.alpha, x=6, y=3, width=1, height=1},

        {class="label", label="排列参数", x=0, y=4, width=7, height=1},
        {class="label", label="图案大小", x=0, y=5, width=1, height=1},
        {class="floatedit", name="size", value=config.size, min=0.1, max=500, step=0.5, x=1, y=5, width=1, height=1},
        {class="label", label="横向间距", x=2, y=5, width=1, height=1},
        {class="floatedit", name="gap_x", value=config.gap_x, min=-499, max=1000, step=0.5, x=3, y=5, width=1, height=1},
        {class="label", label="纵向间距", x=4, y=5, width=1, height=1},
        {class="floatedit", name="gap_y", value=config.gap_y, min=-499, max=1000, step=0.5, x=5, y=5, width=1, height=1},
        {class="label", label="X 相位", x=0, y=6, width=1, height=1},
        {class="floatedit", name="offset_x", value=config.offset_x, min=-5000, max=5000, step=0.5, x=1, y=6, width=1, height=1},
        {class="label", label="Y 相位", x=2, y=6, width=1, height=1},
        {class="floatedit", name="offset_y", value=config.offset_y, min=-5000, max=5000, step=0.5, x=3, y=6, width=1, height=1},
        {class="label", label="随机抖动 %", x=4, y=6, width=1, height=1},
        {class="floatedit", name="jitter", value=config.jitter, min=0, max=100, step=1, x=5, y=6, width=1, height=1},
        {class="checkbox", name="stagger", label="错行排列", value=config.stagger, x=0, y=7, width=2, height=1},
        {class="checkbox", name="replace_same", label="替换同一源字幕的旧图案", value=config.replace_same, x=2, y=7, width=3, height=1},
        {class="label", label="铺设区域固定外扩 20 px", x=5, y=7, width=2, height=1},

        {class="label", label="自定义图形", x=0, y=8, width=7, height=1},
        {class="label", label="仅在选择“自定义绘图”时生效，可粘贴 m / l / b 等 ASS 绘图命令。", x=0, y=9, width=7, height=1},
        {class="textbox", name="custom_shape", text=config.custom_shape, x=0, y=10, width=7, height=4},
        {class="label", label="提示：应用成功后会立即提交字幕，并保留一个撤销点。", x=0, y=14, width=7, height=1}
    }
end

local function is_source_line(line)
    return line and line.class == "dialogue" and not line.comment
        and not effect_has_prefix(line, OLD_TEMP_PREFIX)
        and not effect_has_prefix(line, OUTPUT_PREFIX)
end

local function source_occurrence_at(subtitles, target_index, id)
    local occurrence = 0
    for index = 1, target_index do
        local line = subtitles[index]
        if is_source_line(line) and fingerprint(line) == id then
            occurrence = occurrence + 1
        end
    end
    return occurrence
end

local function selected_source_records(subtitles, selection)
    local records = {}
    for _, index in ipairs(selection or {}) do
        local line = subtitles[index]
        if is_source_line(line) then
            local id = fingerprint(line)
            records[#records + 1] = {
                line = shallow_copy(line),
                id = id,
                occurrence = source_occurrence_at(subtitles, index, id)
            }
        end
    end
    return records
end

local function find_source_index(subtitles, record)
    local occurrence = 0
    for index = 1, #subtitles do
        local line = subtitles[index]
        if is_source_line(line) and fingerprint(line) == record.id then
            occurrence = occurrence + 1
            if occurrence == record.occurrence then
                return index
            end
        end
    end
    return nil
end

local function current_source_selection(subtitles, records)
    local result = {}
    for _, record in ipairs(records) do
        local index = find_source_index(subtitles, record)
        if index then result[#result + 1] = index end
    end
    table.sort(result)
    return result
end

local function generate_pattern(subtitles, records, yutils, config)
    -- 只负责清理旧版脚本留下的临时行；本版本没有任何视频预览按钮或预览宏。
    clear_by_prefix(subtitles, OLD_TEMP_PREFIX)

    local ids = {}
    for _, record in ipairs(records) do
        ids[record.id] = true
    end
    if config.replace_same then
        remove_matching_outputs(subtitles, ids)
    end

    local meta, styles = karaskel.collect_head(subtitles, false)
    local generated = {}
    local skipped = {}

    for index, record in ipairs(records) do
        aegisub.progress.task("正在处理第 %d / %d 行", index, #records)
        aegisub.progress.set((index - 1) / #records * 100)
        if aegisub.progress.is_cancelled() then
            aegisub.cancel()
        end

        local overlay, err = create_overlay(yutils, subtitles, meta, styles, record.line, config)
        if overlay then
            local source_index = find_source_index(subtitles, record)
            if source_index then
                generated[#generated + 1] = {
                    source_index = source_index,
                    overlay = overlay
                }
            else
                skipped[#skipped + 1] = string.format("%d. 找不到原字幕行，未插入图案。", index)
            end
        else
            skipped[#skipped + 1] = string.format("%d. %s", index, tostring(err))
        end
    end

    -- 从下往上插入，避免前面的插入操作改变后面源字幕的索引。
    table.sort(generated, function(a, b)
        return a.source_index > b.source_index
    end)
    for _, item in ipairs(generated) do
        subtitles.insert(item.source_index + 1, item.overlay)
    end

    aegisub.progress.set(100)
    if #generated > 0 then
        aegisub.set_undo_point("文字内部图案填充")
    end

    if #generated == 0 then
        show_message("没有生成任何图案行。\n\n" .. table.concat(skipped, "\n"), "处理失败")
    elseif #skipped > 0 then
        show_message(
            string.format("已生成 %d 行，跳过 %d 行：\n\n%s", #generated, #skipped, table.concat(skipped, "\n")),
            "处理完成，但有跳过项"
        )
    end

    return #generated
end

local function apply_pattern(subtitles, selection, active_line)
    local yutils = get_yutils()
    local records = selected_source_records(subtitles, selection)
    if #records == 0 then
        show_message("请选择至少一条非注释、非脚本生成的对话行。", "没有可处理的字幕")
        aegisub.cancel()
    end

    local return_selection = current_source_selection(subtitles, records)
    local return_active = return_selection[1] or active_line

    while true do
        local button, result = aegisub.dialog.display(
            make_dialog(last_config),
            {"应用", "取消"},
            {ok="应用", cancel="取消"}
        )

        if not button or button == "取消" then
            return return_selection, return_active
        end

        local config, config_error = normalize_config(result)
        if not config then
            show_message(config_error, "参数错误")
        else
            last_config = config

            local custom_error = nil
            if config.shape_type == "自定义绘图" then
                local _
                _, custom_error = create_base_shape(yutils, config)
            end

            if custom_error then
                show_message(custom_error, "自定义绘图错误")
            else
                local generated_count = generate_pattern(subtitles, records, yutils, config)
                if generated_count > 0 then
                    return_selection = current_source_selection(subtitles, records)
                    return_active = return_selection[1] or return_active
                    return return_selection, return_active
                end
            end
        end
    end
end

local function validate_selection(subtitles, selection, active_line)
    return selection ~= nil and #selection > 0
end

aegisub.register_macro(
    "文字内部图案填充 v0.2.1/应用（立即写入）",
    "把图案铺在文字矢量遮罩内部；固定外扩 20 px，生成行紧跟源字幕；应用后立即提交并关闭窗口。",
    apply_pattern,
    validate_selection
)

]==]
    },
    {
        id = 'slanted_stripes',
        name = '倾斜文字条纹',
        description = '读取矩形 clip，为文字生成高一层的倾斜条纹。',
        source = [==[

script_name = "倾斜文字条纹"
script_description = "根据所选字幕行中的矩形 \\clip，生成高一层、无边框无阴影的倾斜条纹文字层。"
script_author = "OpenAI"
script_version = "1.0.0"

local OUTPUT_PREFIX = "SLANTED_STRIPES|"
local GENERATED_EXTRA_KEY = "_hcoo_aegtools_generated"
local MAX_STRIPES = 1200
local EPSILON = 0.000001

local last_config = {
    color = "#554CFF",
    angle = 45,
    gap = 10,
    width = 8,
    replace_existing = false
}

local function shallow_copy(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function copy_extra(extra)
    local target = {}
    for key, value in pairs(extra or {}) do
        target[key] = value
    end
    return target
end

local function generated_marker(line)
    if line and type(line.extra) == "table"
        and type(line.extra[GENERATED_EXTRA_KEY]) == "string" then
        return line.extra[GENERATED_EXTRA_KEY]
    end
    return line and type(line.effect) == "string" and line.effect or ""
end

local function set_generated_marker(line, marker)
    line.effect = ""
    line.extra = copy_extra(line.extra)
    line.extra[GENERATED_EXTRA_KEY] = marker
end

local function show_message(message, title)
    aegisub.dialog.display({
        {
            class = "label",
            label = (title and (title .. "\n\n") or "") .. tostring(message),
            x = 0,
            y = 0,
            width = 4,
            height = 2
        }
    }, {"确定"}, {ok = "确定"})
end

local function fmt_number(value)
    local rounded
    if value >= 0 then
        rounded = math.floor(value * 1000 + 0.5) / 1000
    else
        rounded = math.ceil(value * 1000 - 0.5) / 1000
    end

    if math.abs(rounded) < 0.0005 then
        rounded = 0
    end

    local text = string.format("%.3f", rounded)
    text = text:gsub("(%..-)0+$", "%1")
    text = text:gsub("%.$", "")
    return text
end

local function html_color_to_ass(value)
    local hex = tostring(value or "#FFFFFF"):gsub("#", "")
    if #hex ~= 6 or not hex:match("^%x%x%x%x%x%x$") then
        hex = "FFFFFF"
    end

    local rr = hex:sub(1, 2)
    local gg = hex:sub(3, 4)
    local bb = hex:sub(5, 6)
    return "&H" .. bb .. gg .. rr .. "&"
end

local function style_color(style, key)
    local hex = style and tostring(style[key] or ""):upper():match("&H(%x+)")
    if not hex then return nil end
    if #hex < 8 then hex = string.rep("0", 8 - #hex) .. hex end
    return "&H" .. hex:sub(-6) .. "&"
end

local function style_alpha(style, key)
    local hex = style and tostring(style[key] or ""):upper():match("&H(%x+)")
    if not hex then return nil end
    if #hex < 8 then return "&H00&" end
    return "&H" .. hex:sub(#hex - 7, #hex - 6) .. "&"
end

local function differs(value, expected)
    value = tonumber(value)
    return value == nil or math.abs(value - expected) > EPSILON
end

local function collect_styles(subtitles)
    local styles = {}
    for index = 1, #subtitles do
        local line = subtitles[index]
        if line and line.class == "style" and line.name then
            styles[line.name] = line
        end
    end
    return styles
end

local function effect_has_prefix(line)
    return line
        and line.class == "dialogue"
        and generated_marker(line):sub(1, #OUTPUT_PREFIX) == OUTPUT_PREFIX
end

local function extract_rect_clip(text)
    local pattern =
        "\\[cC][lL][iI][pP]%s*%(%s*" ..
        "([%+%-]-[%d%.]+)%s*,%s*" ..
        "([%+%-]-[%d%.]+)%s*,%s*" ..
        "([%+%-]-[%d%.]+)%s*,%s*" ..
        "([%+%-]-[%d%.]+)%s*%)"

    local start_pos, end_pos, x1, y1, x2, y2 = tostring(text or ""):find(pattern)
    if not start_pos then
        return nil, "没有找到矩形 \\clip(x1,y1,x2,y2)。"
    end

    x1, y1, x2, y2 = tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)
    if not x1 or not y1 or not x2 or not y2 then
        return nil, "矩形 \\clip 的坐标无法解析。"
    end

    local left = math.min(x1, x2)
    local right = math.max(x1, x2)
    local top = math.min(y1, y2)
    local bottom = math.max(y1, y2)

    if right - left < EPSILON or bottom - top < EPSILON then
        return nil, "矩形 \\clip 的宽度或高度为 0。"
    end

    return {
        left = left,
        top = top,
        right = right,
        bottom = bottom,
        raw = tostring(text):sub(start_pos, end_pos)
    }
end

local function contains_style_reset(text)
    for block in tostring(text or ""):gmatch("{([^}]*)}") do
        if block:find("\\[rR]") then
            return true
        end
    end
    return false
end

local function clean_override_block(block)
    block = block:gsub("\\[iI][cC][lL][iI][pP]%s*%b()", "")
    block = block:gsub("\\[cC][lL][iI][pP]%s*%b()", "")

    local numeric_tags = {
        "\\[bB][oO][rR][dD][%+%-]-[%d%.]+",
        "\\[xX][bB][oO][rR][dD][%+%-]-[%d%.]+",
        "\\[yY][bB][oO][rR][dD][%+%-]-[%d%.]+",
        "\\[sS][hH][aA][dD][%+%-]-[%d%.]+",
        "\\[xX][sS][hH][aA][dD][%+%-]-[%d%.]+",
        "\\[yY][sS][hH][aA][dD][%+%-]-[%d%.]+",
        "\\[bB][lL][uU][rR][%+%-]-[%d%.]+",
        "\\[bB][eE][%+%-]-[%d%.]+"
    }

    for _, pattern in ipairs(numeric_tags) do
        block = block:gsub(pattern, "")
    end

    block = block:gsub("\\1[cC]&[hH]%x+&", "")
    block = block:gsub("\\[cC]&[hH]%x+&", "")
    block = block:gsub("\\1[aA]&[hH]%x+&", "")
    block = block:gsub("\\[aA][lL][pP][hH][aA]&[hH]%x+&", "")

    -- Also remove parameter-less resets for these properties.
    local bare_tags = {
        "\\[bB][oO][rR][dD]",
        "\\[xX][bB][oO][rR][dD]",
        "\\[yY][bB][oO][rR][dD]",
        "\\[sS][hH][aA][dD]",
        "\\[xX][sS][hH][aA][dD]",
        "\\[yY][sS][hH][aA][dD]",
        "\\[bB][lL][uU][rR]",
        "\\[bB][eE]"
    }

    for _, pattern in ipairs(bare_tags) do
        block = block:gsub(pattern, "")
    end

    return block
end

local function sanitize_top_text(text)
    return (tostring(text or ""):gsub("{([^}]*)}", function(block)
        local cleaned = clean_override_block(block)
        if cleaned == "" then
            return ""
        end
        return "{" .. cleaned .. "}"
    end))
end

local function point_dot(point, nx, ny)
    return point.x * nx + point.y * ny
end

local function clip_polygon_halfplane(polygon, nx, ny, limit, keep_greater)
    if #polygon == 0 then
        return {}
    end

    local function is_inside(point)
        local value = point_dot(point, nx, ny)
        if keep_greater then
            return value >= limit - EPSILON
        end
        return value <= limit + EPSILON
    end

    local result = {}
    local previous = polygon[#polygon]
    local previous_inside = is_inside(previous)
    local previous_value = point_dot(previous, nx, ny)

    for _, current in ipairs(polygon) do
        local current_inside = is_inside(current)
        local current_value = point_dot(current, nx, ny)

        if current_inside ~= previous_inside then
            local denominator = current_value - previous_value
            if math.abs(denominator) > EPSILON then
                local t = (limit - previous_value) / denominator
                result[#result + 1] = {
                    x = previous.x + (current.x - previous.x) * t,
                    y = previous.y + (current.y - previous.y) * t
                }
            end
        end

        if current_inside then
            result[#result + 1] = {
                x = current.x,
                y = current.y
            }
        end

        previous = current
        previous_inside = current_inside
        previous_value = current_value
    end

    return result
end

local function polygon_area(polygon)
    local area = 0
    for index = 1, #polygon do
        local current = polygon[index]
        local following = polygon[index % #polygon + 1]
        area = area + current.x * following.y - following.x * current.y
    end
    return area / 2
end

local function polygon_to_path(polygon)
    if #polygon < 3 or math.abs(polygon_area(polygon)) < EPSILON then
        return nil
    end

    local parts = {
        "m",
        fmt_number(polygon[1].x),
        fmt_number(polygon[1].y),
        "l"
    }

    for index = 2, #polygon do
        parts[#parts + 1] = fmt_number(polygon[index].x)
        parts[#parts + 1] = fmt_number(polygon[index].y)
    end

    -- Repeat the first point so every contour is explicitly closed.
    parts[#parts + 1] = fmt_number(polygon[1].x)
    parts[#parts + 1] = fmt_number(polygon[1].y)

    return table.concat(parts, " ")
end

local function build_stripe_clip(rect, angle, stripe_width, gap)
    local radians = math.rad(angle)

    -- Positive angles rise toward the right on screen:
    -- 0 degrees = horizontal, 45 degrees = /, 90 degrees = vertical.
    local direction_x = math.cos(radians)
    local direction_y = -math.sin(radians)
    local normal_x = -direction_y
    local normal_y = direction_x

    local rectangle = {
        {x = rect.left, y = rect.top},
        {x = rect.right, y = rect.top},
        {x = rect.right, y = rect.bottom},
        {x = rect.left, y = rect.bottom}
    }

    local minimum = point_dot(rectangle[1], normal_x, normal_y)
    local maximum = minimum

    for index = 2, #rectangle do
        local value = point_dot(rectangle[index], normal_x, normal_y)
        minimum = math.min(minimum, value)
        maximum = math.max(maximum, value)
    end

    local span = maximum - minimum
    local pitch = stripe_width + gap
    local stripe_count = math.floor((span + gap) / pitch)

    if stripe_count < 1 then
        stripe_count = 1
    end

    if stripe_count > MAX_STRIPES then
        return nil, string.format(
            "需要生成 %d 条条纹，超过安全上限 %d。请增大条纹宽度或间距。",
            stripe_count,
            MAX_STRIPES
        )
    end

    local total_width = stripe_count * stripe_width + (stripe_count - 1) * gap
    local start = minimum + (span - total_width) / 2
    local paths = {}

    for index = 0, stripe_count - 1 do
        local lower = start + index * pitch
        local upper = lower + stripe_width

        local polygon = rectangle
        polygon = clip_polygon_halfplane(polygon, normal_x, normal_y, lower, true)
        polygon = clip_polygon_halfplane(polygon, normal_x, normal_y, upper, false)

        local path = polygon_to_path(polygon)
        if path then
            paths[#paths + 1] = path
        end
    end

    if #paths == 0 then
        return nil, "没有生成有效的条纹路径。"
    end

    local drawing = table.concat(paths, " ")
    if #drawing > 250000 then
        return nil, "生成的矢量遮罩过长。请增大条纹宽度或间距。"
    end

    return drawing
end

local function make_dialog(config)
    return {
        {
            class = "label",
            label = "【倾斜文字条纹】\n读取源行的矩形 \\clip，生成高一层的倾斜条纹。",
            x = 0,
            y = 0,
            width = 4,
            height = 2
        },
        {
            class = "label",
            label = "外观与排列",
            x = 0,
            y = 2,
            width = 4,
            height = 1
        },
        {
            class = "label",
            label = "顶层颜色",
            x = 0,
            y = 3,
            width = 2,
            height = 1
        },
        {
            class = "color",
            name = "color",
            value = config.color,
            x = 2,
            y = 3,
            width = 2,
            height = 1
        },
        {
            class = "label",
            label = "遮罩倾斜角度",
            x = 0,
            y = 4,
            width = 2,
            height = 1
        },
        {
            class = "floatedit",
            name = "angle",
            value = config.angle,
            min = -180,
            max = 180,
            step = 1,
            x = 2,
            y = 4,
            width = 2,
            height = 1
        },
        {
            class = "label",
            label = "条纹间距",
            x = 0,
            y = 5,
            width = 2,
            height = 1
        },
        {
            class = "floatedit",
            name = "gap",
            value = config.gap,
            min = 0,
            max = 1000,
            step = 0.5,
            x = 2,
            y = 5,
            width = 2,
            height = 1
        },
        {
            class = "label",
            label = "条纹宽度",
            x = 0,
            y = 6,
            width = 2,
            height = 1
        },
        {
            class = "floatedit",
            name = "width",
            value = config.width,
            min = 0.1,
            max = 1000,
            step = 0.5,
            x = 2,
            y = 6,
            width = 2,
            height = 1
        },
        {
            class = "checkbox",
            name = "replace_existing",
            label = "替换源行正下方由本脚本生成的旧条纹行",
            value = config.replace_existing,
            x = 0,
            y = 7,
            width = 4,
            height = 1
        },
        {
            class = "label",
            label = "提示：0° 为水平，45° 为向右上倾斜（/），90° 为垂直。\n“条纹间距”是两条彩色条纹之间的透明空隙。",
            x = 0,
            y = 8,
            width = 4,
            height = 2
        }
    }
end

local function normalize_config(result)
    local config = {
        color = tostring(result.color or last_config.color),
        angle = tonumber(result.angle),
        gap = tonumber(result.gap),
        width = tonumber(result.width),
        replace_existing = result.replace_existing == true
    }

    if not config.angle then
        return nil, "遮罩倾斜角度必须是数字。"
    end
    if not config.gap or config.gap < 0 then
        return nil, "条纹间距必须是大于或等于 0 的数字。"
    end
    if not config.width or config.width <= 0 then
        return nil, "条纹宽度必须大于 0。"
    end
    if config.width + config.gap <= 0 then
        return nil, "条纹宽度与间距的合计必须大于 0。"
    end

    return config
end

local function make_overlay_line(source, style, drawing, config, effect_value)
    local overlay = shallow_copy(source)
    overlay.layer = (tonumber(source.layer) or 0) + 1
    overlay.comment = false
    set_generated_marker(overlay, effect_value)

    local color = html_color_to_ass(config.color)
    local tags = {"\\clip(" .. drawing .. ")"}
    if not style or style_color(style, "color1") ~= color then
        tags[#tags + 1] = "\\c" .. color
    end
    if not style or style_alpha(style, "color1") ~= "&H00&" then
        tags[#tags + 1] = "\\1a&H00&"
    end
    if not style or differs(style.outline, 0) then tags[#tags + 1] = "\\bord0" end
    if not style or differs(style.shadow, 0) then tags[#tags + 1] = "\\shad0" end
    local prefix = "{" .. table.concat(tags) .. "}"

    overlay.text = prefix .. sanitize_top_text(source.text)
    return overlay
end

local function sorted_selection(selection)
    local result = {}
    for _, index in ipairs(selection or {}) do
        result[#result + 1] = index
    end
    table.sort(result)
    return result
end

local function apply_stripes(subtitles, selection, active_line)
    if not selection or #selection == 0 then
        show_message("请先选择至少一条带矩形 \\clip 的字幕行。", "没有选择字幕")
        aegisub.cancel()
    end

    local button, result = aegisub.dialog.display(
        make_dialog(last_config),
        {"应用", "取消"},
        {ok = "应用", cancel = "取消"}
    )

    if not button or button == "取消" then
        aegisub.cancel()
    end

    local config, config_error = normalize_config(result)
    if not config then
        show_message(config_error, "参数错误")
        aegisub.cancel()
    end
    last_config = config

    local indexes = sorted_selection(selection)
    local styles = collect_styles(subtitles)
    local run_id = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local effect_value = OUTPUT_PREFIX .. run_id
    local generated_count = 0
    local skipped = {}

    -- Work from bottom to top so inserts never invalidate unprocessed indexes.
    for selection_index = #indexes, 1, -1 do
        local line_index = indexes[selection_index]
        local source = subtitles[line_index]

        if not source or source.class ~= "dialogue" then
            skipped[#skipped + 1] = string.format("第 %d 行：不是对话行。", line_index)
        elseif source.comment then
            skipped[#skipped + 1] = string.format("第 %d 行：注释行不会处理。", line_index)
        elseif effect_has_prefix(source) then
            skipped[#skipped + 1] = string.format("第 %d 行：这是脚本已经生成的条纹行。", line_index)
        elseif contains_style_reset(source.text) then
            skipped[#skipped + 1] = string.format("第 %d 行：包含 \\\\r 样式重置，无法保证顶层颜色与无边框状态。", line_index)
        else
            local rect, rect_error = extract_rect_clip(source.text)
            if not rect then
                skipped[#skipped + 1] = string.format("第 %d 行：%s", line_index, rect_error)
            else
                local drawing, drawing_error = build_stripe_clip(
                    rect,
                    config.angle,
                    config.width,
                    config.gap
                )

                if not drawing then
                    skipped[#skipped + 1] = string.format("第 %d 行：%s", line_index, drawing_error)
                else
                    local style = type(source.styleref) == "table"
                        and source.styleref or styles[source.style]
                    local overlay = make_overlay_line(source, style, drawing, config, effect_value)

                    if config.replace_existing then
                        while line_index + 1 <= #subtitles and effect_has_prefix(subtitles[line_index + 1]) do
                            subtitles.delete(line_index + 1)
                        end
                    end

                    -- subtitles.insert inserts before the supplied index.
                    -- Inserting before line_index + 1 therefore places it directly below the source.
                    subtitles.insert(line_index + 1, overlay)
                    generated_count = generated_count + 1
                end
            end
        end
    end

    if generated_count == 0 then
        show_message(
            "没有生成任何条纹行。\n\n" .. table.concat(skipped, "\n"),
            "处理失败"
        )
        aegisub.cancel()
    end

    aegisub.set_undo_point("生成倾斜文字条纹")

    if #skipped > 0 then
        show_message(
            string.format(
                "已生成 %d 行，另有 %d 行被跳过：\n\n%s",
                generated_count,
                #skipped,
                table.concat(skipped, "\n")
            ),
            "处理完成"
        )
    end

    local generated_selection = {}
    for index = 1, #subtitles do
        local line = subtitles[index]
        if line and line.class == "dialogue" and generated_marker(line) == effect_value then
            generated_selection[#generated_selection + 1] = index
        end
    end

    return generated_selection, generated_selection[1] or active_line
end

local function validate_selection(subtitles, selection, active_line)
    return selection ~= nil and #selection > 0
end

aegisub.register_macro(
    "倾斜文字条纹/根据矩形 clip 生成条纹层",
    "读取所选行的矩形 clip，生成高一层、无边框无阴影的倾斜条纹文字。",
    apply_stripes,
    validate_selection
)

]==]
    },
    {
        id = 'add_margin',
        name = '标点自动边距',
        description = '给行尾感叹号或问号自动调整左右边距。',
        source = [==[
script_name = "Add Margin"
script_description = "Add margin when the line ends with exclamation mark or question mark"
script_author = "baizhanji"
script_version = "0.3"

re = require 'aegisub.re'

local function get_delta()
    local config = {
        {class="label", label="【标点自动边距】\n根据行尾全角叹号或问号，调整所选字幕的左右边距。", x=0, y=0, width=4, height=2},
        {class="label", label="参数设置", x=0, y=2, width=4, height=1},
        {class="label", label="叹号增量（px）", x=0, y=3, width=2, height=1},
        {class="intedit", name="delta_excl", value=15, min=0, max=100000, x=2, y=3, width=2, height=1},
        {class="label", label="问号增量（px）", x=0, y=4, width=2, height=1},
        {class="intedit", name="delta_ques", value=15, min=0, max=100000, x=2, y=4, width=2, height=1},
        {class="label", label="提示：数值为 0 时不改变对应标点的边距。", x=0, y=5, width=4, height=1}
    }
    local button, tbl = aegisub.dialog.display(
        config,
        {"应用", "取消"},
        {ok="应用", cancel="取消"}
    )
    if button ~= "应用" then return nil end
    local delta_excl = tonumber(tbl.delta_excl)
    local delta_ques = tonumber(tbl.delta_ques)
    if not delta_excl or not delta_ques or delta_excl < 0 or delta_ques < 0 then
        aegisub.dialog.display({
            {class="label", label="边距增量必须是大于或等于 0 的数字。", x=0, y=0, width=4, height=1}
        }, {"确定"}, {ok="确定"})
        return nil
    end
    return delta_excl, delta_ques
end

local function add_margin(subtitles, selected_lines, active_line)
    local delta_excl, delta_ques = get_delta()
    if delta_excl == nil or delta_ques == nil then return end

    for _, i in ipairs(selected_lines) do
        local l = subtitles[i]
        local clean_text = re.sub(l.text, "\\{[^}]*\\}", "")
        if re.match(clean_text, '！\\s*$') then
            local mr = l.margin_r or 0
            local ml = l.margin_l or 0
            if mr ~= 0 then
                l.margin_r = math.max(0, mr - delta_excl)
            else
                l.margin_l = ml + delta_excl
            end
            subtitles[i] = l
        elseif re.match(clean_text, '？\\s*$') then
            local mr = l.margin_r or 0
            local ml = l.margin_l or 0
            if mr ~= 0 then
                l.margin_r = math.max(0, mr - delta_ques)
            else
                l.margin_l = ml + delta_ques
            end
            subtitles[i] = l
        end
    end
    aegisub.set_undo_point("Add Margin")
end

aegisub.register_macro(
    "Add Margin - 自动添加边距",
    "给行尾为感叹号或问号的字幕添加边距以和日字对齐",
    add_margin
)
]==]
    },
    {
        id = 'typewriter',
        name = '逐字逐音节出现',
        description = '按固定时间间隔让字符逐个显现。',
        source = [==[
script_name = "逐字逐音节出现"
script_description = "让选中行的字幕按指定的固定时间间隔，逐个字符/汉字显现（打字机效果）"
script_author = "AI Collaborator"
script_version = "1.0"

function type_writer_effect(subtitles, selected_rows, active_line)
    if not selected_rows or #selected_rows == 0 then
        aegisub.dialog.display({
            {class="label", label="请先选择至少一条字幕。", x=0, y=0, width=4, height=1}
        }, {"确定"}, {ok="确定"})
        aegisub.cancel()
    end

    -- 1. 弹出对话框获取用户配置
    local dialog_config = {
        {class="label", label="【逐字逐音节出现】\n为所选字幕生成按字符依次显现的打字机效果。", x=0, y=0, width=4, height=2},
        {class="label", label="时间设置", x=0, y=2, width=4, height=1},
        {class="label", label="字符间隔（ms）", x=0, y=3, width=2, height=1},
        {class="intedit", name="delay", value=150, min=0, max=600000, x=2, y=3, width=2, height=1},
        {class="label", label="单字淡入（ms）", x=0, y=4, width=2, height=1},
        {class="intedit", name="fade", value=0, min=0, max=600000, x=2, y=4, width=2, height=1},
        {class="label", label="提示：淡入时间为 0 时，字符会瞬间出现。", x=0, y=5, width=4, height=1}
    }
    local buttons = {"应用", "取消"}
    local pressed, result = aegisub.dialog.display(dialog_config, buttons, {ok="应用", cancel="取消"})
    
    if pressed ~= "应用" then
        aegisub.cancel()
    end
    
    local delay = tonumber(result.delay)
    local fade = tonumber(result.fade)
    if not delay or not fade or delay < 0 or fade < 0 then
        aegisub.dialog.display({
            {class="label", label="字符间隔和淡入时间必须是大于或等于 0 的数字。", x=0, y=0, width=4, height=1}
        }, {"确定"}, {ok="确定"})
        aegisub.cancel()
    end

    -- 2. 遍历所有选中的行
    for _, line_index in ipairs(selected_rows) do
        local line = subtitles[line_index]
        
        -- 仅处理非注释的对话行
        if line.class == "dialogue" and not line.comment then
            -- 2.1 提取行首可能存在的样式标签（如 \pos, \fn, \fs 等），确保排版不丢失
            local lead_tags, raw_text = line.text:match("^({[^}]*})(.*)$")
            if not lead_tags then
                lead_tags = ""
                raw_text = line.text
            end
            
            -- 2.2 清理文本中间可能残留的其他 K 轴或特殊标签，防止冲突
            raw_text = raw_text:gsub("{[^}]*}", "")
            
            local new_text = ""
            local idx = 0
            
            -- 2.3 使用正则表达式安全地遍历 UTF-8 字符（汉字、英文、符号、表情均适用）
            for c in raw_text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                local start_t = idx * delay
                local end_t = start_t + fade
                
                -- 生成核心特效标签：
                -- \alpha&HFF& 让字初始完全透明
                -- \t(开始时间, 结束时间, \alpha&H00&) 在指定时间段内变为完全不透明
                new_text = new_text .. string.format("{\\alpha&HFF&\\t(%d,%d,\\alpha&H00&)}%s", start_t, end_t, c)
                idx = idx + 1
            end
            
            -- 3. 重新拼接并写回字幕
            line.text = lead_tags .. new_text
            subtitles[line_index] = line
        end
    end
    
    -- 创建撤销点
    aegisub.set_undo_point(script_name)
end

-- 注册到 Aegisub 自动化菜单
aegisub.register_macro(script_name, script_description, type_writer_effect)
]==]
    },
    {
        id = 'delete_out_of_bounds',
        name = '删除选中越界字幕',
        description = '删除所选行中 pos 或 move 坐标越出画面的字幕。',
        source = [==[
script_name = "删除选中越界字幕"
script_description = "仅遍历选中的行，删除绝对坐标（\\pos 或 \\move）超出画面指定距离的行"
script_author = "AI Collaborator"
script_version = "1.1"

function delete_selected_out_of_bounds(subtitles, selected_rows, active_line)
    -- 1. 获取视频脚本的基准分辨率 (PlayResX, PlayResY)
    local res_x = 1920
    local res_y = 1080
    for i = 1, #subtitles do
        local line = subtitles[i]
        if line.class == "info" then
            if line.key == "PlayResX" then res_x = tonumber(line.value) or 1920 end
            if line.key == "PlayResY" then res_y = tonumber(line.value) or 1080 end
        end
    end

    -- 2. 弹出对话框获取用户输入的阈值
    local dialog_config = {
        {class="label", label="【删除选中越界字幕】\n检查所选行的 \\pos 或 \\move 坐标，删除超出允许范围的字幕。", x=0, y=0, width=4, height=2},
        {class="label", label=string.format("当前脚本分辨率：%d × %d", res_x, res_y), x=0, y=2, width=4, height=1},
        {class="label", label="越界容差（px）", x=0, y=3, width=2, height=1},
        {class="intedit", name="threshold", value=100, min=0, max=1000000, x=2, y=3, width=2, height=1},
        {class="label", label="提示：容差为 0 时，坐标只要离开画面边界就会被判定为越界。", x=0, y=4, width=4, height=1}
    }
    local buttons = {"删除", "取消"}
    local pressed, result = aegisub.dialog.display(dialog_config, buttons, {ok="删除", cancel="取消"})
    
    if pressed ~= "删除" then
        aegisub.cancel()
    end
    
    local threshold = tonumber(result.threshold)
    if not threshold or threshold < 0 then
        aegisub.dialog.display({
            {class="label", label="越界容差必须是大于或等于 0 的数字。", x=0, y=0, width=4, height=1}
        }, {"确定"}, {ok="确定"})
        aegisub.cancel()
    end

    -- 辅助判断函数：检查单组坐标是否越界
    local function check_bounds(x, y)
        return x < -threshold or x > (res_x + threshold) or y < -threshold or y > (res_y + threshold)
    end

    -- 3. 倒序遍历“选中的行”
    local delete_count = 0
    for i = #selected_rows, 1, -1 do
        local line_index = selected_rows[i]
        local line = subtitles[line_index]
        
        -- 仅处理非注释的对话行
        if line.class == "dialogue" and not line.comment then
            local text = line.text
            local should_delete = false

            -- 3.1 匹配 \pos(x,y)
            local px, py = text:match("\\pos%s*%(%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*%)")
            if px and py then
                if check_bounds(tonumber(px), tonumber(py)) then
                    should_delete = true
                end
            else
                -- 3.2 如果没有 \pos，则尝试匹配 \move(x1,y1,x2,y2)
                local mx1, my1, mx2, my2 = text:match("\\move%s*%(%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)")
                if mx1 and my1 and mx2 and my2 then
                    -- 只有当移动的起点和终点都越界时，才判定为需要删除
                    if check_bounds(tonumber(mx1), tonumber(my1)) and check_bounds(tonumber(mx2), tonumber(my2)) then
                        should_delete = true
                    end
                end
            end

            -- 执行删除
            if should_delete then
                subtitles.delete(line_index)
                delete_count = delete_count + 1
            end
        end
    end

    -- 创建撤销点并提示结果
    aegisub.set_undo_point(script_name)
    aegisub.debug.out(string.format("处理完毕！在选中的行中，共删除了 %d 行越界字幕。", delete_count))
end

-- 注册到 Aegisub 自动化菜单
aegisub.register_macro(script_name, script_description, delete_selected_out_of_bounds)
]==]
    },
    {
        id = 'quick_rectangle_frame',
        name = '快速添加矩形图框',
        description = '按绝对坐标、文字边界或矩形 clip 快速创建 ASS 矩形图框。',
        source = [==[

script_name = "快速添加矩形图框"
script_description = "按绝对坐标、文字边界或矩形 \\clip 快速创建 ASS 矩形图框。"
script_author = "OpenAI"
script_version = "1.1.1"

include("karaskel.lua")

local MODE_DIRECT = "direct"
local MODE_TEXT = "text"
local MODE_CLIP = "clip"
local OUTPUT_PREFIX = "QUICK_RECT_FRAME|"
local GENERATED_EXTRA_KEY = "_hcoo_aegtools_generated"
local EPSILON = 0.000001
local KAPPA = 0.5522847498

local Yutils = nil
local GeometryModules = nil

local function require_module(name)
    local ok, module_or_error = pcall(require, name)
    if not ok or type(module_or_error) ~= "table" then
        return nil, string.format("无法加载 %s：%s", name, tostring(module_or_error))
    end
    return module_or_error
end

local function get_geometry_modules()
    if GeometryModules then return GeometryModules end

    local modules = {}
    local error_message

    modules.yutils, error_message = require_module("Yutils")
    if not modules.yutils then return nil, error_message end
    modules.ass, error_message = require_module("l0.ASSFoundation")
    if not modules.ass then return nil, error_message end
    modules.assf_plus, error_message = require_module("phos.AssfPlus")
    if not modules.assf_plus then return nil, error_message end
    modules.perspective, error_message = require_module("arch.Perspective")
    if not modules.perspective then return nil, error_message end
    modules.arch_util, error_message = require_module("arch.Util")
    if not modules.arch_util then return nil, error_message end
    modules.line_collection, error_message = require_module("a-mo.LineCollection")
    if not modules.line_collection then return nil, error_message end

    if type(modules.ass.parse) ~= "function"
        or type(modules.assf_plus.lineData) ~= "table"
        or type(modules.assf_plus.lineData.getTextShape) ~= "function"
        or type(modules.perspective.transformPoints) ~= "function"
        or type(modules.arch_util.line2fbf) ~= "function" then
        return nil, "文字几何依赖版本不完整，请检查 ASSFoundation、AssfPlus、arch.Perspective 和 arch.Util。"
    end

    Yutils = modules.yutils
    GeometryModules = modules
    return GeometryModules
end

local common_defaults = {
    fill_color = "#000000",
    fill_alpha = "#00",
    use_fill_alpha = false,
    border_size = 0,
    use_border_size = false,
    border_color = "#000000",
    border_alpha = "#00",
    use_border_alpha = false,
    shadow_size = 0,
    use_shadow_size = false,
    shadow_color = "#000000",
    shadow_alpha = "#00",
    use_shadow_alpha = false,
    blur = 0,
    use_blur = false,
    radius = 0,
    use_radius = false
}

local function copy_table(source)
    local target = {}
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

local function generated_marker(line)
    if line and type(line.extra) == "table"
        and type(line.extra[GENERATED_EXTRA_KEY]) == "string" then
        return line.extra[GENERATED_EXTRA_KEY]
    end
    return line and type(line.effect) == "string" and line.effect or ""
end

local function set_generated_marker(line, marker)
    line.effect = ""
    line.extra = copy_table(line.extra)
    line.extra[GENERATED_EXTRA_KEY] = marker
end

local function make_defaults(extra)
    local result = copy_table(common_defaults)
    for key, value in pairs(extra or {}) do
        result[key] = value
    end
    return result
end

local last_configs = {
    [MODE_DIRECT] = make_defaults({
        x = 0,
        use_x = false,
        y = 0,
        use_y = false,
        width = 100,
        use_width = false,
        height = 100,
        use_height = false
    }),
    [MODE_TEXT] = make_defaults({
        padding_x = 20,
        use_padding_x = false,
        padding_y = 10,
        use_padding_y = false
    }),
    [MODE_CLIP] = make_defaults()
}

local function show_message(message, title)
    aegisub.dialog.display({
        {
            class = "label",
            label = (title and (title .. "\n\n") or "") .. tostring(message),
            x = 0,
            y = 0,
            width = 5,
            height = 1
        }
    }, {"确定"}, {ok = "确定"})
end

local function fmt_number(value)
    local number = tonumber(value) or 0
    local rounded
    if number >= 0 then
        rounded = math.floor(number * 1000 + 0.5) / 1000
    else
        rounded = math.ceil(number * 1000 - 0.5) / 1000
    end
    if math.abs(rounded) < 0.0005 then rounded = 0 end
    local text = string.format("%.3f", rounded):gsub(",", ".")
    return text:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
end

local function html_color_to_ass(value)
    local hex = tostring(value or "#000000"):gsub("#", "")
    if #hex ~= 6 then hex = "000000" end
    return "&H" .. hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2) .. "&"
end

local function html_alpha_to_ass(value)
    local hex = tostring(value or "#00"):gsub("#", "")
    if #hex ~= 2 then hex = "00" end
    return "&H" .. hex .. "&"
end

local function style_color(style, key)
    local hex = style and tostring(style[key] or ""):upper():match("&H(%x+)")
    if not hex then return nil end
    if #hex < 8 then hex = string.rep("0", 8 - #hex) .. hex end
    return "&H" .. hex:sub(-6) .. "&"
end

local function style_alpha(style, key)
    local hex = style and tostring(style[key] or ""):upper():match("&H(%x+)")
    if not hex then return nil end
    if #hex < 8 then return "&H00&" end
    return "&H" .. hex:sub(#hex - 7, #hex - 6) .. "&"
end

local function differs(value, expected)
    value = tonumber(value)
    return value == nil or math.abs(value - expected) > EPSILON
end

local function collect_styles(subtitles)
    local styles = {}
    for index = 1, #subtitles do
        local line = subtitles[index]
        if line and line.class == "style" and line.name then
            styles[line.name] = line
        end
    end
    return styles
end

local function add_number(dialog, row, name, label, config, minimum, maximum, step)
    dialog[#dialog + 1] = {
        class = "checkbox",
        name = "use_" .. name,
        label = "",
        value = config["use_" .. name] == true,
        x = 0,
        y = row,
        width = 1,
        height = 1
    }
    dialog[#dialog + 1] = {
        class = "label",
        label = label,
        x = 1,
        y = row,
        width = 1,
        height = 1
    }
    dialog[#dialog + 1] = {
        class = "floatedit",
        name = name,
        value = config[name],
        min = minimum,
        max = maximum,
        step = step,
        x = 2,
        y = row,
        width = 2,
        height = 1
    }
end

local function add_color(dialog, row, name, label, config)
    dialog[#dialog + 1] = {
        class = "label",
        label = label,
        x = 1,
        y = row,
        width = 1,
        height = 1
    }
    dialog[#dialog + 1] = {
        class = "color",
        name = name,
        value = config[name],
        x = 2,
        y = row,
        width = 2,
        height = 1
    }
end

local function add_alpha(dialog, row, name, label, config)
    dialog[#dialog + 1] = {
        class = "checkbox",
        name = "use_" .. name,
        label = "",
        value = config["use_" .. name] == true,
        x = 0,
        y = row,
        width = 1,
        height = 1
    }
    dialog[#dialog + 1] = {
        class = "label",
        label = label,
        x = 1,
        y = row,
        width = 1,
        height = 1
    }
    dialog[#dialog + 1] = {
        class = "alpha",
        name = name,
        value = config[name],
        x = 2,
        y = row,
        width = 2,
        height = 1
    }
end

local function mode_title(mode)
    if mode == MODE_DIRECT then return "直接添加矩形图框" end
    if mode == MODE_TEXT then return "根据文字添加矩形图框" end
    return "根据 \\clip 创建矩形图框"
end

local function make_dialog(mode, config)
    local dialog = {
        {
            class = "label",
            label = "【" .. mode_title(mode) .. "】\n数值左侧的复选框用于启用对应参数；未勾选时会使用默认值。",
            x = 0,
            y = 0,
            width = 5,
            height = 2
        },
        {
            class = "label",
            label = mode == MODE_DIRECT and "尺寸与位置" or mode == MODE_TEXT and "文字外扩" or "尺寸来源",
            x = 0,
            y = 2,
            width = 5,
            height = 1
        }
    }
    local row = 3

    if mode == MODE_DIRECT then
        add_number(dialog, row, "x", "X边界", config, 0, 100000, 1)
        row = row + 1
        add_number(dialog, row, "y", "Y边界", config, 0, 100000, 1)
        row = row + 1
        add_number(dialog, row, "width", "X长度", config, 0.001, 100000, 1)
        row = row + 1
        add_number(dialog, row, "height", "Y长度", config, 0.001, 100000, 1)
        row = row + 1
    elseif mode == MODE_TEXT then
        add_number(dialog, row, "padding_x", "X边界", config, 0, 100000, 1)
        row = row + 1
        add_number(dialog, row, "padding_y", "Y边界", config, 0, 100000, 1)
        row = row + 1
    end

    dialog[#dialog + 1] = {
        class = "label",
        label = "填充外观",
        x = 0,
        y = row,
        width = 5,
        height = 1
    }
    row = row + 1
    add_color(dialog, row, "fill_color", "图框颜色", config)
    row = row + 1
    add_alpha(dialog, row, "fill_alpha", "图框透明度", config)
    row = row + 1

    dialog[#dialog + 1] = {
        class = "label",
        label = "边框外观",
        x = 0,
        y = row,
        width = 5,
        height = 1
    }
    row = row + 1
    add_number(dialog, row, "border_size", "边框大小", config, 0, 10000, 0.1)
    row = row + 1
    add_color(dialog, row, "border_color", "边框颜色", config)
    row = row + 1
    add_alpha(dialog, row, "border_alpha", "边框透明度", config)
    row = row + 1

    dialog[#dialog + 1] = {
        class = "label",
        label = "阴影外观",
        x = 0,
        y = row,
        width = 5,
        height = 1
    }
    row = row + 1
    add_number(dialog, row, "shadow_size", "阴影大小", config, 0, 10000, 0.1)
    row = row + 1
    add_color(dialog, row, "shadow_color", "阴影颜色", config)
    row = row + 1
    add_alpha(dialog, row, "shadow_alpha", "阴影透明度", config)
    row = row + 1

    dialog[#dialog + 1] = {
        class = "label",
        label = "轮廓细节",
        x = 0,
        y = row,
        width = 5,
        height = 1
    }
    row = row + 1
    add_number(dialog, row, "blur", "高斯模糊 blur", config, 0, 1000, 0.1)
    row = row + 1
    add_number(dialog, row, "radius", "图框圆角", config, 0, 100000, 1)
    row = row + 1

    local note
    if mode == MODE_DIRECT then
        note = "未启用 X/Y 边界时按 0；未启用 X/Y 长度时按 100。"
    elseif mode == MODE_TEXT then
        note = "X/Y 边界表示整体文字包围盒向左右/上下的外扩距离；支持大写 \\N 多行、旋转、透视和动态标签，测量时忽略 clip/iclip。"
    else
        note = "仅识别矩形 \\clip(x1,y1,x2,y2)，不处理矢量 clip 或 iclip。"
    end

    dialog[#dialog + 1] = {
        class = "label",
        label = note,
        x = 0,
        y = row,
        width = 5,
        height = 2
    }
    return dialog
end

local common_number_names = {
    "border_size",
    "shadow_size",
    "blur",
    "radius"
}

local common_enabled_names = {
    "fill_alpha",
    "border_size",
    "border_alpha",
    "shadow_size",
    "shadow_alpha",
    "blur",
    "radius"
}

local function normalize_config(mode, result)
    local previous = last_configs[mode]
    local config = copy_table(previous)

    config.fill_color = tostring(result.fill_color or previous.fill_color)
    config.fill_alpha = tostring(result.fill_alpha or previous.fill_alpha)
    config.border_color = tostring(result.border_color or previous.border_color)
    config.border_alpha = tostring(result.border_alpha or previous.border_alpha)
    config.shadow_color = tostring(result.shadow_color or previous.shadow_color)
    config.shadow_alpha = tostring(result.shadow_alpha or previous.shadow_alpha)

    for _, name in ipairs(common_number_names) do
        config[name] = tonumber(result[name]) or tonumber(previous[name]) or 0
    end
    for _, name in ipairs(common_enabled_names) do
        config["use_" .. name] = result["use_" .. name] == true
    end

    if mode == MODE_DIRECT then
        for _, name in ipairs({"x", "y", "width", "height"}) do
            config[name] = tonumber(result[name]) or tonumber(previous[name]) or 0
            config["use_" .. name] = result["use_" .. name] == true
        end
    elseif mode == MODE_TEXT then
        for _, name in ipairs({"padding_x", "padding_y"}) do
            config[name] = tonumber(result[name]) or tonumber(previous[name]) or 0
            config["use_" .. name] = result["use_" .. name] == true
        end
    end

    if config.use_border_size and config.border_size < 0 then
        return nil, "边框大小不能小于 0。"
    end
    if config.use_shadow_size and config.shadow_size < 0 then
        return nil, "阴影大小不能小于 0。"
    end
    if config.use_blur and config.blur < 0 then
        return nil, "高斯模糊数值不能小于 0。"
    end
    if config.use_radius and config.radius < 0 then
        return nil, "图框圆角不能小于 0。"
    end

    if mode == MODE_DIRECT then
        local x = config.use_x and config.x or 0
        local y = config.use_y and config.y or 0
        local width = config.use_width and config.width or 100
        local height = config.use_height and config.height or 100
        if x < 0 or y < 0 then
            return nil, "X边界和Y边界不能小于 0。"
        end
        if width <= 0 or height <= 0 then
            return nil, "X长度和Y长度必须大于 0。"
        end
    elseif mode == MODE_TEXT then
        local padding_x = config.use_padding_x and config.padding_x or 0
        local padding_y = config.use_padding_y and config.padding_y or 0
        if padding_x < 0 or padding_y < 0 then
            return nil, "文字的 X边界和Y边界不能小于 0。"
        end
    end

    return config
end

local function build_rectangle(left, top, right, bottom, radius)
    left = tonumber(left)
    top = tonumber(top)
    right = tonumber(right)
    bottom = tonumber(bottom)
    if not left or not top or not right or not bottom then
        return nil, "矩形坐标不是有效数字。"
    end
    if right - left <= EPSILON or bottom - top <= EPSILON then
        return nil, "矩形宽度或高度必须大于 0。"
    end

    local maximum_radius = math.min((right - left) / 2, (bottom - top) / 2)
    local r = math.max(0, math.min(tonumber(radius) or 0, maximum_radius))

    if r <= EPSILON then
        return table.concat({
            "m", fmt_number(left), fmt_number(top),
            "l", fmt_number(right), fmt_number(top),
            fmt_number(right), fmt_number(bottom),
            fmt_number(left), fmt_number(bottom),
            fmt_number(left), fmt_number(top)
        }, " ")
    end

    local k = r * KAPPA
    return table.concat({
        "m", fmt_number(left + r), fmt_number(top),
        "l", fmt_number(right - r), fmt_number(top),
        "b", fmt_number(right - r + k), fmt_number(top),
             fmt_number(right), fmt_number(top + r - k),
             fmt_number(right), fmt_number(top + r),
        "l", fmt_number(right), fmt_number(bottom - r),
        "b", fmt_number(right), fmt_number(bottom - r + k),
             fmt_number(right - r + k), fmt_number(bottom),
             fmt_number(right - r), fmt_number(bottom),
        "l", fmt_number(left + r), fmt_number(bottom),
        "b", fmt_number(left + r - k), fmt_number(bottom),
             fmt_number(left), fmt_number(bottom - r + k),
             fmt_number(left), fmt_number(bottom - r),
        "l", fmt_number(left), fmt_number(top + r),
        "b", fmt_number(left), fmt_number(top + r - k),
             fmt_number(left + r - k), fmt_number(top),
             fmt_number(left + r), fmt_number(top)
    }, " ")
end

local function strip_clip_tags(text)
    local source = tostring(text or "")
    local output = {}
    local index = 1
    local in_override = false

    while index <= #source do
        local char = source:sub(index, index)
        if char == "{" then
            in_override = true
            output[#output + 1] = char
            index = index + 1
        elseif char == "}" then
            in_override = false
            output[#output + 1] = char
            index = index + 1
        elseif in_override and char == "\\" then
            local name = source:sub(index + 1):match("^([%a]+)")
            local lowered = name and name:lower() or ""
            if lowered == "clip" or lowered == "iclip" then
                local cursor = index + 1 + #name
                while source:sub(cursor, cursor):match("%s") do
                    cursor = cursor + 1
                end
                if source:sub(cursor, cursor) == "(" then
                    local depth = 1
                    cursor = cursor + 1
                    while cursor <= #source and depth > 0 do
                        local token = source:sub(cursor, cursor)
                        if token == "(" then
                            depth = depth + 1
                        elseif token == ")" then
                            depth = depth - 1
                        end
                        cursor = cursor + 1
                    end
                    index = cursor
                else
                    output[#output + 1] = char
                    index = index + 1
                end
            else
                output[#output + 1] = char
                index = index + 1
            end
        else
            output[#output + 1] = char
            index = index + 1
        end
    end

    return table.concat(output)
end

local function contains_dynamic_geometry(text)
    local source = tostring(text or "")
    local lowered = source:lower()
    if lowered:match("\\move%s*%(") then return true end

    for transform in lowered:gmatch("\\t%s*(%b())") do
        if transform:find("\\fs", 1, true)
            or transform:find("\\fsp", 1, true)
            or transform:find("\\fsc", 1, true)
            or transform:find("\\fr", 1, true)
            or transform:find("\\fax", 1, true)
            or transform:find("\\fay", 1, true)
            or transform:find("\\fn", 1, true)
            or transform:match("\\b[%+%-]?%d")
            or transform:match("\\i[01]")
            or transform:match("\\u[01]")
            or transform:match("\\s[01]") then
            return true
        end
    end
    return false
end

local function split_preserving_empty(text, separator)
    local result = {}
    local start_index = 1
    while true do
        local found = text:find(separator, start_index, true)
        if not found then
            result[#result + 1] = text:sub(start_index)
            break
        end
        result[#result + 1] = text:sub(start_index, found - 1)
        start_index = found + #separator
    end
    return result
end

local function tag_number(tags, name)
    local tag = tags and tags[name]
    if not tag then return 0 end
    if tag.value ~= nil then return tonumber(tag.value) or 0 end
    if type(tag.getTagParams) == "function" then
        local ok, value = pcall(tag.getTagParams, tag)
        if ok then return tonumber(value) or 0 end
    end
    return 0
end

local PLANE_TAGS = {
    "angle",
    "angle_x",
    "angle_y",
    "shear_x",
    "shear_y"
}

local function plane_signature(tags)
    local values = {}
    for _, name in ipairs(PLANE_TAGS) do
        local value = tag_number(tags, name)
        if name == "angle" or name == "angle_x" or name == "angle_y" then
            value = ((value % 360) + 360) % 360
            if value > 180 then value = value - 360 end
        end
        if math.abs(value) < EPSILON then value = 0 end
        values[#values + 1] = string.format("%.6f", value)
    end
    return table.concat(values, "|")
end

local function copy_ass_tag(tag)
    if type(tag) ~= "table" then return tag end
    if type(tag.copy) == "function" then
        local ok, copied = pcall(tag.copy, tag)
        if ok and copied then return copied end
    end

    local copied = copy_table(tag)
    return setmetatable(copied, getmetatable(tag))
end

local function copy_effective_tag_list(tag_list)
    if type(tag_list) ~= "table" then return nil end
    if type(tag_list.copy) == "function" then
        local ok, copied = pcall(tag_list.copy, tag_list)
        if ok and copied and copied.tags then return copied end
    end

    local copied = copy_table(tag_list)
    copied.tags = {}
    for name, tag in pairs(tag_list.tags or {}) do
        copied.tags[name] = copy_ass_tag(tag)
    end
    return setmetatable(copied, getmetatable(tag_list))
end

local function point_coordinates(tag)
    if type(tag) ~= "table" then return nil end

    local x = tonumber(tag.x)
    local y = tonumber(tag.y)
    if x and y then return x, y end

    -- An unevaluated zero-distance move is still a fixed position.
    local start_pos = tag.startPos
    local end_pos = tag.endPos
    if type(start_pos) == "table" and type(end_pos) == "table" then
        local x1, y1 = tonumber(start_pos.x), tonumber(start_pos.y)
        local x2, y2 = tonumber(end_pos.x), tonumber(end_pos.y)
        if x1 and y1 and x2 and y2
            and math.abs(x1 - x2) <= EPSILON
            and math.abs(y1 - y2) <= EPSILON then
            return x1, y1
        end
    end
    return nil
end

local function resolve_projection_geometry(data)
    if not data or type(data.getPosition) ~= "function" then
        return nil, "ASS 解析结果无法解析文字位置。"
    end

    local ok, position, _, origin = pcall(data.getPosition, data)
    if not ok then
        return nil, "无法解析文字位置和旋转原点：" .. tostring(position)
    end

    local position_x, position_y = point_coordinates(position)
    if not position_x then
        return nil, "文字位置不是可投影的固定坐标。"
    end

    local origin_x, origin_y = point_coordinates(origin)
    if not origin_x then
        -- ASS semantics: when \org is omitted, the rotation origin follows
        -- the current \pos (or the position of the current move snapshot).
        origin_x, origin_y = position_x, position_y
    end

    return {
        position = {x = position_x, y = position_y},
        origin = {x = origin_x, y = origin_y}
    }
end

local function apply_projection_geometry(tag_list, geometry)
    local copied = copy_effective_tag_list(tag_list)
    if not copied or not copied.tags then return nil end

    copied.tags.position = {
        x = geometry.position.x,
        y = geometry.position.y
    }
    copied.tags.origin = {
        x = geometry.origin.x,
        y = geometry.origin.y
    }
    return copied
end

local function measure_text_fragment(style, fragment)
    local sample = fragment
    if sample == "" then sample = " " end

    local ok, width, height, descent, external_leading = pcall(
        aegisub.text_extents,
        style,
        sample
    )
    if not ok then
        return nil, "无法测量文字片段：" .. tostring(width)
    end

    width = tonumber(width) or 0
    height = tonumber(height) or 0
    descent = tonumber(descent) or 0
    external_leading = tonumber(external_leading) or 0
    if fragment == "" then width = 0 end
    if height <= EPSILON then
        return nil, "字体行高无效。"
    end

    return {
        width = width,
        height = height + math.max(0, external_leading),
        descent = descent
    }
end

local function measure_multiline_layout(modules, data, geometry)
    local lines = {}
    local current = {width = 0, height = 0}
    local first_tag_list = nil
    local first_plane = nil
    local mixed_plane = false
    local visible_text = false
    local text_section_count = 0
    local drawing_section_count = 0

    local function apply_metrics(metrics)
        current.height = math.max(current.height, metrics.height)
    end

    local function finish_line(next_metrics)
        if current.height <= EPSILON and next_metrics then
            current.height = next_metrics.height
        end
        lines[#lines + 1] = current
        current = {
            width = 0,
            height = next_metrics and next_metrics.height or 0
        }
    end

    for _, section in ipairs(data.sections or {}) do
        if section.class == modules.ass.Section.Drawing then
            drawing_section_count = drawing_section_count + 1
        elseif section.class == modules.ass.Section.Text then
            text_section_count = text_section_count + 1

            local ok_tags, tag_list = pcall(
                section.getEffectiveTags,
                section,
                true,
                true,
                true
            )
            if not ok_tags or not tag_list or not tag_list.tags then
                return nil, "无法取得文字片段的有效标签。"
            end
            tag_list = apply_projection_geometry(tag_list, geometry)
            if not tag_list then
                return nil, "无法建立独立的文字投影标签。"
            end
            if not first_tag_list then first_tag_list = tag_list end

            local signature = plane_signature(tag_list.tags)
            if not first_plane then
                first_plane = signature
            elseif first_plane ~= signature then
                mixed_plane = true
            end

            local ok_style, style = pcall(section.getStyleTable, section)
            if not ok_style or type(style) ~= "table" then
                return nil, "无法取得文字片段的字体样式。"
            end

            local value = tostring(section:getString() or "")
            value = value:gsub("\\h", " "):gsub("\\n", " ")
            local fragments = split_preserving_empty(value, "\\N")

            for fragment_index, fragment in ipairs(fragments) do
                local metrics, metrics_error = measure_text_fragment(style, fragment)
                if not metrics then return nil, metrics_error end

                current.width = current.width + metrics.width
                apply_metrics(metrics)
                if fragment:gsub("%s+", "") ~= "" then
                    visible_text = true
                end

                if fragment_index < #fragments then
                    finish_line(metrics)
                end
            end
        end
    end

    if current.height > EPSILON or #lines > 0 then
        finish_line()
    end

    if drawing_section_count > 0 then
        return {
            has_drawing = true,
            has_text = text_section_count > 0,
            mixed_plane = true
        }
    end
    if not visible_text then return nil, "文字为空或没有可见字形。" end
    if #lines == 0 then return nil, "没有找到可测量的文字行。" end

    local width = 0
    local height = 0
    for _, line in ipairs(lines) do
        width = math.max(width, line.width)
        height = height + line.height
    end
    if width <= EPSILON or height <= EPSILON then
        return nil, "文字整体宽度或高度为 0。"
    end

    return {
        width = width,
        height = height,
        lines = lines,
        tag_list = first_tag_list,
        mixed_plane = mixed_plane,
        has_text = true,
        has_drawing = false
    }
end

local function append_arc(points, center_x, center_y, radius, start_angle, end_angle, steps)
    for step = 0, steps do
        if #points == 0 or step > 0 then
            local factor = step / steps
            local angle = start_angle + (end_angle - start_angle) * factor
            points[#points + 1] = {
                center_x + math.cos(angle) * radius,
                center_y + math.sin(angle) * radius
            }
        end
    end
end

local function build_local_rectangle_points(left, top, right, bottom, radius)
    local maximum_radius = math.min((right - left) / 2, (bottom - top) / 2)
    local r = math.max(0, math.min(tonumber(radius) or 0, maximum_radius))
    if r <= EPSILON then
        return {
            {left, top},
            {right, top},
            {right, bottom},
            {left, bottom}
        }
    end

    local points = {}
    local steps = 6
    append_arc(points, right - r, top + r, r, -math.pi / 2, 0, steps)
    append_arc(points, right - r, bottom - r, r, 0, math.pi / 2, steps)
    append_arc(points, left + r, bottom - r, r, math.pi / 2, math.pi, steps)
    append_arc(points, left + r, top + r, r, math.pi, math.pi * 1.5, steps)
    return points
end

local function build_polygon(points)
    if not points or #points < 3 then
        return nil, "投影后的矩形节点不足。"
    end

    local output = {
        "m",
        fmt_number(points[1][1]),
        fmt_number(points[1][2]),
        "l"
    }
    for index = 2, #points do
        output[#output + 1] = fmt_number(points[index][1])
        output[#output + 1] = fmt_number(points[index][2])
    end
    output[#output + 1] = fmt_number(points[1][1])
    output[#output + 1] = fmt_number(points[1][2])
    return table.concat(output, " ")
end

local function projected_text_rectangle(modules, layout, padding_x, padding_y, radius)
    local tag_list = layout.tag_list
    if not tag_list or not tag_list.tags then
        return nil, "无法取得文字平面的有效标签。"
    end

    local tags = tag_list.tags
    if not tags.position or not tags.origin or not tags.align then
        return nil, "文字缺少有效的位置、原点或对齐信息。"
    end

    if tags.scale_x and tags.scale_x.value ~= nil then tags.scale_x.value = 100 end
    if tags.scale_y and tags.scale_y.value ~= nil then tags.scale_y.value = 100 end

    local local_points = build_local_rectangle_points(
        -padding_x,
        -padding_y,
        layout.width + padding_x,
        layout.height + padding_y,
        radius
    )

    local ok_transform, transformed_or_error = pcall(
        modules.perspective.transformPoints,
        tags,
        layout.width,
        layout.height,
        local_points
    )
    if not ok_transform or not transformed_or_error then
        return nil, "文字平面投影失败：" .. tostring(transformed_or_error)
    end

    local transformed = {}
    for index = 1, #local_points do
        local point = transformed_or_error[index]
        local x = point and tonumber(point[1])
        local y = point and tonumber(point[2])
        if not x or not y or x ~= x or y ~= y
            or math.abs(x) == math.huge or math.abs(y) == math.huge then
            return nil, "文字平面投影产生了无效坐标。"
        end
        transformed[#transformed + 1] = {x, y}
    end

    return build_polygon(transformed)
end

local function shape_bounds(yutils, shape)
    local ok_bounds, left, top, right, bottom = pcall(
        yutils.shape.bounding,
        shape
    )
    if not ok_bounds or not left or not top or not right or not bottom then
        return nil
    end
    if right - left <= EPSILON or bottom - top <= EPSILON then
        return nil
    end
    return {
        left = left,
        top = top,
        right = right,
        bottom = bottom
    }
end

local function rendered_bounds(modules, data)
    local ok_bounds, bounds_or_error = pcall(
        modules.assf_plus.lineData.getLineBounds,
        data,
        true,
        true,
        true,
        false
    )
    if not ok_bounds or not bounds_or_error
        or not bounds_or_error[1] or not bounds_or_error[2] then
        return nil
    end

    local left = tonumber(bounds_or_error[1].x)
    local top = tonumber(bounds_or_error[1].y)
    local right = tonumber(bounds_or_error[2].x)
    local bottom = tonumber(bounds_or_error[2].y)
    if not left or not top or not right or not bottom
        or right - left <= EPSILON or bottom - top <= EPSILON then
        return nil
    end
    return {left = left, top = top, right = right, bottom = bottom}
end

local function union_rect(first, second)
    if not first then return second end
    if not second then return first end
    return {
        left = math.min(first.left, second.left),
        top = math.min(first.top, second.top),
        right = math.max(first.right, second.right),
        bottom = math.max(first.bottom, second.bottom)
    }
end

local function drawing_section_bounds(modules, data, geometry)
    local rect = nil

    for _, section in ipairs(data.sections or {}) do
        if section.class == modules.ass.Section.Drawing then
            local ok_extents, extents = pcall(section.getExtremePoints, section)
            local ok_tags, tag_list = pcall(
                section.getEffectiveTags,
                section,
                true,
                true,
                true
            )
            if ok_extents and extents and extents.left and extents.top
                and extents.right and extents.bottom
                and ok_tags and tag_list and tag_list.tags then
                tag_list = apply_projection_geometry(tag_list, geometry)
                if not tag_list then return nil end
                local drawing_scale = tonumber(section.scale and section.scale.value) or 1
                local coordinate_scale = 1 / (2 ^ math.max(0, drawing_scale - 1))
                local width = (tonumber(extents.w) or 0) * coordinate_scale
                local height = (tonumber(extents.h) or 0) * coordinate_scale
                local points = {
                    {extents.left.x * coordinate_scale, extents.top.y * coordinate_scale},
                    {extents.right.x * coordinate_scale, extents.top.y * coordinate_scale},
                    {extents.right.x * coordinate_scale, extents.bottom.y * coordinate_scale},
                    {extents.left.x * coordinate_scale, extents.bottom.y * coordinate_scale}
                }

                local ok_transform, transformed = pcall(
                    modules.perspective.transformPoints,
                    tag_list.tags,
                    width,
                    height,
                    points
                )
                if ok_transform and transformed then
                    local left, top, right, bottom
                    for index = 1, #points do
                        local point = transformed[index]
                        local x = point and tonumber(point[1])
                        local y = point and tonumber(point[2])
                        if x and y then
                            left = left and math.min(left, x) or x
                            top = top and math.min(top, y) or y
                            right = right and math.max(right, x) or x
                            bottom = bottom and math.max(bottom, y) or y
                        end
                    end
                    if left and right - left > EPSILON and bottom - top > EPSILON then
                        rect = union_rect(rect, {
                            left = left,
                            top = top,
                            right = right,
                            bottom = bottom
                        })
                    end
                end
            end
        end
    end

    return rect
end

local function conservative_text_rectangle(
    modules,
    data,
    padding_x,
    padding_y,
    radius,
    geometry
)
    local rect = nil
    local ok_shape, shape_or_error = pcall(
        modules.assf_plus.lineData.getTextShape,
        data
    )
    if ok_shape and shape_or_error and shape_or_error ~= "" then
        rect = shape_bounds(modules.yutils, shape_or_error)
    end
    rect = union_rect(rect, drawing_section_bounds(modules, data, geometry))
    if not rect then rect = rendered_bounds(modules, data) end
    if not rect then
        return nil, "无法取得复杂文字或绘图的屏幕外接范围。"
    end

    return build_rectangle(
        rect.left - padding_x,
        rect.top - padding_y,
        rect.right + padding_x,
        rect.bottom + padding_y,
        radius
    )
end

local function measure_text_snapshot(modules, snapshot, padding_x, padding_y, radius)
    -- ASSFoundation.parse is a MoonScript instance method (ASS\parse line).
    -- Calling the raw function through pcall must pass the module instance first.
    local ok_parse, data_or_error = pcall(
        modules.ass.parse,
        modules.ass,
        snapshot
    )
    if not ok_parse or not data_or_error then
        return nil, "ASS 标签解析失败：" .. tostring(data_or_error)
    end
    local data = data_or_error

    local geometry, geometry_error = resolve_projection_geometry(data)
    if not geometry then return nil, geometry_error end

    local layout, layout_error = measure_multiline_layout(modules, data, geometry)
    if not layout then return nil, layout_error end

    if layout.has_drawing or layout.mixed_plane then
        return conservative_text_rectangle(
            modules,
            data,
            padding_x,
            padding_y,
            radius,
            geometry
        )
    end

    local drawing, projection_error = projected_text_rectangle(
        modules,
        layout,
        padding_x,
        padding_y,
        radius
    )
    if drawing then return drawing end

    local fallback, fallback_error = conservative_text_rectangle(
        modules,
        data,
        padding_x,
        padding_y,
        radius,
        geometry
    )
    if fallback then return fallback end
    return nil, projection_error .. "；" .. tostring(fallback_error)
end

local function video_frame_range(source)
    local ok_start, start_frame = pcall(aegisub.frame_from_ms, source.start_time)
    local ok_end, end_frame = pcall(aegisub.frame_from_ms, source.end_time)
    if not ok_start or not ok_end
        or type(start_frame) ~= "number" or type(end_frame) ~= "number" then
        return nil, nil, "未载入视频或无法取得帧时间。"
    end
    if end_frame <= start_frame then
        return nil, nil, "字幕不足一个可见视频帧。"
    end
    return start_frame, end_frame
end

local function build_text_segments(modules, wrapped_line, source, config)
    if (tonumber(source.end_time) or 0) <= (tonumber(source.start_time) or 0) then
        return nil, "字幕持续时间无效。"
    end

    wrapped_line.text = strip_clip_tags(wrapped_line.text)
    local dynamic = contains_dynamic_geometry(wrapped_line.text)
    local padding_x = config.use_padding_x and config.padding_x or 0
    local padding_y = config.use_padding_y and config.padding_y or 0
    local radius = config.use_radius and config.radius or 0
    local snapshots = {}

    if dynamic then
        local _, _, frame_error = video_frame_range(source)
        if frame_error then return nil, frame_error end

        local ok_parse, data_or_error = pcall(
            modules.ass.parse,
            modules.ass,
            wrapped_line
        )
        if not ok_parse or not data_or_error then
            return nil, "动态标签解析失败：" .. tostring(data_or_error)
        end

        local ok_fbf, fbf_or_error = pcall(
            modules.arch_util.line2fbf,
            data_or_error,
            3
        )
        if not ok_fbf or type(fbf_or_error) ~= "table" then
            return nil, "动态字幕逐帧展开失败：" .. tostring(fbf_or_error)
        end
        snapshots = fbf_or_error
        if #snapshots == 0 then
            return nil, "动态字幕没有可处理的视频帧。"
        end
    else
        snapshots[1] = wrapped_line
    end

    local segments = {}
    for snapshot_index, snapshot in ipairs(snapshots) do
        if aegisub.progress and aegisub.progress.is_cancelled
            and aegisub.progress.is_cancelled() then
            aegisub.cancel()
        end

        local start_time
        local end_time
        if dynamic then
            start_time = math.max(source.start_time, snapshot.start_time)
            end_time = math.min(source.end_time, snapshot.end_time)
        else
            start_time = source.start_time
            end_time = source.end_time
        end

        if end_time > start_time then
            local drawing, drawing_error = measure_text_snapshot(
                modules,
                snapshot,
                padding_x,
                padding_y,
                radius
            )
            if not drawing then
                return nil, string.format(
                    "第 %d 个时间片测量失败：%s",
                    snapshot_index,
                    drawing_error or "未知错误"
                )
            end

            local previous = segments[#segments]
            if previous and previous.drawing == drawing
                and start_time <= previous.end_time + 1 then
                previous.end_time = end_time
            else
                segments[#segments + 1] = {
                    start_time = start_time,
                    end_time = end_time,
                    drawing = drawing
                }
            end
        end
    end

    if #segments == 0 then
        return nil, "没有生成有效的图框时间片。"
    end
    return segments
end

local function build_frame_text(drawing, config, style)
    local tags = {"\\pos(0,0)"}
    if not style or tonumber(style.align or style.alignment) ~= 7 then
        tags[#tags + 1] = "\\an7"
    end
    tags[#tags + 1] = "\\p1"
    if not style or differs(style.scale_x, 100) then tags[#tags + 1] = "\\fscx100" end
    if not style or differs(style.scale_y, 100) then tags[#tags + 1] = "\\fscy100" end
    if not style or differs(style.angle, 0) then tags[#tags + 1] = "\\frz0" end

    local fill_color = html_color_to_ass(config.fill_color)
    if not style or style_color(style, "color1") ~= fill_color then
        tags[#tags + 1] = "\\c" .. fill_color
    end
    if config.use_fill_alpha then
        local fill_alpha = html_alpha_to_ass(config.fill_alpha)
        if not style or style_alpha(style, "color1") ~= fill_alpha then
            tags[#tags + 1] = "\\1a" .. fill_alpha
        end
    end

    local inherited_border = style and tonumber(style.outline) or nil
    local border_size = config.use_border_size and config.border_size or inherited_border
    if config.use_border_size and (not style or differs(inherited_border, config.border_size)) then
        tags[#tags + 1] = "\\bord" .. fmt_number(config.border_size)
    end
    if border_size == nil or border_size > EPSILON then
        local border_color = html_color_to_ass(config.border_color)
        if not style or style_color(style, "color3") ~= border_color then
            tags[#tags + 1] = "\\3c" .. border_color
        end
        if config.use_border_alpha then
            local border_alpha = html_alpha_to_ass(config.border_alpha)
            if not style or style_alpha(style, "color3") ~= border_alpha then
                tags[#tags + 1] = "\\3a" .. border_alpha
            end
        end
    end

    local inherited_shadow = style and tonumber(style.shadow) or nil
    local shadow_size = config.use_shadow_size and config.shadow_size or inherited_shadow
    if config.use_shadow_size and (not style or differs(inherited_shadow, config.shadow_size)) then
        tags[#tags + 1] = "\\shad" .. fmt_number(config.shadow_size)
    end
    if shadow_size == nil or math.abs(shadow_size) > EPSILON then
        local shadow_color = html_color_to_ass(config.shadow_color)
        if not style or style_color(style, "color4") ~= shadow_color then
            tags[#tags + 1] = "\\4c" .. shadow_color
        end
        if config.use_shadow_alpha then
            local shadow_alpha = html_alpha_to_ass(config.shadow_alpha)
            if not style or style_alpha(style, "color4") ~= shadow_alpha then
                tags[#tags + 1] = "\\4a" .. shadow_alpha
            end
        end
    end

    if config.use_blur and config.blur > EPSILON then
        tags[#tags + 1] = "\\blur" .. fmt_number(config.blur)
    end

    return "{" .. table.concat(tags) .. "}" .. drawing
end

local function extract_rect_clip(text)
    local pattern =
        "\\[cC][lL][iI][pP]%s*%(%s*" ..
        "([%+%-]-[%d%.]+)%s*,%s*" ..
        "([%+%-]-[%d%.]+)%s*,%s*" ..
        "([%+%-]-[%d%.]+)%s*,%s*" ..
        "([%+%-]-[%d%.]+)%s*%)"

    local _, _, x1, y1, x2, y2 = tostring(text or ""):find(pattern)
    if not x1 then
        return nil, "没有找到矩形 \\clip(x1,y1,x2,y2)。"
    end

    x1, y1, x2, y2 = tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)
    if not x1 or not y1 or not x2 or not y2 then
        return nil, "矩形 \\clip 的坐标无法解析。"
    end

    local left = math.min(x1, x2)
    local top = math.min(y1, y2)
    local right = math.max(x1, x2)
    local bottom = math.max(y1, y2)
    if right - left <= EPSILON or bottom - top <= EPSILON then
        return nil, "矩形 \\clip 的宽度或高度为 0。"
    end

    return {left = left, top = top, right = right, bottom = bottom}
end

local function sorted_selection(selection)
    local result = {}
    local seen = {}
    for _, index in ipairs(selection or {}) do
        index = tonumber(index)
        if index and not seen[index] then
            seen[index] = true
            result[#result + 1] = index
        end
    end
    table.sort(result)
    return result
end

local function make_overlay(source, style, drawing, config, effect_value, start_time, end_time)
    local overlay = copy_table(source)
    overlay.comment = false
    overlay.layer = tonumber(source.layer) or 0
    set_generated_marker(overlay, effect_value)
    overlay.start_time = start_time or source.start_time
    overlay.end_time = end_time or source.end_time
    overlay.text = build_frame_text(drawing, config, style)
    return overlay
end

local function run_mode(mode, subtitles, selection, active_line)
    local indexes = sorted_selection(selection)
    if #indexes == 0 then
        show_message("请先选择至少一条字幕行。", "没有选择字幕")
        aegisub.cancel()
    end

    local config
    while true do
        local button, result = aegisub.dialog.display(
            make_dialog(mode, last_configs[mode]),
            {"创建", "取消"},
            {ok = "创建", cancel = "取消"}
        )
        if not button or button == "取消" then aegisub.cancel() end

        local config_error
        config, config_error = normalize_config(mode, result)
        if config then
            last_configs[mode] = config
            break
        end
        show_message(config_error, "参数错误")
    end

    local modules
    if mode == MODE_TEXT then
        local modules_error
        modules, modules_error = get_geometry_modules()
        if not modules then
            show_message(modules_error, "无法运行")
            aegisub.cancel()
        end
    end

    local styles = collect_styles(subtitles)
    local radius = config.use_radius and config.radius or 0
    local run_id = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local effect_value = OUTPUT_PREFIX .. mode .. "|" .. run_id
    local skipped = {}
    local prepared = {}
    local wrapped_by_index = {}

    if mode == MODE_TEXT then
        local valid_indexes = {}
        for _, line_index in ipairs(indexes) do
            local source = subtitles[line_index]
            if source and source.class == "dialogue" and not source.comment then
                valid_indexes[#valid_indexes + 1] = line_index
            end
        end

        if #valid_indexes > 0 then
            local ok_collection, collection_or_error = pcall(
                modules.line_collection,
                subtitles,
                valid_indexes,
                function() return true end,
                true
            )
            if not ok_collection or not collection_or_error then
                show_message(
                    "无法建立字幕解析环境：" .. tostring(collection_or_error),
                    "无法运行"
                )
                aegisub.cancel()
            end
            for _, wrapped_line in ipairs(collection_or_error.lines or {}) do
                wrapped_by_index[wrapped_line.number] = wrapped_line
            end
        end
    end

    for selection_position, line_index in ipairs(indexes) do
        if aegisub.progress then
            if aegisub.progress.title then
                aegisub.progress.title(mode_title(mode))
            end
            if aegisub.progress.task then
                aegisub.progress.task(string.format(
                    "正在计算第 %d/%d 条字幕",
                    selection_position,
                    #indexes
                ))
            end
            if aegisub.progress.set then
                aegisub.progress.set((selection_position - 1) * 100 / #indexes)
            end
            if aegisub.progress.is_cancelled and aegisub.progress.is_cancelled() then
                aegisub.cancel()
            end
        end

        local source = subtitles[line_index]
        local segments
        local prepare_error

        if not source or source.class ~= "dialogue" then
            prepare_error = "不是对话行。"
        elseif source.comment then
            prepare_error = "注释行不会处理。"
        elseif mode == MODE_DIRECT then
            local left = config.use_x and config.x or 0
            local top = config.use_y and config.y or 0
            local width = config.use_width and config.width or 100
            local height = config.use_height and config.height or 100
            local drawing, drawing_error = build_rectangle(
                left,
                top,
                left + width,
                top + height,
                radius
            )
            if drawing then
                segments = {{
                    start_time = source.start_time,
                    end_time = source.end_time,
                    drawing = drawing
                }}
            else
                prepare_error = drawing_error
            end
        elseif mode == MODE_CLIP then
            local rect, rect_error = extract_rect_clip(source.text)
            if rect then
                local drawing, drawing_error = build_rectangle(
                    rect.left,
                    rect.top,
                    rect.right,
                    rect.bottom,
                    radius
                )
                if drawing then
                    segments = {{
                        start_time = source.start_time,
                        end_time = source.end_time,
                        drawing = drawing
                    }}
                else
                    prepare_error = drawing_error
                end
            else
                prepare_error = rect_error
            end
        else
            local wrapped_line = wrapped_by_index[line_index]
            if not wrapped_line then
                prepare_error = "无法取得该字幕的样式和解析信息。"
            else
                local ok_segments, segments_or_error, returned_error = pcall(
                    build_text_segments,
                    modules,
                    wrapped_line,
                    source,
                    config
                )
                if ok_segments and segments_or_error then
                    segments = segments_or_error
                elseif ok_segments then
                    prepare_error = returned_error or "无法计算文字图框。"
                else
                    prepare_error = "计算文字图框时发生错误：" .. tostring(segments_or_error)
                end
            end
        end

        if not segments then
            skipped[#skipped + 1] = string.format(
                "第 %d 行：%s",
                line_index,
                prepare_error or "无法确定矩形范围。"
            )
        else
            prepared[#prepared + 1] = {
                index = line_index,
                source = copy_table(source),
                style = type(source.styleref) == "table"
                    and source.styleref or styles[source.style],
                segments = segments
            }
        end
    end

    if aegisub.progress and aegisub.progress.set then
        aegisub.progress.set(100)
    end

    local generated_count = 0
    for prepared_index = #prepared, 1, -1 do
        local record = prepared[prepared_index]
        local current_source = subtitles[record.index]
        if mode == MODE_TEXT then
            current_source.layer = (tonumber(current_source.layer) or 0) + 1
            subtitles[record.index] = current_source
        end

        for segment_index = #record.segments, 1, -1 do
            local segment = record.segments[segment_index]
            local overlay = make_overlay(
                record.source,
                record.style,
                segment.drawing,
                config,
                effect_value,
                segment.start_time,
                segment.end_time
            )
            subtitles.insert(record.index + 1, overlay)
            generated_count = generated_count + 1
        end
    end

    if generated_count == 0 then
        show_message("没有生成任何图框行。\n\n" .. table.concat(skipped, "\n"), "处理失败")
        aegisub.cancel()
    end

    aegisub.set_undo_point(mode_title(mode))
    if #skipped > 0 then
        show_message(
            string.format(
                "已生成 %d 行，另有 %d 行被跳过：\n\n%s",
                generated_count,
                #skipped,
                table.concat(skipped, "\n")
            ),
            "处理完成"
        )
    end

    local generated_selection = {}
    for index = 1, #subtitles do
        local line = subtitles[index]
        if line and line.class == "dialogue" and generated_marker(line) == effect_value then
            generated_selection[#generated_selection + 1] = index
        end
    end
    return generated_selection, generated_selection[1] or active_line
end

local function run_direct(subtitles, selection, active_line)
    return run_mode(MODE_DIRECT, subtitles, selection, active_line)
end

local function run_text(subtitles, selection, active_line)
    return run_mode(MODE_TEXT, subtitles, selection, active_line)
end

local function run_clip(subtitles, selection, active_line)
    return run_mode(MODE_CLIP, subtitles, selection, active_line)
end

local function validate_selection(subtitles, selection, active_line)
    return selection ~= nil and #selection > 0
end

aegisub.register_macro(
    "快速添加矩形图框/直接添加矩形图框",
    "按左上角坐标和长度直接生成矩形图框。",
    run_direct,
    validate_selection
)

aegisub.register_macro(
    "快速添加矩形图框/根据文字添加矩形图框",
    "按单行或 \\N 多行文字的整体范围生成图框，支持旋转、透视、移动和动态标签。",
    run_text,
    validate_selection
)

aegisub.register_macro(
    "快速添加矩形图框/根据 \\clip 创建矩形图框",
    "读取所选行的矩形 clip 并生成对应图框。",
    run_clip,
    validate_selection
)
]==]
    },
    {
        id = 'quick_move_from_clip',
        name = '快速添加 Move',
        description = '根据首尾帧的两点矢量 Clip 和当前帧的 Pos，生成四参数 Move。',
        source = [==[
script_name = "快速添加 Move（两点 Clip）"
script_description = "根据首尾帧的两点矢量 Clip 和当前帧的 Pos，生成四参数 Move。"
script_author = "OpenAI"
script_version = "1.0.0"
script_namespace = "OpenAI.QuickMoveFromClip"

local TARGET_TAGS = {
    pos = true,
    move = true,
    clip = true,
    iclip = true,
}

local function show_error(message)
    aegisub.dialog.display({
        {
            class = "label",
            label = message,
            x = 0,
            y = 0,
            width = 5,
            height = 2,
        },
    }, {"确定"}, {ok="确定"})
    aegisub.cancel()
end

local function find_closing_parenthesis(text, opening)
    local depth = 0
    for index = opening, #text do
        local char = text:sub(index, index)
        if char == "(" then
            depth = depth + 1
        elseif char == ")" then
            depth = depth - 1
            if depth == 0 then
                return index
            end
        end
    end
    return nil
end

local function parse_override_block(block, block_index, absolute_offset, tags)
    local index = 1

    while index <= #block do
        if block:sub(index, index) ~= "\\" then
            index = index + 1
        else
            local name_start = index + 1
            local name_end = name_start - 1

            while name_end + 1 <= #block
                and block:sub(name_end + 1, name_end + 1):match("[%w]")
            do
                name_end = name_end + 1
            end

            local name = block:sub(name_start, name_end):lower()
            local opening = name_end + 1

            if name ~= "" and block:sub(opening, opening) == "(" then
                local closing = find_closing_parenthesis(block, opening)
                if not closing then
                    return nil, "发现括号不完整的 \\" .. name .. " 标签。"
                end

                if TARGET_TAGS[name] then
                    tags[name][#tags[name] + 1] = {
                        name = name,
                        arguments = block:sub(opening + 1, closing - 1),
                        absolute_start = absolute_offset + index,
                        absolute_end = absolute_offset + closing,
                        local_start = index,
                        local_end = closing,
                        block_index = block_index,
                    }
                end

                -- 跳过完整参数列表，避免把 \t(...) 内部标签误判为顶层标签。
                index = closing + 1
            else
                index = math.max(index + 1, name_end + 1)
            end
        end
    end

    return true
end

local function collect_top_level_tags(text)
    local tags = {
        pos = {},
        move = {},
        clip = {},
        iclip = {},
    }
    local blocks = {}
    local search_from = 1

    while true do
        local opening = text:find("{", search_from, true)
        if not opening then
            break
        end

        local closing = text:find("}", opening + 1, true)
        if not closing then
            break
        end

        local content = text:sub(opening + 1, closing - 1)
        local block_index = #blocks + 1
        blocks[block_index] = {
            opening = opening,
            closing = closing,
            content = content,
        }

        local ok, error_message = parse_override_block(
            content,
            block_index,
            opening,
            tags
        )
        if not ok then
            return nil, nil, error_message
        end

        search_from = closing + 1
    end

    return tags, blocks
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strict_number(text)
    local value_text = trim(text)
    local unsigned = value_text:gsub("^[+-]", "")

    if not unsigned:match("^%d+%.?%d*$")
        and not unsigned:match("^%.%d+$")
    then
        return nil
    end

    return tonumber(value_text)
end

local function parse_pos(arguments)
    local first_comma = arguments:find(",", 1, true)
    if not first_comma or arguments:find(",", first_comma + 1, true) then
        return nil, nil
    end

    local x = strict_number(arguments:sub(1, first_comma - 1))
    local y = strict_number(arguments:sub(first_comma + 1))
    return x, y
end

local function parse_two_point_clip(arguments)
    if arguments:find(",", 1, true) then
        return nil, "两点 Clip 不能带缩放参数或逗号。"
    end

    local tokens = {}
    for token in arguments:gmatch("%S+") do
        tokens[#tokens + 1] = token
    end

    if #tokens ~= 6
        or tokens[1]:lower() ~= "m"
        or tokens[4]:lower() ~= "l"
    then
        return nil, "Clip 必须恰好为两个节点：\\clip(m x1 y1 l x2 y2)。"
    end

    local x1 = strict_number(tokens[2])
    local y1 = strict_number(tokens[3])
    local x2 = strict_number(tokens[5])
    local y2 = strict_number(tokens[6])
    if not x1 or not y1 or not x2 or not y2 then
        return nil, "Clip 坐标必须是有效数字。"
    end

    return {
        x1 = x1,
        y1 = y1,
        x2 = x2,
        y2 = y2,
    }
end

local function rounded_coordinate(value)
    local rounded
    if value >= 0 then
        rounded = math.floor(value * 1000 + 0.5) / 1000
    else
        rounded = math.ceil(value * 1000 - 0.5) / 1000
    end

    if math.abs(rounded) < 0.0005 then
        rounded = 0
    end

    local output = string.format("%.3f", rounded):gsub(",", ".")
    output = output:gsub("(%..-)0+$", "%1")
    output = output:gsub("%.$", "")
    return output
end

local function apply_edits(text, edits)
    table.sort(edits, function(left, right)
        return left.first > right.first
    end)

    for _, edit in ipairs(edits) do
        text = text:sub(1, edit.first - 1)
            .. edit.replacement
            .. text:sub(edit.last + 1)
    end

    return text
end

local function only_clip_remains_in_block(clip_tag, blocks)
    local content = blocks[clip_tag.block_index].content
    local remaining = content:sub(1, clip_tag.local_start - 1)
        .. content:sub(clip_tag.local_end + 1)
    return remaining:match("^%s*$") ~= nil
end

local function safe_frame_from_ms(milliseconds)
    local ok, frame = pcall(aegisub.frame_from_ms, milliseconds)
    if not ok or type(frame) ~= "number" then
        return nil
    end
    return frame
end

local function safe_ms_from_frame(frame)
    local ok, milliseconds = pcall(aegisub.ms_from_frame, frame)
    if not ok or type(milliseconds) ~= "number" then
        return nil
    end
    return milliseconds
end

local function validate_active_line(subtitles, active_line)
    if type(active_line) ~= "number" or active_line < 1 then
        return nil, "没有活动字幕行。"
    end

    local line = subtitles[active_line]
    if not line or line.class ~= "dialogue" then
        return nil, "活动行不是字幕事件。"
    end
    if line.comment then
        return nil, "注释行不能生成 Move。"
    end
    if type(line.start_time) ~= "number"
        or type(line.end_time) ~= "number"
        or line.end_time <= line.start_time
    then
        return nil, "字幕持续时间无效。"
    end

    return line
end

local function build_move(subtitles, selected_lines, active_line)
    local line, line_error = validate_active_line(subtitles, active_line)
    if not line then
        show_error(line_error)
    end

    local tags, blocks, parse_error = collect_top_level_tags(line.text)
    if not tags then
        show_error(parse_error)
    end

    if #tags.iclip > 0 then
        show_error("不支持 \\iclip；请使用两点矢量 \\clip。")
    end
    if #tags.move > 0 then
        show_error("活动行已经包含 \\move，请先移除后再运行。")
    end
    if #tags.pos ~= 1 then
        show_error(
            #tags.pos == 0
                and "活动行缺少顶层 \\pos(x,y)。"
                or "活动行必须且只能包含一个顶层 \\pos。"
        )
    end
    if #tags.clip ~= 1 then
        show_error(
            #tags.clip == 0
                and "活动行缺少顶层两点矢量 \\clip。"
                or "活动行必须且只能包含一个顶层 \\clip。"
        )
    end

    local pos_x, pos_y = parse_pos(tags.pos[1].arguments)
    if not pos_x or not pos_y then
        show_error("\\pos 必须为两个有效坐标：\\pos(x,y)。")
    end

    local clip, clip_error = parse_two_point_clip(tags.clip[1].arguments)
    if not clip then
        show_error(clip_error)
    end

    local ok_properties, properties = pcall(aegisub.project_properties)
    if not ok_properties or type(properties) ~= "table"
        or type(properties.video_position) ~= "number"
        or type(properties.video_file) ~= "string"
        or properties.video_file == ""
    then
        show_error("无法取得当前视频帧；请先载入视频。")
    end

    local first_frame = safe_frame_from_ms(line.start_time)
    local end_boundary_frame = safe_frame_from_ms(line.end_time)
    if not first_frame or not end_boundary_frame then
        show_error("无法取得视频时间码；请先载入带时间码的视频。")
    end

    local last_frame = end_boundary_frame - 1
    if last_frame <= first_frame then
        show_error("字幕必须至少覆盖两个可见视频帧。")
    end

    local current_frame = properties.video_position
    if current_frame < first_frame or current_frame > last_frame then
        show_error("当前视频帧不在活动字幕的可见范围内。")
    end

    local first_time = safe_ms_from_frame(first_frame)
    local last_time = safe_ms_from_frame(last_frame)
    local current_time = safe_ms_from_frame(current_frame)
    if not first_time or not last_time or not current_time then
        show_error("无法换算视频帧时间；请检查视频时间码。")
    end

    local visible_span = last_time - first_time
    if visible_span <= 0 then
        show_error("首尾可见帧的时间差无效。")
    end

    local velocity_x = (clip.x2 - clip.x1) / visible_span
    local velocity_y = (clip.y2 - clip.y1) / visible_span
    local duration = line.end_time - line.start_time
    local current_offset = current_time - line.start_time

    local move_x1 = pos_x - velocity_x * current_offset
    local move_y1 = pos_y - velocity_y * current_offset
    local move_x2 = move_x1 + velocity_x * duration
    local move_y2 = move_y1 + velocity_y * duration

    local move_tag = string.format(
        "\\move(%s,%s,%s,%s)",
        rounded_coordinate(move_x1),
        rounded_coordinate(move_y1),
        rounded_coordinate(move_x2),
        rounded_coordinate(move_y2)
    )

    local edits = {
        {
            first = tags.pos[1].absolute_start,
            last = tags.pos[1].absolute_end,
            replacement = move_tag,
        },
    }

    local clip_tag = tags.clip[1]
    if only_clip_remains_in_block(clip_tag, blocks) then
        local clip_block = blocks[clip_tag.block_index]
        edits[#edits + 1] = {
            first = clip_block.opening,
            last = clip_block.closing,
            replacement = "",
        }
    else
        edits[#edits + 1] = {
            first = clip_tag.absolute_start,
            last = clip_tag.absolute_end,
            replacement = "",
        }
    end

    line.text = apply_edits(line.text, edits)
    subtitles[active_line] = line
    aegisub.set_undo_point(script_name)

    return selected_lines, active_line
end

local function can_build_move(subtitles, selected_lines, active_line)
    if type(active_line) ~= "number" or active_line < 1 then
        return false
    end
    local line = subtitles[active_line]
    return line ~= nil and line.class == "dialogue" and not line.comment
end

aegisub.register_macro(
    script_name,
    script_description,
    build_move,
    can_build_move
)
]==]
    },
    {
        id = 'fonts_to_english',
        name = '中英字体转换',
        description = '扫描系统字体，将中文字体名替换成英文字体名；也可配置 Python 路径。',
        source = [==[
local tr = aegisub.gettext
script_name = tr("中英字体转换")
script_description = tr("自动扫描并转换字幕中的中文字体名")
script_author = "H.Coo"
script_version = "0.3"

local user_dir = aegisub.decode_path("?user")
local py_script_path = user_dir .. "\\_temp_font_scanner.py"
local dict_file_path = user_dir .. "\\_font_dict_cache.txt"
local py_config_path = user_dir .. "\\_python_config.txt"

local python_code = [[
import os, sys, traceback
from fontTools.ttLib import TTFont

def get_names(path):
    f = None
    try:
        f = TTFont(path, fontNumber=0, lazy=True)
        cn_family, en_family = None, None
        cn_full, en_full = None, None
        
        for r in f['name'].names:
            if r.platformID == 3:
                if r.nameID == 1:
                    if r.langID == 0x0804: cn_family = r.string.decode('utf-16-be')
                    elif r.langID == 0x0409: en_family = r.string.decode('utf-16-be')
                elif r.nameID == 4:
                    if r.langID == 0x0804: cn_full = r.string.decode('utf-16-be')
                    elif r.langID == 0x0409: en_full = r.string.decode('utf-16-be')
        f.close()
        
        final_cn = cn_family if cn_family else cn_full
        final_en = en_family if en_family else en_full
        
        return final_cn, final_en
    except:
        if f:
            try: f.close()
            except: pass
        return None, None

def main():
    try:
        with open(sys.argv[1], 'w', encoding='utf-8') as out_f:
            dir = r"C:\Windows\Fonts"
            for name in os.listdir(dir):
                if name.lower().endswith(('.ttf', '.otf', '.ttc')):
                    cn, en = get_names(os.path.join(dir, name))
                    if cn and en and cn != en: 
                        out_f.write(f"{cn}|{en}\n")
    except Exception as e:
        err_path = os.path.join(os.path.dirname(sys.argv[1]), '_python_crash.log')
        with open(err_path, 'w', encoding='utf-8') as ef:
            ef.write(traceback.format_exc())
        sys.exit(1)

if __name__ == "__main__": main()
]]

local function get_py_path(force)
    local path = ""
    local f = io.open(py_config_path, "r")
    if f then
        path = f:read("*l") or ""
        f:close()
        if not force and path ~= "" then return path end
    elseif not force then
        force = true
    end
    
    if force then
        local btn, res = aegisub.dialog.display({
            {class="label", label="【Python 路径设置】\n配置中英字体转换使用的 Python 可执行文件。", x=0, y=0, width=6, height=2},
            {class="label", label="Python 绝对路径", x=0, y=2, width=2, height=1},
            {class="textbox", name="p", text=path, value=path, x=0, y=3, width=6, height=1},
            {class="label", label="例如：C:\\\\Users\\\\你的用户名\\\\AppData\\\\Local\\\\Programs\\\\Python\\\\Python313\\\\python.exe", x=0, y=4, width=6, height=1}
        }, {"保存", "取消"}, {ok="保存", cancel="取消"})
        if btn == "保存" and res.p ~= "" then
            local clean_path = string.gsub(res.p, '"', '')
            f = io.open(py_config_path, "w")
            if f then f:write(clean_path); f:close() end
            return clean_path
        end
        return nil
    end
end

local function load_dict()
    local map, f = {}, io.open(dict_file_path, "r")
    if not f then return nil end
    for line in f:lines() do
        local cn, en = string.match(line, "^([^|]+)|([^|]+)$")
        if cn and en then map[cn] = en end
    end
    f:close()
    return map
end

local function do_replace(subs, sel, active, map)
    local cnt = 0
    for i = 1, #subs do
        local l = subs[i]
        local mod = false
        
        if l.class == "style" then
            local is_vert = string.sub(l.fontname, 1, 1) == "@"
            local base = is_vert and string.sub(l.fontname, 2) or l.fontname
            if map[base] then
                l.fontname = (is_vert and "@" or "") .. map[base]
                mod = true
            end
            
        elseif l.class == "dialogue" then
            local nt, n = string.gsub(l.text, "(\\fn)([^\\}]+)", function(p, fn)
                local is_vert = string.sub(fn, 1, 1) == "@"
                local base = is_vert and string.sub(fn, 2) or fn
                return map[base] and (p .. (is_vert and "@" or "") .. map[base]) or (p .. fn)
            end)
            if n > 0 and nt ~= l.text then l.text = nt; mod = true end
        end
        
        if mod then subs[i] = l; cnt = cnt + 1 end
    end
    aegisub.set_undo_point("字体转换")
    aegisub.dialog.display({{class="label", label="大功告成！修改了 "..cnt.." 处字体。", x=0, y=0}}, {"确定"})
end

local function run_scanner(py_cmd)
    local f = io.open(py_script_path, "w")
    if not f then return false end
    f:write(python_code); f:close()
    
    aegisub.progress.title("正在后台静默重新扫描系统字体字典...")
    local cmd = string.format('""%s" "%s" "%s""', py_cmd, py_script_path, dict_file_path)
    os.execute(cmd)
    
    os.remove(py_script_path)
    return true
end

local function auto_scan_and_replace(subs, sel, active)
    local py_cmd = get_py_path(false)
    if not py_cmd then return end
    
    if run_scanner(py_cmd) then
        local map = load_dict()
        if map and next(map) ~= nil then 
            do_replace(subs, sel, active, map) 
        else
            aegisub.dialog.display({{class="label", label="执行失败：字典为空或运行异常。可查看日志。", x=0, y=0}}, {"确定"})
        end
    end
end

local function config_python_path()
    get_py_path(true)
end

aegisub.register_macro("中英字体转换/修改 Python 路径", script_description, config_python_path)
aegisub.register_macro("中英字体转换/扫描并转换字幕字体", script_description, auto_scan_and_replace)

]==]
    }
}

local function show_message(message, title)
    REAL_AEGISUB.dialog.display({
        {
            class = "label",
            label = (title and (title .. "\n\n") or "") .. tostring(message),
            x = 0,
            y = 0,
            width = 6,
            height = 2
        }
    }, {"确定"}, {ok = "确定"})
end

local SHARED_PYTHON_CONFIG_PATH = REAL_AEGISUB.decode_path("?user") .. "\\_python_config.txt"

local function read_shared_python_path()
    local file = io.open(SHARED_PYTHON_CONFIG_PATH, "r")
    if not file then
        return ""
    end

    local path = file:read("*l") or ""
    file:close()
    return path
end

local function configure_shared_python_path(subtitles, selection, active_line)
    local current_path = read_shared_python_path()
    local button, result = REAL_AEGISUB.dialog.display({
        {
            class = "label",
            label = "【Python 路径设置】\n配置工具集共用的 Python 可执行文件。",
            x = 0,
            y = 0,
            width = 6,
            height = 2
        },
        {
            class = "label",
            label = "Python 绝对路径",
            x = 0,
            y = 2,
            width = 6,
            height = 1
        },
        {
            class = "textbox",
            name = "path",
            text = current_path,
            value = current_path,
            x = 0,
            y = 3,
            width = 6,
            height = 1
        },
        {
            class = "label",
            label = "例如：C:\\\\Users\\\\你的用户名\\\\AppData\\\\Local\\\\Programs\\\\Python\\\\Python313\\\\python.exe\n该设置保存在 Aegisub 用户目录的 _python_config.txt，之后其他需要 Python 的工具也可以共用。",
            x = 0,
            y = 4,
            width = 6,
            height = 2
        }
    }, {"保存", "清除", "取消"}, {ok = "保存", cancel = "取消"})

    if not button or button == "取消" then
        return selection, active_line
    end

    local path = tostring((result and result.path) or ""):gsub('"', '')
    path = path:gsub("^%s+", ""):gsub("%s+$", "")

    if button == "清除" then
        path = ""
    elseif path == "" then
        show_message("请输入 Python 可执行文件的绝对路径，或点击“清除”删除现有设置。", "路径为空")
        return selection, active_line
    end

    local file, open_error = io.open(SHARED_PYTHON_CONFIG_PATH, "w")
    if not file then
        show_message("无法写入共享 Python 配置文件：\n" .. tostring(open_error), "保存失败")
        return selection, active_line
    end

    file:write(path)
    file:close()

    if path == "" then
        show_message("已清除工具集共用的 Python 路径。", "设置完成")
    else
        show_message("已保存工具集共用的 Python 路径：\n" .. path, "设置完成")
    end

    return selection, active_line
end

local function compile_in_environment(source, chunk_name, environment)
    if type(loadstring) == "function" and type(setfenv) == "function" then
        local chunk, err = loadstring(source, chunk_name)
        if chunk then
            setfenv(chunk, environment)
        end
        return chunk, err
    end

    if type(load) == "function" then
        return load(source, chunk_name, "t", environment)
    end

    return nil, "当前 Lua 环境不支持 loadstring/load。"
end

local function load_embedded_tool(spec)
    local captured = {}
    local proxy = {}

    setmetatable(proxy, {__index = REAL_AEGISUB})
    proxy.register_macro = function(name, description, run, validate)
        captured[#captured + 1] = {
            name = tostring(name or spec.name),
            description = tostring(description or spec.description),
            run = run,
            validate = validate
        }
    end

    local environment = {
        aegisub = proxy
    }
    setmetatable(environment, {__index = _G})
    environment._G = environment

    local chunk, compile_error = compile_in_environment(
        spec.source,
        "@AegisubToolkit/" .. spec.id,
        environment
    )

    if not chunk then
        LOAD_ERRORS[spec.id] = "编译失败：" .. tostring(compile_error)
        CAPTURED[spec.id] = captured
        return
    end

    local ok, runtime_error = pcall(chunk)
    if not ok then
        LOAD_ERRORS[spec.id] = "加载失败：" .. tostring(runtime_error)
    elseif #captured == 0 then
        LOAD_ERRORS[spec.id] = "脚本没有注册任何可调用宏。"
    end

    CAPTURED[spec.id] = captured
end

for _, spec in ipairs(TOOL_SPECS) do
    load_embedded_tool(spec)
end

local function action_display_name(action)
    local name = tostring(action.name or "未命名操作")
    local tail = name:match("([^/]+)$")
    return tail or name
end

local function make_run_wrapper(action)
    return function(subtitles, selection, active_line)
        local first, second = action.run(subtitles, selection, active_line)
        if first ~= nil then
            return first, second
        end
        return selection, active_line
    end
end

local function make_validate_wrapper(action)
    if type(action.validate) ~= "function" then
        return nil
    end

    return function(subtitles, selection, active_line)
        return action.validate(subtitles, selection, active_line)
    end
end

local function register_tool_actions(spec)
    local actions = CAPTURED[spec.id] or {}

    if #actions == 0 then
        -- 加载异常时不注册空入口，避免菜单中出现无法运行的项目。
        return
    end

    for _, action in ipairs(actions) do
        local display_name = action_display_name(action)
        local menu_name = nil

        if spec.id == "fonts_to_english" then
            -- Python 路径由工具集根菜单中的共享设置。
            if display_name == "修改 Python 路径" then
                menu_name = nil
            elseif display_name == "扫描并转换字幕字体" then
                menu_name = ROOT_MENU .. "/中英字体转换"
            else
                menu_name = ROOT_MENU .. "/" .. display_name
            end
        elseif #actions == 1 then
            menu_name = ROOT_MENU .. "/" .. spec.name
        else
            menu_name = ROOT_MENU .. "/" .. spec.name .. "/" .. display_name
        end

        if menu_name then
            REAL_AEGISUB.register_macro(
                menu_name,
                action.description or spec.description,
                make_run_wrapper(action),
                make_validate_wrapper(action)
            )
        end
    end
end

REAL_AEGISUB.register_macro(
    ROOT_MENU .. "/Python 路径设置",
    "配置整个工具集共用的 Python 可执行文件路径。",
    configure_shared_python_path
)

for _, spec in ipairs(TOOL_SPECS) do
    register_tool_actions(spec)
end
