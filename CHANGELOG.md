# Changelog

## 1.0.0 - 2026-08-29

首个稳定版本。

### 功能

- Android 接收端与 Windows/Android 发送端。
- 局域网自动发现、手动 IP、连接码配对、证书固定 WSS 和自动重连。
- 本地视频 HTTPS Range 流式投放、持久播放列表和基础播放控制。
- HTTP、HTTPS、HLS、DASH、RTSP 及 Windows 网页视频解析。
- 抖音分享文本 URL 提取、视频解析及 H.264/AAC 分轨播放。
- 照片批量传输、宫格讲解和断线续传。
- 接收端有界磁盘缓存与发送端有界滚动诊断日志。

### 修复与兼容性

- 移除本地媒体客户端总调用超时，避免长视频约 17 秒后停止读取。
- Windows 防火墙规则覆盖 Domain、Private 和 Public 网络。
- 播放列表跨发送端重启恢复，并保留不可用文件提示。
- Windows Setup 支持同路径覆盖安装。

### 已知限制

- 当前版本不包含屏幕镜像。
- Windows 二进制尚未使用 Authenticode 证书签名，首次运行可能触发 SmartScreen。
- UDP 自动发现只覆盖同一广播域；跨子网需要手动 IP 和双向路由。
