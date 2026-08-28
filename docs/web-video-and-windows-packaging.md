# 网页视频解析与 Windows 安装包方案

## 1. 范围

Windows 发送端允许粘贴普通 HTTP/HTTPS 网页地址，通过独立 `yt-dlp.exe` 解析可由 Android
Media3 直接播放的媒体地址。Android 发送端首版继续支持 HTTP/HTTPS/RTSP 媒体直链，不在
Android 应用内集成 Python 或 yt-dlp。

`.mp4`、`.m3u8`、`.mpd`、常见音频扩展名和 RTSP 地址保持快速路径，不启动外部进程。网页
解析优先选择 H.264 视频轨和 AAC 音频轨，也支持同时含音视频的单路 MP4/HLS。独立音视频轨
不在 Windows 端下载或转码，由接收端 Media3 在同一个播放项内合并并同步播放。

## 2. 安全与资源边界

- yt-dlp 以可替换 sidecar 运行并使用 `--ignore-config`。默认不读取用户配置或浏览器 Cookie；
  用户可在每次添加链接时显式选择 Edge、Chrome 或 Firefox 登录状态。
- 单次解析总超时 45 秒，socket 超时 10 秒，stdout 上限 8 MiB，stderr 上限 256 KiB。
- 应用退出会终止活动解析进程；同一时间只允许一个解析任务。
- 只转发 `User-Agent`、`Referer`、`Origin`、`Accept`、`Accept-Language`。
- Header 最多 5 个，单值最多 2048 字节，总计最多 4096 字节；值必须为无首尾空白的可见
  ASCII，禁止控制字符。
- 浏览器 Cookie 仅由本机 yt-dlp 在解析进程中读取，不持久化，也不进入控制协议。解析结果中的
  `Cookie` 和 `Authorization` 一律过滤；要求 CDN 取流持续携带 Cookie 的站点仍不支持。
- DRM、付费授权、验证码自动绕过和站点主动封禁不支持。

抖音在 Windows 上可能拒绝 yt-dlp 直接解析。此时发送端使用独立的临时 Edge 配置打开抖音
官方页面，并从页面已加载的资源中选择可 Range 读取的 H.264/AAC 分轨；若页面返回明确的
H.264 合并 MP4，也可直接使用。需要安全验证时 Edge 窗口保持可交互，用户完成官方验证后
自动继续；发送端不读取或导出 Cookie，也不绕过验证码。窗口关闭后必须终止临时 Edge 并删除
临时配置目录，清理失败时本次解析按失败处理，后续解析还会清理超过 5 分钟的残留目录。

Edge 页面解析期间会短暂在随机的 IPv4 回环端口启用 DevTools。发送端校验 `/json/version` 的
Edge 身份、页面域名、WebSocket 地址和端口，并只接受 `douyinvod.com`、`365yg.com` 及其子域的 HTTPS 媒体 URL；
解析完成后立即关闭端口。本机高权限或恶意进程仍可能在这段时间访问无鉴权的 DevTools 端口，
这是 Chromium 远程调试机制的残余风险，因此临时浏览器不应用于登录账号或访问其他页面。

解析后的地址可能带短期签名。发送端本地保存原网页地址和解析时间；超过 10 分钟后再次选择
该列表项时自动重新解析。原网页地址和解析时间不发送给接收端。

## 3. 播放与缓存

接收端为每条轨道创建独立的 URL、请求 Header 和 MediaSource；分离音视频通过
`MergingMediaSource` 合并。HTTP progressive、HLS 和 DASH 经过接收端有界磁盘缓存；网页
progressive 轨使用基于原网页和轨道角色的稳定 cache key，临时 CDN URL 刷新后仍可复用缓存。
控制连接断开时，已缓存区段仍可继续播放。RTSP 不经过 HTTP 缓存。

## 4. yt-dlp 供应链

仓库不提交二进制。`scripts/prepare-yt-dlp.ps1` 固定下载 yt-dlp `2026.08.19` 的 Windows
独立可执行文件，并校验 GitHub Release 声明的 SHA-256：

```text
66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a
```

可用 `YT_DLP_PATH` 临时指定其他可执行文件。应用依次查找环境变量、主程序同目录、开发仓库
`tools/yt-dlp.exe` 和 `PATH`。

## 5. Windows 安装包

NSIS 安装包包含 Flutter Windows Release 目录和已校验的 `yt-dlp.exe`，提供：

- `Program Files\LAN Media Cast` 安装目录；
- 开始菜单、桌面快捷方式和“应用和功能”卸载项；
- Domain/Private/Public 网络均生效的程序级入站防火墙规则；
- 覆盖安装前关闭旧发送端进程，卸载时移除快捷方式和防火墙规则。

构建命令：

```powershell
.\scripts\build-windows-installer.ps1
```

输出为 `dist\LANMediaCast-Sender-<version>-Setup.exe`。安装包构建需要 Flutter Windows 工具链、
网络访问和 NSIS 3；可通过 `winget install --id NSIS.NSIS` 安装 NSIS。

构建完成后，可在管理员 PowerShell 中执行安装生命周期验证：

```powershell
.\scripts\test-windows-installer-lifecycle.ps1
```

该脚本使用系统临时目录执行静默安装、同版本覆盖升级和卸载，并断言升级不会保留旧运行时文件、
卸载后安装目录不存在。测试会短暂改写全局卸载项、全体用户快捷方式和防火墙规则，因此检测到
任何现有正式安装时会直接拒绝运行；只应在干净的测试机器上执行。测试目录会在运行前打印，
失败时保留现场供检查。

当前开发构建没有配置 Authenticode 代码签名证书，复制到其他机器首次运行时可能出现 Windows
SmartScreen 提示。正式分发前应使用受信任的组织代码签名证书签名安装包和主程序。
