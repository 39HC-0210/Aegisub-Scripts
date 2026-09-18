local tr = aegisub.gettext
script_name = tr("将中文字体名转换为英文字体名")
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
