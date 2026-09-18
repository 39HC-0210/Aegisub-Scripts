script_name = "删除画外字幕"
script_description = "遍历选中的行，删除绝对坐标（\\pos 或 \\move）超出画面指定距离的行"
script_author = "H.Coo"
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
            {class="label", label="必须是大于或等于 0 的数字。", x=0, y=0, width=4, height=1}
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
