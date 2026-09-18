script_name = "根据两点 clip 快速添加 Move"
script_description = "根据首尾帧的两点矢量 Clip 和当前帧的 Pos，生成 Move。"
script_author = "H.Coo"
script_version = "1.0.0"
script_namespace = "H.Coo.QuickMoveFromClip"

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
