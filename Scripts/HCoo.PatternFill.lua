script_name = "文字内部矢量图案填充"
script_description = "使用 Yutils 将文字转换为矢量遮罩，并在文字内部铺设圆点、方块或自定义 ASS 绘图。"
script_author = "H.Coo"
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
