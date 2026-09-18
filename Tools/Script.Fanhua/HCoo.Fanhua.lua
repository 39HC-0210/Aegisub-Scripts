script_name = "字幕一键繁化 (调用繁化姬)"
script_description = "对字幕进行简单处理，然后调用繁化姬一键繁化（维基繁体化 + 台湾本地化），输出简繁两份字幕"
script_author = "H.Coo"
script_version = "1.0.0"

local PROTOCOL_VERSION = 1

local BTN_SELECT_SAVE = "选择/保存"
local BTN_NEW = "新增"
local BTN_DELETE = "删除"
local BTN_RESET = "重置"
local BTN_START = "开始处理"
local BTN_CANCEL = "取消"

local DEFAULT_PROFILE = "默认"
local UNSAVED_LABEL = "未保存字幕"

local MODULE_FIELDS = {
  { name = "mod_ChineseVariant", key = "ChineseVariant", label = "地区词转换" },
  { name = "mod_Computer",       key = "Computer",       label = "计算机用语" },
  { name = "mod_ProperNoun",     key = "ProperNoun",     label = "专有名词" },
  { name = "mod_Repeat",         key = "Repeat",         label = "重复词修正" },
  { name = "mod_RepeatAutoFix",  key = "RepeatAutoFix",  label = "重复词自动修正" },
  { name = "mod_Unit",           key = "Unit",           label = "单位用语" },
}

local MISC_FIELDS = {
  { name = "clean_aegisub",  label = "清理 Aegisub 杂项", default = true },
  { name = "auto_metadata",  label = "自动整理 Metadata", default = true },
  { name = "auto_comment",   label = "自动切换简繁注释",  default = true },
  { name = "check_iriya",    label = "Iriya 字体检查",    default = true },
  { name = "check_matrix",   label = "YCbCr Matrix 检查", default = true },
  { name = "check_asterisk", label = "{*} 特殊标记检查",  default = true },
  { name = "generate_diff",  label = "生成繁化差异 HTML", default = true },
  { name = "open_diff",      label = "生成后自动打开",    default = true },
}

local TEXT_KEYS = { "chs_suffix", "cht_suffix", "ignore_styles", "custom_replacements" }
local OBSOLETE_ZHCONVERT_KEYS = {
  ignoreTextStyles = true,
  userPostReplace = true,
}

local MODULE_OFF = 0
local MODULE_ON = -1

-- 1. JSON

local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })

local JSON_ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_escape_char(char)
  local mapped = JSON_ESCAPES[char]
  if mapped then return mapped end
  return string.format("\\u%04x", string.byte(char))
end

local function json_encode_string(value)
  return '"' .. value:gsub('[%z\1-\31"\\]', json_escape_char) .. '"'
end

local function json_is_array(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then return false end
    count = count + 1
  end
  -- 空表按对象编码；插件不会发送空数组。
  if count == 0 then return false end
  return count == #value
end

local function json_encode_number(value)
  if value ~= value or value == math.huge or value == -math.huge then return "null" end
  if value == math.floor(value) and math.abs(value) < 1e15 then
    return string.format("%d", value)
  end
  return string.format("%.14g", value)
end

local json_encode_value

local function json_encode_table(value)
  local buffer = {}
  if json_is_array(value) then
    for index = 1, #value do buffer[#buffer + 1] = json_encode_value(value[index]) end
    return "[" .. table.concat(buffer, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local item = value[key]
    if item == nil then item = value[tonumber(key)] end
    buffer[#buffer + 1] = json_encode_string(key) .. ":" .. json_encode_value(item)
  end
  return "{" .. table.concat(buffer, ",") .. "}"
end

json_encode_value = function(value)
  if value == nil or value == json.null then return "null" end
  local kind = type(value)
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return json_encode_number(value) end
  if kind == "string" then return json_encode_string(value) end
  if kind == "table" then return json_encode_table(value) end
  return "null"
end

function json.encode(value)
  return json_encode_value(value)
end

local function json_skip_space(text, index)
  local _, stop = text:find("^[ \t\r\n]*", index)
  return stop + 1
end

local function json_decode_error(index, message)
  error(string.format("JSON 解析失败（位置 %d）：%s", index, message), 0)
end

local JSON_UNESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
  n = "\n", r = "\r", t = "\t",
}

local function json_utf8_char(point)
  if point < 0x80 then
    return string.char(point)
  elseif point < 0x800 then
    return string.char(0xC0 + math.floor(point / 0x40), 0x80 + point % 0x40)
  elseif point < 0x10000 then
    return string.char(0xE0 + math.floor(point / 0x1000),
      0x80 + math.floor(point / 0x40) % 0x40, 0x80 + point % 0x40)
  end
  return string.char(0xF0 + math.floor(point / 0x40000),
    0x80 + math.floor(point / 0x1000) % 0x40,
    0x80 + math.floor(point / 0x40) % 0x40, 0x80 + point % 0x40)
end

local function json_decode_string(text, index)
  local buffer = {}
  index = index + 1
  while true do
    local char = text:sub(index, index)
    if char == "" then json_decode_error(index, "字符串未闭合") end
    if char == '"' then return table.concat(buffer), index + 1 end
    if char == "\\" then
      local escape = text:sub(index + 1, index + 1)
      if escape == "u" then
        local code = tonumber(text:sub(index + 2, index + 5), 16)
        if not code then json_decode_error(index, "非法的 \\u 转义") end
        index = index + 6
        if code >= 0xD800 and code <= 0xDBFF and text:sub(index, index + 1) == "\\u" then
          local low = tonumber(text:sub(index + 2, index + 5), 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            index = index + 6
          end
        end
        buffer[#buffer + 1] = json_utf8_char(code)
      else
        local mapped = JSON_UNESCAPES[escape]
        if not mapped then json_decode_error(index, "非法的转义 \\" .. escape) end
        buffer[#buffer + 1] = mapped
        index = index + 2
      end
    else
      buffer[#buffer + 1] = char
      index = index + 1
    end
  end
end

local function json_decode_number(text, index)
  local _, stop = text:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", index)
  if not stop then json_decode_error(index, "非法数字") end
  local value = tonumber(text:sub(index, stop))
  if not value then json_decode_error(index, "非法数字") end
  return value, stop + 1
end

local json_decode_value

local function json_decode_array(text, index)
  local result = {}
  index = json_skip_space(text, index + 1)
  if text:sub(index, index) == "]" then return result, index + 1 end
  while true do
    local value
    value, index = json_decode_value(text, index)
    result[#result + 1] = value
    index = json_skip_space(text, index)
    local char = text:sub(index, index)
    if char == "," then
      index = json_skip_space(text, index + 1)
    elseif char == "]" then
      return result, index + 1
    else
      json_decode_error(index, "数组缺少 , 或 ]")
    end
  end
end

local function json_decode_object(text, index)
  local result = {}
  index = json_skip_space(text, index + 1)
  if text:sub(index, index) == "}" then return result, index + 1 end
  while true do
    if text:sub(index, index) ~= '"' then
      json_decode_error(index, "对象的键必须是字符串")
    end
    local key
    key, index = json_decode_string(text, index)
    index = json_skip_space(text, index)
    if text:sub(index, index) ~= ":" then
      json_decode_error(index, "对象的键后面缺少 :")
    end
    index = json_skip_space(text, index + 1)
    local value
    value, index = json_decode_value(text, index)
    result[key] = value
    index = json_skip_space(text, index)
    local char = text:sub(index, index)
    if char == "," then
      index = json_skip_space(text, index + 1)
    elseif char == "}" then
      return result, index + 1
    else
      json_decode_error(index, "对象缺少 , 或 }")
    end
  end
end

json_decode_value = function(text, index)
  index = json_skip_space(text, index)
  local char = text:sub(index, index)
  if char == "" then json_decode_error(index, "内容意外结束") end
  if char == '"' then return json_decode_string(text, index) end
  if char == "{" then return json_decode_object(text, index) end
  if char == "[" then return json_decode_array(text, index) end
  if text:sub(index, index + 3) == "true" then return true, index + 4 end
  if text:sub(index, index + 4) == "false" then return false, index + 5 end
  if text:sub(index, index + 3) == "null" then return json.null, index + 4 end
  return json_decode_number(text, index)
end

function json.decode(text)
  if type(text) ~= "string" then error("JSON 解析失败：输入不是字符串", 0) end
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  local value, index = json_decode_value(text, 1)
  index = json_skip_space(text, index)
  if index <= #text then
    error(string.format("JSON 解析失败：位置 %d 之后还有多余内容", index), 0)
  end
  return value
end

-- 2. 路径与文件

local paths_cache = nil
local lfs_module = nil
local lfs_probed = false

local function decode_path(token)
  local ok, value = pcall(aegisub.decode_path, token)
  if ok and type(value) == "string" and value ~= token and value ~= "" then
    return value
  end
  return nil
end

local function resolve_install_dirs(script_dir)
  script_dir = tostring(script_dir or "."):gsub("\\", "/"):gsub("/+$", "")
  local automation_dir = script_dir:match("^(.*)/[^/]*$") or script_dir
  -- 安装时附属文件在 autoload/fanhua；源码测试时与本文件同目录。
  local fanhua_dir = script_dir
  if script_dir:lower():match("/autoload$") then
    fanhua_dir = script_dir .. "/fanhua"
  end
  return automation_dir, fanhua_dir
end

local function get_plugin_paths()
  if paths_cache then return paths_cache end
  local source = debug.getinfo(1, "S").source or ""
  local script_path = source:gsub("^@", ""):gsub("\\", "/")
  local script_dir = script_path:match("^(.*)/[^/]*$") or "."
  local automation_dir, fanhua_dir = resolve_install_dirs(script_dir)
  local user_dir = decode_path("?user") or decode_path("?data") or "."
  local paths = {
    script_file = script_path,
    script_dir = script_dir,
    automation_dir = automation_dir,
    fanhua_dir = fanhua_dir,
    user_dir = user_dir,
    config_dir = user_dir .. "/fanhua/configs",
    log_dir = user_dir .. "/fanhua/logs",
    temp_dir = user_dir .. "/fanhua/tmp",
  }
  paths.python = paths.fanhua_dir .. "/python/pythonw.exe"
  paths.python_console = paths.fanhua_dir .. "/python/python.exe"
  paths.backend = paths.fanhua_dir .. "/fanhua.py"
  paths.template = paths.fanhua_dir .. "/_fanhua.yml"
  paths.iriya = paths.fanhua_dir .. "/iriya.exe"
  paths_cache = paths
  return paths
end

local function get_lfs()
  if lfs_probed then return lfs_module end
  lfs_probed = true
  if type(lfs) == "table" and type(lfs.dir) == "function" then
    lfs_module = lfs
    return lfs_module
  end
  local ok, module = pcall(require, "lfs")
  if ok and type(module) == "table" and type(module.dir) == "function" then
    lfs_module = module
    return lfs_module
  end
  ok, module = pcall(require, "aegisub.__lfs_impl")
  if ok and type(module) == "table" and type(module.dir) == "function" then
    lfs_module = module
    return lfs_module
  end
  lfs_module = nil
  return nil
end

local function path_join(...)
  local parts = { ... }
  local result = tostring(parts[1] or "")
  for index = 2, #parts do
    local part = parts[index]
    if part and part ~= "" then
      result = result:gsub("[/\\]+$", "") .. "/" .. tostring(part):gsub("^[/\\]+", "")
    end
  end
  return result
end

local function read_text_file(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local contents = handle:read("*a")
  handle:close()
  if not contents then return nil end
  if contents:sub(1, 3) == "\239\187\191" then contents = contents:sub(4) end
  return contents
end

local function write_text_file(path, contents)
  local handle = io.open(path, "wb")
  if not handle then return false, "无法写入 " .. tostring(path) end
  handle:write(contents)
  handle:close()
  return true
end

local function copy_file(source, target)
  local contents = read_text_file(source)
  if not contents then return false, "无法读取 " .. tostring(source) end
  return write_text_file(target, contents)
end

local function file_exists(path)
  if not path then return false end
  local handle = io.open(path, "rb")
  if handle then handle:close() return true end
  return false
end

local function split_path(path)
  local parts, prefix = {}, ""
  local drive = path:match("^(%a:)[/\\]")
  if drive then prefix = drive .. "/" end
  local rest = path:sub(#prefix + 1)
  for part in rest:gmatch("[^/\\]+") do parts[#parts + 1] = part end
  return prefix, parts
end

local function ensure_directory(path)
  if not path or path == "" then return false end
  local module = get_lfs()
  if module then
    local attributes = module.attributes(path)
    if attributes and attributes.mode == "directory" then return true end
    local prefix, parts = split_path(path)
    local built = prefix
    for _, part in ipairs(parts) do
      built = built .. part
      local mode = module.attributes(built, "mode")
      if not mode then module.mkdir(built) end
      built = built .. "/"
    end
    attributes = module.attributes(path)
    return attributes ~= nil and attributes.mode == "directory"
  end
  -- 无 lfs 时使用系统 mkdir。
  if file_exists(path) then return true end
  os.execute('mkdir "' .. path:gsub('"', "") .. '" 2>nul')
  return true
end

local function list_directory(path)
  local module = get_lfs()
  if not module then return nil end
  local names = {}
  local ok = pcall(function()
    for entry in module.dir(path) do
      if entry ~= "." and entry ~= ".." then names[#names + 1] = entry end
    end
  end)
  if not ok then return nil end
  return names
end

-- 3. UTF-16、参数引用与进程启动

local ffi_module = nil
local ffi_api = nil
local ffi_probed = false

local FFI_DEFINITIONS = [[
typedef struct FanhuaStartupInfo {
  uint32_t cb;
  void* lpReserved;
  void* lpDesktop;
  void* lpTitle;
  uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
  uint16_t wShowWindow;
  uint16_t cbReserved2;
  void* lpReserved2;
  void* hStdInput;
  void* hStdOutput;
  void* hStdError;
} FanhuaStartupInfo;

typedef struct FanhuaProcessInfo {
  void* hProcess;
  void* hThread;
  uint32_t dwProcessId;
  uint32_t dwThreadId;
} FanhuaProcessInfo;

int CreateProcessW(const uint16_t* lpApplicationName, uint16_t* lpCommandLine,
                   void* lpProcessAttributes, void* lpThreadAttributes,
                   int bInheritHandles, uint32_t dwCreationFlags,
                   void* lpEnvironment, const uint16_t* lpCurrentDirectory,
                   FanhuaStartupInfo* lpStartupInfo, FanhuaProcessInfo* lpProcessInformation);
uint32_t WaitForSingleObject(void* hHandle, uint32_t dwMilliseconds);
int GetExitCodeProcess(void* hProcess, uint32_t* lpExitCode);
int TerminateProcess(void* hProcess, uint32_t uExitCode);
int CloseHandle(void* hObject);
int ShellExecuteW(void* hwnd, const uint16_t* lpOperation, const uint16_t* lpFile,
                  const uint16_t* lpParameters, const uint16_t* lpDirectory, int nShowCmd);
]]

local function get_ffi()
  if ffi_probed then return ffi_api end
  ffi_probed = true
  ffi_api = nil
  local ok, module = pcall(require, "ffi")
  if not ok or type(module) ~= "table" then return nil end
  -- 声明可能已由其它脚本定义，重复失败可忽略。
  for _, block in ipairs({
    "typedef struct FanhuaStartupInfo { uint32_t cb; void* lpReserved; void* lpDesktop; void* lpTitle; uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; uint16_t wShowWindow; uint16_t cbReserved2; void* lpReserved2; void* hStdInput; void* hStdOutput; void* hStdError; } FanhuaStartupInfo;",
    "typedef struct FanhuaProcessInfo { void* hProcess; void* hThread; uint32_t dwProcessId; uint32_t dwThreadId; } FanhuaProcessInfo;",
    "int CreateProcessW(const uint16_t*, uint16_t*, void*, void*, int, uint32_t, void*, const uint16_t*, FanhuaStartupInfo*, FanhuaProcessInfo*);",
    "uint32_t WaitForSingleObject(void*, uint32_t);",
    "int GetExitCodeProcess(void*, uint32_t*);",
    "int TerminateProcess(void*, uint32_t);",
    "int CloseHandle(void*);",
    "int ShellExecuteW(void*, const uint16_t*, const uint16_t*, const uint16_t*, const uint16_t*, int);",
  }) do
    pcall(module.cdef, block)
  end
  local kernel_ok, kernel = pcall(module.load, "kernel32")
  if not kernel_ok then return nil end
  local usable = pcall(function()
    return kernel.CreateProcessW ~= nil and kernel.WaitForSingleObject ~= nil
      and kernel.GetExitCodeProcess ~= nil and kernel.CloseHandle ~= nil
      and module.sizeof("FanhuaStartupInfo") > 0
  end)
  if not usable then return nil end
  local shell_ok, shell = pcall(module.load, "shell32")
  ffi_module = module
  ffi_api = {
    kernel = kernel,
    shell = shell_ok and shell or nil,
    startup_size = module.sizeof("FanhuaStartupInfo"),
  }
  return ffi_api
end

-- Win32 调用使用带 NUL 的 UTF-16LE，保证中文路径可用。
local function utf16(value)
  local api = get_ffi()
  if not api then return nil end
  value = tostring(value)
  local units = {}
  local index, length = 1, #value
  while index <= length do
    local first = value:byte(index)
    local code, size
    if first < 0x80 then
      code, size = first, 1
    elseif first < 0xE0 then
      code, size = first % 0x20, 2
    elseif first < 0xF0 then
      code, size = first % 0x10, 3
    else
      code, size = first % 0x08, 4
    end
    for offset = 1, size - 1 do
      local follow = value:byte(index + offset) or 0
      code = code * 0x40 + (follow % 0x40)
    end
    index = index + size
    if code >= 0x10000 then
      local rest = code - 0x10000
      units[#units + 1] = 0xD800 + math.floor(rest / 0x400)
      units[#units + 1] = 0xDC00 + rest % 0x400
    elseif code == 0 then
      units[#units + 1] = 0xFFFD
    else
      units[#units + 1] = code
    end
  end
  local buffer = ffi_module.new("uint16_t[?]", #units + 1)
  for position = 1, #units do buffer[position - 1] = units[position] end
  buffer[#units] = 0
  return buffer
end

-- MSVCRT / CreateProcessW 参数引用规则。
local function quote_arg(value)
  value = tostring(value)
  if value == "" then return '""' end
  if not value:find('[%s"]') then return value end
  local buffer = { '"' }
  local backslashes = 0
  for index = 1, #value do
    local char = value:sub(index, index)
    if char == "\\" then
      backslashes = backslashes + 1
    elseif char == '"' then
      buffer[#buffer + 1] = string.rep("\\", backslashes * 2 + 1) .. '"'
      backslashes = 0
    else
      if backslashes > 0 then
        buffer[#buffer + 1] = string.rep("\\", backslashes)
        backslashes = 0
      end
      buffer[#buffer + 1] = char
    end
  end
  if backslashes > 0 then buffer[#buffer + 1] = string.rep("\\", backslashes * 2) end
  buffer[#buffer + 1] = '"'
  return table.concat(buffer)
end

-- cmd.exe 回退时额外转义元字符。
local function quote_arg_cmd(value)
  value = tostring(value):gsub('"', "")
  value = value:gsub("([&|<>^%%!])", "^%1")
  return '"' .. value .. '"'
end

local CREATE_NO_WINDOW = 0x08000000
local INFINITE_WAIT = 0xFFFFFFFF
local WAIT_TIMEOUT = 0x102

local function run_process_ffi(argv, timeout_ms)
  local api = get_ffi()
  if not api then return nil, "FFI 不可用" end
  local parts = {}
  for index, item in ipairs(argv) do parts[index] = quote_arg(item) end
  local application = utf16(argv[1])
  local command_line = utf16(table.concat(parts, " "))
  if not application or not command_line then return nil, "UTF-16 转换失败" end

  local startup = ffi_module.new("FanhuaStartupInfo")
  startup.cb = api.startup_size
  local info = ffi_module.new("FanhuaProcessInfo")
  local created = api.kernel.CreateProcessW(
    application, command_line, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, startup, info)
  if created == 0 then return nil, "CreateProcessW 失败" end

  local wait = api.kernel.WaitForSingleObject(info.hProcess, timeout_ms or INFINITE_WAIT)
  local timed_out = (wait == WAIT_TIMEOUT)
  if timed_out then pcall(function() api.kernel.TerminateProcess(info.hProcess, 1) end) end
  local code = ffi_module.new("uint32_t[1]")
  code[0] = 0
  local got = api.kernel.GetExitCodeProcess(info.hProcess, code)
  pcall(function() api.kernel.CloseHandle(info.hThread) end)
  pcall(function() api.kernel.CloseHandle(info.hProcess) end)
  if timed_out then return nil, "处理超时" end
  if got == 0 then return nil, "GetExitCodeProcess 失败" end
  return tonumber(code[0]), nil
end

local function run_process_shell(argv)
  local parts = {}
  for index, item in ipairs(argv) do parts[index] = quote_arg_cmd(item) end
  local code = os.execute(table.concat(parts, " "))
  if type(code) == "number" then return code end
  return code and 0 or 1
end

local last_launch_method = ""

local function run_process(argv, timeout_ms)
  local code = run_process_ffi(argv, timeout_ms)
  if code ~= nil then
    last_launch_method = "ffi"
    return code
  end
  last_launch_method = "shell"
  return run_process_shell(argv)
end

local function open_in_shell(path)
  local api = get_ffi()
  if api and api.shell then
    local ok, result = pcall(function()
      return api.shell.ShellExecuteW(nil, utf16("open"), utf16(path), nil, nil, 1)
    end)
    local numeric = ok and tonumber(result) or nil
    if numeric and numeric > 32 then return true end
  end
  os.execute('start "" ' .. quote_arg_cmd(path))
  return true
end

-- 4. 当前 ASS
local function get_current_script()
  local directory = decode_path("?script")
  if not directory or directory == "?script" then
    return nil, UNSAVED_LABEL
  end
  local name
  if type(aegisub.file_name) == "function" then
    local ok, value = pcall(aegisub.file_name)
    if ok and type(value) == "string" and value ~= "" then name = value end
  end
  if not name then return nil, UNSAVED_LABEL end
  local separator = "\\"
  if directory:find("/", 1, true) and not directory:find("\\", 1, true) then
    separator = "/"
  end
  if directory:sub(-1) == "/" or directory:sub(-1) == "\\" then separator = "" end
  return directory .. separator .. name, name
end

local function script_not_saved_error()
  return UNSAVED_LABEL
    .. "：当前字幕尚未保存到文件，请先在 Aegisub 中保存 ASS 后再使用繁化姬。"
end

-- 5. Profile

local function normalize_profile(raw)
  raw = type(raw) == "table" and raw or {}
  local misc_raw = type(raw.misc_config) == "table" and raw.misc_config or {}
  local zh_raw = type(raw.zhconvert_config) == "table" and raw.zhconvert_config or {}

  local misc = {}
  for _, field in ipairs(MISC_FIELDS) do
    local value = misc_raw[field.name]
    if value == nil then value = field.default end
    misc[field.name] = value and true or false
  end
  misc.chs_suffix = tostring(misc_raw.chs_suffix or "_CHS")
  misc.cht_suffix = tostring(misc_raw.cht_suffix or "_CHT")
  misc.ignore_styles = tostring(misc_raw.ignore_styles or "")
  misc.custom_replacements = tostring(misc_raw.custom_replacements or "")

  local modules = {}
  if type(zh_raw.modules) == "table" then
    for key, value in pairs(zh_raw.modules) do modules[key] = value end
  end
  if modules["*"] == nil then modules["*"] = MODULE_OFF end

  -- 保留未知键；丢弃已由 GUI 功能取代的旧服务端字段。
  local zh_extra = {}
  for key, value in pairs(zh_raw) do
    if key ~= "modules" and not OBSOLETE_ZHCONVERT_KEYS[key] then
      zh_extra[key] = value
    end
  end

  return {
    profile_version = tonumber(raw.profile_version) or 1,
    misc_config = misc,
    zhconvert_config = zh_extra,
    modules = modules,
  }
end

local function profile_path(name)
  return path_join(get_plugin_paths().config_dir, name .. ".yml")
end

local function resolve_python()
  local paths = get_plugin_paths()
  if file_exists(paths.python) then return paths.python end
  if file_exists(paths.python_console) then return paths.python_console end
  return nil
end

local function read_result_file(path)
  local contents = read_text_file(path)
  if not contents or contents == "" then return nil end
  local ok, value = pcall(json.decode, contents)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function list_profiles()
  local paths = get_plugin_paths()
  local names = list_directory(paths.config_dir)
  if names then
    local result = {}
    for _, entry in ipairs(names) do
      local lower = entry:lower()
      local stem = nil
      if lower:sub(-4) == ".yml" then stem = entry:sub(1, #entry - 4) end
      if lower:sub(-5) == ".yaml" then stem = entry:sub(1, #entry - 5) end
      if stem and stem ~= "" then result[#result + 1] = stem end
    end
    if #result > 0 then
      table.sort(result)
      return result
    end
  end
  -- 无 lfs 或结果为空时交给 Python 枚举 Unicode 路径。
  if file_exists(paths.backend) and resolve_python() then
    local request_path = path_join(paths.temp_dir, "profile-list.json")
    local result_path = path_join(paths.temp_dir, "profile-list.result.json")
    ensure_directory(paths.temp_dir)
    os.remove(result_path)
    write_text_file(request_path, json.encode({
      protocol_version = PROTOCOL_VERSION,
      config_dir = paths.config_dir,
    }))
    run_process({ resolve_python(), paths.backend, "--profile-list", request_path,
      "--result", result_path }, 60000)
    local result = read_result_file(result_path)
    if result and result.success and type(result.profiles) == "table" and #result.profiles > 0 then
      table.sort(result.profiles)
      return result.profiles
    end
  end
  return { DEFAULT_PROFILE }
end

local function ensure_profiles()
  local paths = get_plugin_paths()
  ensure_directory(paths.config_dir)
  ensure_directory(paths.log_dir)
  ensure_directory(paths.temp_dir)
  local target = profile_path(DEFAULT_PROFILE)
  if not file_exists(target) then
    if not file_exists(paths.template) then
      return false, "插件缺少默认配置模板：" .. tostring(paths.template)
    end
    local ok, message = copy_file(paths.template, target)
    if not ok then return false, message end
  end
  return true
end

-- YAML 读写统一交给 Python。
local function load_profile(name)
  local paths = get_plugin_paths()
  local python = resolve_python()
  if not python then
    return nil, "找不到插件自带的 Python。\n预期位置：" .. tostring(paths.python)
  end
  if not file_exists(paths.backend) then
    return nil, "找不到后端脚本：" .. tostring(paths.backend)
  end
  local target = profile_path(name)
  if not file_exists(target) then
    return nil, "配置文件不存在：" .. tostring(name) .. ".yml"
  end
  local result_path = path_join(paths.temp_dir, "profile-read.result.json")
  ensure_directory(paths.temp_dir)
  os.remove(result_path)
  run_process({ python, paths.backend, "--profile-read", target,
    "--result", result_path }, 60000)
  local result = read_result_file(result_path)
  if not result then return nil, "读取配置失败：后端没有返回结果文件。" end
  if not result.success then
    return nil, tostring(result.message or "读取配置失败")
  end
  return normalize_profile(result.profile), nil, result.warnings
end

local function save_profile(name, profile)
  local paths = get_plugin_paths()
  local python = resolve_python()
  if not python then
    return false, "找不到插件自带的 Python。\n预期位置：" .. tostring(paths.python)
  end
  local request_path = path_join(paths.temp_dir, "profile-write.json")
  local result_path = path_join(paths.temp_dir, "profile-write.result.json")
  ensure_directory(paths.temp_dir)
  os.remove(result_path)
  write_text_file(request_path, json.encode({
    protocol_version = PROTOCOL_VERSION,
    profile = profile,
  }))
  run_process({ python, paths.backend, "--profile-write", request_path,
    "--output", profile_path(name), "--result", result_path }, 60000)
  local result = read_result_file(result_path)
  if not result or not result.success then
    return false, result and tostring(result.message or "写入配置失败")
      or "写入配置失败：后端没有返回结果文件。"
  end
  return true
end

local function delete_profile(name)
  if name == DEFAULT_PROFILE then return false, "默认配置不可删除。" end
  local target = profile_path(name)
  if not file_exists(target) then
    return false, "配置文件不存在：" .. tostring(name) .. ".yml"
  end
  local ok, message = os.remove(target)
  if not ok then return false, "删除失败：" .. tostring(message) end
  return true
end

-- 6. Dialog

-- dialog 仅在宏运行期可用；两参数调用可避免平台自动重排自定义按钮。
local function dialog_display(dialog, buttons)
  local override = Fanhua and Fanhua.override_display
  if override then return override(dialog, buttons) end
  return aegisub.dialog.display(dialog, buttons)
end

-- Aegisub 无最小窗口尺寸接口，用 label 内容锚定对话框宽度。
local function display_units(text)
  -- 半角算 1，全角字符算 2。
  local units, index = 0, 1
  local length = #text
  while index <= length do
    local byte = text:byte(index)
    if byte < 0x80 then
      units = units + 1
      index = index + 1
    elseif byte < 0xE0 then
      units = units + 1
      index = index + 2
    elseif byte < 0xF0 then
      units = units + 2
      index = index + 3
    else
      units = units + 2
      index = index + 4
    end
  end
  return units
end

-- 用全角空格补足显示宽度。
local function width_anchor(text, minimum)
  text = tostring(text or "")
  local units = display_units(text)
  if units >= minimum then return text end
  return text .. string.rep("　", math.ceil((minimum - units) / 2))
end

-- 截断超长 Profile 名，避免撑宽窗口。
local function truncate_units(text, maximum)
  text = tostring(text or "")
  if display_units(text) <= maximum then return text end
  local out, units, index = {}, 0, 1
  while index <= #text do
    local byte = text:byte(index)
    local size = 1
    if byte >= 0xF0 then size = 4
    elseif byte >= 0xE0 then size = 3
    elseif byte >= 0xC0 then size = 2 end
    local char = text:sub(index, index + size - 1)
    local char_units = (size >= 3) and 2 or 1
    if units + char_units > maximum - 2 then break end
    out[#out + 1] = char
    units = units + char_units
    index = index + size
  end
  return table.concat(out) .. "…"
end

local DIALOG_WIDTH_UNITS = 118
local SPAN = 6

local function wide_label(text, x, y, span, minimum)
  return {
    class = "label",
    label = width_anchor(text, minimum or DIALOG_WIDTH_UNITS),
    x = x, y = y, width = span,
  }
end

local function module_enabled(modules, key)
  local value = modules and modules[key]
  if value == nil and modules then value = modules["*"] end
  if value == nil then return false end
  local number = tonumber(value)
  return number ~= nil and number ~= 0
end

local function set_module(modules, key, enabled)
  local result = {}
  for name, value in pairs(modules or {}) do result[name] = value end
  result[key] = enabled and MODULE_ON or MODULE_OFF
  return result
end

local function build_dialog(state)
  local dialog = {}
  local row = 0
  local function put(control)
    control.y = row
    dialog[#dialog + 1] = control
  end
  local function newline(count)
    row = row + (count or 1)
  end

  -- 首列拆分后，配置下拉框可紧贴标签。
  put { class = "label", label = "输入与配置", x = 0, width = 5 }
  newline()

  put { class = "label", label = "当前 ASS 字幕", x = 0, width = 2 }
  put { class = "label", label = state.display_name, x = 2, width = 3 }
  newline()

  put { class = "label", label = "简体后缀", x = 0, width = 2 }
  put { class = "edit", name = "chs_suffix", value = state.values.chs_suffix or "", x = 2 }
  put { class = "label", label = "繁体后缀", x = 3 }
  put { class = "edit", name = "cht_suffix", value = state.values.cht_suffix or "", x = 4 }
  newline()

  put { class = "label", label = "忽略样式名", x = 0, width = 3 }
  put { class = "label", label = "自定义替换规则", x = 3, width = 2 }
  newline()
  put { class = "label", label = "每行一个 Style Name（精确匹配）", x = 0, width = 3 }
  put { class = "label", label = "每行一条：原文=替换后", x = 3, width = 2 }
  newline()

  put { class = "textbox", name = "ignore_styles",
        text = state.values.ignore_styles or "", x = 0, width = 3, height = 6 }
  put { class = "textbox", name = "custom_replacements",
        text = state.values.custom_replacements or "", x = 3, width = 2, height = 6 }
  newline(6)

  put { class = "label", label = "预设", x = 0, width = 5 }
  newline()
  put { class = "label", label = "繁化姬模块", x = 0, width = 5 }
  newline()
  for index, field in ipairs(MODULE_FIELDS) do
    put { class = "checkbox", name = field.name, label = field.label,
          value = module_enabled(state.modules, field.key),
          x = ((index - 1) % 3 == 0) and 0 or ((index - 1) % 3 + 1),
          width = ((index - 1) % 3 == 0) and 2 or 1 }
    if index % 3 == 0 then newline() end
  end
  if #MODULE_FIELDS % 3 ~= 0 then newline() end

  local groups = {
    { title = "字幕处理", first = 1, last = 3 },
    { title = "字幕检查", first = 4, last = 6 },
    { title = "Diff 报告", first = 7, last = 8 },
  }
  for _, group in ipairs(groups) do
    put { class = "label", label = group.title, x = 0, width = 5 }
    newline()
    for index = group.first, group.last do
      local field = MISC_FIELDS[index]
      local column = index - group.first
      put { class = "checkbox", name = field.name, label = field.label,
            value = state.values[field.name] and true or false,
            x = (column == 0) and 0 or (column + 1),
            width = (column == 0) and 2 or 1 }
    end
    newline()
  end

  -- 第 0 列仅放配置标签，整行左对齐。
  put { class = "label", label = "配置文件", x = 0 }
  put { class = "dropdown", name = "profile", items = state.profiles,
        value = state.profile_name, x = 1, width = 2 }
  put { class = "label", label = state.profile_hint, x = 3 }

  return dialog
end

local function collect_values(state, dialog, result)
  local values = {}
  for _, control in ipairs(dialog) do
    if control.name then
      local value = result and result[control.name]
      if value == nil then
        if control.class == "checkbox" then
          value = control.value and true or false
        elseif control.class == "textbox" then
          value = control.text or ""
        else
          value = control.value or ""
        end
      end
      if control.class == "checkbox" then value = value and true or false end
      values[control.name] = value
    end
  end
  return values
end

local function profile_from_values(state, values)
  local misc = {}
  misc.chs_suffix = tostring(values.chs_suffix or "")
  misc.cht_suffix = tostring(values.cht_suffix or "")
  misc.ignore_styles = tostring(values.ignore_styles or "")
  misc.custom_replacements = tostring(values.custom_replacements or "")
  for _, field in ipairs(MISC_FIELDS) do
    misc[field.name] = values[field.name] and true or false
  end

  local modules = state.modules
  for _, field in ipairs(MODULE_FIELDS) do
    modules = set_module(modules, field.key, values[field.name] and true or false)
  end

  local zh = {}
  for key, value in pairs(state.zhconvert_extra or {}) do zh[key] = value end
  zh.modules = modules

  return {
    profile_version = 1,
    misc_config = misc,
    zhconvert_config = zh,
  }
end

local function profile_values(profile)
  local values = {}
  local misc = profile.misc_config or {}
  for _, key in ipairs(TEXT_KEYS) do
    values[key] = misc[key] or ""
  end
  for _, field in ipairs(MISC_FIELDS) do
    values[field.name] = misc[field.name] and true or false
  end
  return values
end

local function values_equal(left, right)
  for _, field in ipairs(MISC_FIELDS) do
    if (left[field.name] and true or false) ~= (right[field.name] and true or false) then
      return false
    end
  end
  for _, key in ipairs(TEXT_KEYS) do
    if (left[key] or "") ~= (right[key] or "") then return false end
  end
  return true
end

local function load_state_profile(state, name)
  local profile, message = load_profile(name)
  if not profile then return false, message end
  state.profile_name = name
  state.profile = profile
  state.values = profile_values(profile)
  state.loaded_values = {}
  for key, value in pairs(state.values) do state.loaded_values[key] = value end
  state.modules = profile.modules
  state.zhconvert_extra = profile.zhconvert_config
  return true
end

local function refresh_hint(state)
  if not state.loaded_values then state.loaded_values = {} end
  local modified = not values_equal(state.values, state.loaded_values)
  state.profile_hint = truncate_units(
    "当前配置：" .. tostring(state.profile_name)
    .. (modified and "（已修改）" or ""), 36)
end

-- 7. 后端调用与结果展示

local function backend_error_message(stage, message, detail, traceback_text)
  local lines = { "繁化失败", "", "阶段：" .. tostring(stage or "未知") }
  if message and message ~= "" then lines[#lines + 1] = "原因：" .. tostring(message) end
  if detail and detail ~= "" then lines[#lines + 1] = "详情：" .. tostring(detail) end
  if traceback_text and traceback_text ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "详细错误："
    lines[#lines + 1] = tostring(traceback_text)
  end
  return table.concat(lines, "\n")
end

local function show_message(title, body, buttons)
  local dialog = {
    wide_label(title, 0, 0, SPAN, DIALOG_WIDTH_UNITS),
    { class = "textbox", name = "body", text = body, x = 0, y = 1,
      width = SPAN, height = 14 },
  }
  return dialog_display(dialog, buttons or { "关闭" })
end

local function confirm(title, body)
  local button = dialog_display({
    wide_label(title, 0, 0, SPAN, DIALOG_WIDTH_UNITS),
    { class = "textbox", name = "body", text = body, x = 0, y = 1,
      width = SPAN, height = 8 },
  }, { "确定", BTN_CANCEL })
  return button == "确定"
end

local function prompt_text(title, label, default)
  local button, result = dialog_display({
    wide_label(title, 0, 0, SPAN, DIALOG_WIDTH_UNITS),
    { class = "label", label = label, x = 0, y = 1 },
    { class = "edit", name = "value", value = default or "", x = 1, y = 1 },
  }, { "确定", BTN_CANCEL })
  if button ~= "确定" then return nil end
  return (result and result.value) or ""
end

local CHECK_LABELS = {
  matrix = "YCbCr Matrix",
  asterisk = "特殊标记",
  iriya = "Iriya",
}

local function check_line(warnings, key)
  local label = CHECK_LABELS[key] or key
  local entry = warnings and warnings[key]
  if type(entry) ~= "table" then return label .. "：⚠ 未执行" end
  if entry.skipped then return label .. "：— 已跳过" end
  if entry.ok then return label .. "：✓ 正常" end
  if key == "iriya" and type(entry.missing_fonts) == "table"
    and #entry.missing_fonts > 0 then
    return label .. "：⚠ 缺少 " .. tostring(#entry.missing_fonts) .. " 个字体"
  end
  local message = entry.message
  if not message or message == "" then message = "发现问题" end
  return label .. "：⚠ " .. tostring(message)
end

local function show_result(result)
  local names = result.output_names or {}
  local warnings = result.warnings or {}
  local lines = { "处理完成", "" }
  lines[#lines + 1] = "CHS：" .. tostring(names.chs or "")
  lines[#lines + 1] = "CHT：" .. tostring(names.cht or "")
  lines[#lines + 1] = "Diff：" .. ((names.diff and names.diff ~= "") and names.diff or "（未生成）")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "检查："
  lines[#lines + 1] = check_line(warnings, "iriya")
  local iriya = warnings.iriya
  if type(iriya) == "table" and type(iriya.missing_fonts) == "table"
    and #iriya.missing_fonts > 0 then
    lines[#lines + 1] = "缺失字体："
    for index = 1, #iriya.missing_fonts, 2 do
      local row = tostring(iriya.missing_fonts[index])
      if iriya.missing_fonts[index + 1] ~= nil then
        row = row .. "；" .. tostring(iriya.missing_fonts[index + 1])
      end
      lines[#lines + 1] = row
    end
  end
  lines[#lines + 1] = check_line(warnings, "matrix")
  lines[#lines + 1] = check_line(warnings, "asterisk")

  local stats = result.stats or {}
  if stats.diff_blocks then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "差异块：%s　修改：%s　删除：%s　新增：%s",
      tostring(stats.diff_blocks), tostring(stats.changed_rows),
      tostring(stats.deleted_rows), tostring(stats.added_rows))
  end

  local warning_lines = {}
  for _, key in ipairs({ "config", "zhconvert", "iriya", "matrix", "asterisk" }) do
    local entry = warnings[key]
    if type(entry) == "table" then
      local font_list_shown = key == "iriya" and type(entry.missing_fonts) == "table"
        and #entry.missing_fonts > 0
      if entry.message and entry.message ~= "" and not font_list_shown then
        warning_lines[#warning_lines + 1] = "· " .. tostring(entry.message)
      end
      if type(entry.messages) == "table" then
        for _, message in ipairs(entry.messages) do
          warning_lines[#warning_lines + 1] = "· " .. tostring(message)
        end
      end
      if type(entry.lines) == "table" then
        for _, item in ipairs(entry.lines) do
          if type(item) == "table" then
            warning_lines[#warning_lines + 1] = string.format(
              "· 第 %s 行：%s", tostring(item.line_number), tostring(item.text))
          end
        end
      end
    end
  end
  if #warning_lines > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Warning 摘要："
    for _, line in ipairs(warning_lines) do lines[#lines + 1] = line end
  end

  if result.elapsed then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("耗时：%s 秒　繁化姬请求：%s 次",
      tostring(result.elapsed), tostring(result.zhconvert_requests or "-"))
  end
  if result.log_file and result.log_file ~= "" then
    lines[#lines + 1] = "日志：" .. tostring(result.log_file)
  end

  -- label 锚定宽度，textbox 用于滚动和复制。
  local diff_path = result.outputs and result.outputs.diff or ""
  local buttons = (diff_path ~= "") and { "打开 Diff", "关闭" } or { "关闭" }
  local button = dialog_display({
    wide_label("繁化姬 - 处理结果", 0, 0, SPAN, DIALOG_WIDTH_UNITS),
    { class = "textbox", name = "body", text = table.concat(lines, "\n"),
      x = 0, y = 1, width = SPAN, height = 18 },
  }, buttons)
  if button == "打开 Diff" and diff_path ~= "" then
    open_in_shell(diff_path)
  end
end

local function run_backend(state)
  local paths = get_plugin_paths()
  local python = resolve_python()
  if not python then
    return nil, "找不到插件自带的 Python。\n\n预期位置：" .. tostring(paths.python)
      .. "\n\n请重新完整安装插件（必须包含 fanhua/python/ 目录）。"
  end
  if not file_exists(paths.backend) then
    return nil, "找不到后端脚本：" .. tostring(paths.backend)
  end

  ensure_directory(paths.temp_dir)
  local stamp = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
  local request_path = path_join(paths.temp_dir, "request-" .. stamp .. ".json")
  local result_path = path_join(paths.temp_dir, "result-" .. stamp .. ".json")
  os.remove(result_path)

  local profile = profile_from_values(state, state.values)
  local misc = profile.misc_config
  local request = {
    protocol_version = PROTOCOL_VERSION,
    input_file = state.script_path,
    profile_name = state.profile_name,
    profile = profile,
    log_dir = paths.log_dir,
    chs_suffix = misc.chs_suffix,
    cht_suffix = misc.cht_suffix,
    ignore_styles = misc.ignore_styles,
    custom_replacements = misc.custom_replacements,
    zhconvert_modules = profile.zhconvert_config.modules,
    clean_aegisub = misc.clean_aegisub,
    auto_metadata = misc.auto_metadata,
    auto_comment = misc.auto_comment,
    check_iriya = misc.check_iriya,
    check_matrix = misc.check_matrix,
    check_asterisk = misc.check_asterisk,
    generate_diff = misc.generate_diff,
    open_diff = misc.open_diff,
  }
  local ok, message = write_text_file(request_path, json.encode(request))
  if not ok then return nil, "无法写入请求文件：" .. tostring(message) end

  local code = run_process({ python, paths.backend, "--process", request_path,
    "--result", result_path }, 3600000)

  local result = read_result_file(result_path)
  if not result then
    return nil, "后端没有返回结果（退出码 " .. tostring(code) .. "，启动方式 "
      .. tostring(last_launch_method) .. "）。\n\n"
      .. "请确认 fanhua/python/pythonw.exe 与 fanhua/fanhua.py 完整存在。"
  end
  if result.protocol_version and tonumber(result.protocol_version) ~= PROTOCOL_VERSION then
    return nil, "前后端协议版本不一致：Lua=" .. tostring(PROTOCOL_VERSION)
      .. "，Python=" .. tostring(result.protocol_version) .. "。请重新完整安装插件。"
  end
  return result
end

local function process_current_script(state)
  if not state.script_path then
    show_message("无法开始处理", script_not_saved_error())
    return false
  end
  if not file_exists(state.script_path) then
    show_message("无法开始处理",
      "找不到当前 ASS 文件：\n" .. tostring(state.script_path) .. "\n\n请先保存字幕后再试。")
    return false
  end
  local result, message = run_backend(state)
  if not result then
    show_message("繁化失败", tostring(message))
    return false
  end
  if not result.success then
    show_message("繁化失败", backend_error_message(
      result.stage, result.message, result.detail, result.traceback))
    return false
  end
  show_result(result)
  return true
end

local function new_profile(state, values)
  local name = prompt_text("新增配置", "配置名称：", "")
  if name == nil then return false end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub('[\\/:*?"<>|]', "")
  if name == "" then
    show_message("新增配置", "配置名称不能为空。")
    return false
  end
  if name == DEFAULT_PROFILE then
    show_message("新增配置", "「" .. DEFAULT_PROFILE .. "」已存在，请换一个名称。")
    return false
  end
  if file_exists(profile_path(name)) then
    if not confirm("新增配置", "配置「" .. name .. "」已存在。\n\n确定要覆盖它吗？") then
      return false
    end
  end
  local ok, message = save_profile(name, profile_from_values(state, values))
  if not ok then
    show_message("新增配置失败", tostring(message))
    return false
  end
  local loaded, load_message = load_state_profile(state, name)
  if not loaded then
    show_message("载入新配置失败", tostring(load_message))
    return false
  end
  return true
end

local function delete_current_profile(state, values)
  local name = values.profile or state.profile_name
  if name == DEFAULT_PROFILE then
    show_message("删除配置", "「" .. DEFAULT_PROFILE .. "」是内置默认配置，不可删除。")
    return false
  end
  if not confirm("删除配置", "确定要删除配置「" .. name .. "」吗？\n\n该操作不可撤销。") then
    return false
  end
  local ok, message = delete_profile(name)
  if not ok then
    show_message("删除配置失败", tostring(message))
    return false
  end
  if not load_state_profile(state, DEFAULT_PROFILE) then
    state.profile_name = DEFAULT_PROFILE
  end
  return true
end

local function select_or_save_profile(state, values)
  local target = values.profile or state.profile_name
  if target ~= state.profile_name then
    local ok, message = load_state_profile(state, target)
    return ok, message, "select"
  end

  state.values = values
  local ok, message = save_profile(target, profile_from_values(state, values))
  if not ok then return false, message, "save" end
  ok, message = load_state_profile(state, target)
  return ok, message, "save"
end

-- 8. 主循环

local function dialog_loop(state)
  local values = state.values
  local buttons = { BTN_SELECT_SAVE, BTN_NEW, BTN_DELETE, BTN_RESET, BTN_START, BTN_CANCEL }
  while true do
    refresh_hint(state)
    local dialog = build_dialog(state)
    local button, result = dialog_display(dialog, buttons)
    if not button then return end
    values = collect_values(state, dialog, result)

    if button == BTN_CANCEL then
      return
    elseif button == BTN_START then
      state.values = values
      process_current_script(state)
    elseif button == BTN_SELECT_SAVE then
      local ok, message, action = select_or_save_profile(state, values)
      if not ok then
        local title = (action == "save") and "保存配置失败" or "载入配置失败"
        show_message(title, tostring(message))
      end
    elseif button == BTN_NEW then
      state.values = values
      new_profile(state, values)
    elseif button == BTN_DELETE then
      state.values = values
      delete_current_profile(state, values)
    elseif button == BTN_RESET then
      state.values = values
      local ok, message = load_state_profile(state, state.profile_name)
      if not ok then show_message("重置失败", tostring(message)) end
    else
      state.values = values
    end
    values = state.values

    -- 新增或删除后刷新下拉框。
    local profiles = list_profiles()
    state.profiles = (#profiles > 0) and profiles or { DEFAULT_PROFILE }
    local present = false
    for _, name in ipairs(state.profiles) do
      if name == state.profile_name then present = true end
    end
    if not present then state.profiles[#state.profiles + 1] = state.profile_name end
    if not state.values.profile then state.values.profile = state.profile_name end
  end
end

local function main(subtitles, selected)
  local paths = get_plugin_paths()
  math.randomseed(os.time() % 100000)

  local ok, message = ensure_profiles()
  if not ok then
    show_message("繁化姬初始化失败", tostring(message))
    return
  end

  local script_path, display_name = get_current_script()
  local profiles = list_profiles()
  if #profiles == 0 then profiles = { DEFAULT_PROFILE } end

  local state = {
    script_path = script_path,
    display_name = display_name,
    profiles = profiles,
    profile_name = DEFAULT_PROFILE,
    values = {},
    loaded_values = {},
    modules = {},
    zhconvert_extra = {},
    profile_hint = "",
  }

  local loaded, load_message = load_state_profile(state, DEFAULT_PROFILE)
  if not loaded then
    show_message("繁化姬初始化失败",
      "无法载入默认配置：\n" .. tostring(load_message)
      .. "\n\n配置目录：" .. tostring(paths.config_dir))
    return
  end

  dialog_loop(state)
end

aegisub.register_macro(script_name, script_description, main)

-- 测试接口。
Fanhua = {
  version = script_version,
  protocol_version = PROTOCOL_VERSION,
  json = json,
  quote_arg = quote_arg,
  width_anchor = width_anchor,
  display_units = display_units,
  truncate_units = truncate_units,
  quote_arg_cmd = quote_arg_cmd,
  utf16 = utf16,
  get_plugin_paths = get_plugin_paths,
  resolve_install_dirs = resolve_install_dirs,
  get_current_script = get_current_script,
  ensure_profiles = ensure_profiles,
  list_profiles = list_profiles,
  load_profile = load_profile,
  save_profile = save_profile,
  delete_profile = delete_profile,
  normalize_profile = normalize_profile,
  profile_values = profile_values,
  profile_from_values = profile_from_values,
  values_equal = values_equal,
  module_enabled = module_enabled,
  set_module = set_module,
  build_dialog = build_dialog,
  collect_values = collect_values,
  refresh_hint = refresh_hint,
  load_state_profile = load_state_profile,
  run_process = run_process,
  run_backend = run_backend,
  read_result_file = read_result_file,
  backend_error_message = backend_error_message,
  check_line = check_line,
  show_result = show_result,
  run_backend = run_backend,
  show_message = show_message,
  confirm = confirm,
  prompt_text = prompt_text,
  select_or_save_profile = select_or_save_profile,
  dialog_loop = dialog_loop,
  main = main,
}
