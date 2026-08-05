# mpv-md

在 mpv 里看视频时按一个快捷键，自动截取当前帧，并把「时间戳（H3 标题）+ 截图」以标准 Markdown 追加到 Obsidian 笔记中（走 obsidian-local-rest-api）。同一视频的所有截图自动追加到同一篇视频笔记；没有笔记时按模板自动新建。

> 📖 详细图文使用说明见 [使用说明.md](使用说明.md)

## 功能

- 一键完成：截图 → 上传到 vault 的 assets 目录 → 找到/新建对应视频笔记 → 追加 Markdown 片段
- 片段格式（H3 标题就是可点击的播放定位链接，下一行是截图）：

  ```markdown
  ### [00:12:34](mpv://open?file=C%3A%5Cvideos%5Cdemo.mp4&time=754)

  ![00:12:34](assets/00-12-34_1a2b3c4d.png)
  ```

- 视频笔记自动复用：同一视频（路径+时长指纹）始终追加到同一笔记；不同视频互不串扰
- 新笔记自带 YAML frontmatter 元数据（title/source/source-hash/duration/created/updated/tags/type）
- Windows 下注册 `mpv://` 协议后，在 Obsidian 里点击时间戳链接可重新拉起 mpv 并跳转到对应时间

## 环境要求

- mpv ≥ 0.35
- curl（Windows 需要 OpenSSL/LibreSSL 版，例如 `scoop install curl`；Windows 自带的 schannel 版与 Obsidian 自签证书不兼容，会报 `SEC_E_NO_CREDENTIALS`）
- Obsidian 已安装并启用 [obsidian-local-rest-api](https://github.com/coddingtonbear/obsidian-local-rest-api) 插件
- 平台：Windows 为主支持（`mpv://` 协议注册脚本仅提供 Windows）；脚本本身在 macOS/Linux 也可运行

## 安装

1. 把 `mpv-md.lua` 复制到 mpv 的 scripts 目录：

   - Windows：`%APPDATA%\mpv\scripts\`
   - Linux/macOS：`~/.config/mpv/scripts/`

2. 把 `script-opts/mpv-md.conf` 复制到 mpv 的 script-opts 目录（`%APPDATA%\mpv\script-opts\`），并填写：

   - `obsidian_api_key=`：Obsidian → 设置 → Local REST API → API Key
   - 按需修改 `obsidian_port`、`note_dir`、`asset_dir`、`screenshot_mode`、`key_binding`

3. （可选，Windows）注册 `mpv://` 协议，让笔记里的时间戳链接可以点击跳转：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-mpv-protocol.ps1
   ```

   如果 `mpv` 不在 PATH 中，请设置环境变量 `MPV_MD_MPV_EXE` 指向 `mpv.exe` 的完整路径。

4. 重新打开 mpv（或运行 `load-script mpv-md.lua`），看到 `mpv-md 已加载` 的日志即成功。

## 使用

- 播放视频，按 `Ctrl+Alt+n`（可在配置中修改键位）。
- 每次按键执行：截图（默认带字幕）→ 上传截图 → 追加/新建笔记 → OSD 显示结果。
- 笔记位置：`<vault>/视频笔记/<视频标题>.md`；截图位于 `<vault>/视频笔记/assets/`。
- 同名笔记处理：如果 `<标题>.md` 已存在且 `frontmatter.source` 与当前视频一致，直接追加；如果存在但 source 不匹配（比如手动创建的笔记），会自动使用 `<标题> (2).md`，避免覆盖他人内容。

新笔记模板示例：

```markdown
---
title: "演示视频"
source: "C:\\videos\\demo.mp4"
source-hash: 12345678abcdef01
duration: "01:23:45"
created: "2026-08-05 20:30"
updated: "2026-08-05 20:30"
tags:
  - 视频笔记
type: video-note
---

# 演示视频

### [00:12:34](mpv://open?file=C%3A%5Cvideos%5Cdemo.mp4&time=754)

![00:12:34](assets/00-12-34_1a2b3c4d.png)
```

## 配置项

| 配置 | 默认值 | 说明 |
|------|--------|------|
| `obsidian_host` | `127.0.0.1` | Obsidian Local REST API 地址 |
| `obsidian_port` | `27123` | API 端口 |
| `obsidian_use_https` | `yes` | 插件默认启用 HTTPS |
| `obsidian_api_key` | （空） | 必填，Obsidian → 设置 → Local REST API |
| `obsidian_verify_tls` | `no` | 自签证书，默认跳过校验 |
| `note_dir` | `/视频笔记` | 笔记所在 vault 目录 |
| `asset_dir` | `/视频笔记/assets` | 截图所在 vault 目录（建议放在 note_dir 内） |
| `screenshot_mode` | `subtitles` | `video` 不含字幕 / `subtitles` 含字幕 / `window` 含 OSD |
| `key_binding` | `Ctrl+Alt+n` | 触发快捷键 |
| `max_title_len` | `80` | 笔记标题最大长度 |

## 工作原理

- 脚本运行在 mpv 进程内，通过 mpv 原生 `screenshot-to-file` 截图；
- HTTP 请求用 mpv `subprocess` 调用 curl（官方 mpv 构建不内置 LuaSocket，curl 跨平台且 Windows 自带）；
- 写入 Obsidian 走 local-rest-api：`PUT /vault/...` 建文件、`POST /vault/...` 追加、`PUT application/octet-stream` 传 PNG；
- 视频身份 = 路径+时长 的 FNV-1a 指纹（非加密，仅用于识别）；笔记复用靠 frontmatter 的 `source` 字段判断。

## 常见问题

- **OSD 提示"请先配置 obsidian_api_key"**：按上文步骤 2 填写后重启 mpv。
- **提示"查询笔记失败（HTTP nil）"**：Obsidian 未启动、Local REST API 插件未启用，或端口不一致。可用下面的命令自测（把 key 换成你的 API Key）：

  ```powershell
  curl -k -H "Authorization: Bearer <key>" https://127.0.0.1:27123/vault/
  ```

- **时间戳链接点了没反应**：未注册 `mpv://` 协议，或 `MPV_MD_MPV_EXE` 未设置且 mpv 不在 PATH。
- **提示 `SEC_E_NO_CREDENTIALS`**：Windows 自带 schannel 版 curl 与 Obsidian 自签证书不兼容，运行 `scoop install curl`，再重跑 `install.ps1` 自动配置。
- **截图没有字幕**：`screenshot_mode` 改成 `subtitles`（需要视频有字幕轨道）；不想要字幕改 `video`。
- **截图模式对在线视频无效/失败**：部分流媒体不支持截图，属 mpv 本身限制。

## Roadmap

- 二期：思源笔记适配器（`createDocWithMd` / `appendBlock` / `asset/upload`）
- 二期：OCR 字幕、笔记内点击时间戳回跳的跨平台协议支持
