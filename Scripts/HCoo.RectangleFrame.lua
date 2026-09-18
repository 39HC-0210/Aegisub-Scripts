script_name = "快速添加矩形图框"
script_description = "按绝对坐标、文字边界或矩形 clip 快速创建 ASS 矩形图框。"
script_author = "H.Coo"
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
