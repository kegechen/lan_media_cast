# LAN Media Cast

<p align="center">
  <img src="receiver_android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="112" alt="LAN Media Cast 图标">
</p>

<p align="center">
  无账号、无云服务的局域网媒体投放工具
</p>

<p align="center">
  <a href="https://github.com/kegechen/lan_media_cast/actions/workflows/ci.yml"><img src="https://github.com/kegechen/lan_media_cast/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/kegechen/lan_media_cast/releases/latest"><img src="https://img.shields.io/github/v/release/kegechen/lan_media_cast" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache-2.0"></a>
</p>

LAN Media Cast 由一个 Android 接收端和一个 Flutter 发送端组成。接收端运行在投影仪、电视或
备用 Android 设备上；发送端运行在 Windows 或 Android 上。设备只在可路由的局域网内通信，
不依赖账号、云端中转或公网穿透。

## 功能

- UDP 自动发现、手动 IP 连接、证书固定 WSS、6 位连接码配对和可信重连。
- Windows/Android 本地视频投放；本地媒体通过 HTTPS Range 流式读取，不整文件载入内存。
- HTTP、HTTPS、HLS、DASH 和 RTSP 网络媒体。
- Windows 网页视频解析，支持粘贴包含其他文案的分享文本并自动提取 URL。
- 抖音页面解析及 H.264 视频、AAC 音频分轨合并播放。
- 持久播放列表、播放控制、跳转、单项循环、列表循环和顺序播放一次。
- 1-9 张照片分块传输、断线续传、单图全屏和多图宫格讲解。
- 接收端有界磁盘缓存；控制连接中断时可继续播放已缓存内容。
- Windows 发送端滚动诊断日志，记录连接、播放列表及媒体 Range 请求；Android 接收端保留连接、
  播放列表、播放和媒体网络错误。两端均脱敏凭据。

屏幕镜像不包含在当前版本内，相关设计仍处于后续阶段。

## 安装

从 [Releases](https://github.com/kegechen/lan_media_cast/releases/latest) 下载对应文件：

| 文件 | 用途 | 最低系统 |
|---|---|---|
| `LANMediaCast-Sender-1.0.1-Setup.exe` | Windows 发送端 | Windows 10 64 位 |
| `LANMediaCast-Sender-1.0.1.apk` | Android 发送端 | Android 8.0 / API 26 |
| `LANMediaCast-Receiver-1.0.1.apk` | Android 接收端 | Android 7.0 / API 24 |

Windows Setup 支持覆盖安装，并为发送端程序添加适用于 Domain、Private 和 Public 网络的入站
防火墙规则。安装包和主程序目前没有 Authenticode 证书，Windows SmartScreen 可能在首次运行时
显示提示。

Android `1.0.0` 是首个使用正式 Release 密钥签名的版本。若设备安装过开发阶段使用 debug 密钥
签名的 APK，需要先卸载旧版本；Android 的签名安全策略不允许不同密钥直接覆盖。

## 使用

1. 在接收设备安装并打开 Receiver APK。
2. 在 Windows 或 Android 打开 Sender。
3. 在设备列表选择接收端；首次连接时输入接收画面上的 6 位连接码。之后自动免码重连；只有接收端
   重装或升级导致证书变化时，发送端会提示确认「重新信任」并要求再输入一次连接码。
4. 添加本地文件、网络地址或网页分享文案，然后选择播放列表项目。

UDP 自动发现只覆盖同一广播域。不同子网之间如已配置双向路由，可使用手动 IP 连接；还必须允许
接收端主动访问发送端动态 HTTPS 媒体端口。

Windows 日志位于 `%LOCALAPPDATA%\LAN Media Cast\logs`，默认保留 3 个文件，每个最多 2 MiB。
发送端右上角的下载按钮可通过已配对的 WSS 连接获取接收端最近的诊断日志，保存为
`receiver-YYYYMMDD-HHMMSS.log`（同一秒内重复获取会追加 `-1`、`-2` 后缀），同样只保留最新
3 个；文件夹按钮可直接打开日志目录。接收端日志在内存中最多保留 256 KiB，不需要 ADB，
也不会发送播放控制命令。

## 安全边界

- 控制链路使用安装级证书固定 WSS；首次配对通过 6 位短认证字符串确认设备。
- 可信 token 只在证书与已保存 pin 校验通过后发送；首次信任的连接不交出该凭据。
- 证书指纹不匹配时终止连接并停止自动重连，由用户确认后清除旧凭据并重新配对。
- 本地媒体服务使用独立 TLS 证书、随机 Bearer Token、强 ETag 和 `If-Match`。
- Token、Cookie、证书私钥和完整签名 URL 不写入两端的持久日志。
- 浏览器登录状态只在用户添加网页视频时显式使用，不进入控制协议或持久播放列表。
- DRM、付费授权绕过、验证码绕过和公网中转不在项目范围内。

完整设计见[总体架构](docs/architecture.md)和[通信协议 v1](docs/protocol-v1.md)。

## 项目结构

```text
lan_media_cast/
|-- receiver_android/       # Kotlin / Media3 Android 接收端
|-- sender_flutter/         # Flutter Windows/Android 发送端
|-- protocol/fixtures/      # Dart/Kotlin 共用协议样例
|-- installer/windows/      # NSIS Windows 安装器
|-- scripts/                # PowerShell 检查与构建入口
|-- docs/                   # 需求、架构、协议和验收文档
`-- .github/workflows/      # CI 与 Release 自动打包
```

## 开发环境

- Flutter 3.38.5 stable、Dart 3.10.4 或兼容版本。
- JDK 17、Android SDK Platforms 35 和 36。
- Windows 构建需要 Visual Studio 2022 的 Desktop development with C++ 工作负载。
- Windows 安装包需要 NSIS 3。

不要提交 `local.properties`、SDK 路径、keystore、密码、证书、日志或生成二进制。Gradle wrapper
按项目约定使用腾讯镜像并固定 SHA-256。

## 检查与构建

在 Windows PowerShell 7 中运行：

```powershell
.\scripts\format.ps1
.\scripts\analyze.ps1
.\scripts\test.ps1
.\scripts\build-debug.ps1
.\scripts\build-windows-installer.ps1
```

脚本支持通过 `-Target sender` 或 `-Target receiver` 只处理单端。接收端实机测试使用隔离包：

```powershell
.\scripts\test.ps1 -Target receiver -ConnectedReceiver -DeviceSerial <serial>
```

Android Release 构建必须通过以下环境变量提供同一份长期签名密钥：

```text
ANDROID_KEYSTORE_PATH
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

未提供这些变量时，Gradle 只会生成未签名的 Release APK，不应作为正式版本发布。

## 自动发布

`ci.yml` 在 `main` 和 Pull Request 上运行发送端分析/测试以及接收端单测/lint。
`release.yml` 在推送 `v*` tag 时执行版本一致性检查，构建并签名两个 Android APK，构建 Windows
Setup，生成 SHA-256 清单并发布 GitHub Release。

仓库需要配置四个同名 Android 签名 Secrets：

```text
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

应用版本、内部版本码和 tag 发布规则由 `scripts/check-release-version.ps1` 校验。

## 文档

- [需求基线](docs/requirements.md)
- [总体架构](docs/architecture.md)
- [通信协议 v1](docs/protocol-v1.md)
- [实施计划](docs/implementation-plan.md)
- [验收标准](docs/acceptance.md)
- [网页视频与 Windows 打包](docs/web-video-and-windows-packaging.md)

自动测试覆盖协议、配对、连接恢复、HTTPS Range、播放列表、照片分块和网页解析。真实性能结论仍需
按照[验收标准](docs/acceptance.md)记录设备型号、网络、媒体规格和分位数，不能仅凭构建通过宣称。

## License

本项目使用 [Apache License 2.0](LICENSE)。第三方组件仍遵循各自许可证；Windows 安装包内附
第三方声明。
