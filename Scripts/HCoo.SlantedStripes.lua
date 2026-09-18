script_name = "添加倾斜文字条纹"
script_description = "根据所选字幕行中的矩形 clip 生成倾斜条纹文字层。"
script_author = "H.Coo"
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
