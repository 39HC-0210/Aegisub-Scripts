script_name = "字幕逐字逐音节出现"
script_description = "让选中行的字幕按指定的固定时间间隔，逐个字符/汉字显现（打字机效果）"
script_author = "H.Coo"
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
