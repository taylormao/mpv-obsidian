-- mpv-md.lua
-- mpv 视频笔记插件（MVP：Obsidian + obsidian-local-rest-api）
--
-- 功能：
--   1. 一键截取当前帧并生成"时间戳(H3) + 截图"的标准 Markdown 片段
--   2. 通过 Obsidian Local REST API 上传截图并写入/追加到视频笔记
--   3. 按视频身份（路径+时长指纹）自动复用已有笔记，否则按模板新建
--
-- 依赖：mpv >= 0.35、curl、Obsidian 的 Local REST API 插件

local mp = require("mp")
local msg = require("mp.msg")
local options = require("mp.options")
local utils = require("mp.utils")

local opts = {
    backend             = "obsidian",   -- 目标笔记软件（当前仅支持 obsidian）
    curl                = "curl",
    -- Obsidian Local REST API
    obsidian_host       = "127.0.0.1",
    obsidian_port       = 27123,
    obsidian_use_https  = true,
    obsidian_api_key    = "",
    obsidian_verify_tls = false,
    -- vault 内路径（以 / 开头，无结尾斜杠）
    note_dir            = "/视频笔记",
    asset_dir           = "/视频笔记/assets",
    -- 行为
    timestamp_format    = "hms",        -- hms：超 1 小时显示 h:mm:ss，否则 mm:ss
    screenshot_mode     = "subtitles",  -- video | subtitles | window
    key_binding         = "Ctrl+Alt+n",
    max_title_len       = 80,
}
options.read_options(opts, "mpv-md")

if opts.backend ~= "obsidian" then
    msg.warn("当前仅支持 backend=obsidian，已按 obsidian 处理")
    opts.backend = "obsidian"
end

if opts.screenshot_mode ~= "video" and opts.screenshot_mode ~= "window" then
    opts.screenshot_mode = "subtitles"
end
if opts.timestamp_format ~= "mmss" then
    opts.timestamp_format = "hms"
end

----------------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------------

local MOD32 = 4294967296

-- 可移植的 32 位异或（兼容 Lua 5.1 / LuaJIT）
local function bxor32(a, b)
    local result, p = 0, 1
    for _ = 1, 32 do
        if (a % 2) ~= (b % 2) then result = result + p end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        p = p * 2
    end
    return result
end

local function fnv1a32(s)
    local hash = 2166136261
    for i = 1, #s do
        local a = hash % 65536
        local b = math.floor(hash / 65536)
        hash = (a * 403 + (a * 256 + b * 403) * 65536) % MOD32
        hash = bxor32(hash, s:byte(i))
    end
    return hash
end

-- 视频身份指纹：FNV-1a 64 位风格（纯 Lua，无外部依赖；非加密用途）
local function fingerprint(s)
    local h1 = fnv1a32(s)
    local h2 = fnv1a32(s .. ":" .. h1)
    return string.format("%08x%08x", h1, h2)
end

local function urlencode(s)
    s = tostring(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
            or b == 45 or b == 46 or b == 95 or b == 126 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

-- 把 vault 相对路径转成 URL 里的 path（逐段编码，保留 /）
local function encode_vault_path(p)
    p = p:gsub("^/+", ""):gsub("/+$", "")
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        parts[#parts + 1] = urlencode(seg)
    end
    return table.concat(parts, "/")
end

local RESERVED_NAMES = {
    ["con"] = 1, ["prn"] = 1, ["aux"] = 1, ["nul"] = 1,
    ["com1"] = 1, ["com2"] = 1, ["com3"] = 1, ["com4"] = 1,
    ["com5"] = 1, ["com6"] = 1, ["com7"] = 1, ["com8"] = 1, ["com9"] = 1,
    ["lpt1"] = 1, ["lpt2"] = 1, ["lpt3"] = 1, ["lpt4"] = 1,
    ["lpt5"] = 1, ["lpt6"] = 1, ["lpt7"] = 1, ["lpt8"] = 1, ["lpt9"] = 1,
}

local function sanitize_title(s)
    s = tostring(s or "")
    s = s:gsub("[\\/:\"<>|?*%c]", " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then s = "未命名视频" end
    if #s > opts.max_title_len then
        s = s:sub(1, opts.max_title_len):gsub("%s+$", "")
    end
    if RESERVED_NAMES[s:lower()] then s = s .. "_" end
    return s
end

local function format_timestamp(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if opts.timestamp_format == "mmss" then
        local m = math.floor(sec / 60)
        local s = sec % 60
        return string.format("%02d:%02d", m, s)
    end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

-- 临时文件
local tmp_counter = 0
local tmp_files = {}

local function temp_path(ext)
    tmp_counter = tmp_counter + 1
    local base = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    local p = base .. "/mpv-md-" .. os.time() .. "-" .. tmp_counter .. ext
    tmp_files[#tmp_files + 1] = p
    return p
end

local function cleanup_tmp()
    for _, p in ipairs(tmp_files) do
        pcall(os.remove, p)
    end
    tmp_files = {}
end

local function write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(content)
    f:close()
    return true
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

----------------------------------------------------------------------------
-- JSON 转义（写 Obsidian note+json 请求体用）
----------------------------------------------------------------------------

local function json_escape(s)
    s = tostring(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b == 34 then out[#out + 1] = '\\"'
        elseif b == 92 then out[#out + 1] = "\\\\"
        elseif b == 10 then out[#out + 1] = "\\n"
        elseif b == 13 then out[#out + 1] = "\\r"
        elseif b == 9 then out[#out + 1] = "\\t"
        elseif b < 32 then out[#out + 1] = string.format("\\u%04x", b)
        else out[#out + 1] = string.char(b) end
    end
    return '"' .. table.concat(out) .. '"'
end

local function json_content(content)
    return '{"content": ' .. json_escape(content) .. '}'
end

----------------------------------------------------------------------------
-- HTTP（mpv subprocess + curl）
----------------------------------------------------------------------------

local function curl_run(args, cb)
    local full = { opts.curl, "-sS", "--max-time", "30" }
    for _, a in ipairs(args) do full[#full + 1] = a end
    mp.command_native_async({
        name = "subprocess",
        args = full,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res, err)
        if type(res) == "table" then
            cb(res, err)
        else
            cb(nil, err or "subprocess 无返回")
        end
    end)
end

local function obsidian_url(path)
    local scheme = opts.obsidian_use_https and "https" or "http"
    return string.format("%s://%s:%d%s", scheme, opts.obsidian_host, opts.obsidian_port, path)
end

-- req: { body_file, content_type, need_body }
local function obsidian_request(method, api_path, req, cb)
    local out_file = temp_path(".body")
    local args = { "-X", method, "-w", "%{http_code}", "-o", out_file }
    args[#args + 1] = "-H"
    args[#args + 1] = "Authorization: Bearer " .. opts.obsidian_api_key
    if req.content_type then
        args[#args + 1] = "-H"
        args[#args + 1] = "Content-Type: " .. req.content_type
    end
    if req.accept then
        args[#args + 1] = "-H"
        args[#args + 1] = "Accept: " .. req.accept
    end
    if opts.obsidian_use_https and not opts.obsidian_verify_tls then
        args[#args + 1] = "-k"
    end
    if req.body_file then
        args[#args + 1] = "--data-binary"
        args[#args + 1] = "@" .. req.body_file
    end
    args[#args + 1] = obsidian_url(api_path)

    curl_run(args, function(res, err)
        if not res then
            cb(nil, nil, err)
            return
        end
        local code = tonumber((res.stdout or ""):match("%d+"))
        local body = nil
        if req.need_body then body = read_file(out_file) end
        os.remove(out_file)
        local stderr = res.stderr or ""
        cb(code, body, stderr ~= "" and stderr or nil)
    end)
end

----------------------------------------------------------------------------
-- Markdown 模板
----------------------------------------------------------------------------

local function yaml_quote(s)
    s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

local function build_template(media, hash, now)
    return table.concat({
        "---",
        "title: " .. yaml_quote(media.title),
        "source: " .. yaml_quote(media.path),
        "source-hash: " .. hash,
        "duration: " .. yaml_quote(media.duration and format_timestamp(media.duration) or ""),
        "created: " .. yaml_quote(now),
        "updated: " .. yaml_quote(now),
        "tags:",
        "  - 视频笔记",
        "type: video-note",
        "---",
        "",
        "# " .. media.title,
        "",
    }, "\n")
end

local function relative_asset(note_rel, asset_rel)
    local dir = note_rel:match("^(.*)/[^/]+$") or ""
    local prefix = dir .. "/"
    if asset_rel:sub(1, #prefix) == prefix then
        return asset_rel:sub(#prefix + 1)
    end
    return asset_rel
end

local function build_fragment(media, ts_label, ts_seconds, note_rel, asset_rel)
    local uri = "mpv://open?file=" .. urlencode(media.path) .. "&time=" .. tostring(ts_seconds)
    local img = relative_asset(note_rel, asset_rel)
    return "\n### [" .. ts_label .. "](" .. uri .. ")\n\n![" .. ts_label .. "](" .. img .. ")\n"
end

----------------------------------------------------------------------------
-- 视频身份与笔记复用
----------------------------------------------------------------------------

local function unescape_yaml(s)
    s = s:gsub('\\"', '"')
    s = s:gsub("\\\\", "\\")
    return s
end

-- 单遍扫描的 JSON 字符串反转义（避免 \\t 之类的误替换）
local function unescape_json(s)
    local out = {}
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b == 92 then
            local c = s:sub(i + 1, i + 1)
            if c == "n" then out[#out + 1] = "\n"; i = i + 2
            elseif c == "r" then out[#out + 1] = "\r"; i = i + 2
            elseif c == "t" then out[#out + 1] = "\t"; i = i + 2
            elseif c == '"' then out[#out + 1] = '"'; i = i + 2
            elseif c == "\\" then out[#out + 1] = "\\"; i = i + 2
            else out[#out + 1] = "\\"; i = i + 1 end
        else
            out[#out + 1] = string.char(b)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- obsidian-local-rest-api 对 markdown 笔记返回 {"content": "..."}（与 Accept 无关），需先取出并反转义
local function extract_note_content(body)
    local s = tostring(body or "")
    local content = s:match('"content"%s*:%s*"(.-)"%s*[,}]')
    if content then
        return unescape_json(content)
    end
    return s
end

-- 读取已有笔记 frontmatter 中的 source 字段（仅识别插件自己创建的笔记）
local function parse_frontmatter_source(body)
    local s = extract_note_content(body)
    local fm = s:match("^%-%-%-[ \t]*[\r\n](.-)[\r\n]%-%-%-")
    if not fm then return nil end
    local src = fm:match("^source%s*:%s*(.-)[\r\n]")
        or fm:match("[\r\n]source%s*:%s*(.-)[\r\n]")
    if not src then return nil end
    src = src:gsub("^['\"]", ""):gsub("['\"]$", "")
    return unescape_yaml(src)
end

local function resolve_path(p)
    if p:match("^%a+://") then return p end
    if p:match("^[A-Za-z]:[\\/]") or p:match("^/") then return p end
    local cwd = utils.getcwd()
    if cwd then return utils.join_path(cwd, p) end
    return p
end

local VIDEO_EXTS = {
    ".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".ts", ".flv",
    ".wmv", ".mpg", ".mpeg", ".ogv", ".3gp", ".m2ts", ".rmvb",
}

-- 去掉常见视频扩展名，让笔记标题更干净
local function strip_video_ext(title)
    local t = tostring(title or "")
    local low = t:lower()
    for _, ext in ipairs(VIDEO_EXTS) do
        if low:sub(-#ext) == ext then
            return t:sub(1, -#ext - 1)
        end
    end
    return t
end

----------------------------------------------------------------------------
-- 主流程
----------------------------------------------------------------------------

local busy = false

-- 只保留可打印 ASCII，避免 Windows 下 curl 的 GBK 错误文本在 OSD 中乱码
local function ascii_only(s)
    return (tostring(s):gsub("[%c\127-\255]", ""):gsub("[%s%-]+$", ""))
end

local function http_err(code, err)
    local s = tostring(code or "无响应")
    if err and err ~= "" then
        local e = ascii_only(err)
        if e ~= "" then s = s .. " " .. e end
    end
    return s
end

local function fail(msg_text)
    busy = false
    cleanup_tmp()
    msg.error(msg_text)
    mp.osd_message("mpv-md: " .. msg_text, 4)
end

-- Obsidian Local REST API 对 PUT/POST 成功返回 204 No Content
local function is_ok(code)
    return code == 200 or code == 201 or code == 204
end

local function upload_png(asset_enc, shot_path, cb)
    obsidian_request("PUT", "/vault/" .. asset_enc, {
        body_file = shot_path,
        content_type = "application/octet-stream",
    }, function(code, _, err)
        if is_ok(code) then
            cb(true)
        else
            cb(false, "HTTP " .. tostring(code or err or "无响应"))
        end
    end)
end

local function append_fragment(media, ts_label, hash, png_name, note_rel, asset_rel, shot_path)
    local note_enc = encode_vault_path(note_rel)
    local asset_enc = encode_vault_path(asset_rel)
    upload_png(asset_enc, shot_path, function(ok, err)
        if not ok then
            fail("上传截图失败：" .. tostring(err))
            return
        end
        local frag = build_fragment(media, ts_label, math.floor(media.time), note_rel, asset_rel)
        local tmp = temp_path(".md")
        write_file(tmp, frag)
        obsidian_request("POST", "/vault/" .. note_enc, {
            body_file = tmp,
            content_type = "text/markdown",
        }, function(code, _, err)
            os.remove(tmp)
            if is_ok(code) then
                busy = false
                cleanup_tmp()
                msg.info("已追加笔记：" .. note_rel)
                mp.osd_message("mpv-md: 已追加 ✓ " .. note_rel, 3)
            else
                fail("追加失败（HTTP " .. http_err(code, err) .. "）")
            end
        end)
    end)
end

local function create_note(media, hash, ts_label, png_name, note_rel, asset_rel, shot_path)
    local note_enc = encode_vault_path(note_rel)
    local asset_enc = encode_vault_path(asset_rel)
    upload_png(asset_enc, shot_path, function(ok, err)
        if not ok then
            fail("上传截图失败：" .. tostring(err))
            return
        end
        local now = os.date("%Y-%m-%d %H:%M")
        local template = build_template(media, hash, now)
        local frag = build_fragment(media, ts_label, math.floor(media.time), note_rel, asset_rel)
        local tmp = temp_path(".md")
        write_file(tmp, template .. frag)
        obsidian_request("PUT", "/vault/" .. note_enc, {
            body_file = tmp,
            content_type = "text/markdown",
        }, function(code, _, err)
            os.remove(tmp)
            if is_ok(code) then
                busy = false
                cleanup_tmp()
                msg.info("已新建笔记：" .. note_rel)
                mp.osd_message("mpv-md: 已新建笔记 ✓ " .. note_rel, 3)
            else
                fail("新建笔记失败（HTTP " .. http_err(code, err) .. "）")
            end
        end)
    end)
end

local function proceed_with_note(media, hash, ts_label, png_name, shot_path)
    local note_title = sanitize_title(media.title)
    local asset_rel = (opts.asset_dir .. "/" .. png_name):gsub("^/+", "")

    local function lookup(n)
        if n > 50 then
            fail("同名笔记过多，请手动检查 vault")
            return
        end
        local suffix = n > 1 and (" (" .. n .. ")") or ""
        local note_rel = (opts.note_dir .. "/" .. note_title .. suffix .. ".md"):gsub("^/+", "")
    obsidian_request("GET", "/vault/" .. encode_vault_path(note_rel), {
        need_body = true,
        accept = "text/markdown",
    }, function(code, body, err)
            if code == 200 then
                local src = parse_frontmatter_source(body)
                if src == media.path then
                    append_fragment(media, ts_label, hash, png_name, note_rel, asset_rel, shot_path)
                else
                    msg.info("笔记 " .. note_rel .. " 不是本插件的笔记，尝试下一个名称")
                    lookup(n + 1)
                end
            elseif code == 404 then
                create_note(media, hash, ts_label, png_name, note_rel, asset_rel, shot_path)
            else
                fail("查询笔记失败（HTTP " .. http_err(code, err) .. "）")
            end
        end)
    end
    lookup(1)
end

local function on_note_key()
    if busy then
        mp.osd_message("mpv-md: 正在处理，请稍候…", 1.5)
        return
    end
    if opts.obsidian_api_key == "" then
        mp.osd_message("mpv-md: 请先在 script-opts/mpv-md.conf 配置 obsidian_api_key", 4)
        return
    end

    local path = mp.get_property("path")
    if not path or path == "" then
        mp.osd_message("mpv-md: 无法获取视频路径", 2)
        return
    end
    local time_pos = mp.get_property_number("time-pos")
    if not time_pos then
        mp.osd_message("mpv-md: 无法获取当前时间", 2)
        return
    end

    busy = true
    local raw_title = mp.get_property("media-title")
    local fname_noext = mp.get_property("filename/no-ext")
    local media = {
        path = resolve_path(path),
        title = tostring(raw_title or ""),
        duration = mp.get_property_number("duration"),
        time = time_pos,
    }
    if media.title == "" or media.title == tostring(mp.get_property("filename") or "") then
        media.title = fname_noext or media.title or path
    end
    media.title = strip_video_ext(media.title)
    media.title = media.title:gsub("%s+$", "")
    if media.title == "" then media.title = "未命名视频" end

    local hash = fingerprint(media.path .. "|" .. tostring(media.duration or ""))
    -- 标题与链接使用同一取整值，避免显示与跳转相差 1 秒
    media.time = math.floor(time_pos + 0.5)
    local ts_label = format_timestamp(media.time)
    local png_name = ts_label:gsub(":", "-") .. "_" .. hash:sub(1, 8) .. ".png"
    local shot_path = temp_path(".png")

    mp.osd_message("mpv-md: 正在截图…", 1.5)
    mp.command_native_async({ "screenshot-to-file", shot_path, opts.screenshot_mode }, function(success, res)
        local ok = (success == true)
            or (type(res) == "table" and (res.error == "success" or res.status == 0))
        if not ok or not file_exists(shot_path) then
            local err_msg = (type(res) == "table" and tostring(res.error)) or "未知错误"
            fail("截图失败（" .. err_msg .. "）")
            return
        end
        proceed_with_note(media, hash, ts_label, png_name, shot_path)
    end)
end

mp.add_key_binding(opts.key_binding, "mpv-md-append-note", on_note_key)
msg.info("mpv-md 已加载（Obsidian " .. opts.obsidian_host .. ":" .. opts.obsidian_port
    .. "，键位 " .. opts.key_binding .. "）")
