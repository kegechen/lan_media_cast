# LAN Media Cast 实施计划

## 1. 实施原则

- 先建立跨端协议和可重复测试，再连接真实 UI 和播放器。
- 媒体播放 MVP 完成并通过长稳/性能验收后，才进入屏幕镜像阶段。
- 每个阶段都有可独立验证的完成条件，不以“代码已写”作为完成。
- 依赖选择优先稳定、Android 7 可用、低运行时开销和可离线构建。
- 性能优化基于 trace 和 P50/P95 数据，不做没有基线的猜测式优化。

## 2. 技术基线

### 2.1 接收端

- Kotlin、Android Views、minSdk 24。
- AndroidX Media3 ExoPlayer、HLS、DASH、RTSP 和 DataSource cache；RTSP 不接入
  `CacheDataSource`，缓存状态固定为 unsupported。
- Kotlin coroutines + kotlinx.serialization。
- 支持 TLS、API 24 和证书固定所需握手信息的轻量 WSS server；在阶段 1 spike 后锁定版本。
- 图片使用后台 `BitmapFactory` 下采样 + 有界内存缓存，避免引入完整图片框架。
- 网络服务运行于前台 Service，Activity 只负责展示和用户交互。

### 2.2 发送端

- Flutter stable、Dart 3，Android minSdk 26，Windows 10+。
- Provider/ChangeNotifier 管理少量清晰状态；避免为简单状态引入大型框架。
- `dart:io` 实现 UDP、WSS client 和 Windows HTTPS Range server。
- Android 平台插件实现 ContentResolver 随机读取、持久 URI 授权和前台服务。
- 文件选择以流/文件描述符为主，不启用整文件 bytes 读取。

### 2.3 仓库

- `protocol/fixtures` 是跨语言契约事实源。
- Gradle wrapper、Flutter lockfile 和版本目录进入版本控制。
- SDK 路径、签名、构建产物和缓存不进入版本控制。
- PowerShell 脚本统一提供 format/analyze/test/build 入口。

## 3. 阶段 0：工程初始化

工作项：

1. 创建 Kotlin receiver 和 Flutter sender 工程。
2. 固定包名 `com.iflytek.lanmediacast.receiver/sender`。
3. 配置 UTF-8、lint、测试目录、版本号和统一检查脚本。
4. 建立 protocol package、fixtures 目录和 CI 友好的无设备单测入口。
5. 确认 Android SDK、JDK 17、Gradle 和 Flutter 的最小可构建组合。
6. Gradle wrapper 使用仓库规定的腾讯镜像 URL，并固定 `distributionSha256Sum`；校验 wrapper
   下载、离线缓存和 clean build，tracked 文件中不写本机 SDK/JDK 路径。
7. 为两端生成安装级 TLS 身份和平台安全存储抽象；Android network security config 只允许
   用户显式输入的外部 `http://` 来源，本地控制和媒体链路不得降级明文。
8. 建立连接专用证书 pin 抽象：动态 IP 本地链路只接受预期叶证书 DER SHA-256，禁止无条件
   TrustManager/HostnameVerifier/badCertificateCallback，外部 URL 仍走系统 CA 与主机名校验。

完成条件：两个空应用可构建，基础单测通过，仓库无本地 SDK 路径和生成二进制。

## 4. 阶段 1：协议与网络 spike

工作项：

1. Dart/Kotlin 实现协议信封、限制、错误码和 fixtures 测试。
2. 实现 UDP query/unicast response、多网卡去重、`MulticastLock` 生命周期和实际端口公布。
3. 实现 WSS 单活动连接、接收端随机码配对、证书 pin、busy、trusted token、心跳和超时。
4. 实现 session 作用域 sequence、最多 256 项/最长 60 秒的命令幂等窗口和重连对账。
5. 验证候选 WSS server 在 API 24、网络切换和前台 Service 中的稳定性。
6. 在 Windows Domain/Private/Public 三种配置中分别验证 UDP 查询、入站单播发现回复、WSS
   控制和后续 HTTPS 端口；阻断时给出诊断并验证手动 IP 降级。
7. 实现状态快照、mode state 和 reconnect revision 协商。
8. 契约测试覆盖首次连接码、可信重连、接收端重装新证书、伪造证书和 pin 不匹配时在发送
   trustedToken 前失败。

完成条件：Windows/Android sender 均能发现并连接 receiver；错误配对、证书不匹配、忙碌、
断线和重连有确定测试；协议 fuzz/超限消息不会导致崩溃或大内存分配。

## 5. 阶段 2：接收端播放内核

工作项：

1. Media3 播放器、MediaSource adapters 和 Texture/Surface 生命周期。
2. `PlaybackCoordinator` 状态机和串行命令队列。
3. 音量、静音、seek、上一项/下一项和三种 repeat mode。
4. 视频/照片动态统一存储预算、256/320 MiB 启停迟滞、模式相关回收优先级、LRU、内容版本
   cache key、保护项和 cache range 状态；RTSP/直播上报 unsupported。
5. 沉浸式、常亮、网络监听、顶部横幅和等待页。
6. 硬解能力探测，向发送端报告 H.264/H.265、分辨率和 profile 能力。
7. 自定义 Media3 `LoadErrorHandlingPolicy` 区分网络暂态、资源暂态、资源永久和解码永久；
   并发 503 遵守 Retry-After，API 24 公共 CA 错误单独诊断。
8. 本地媒体使用支持连接级 TLS pin 的 OkHttpDataSource（或等价实现），并按 item 通过
   ResolvingDataSource/DataSpec 注入 If-Match；禁止共享 Factory 默认 ETag Header。

完成条件：使用测试 HTTPS server 可完成不同 ETag 多项/预取、缓存续播、断线 loading、恢复
续播和 8 小时循环；媒体证书 pin 不匹配必定停止读取；1080p H.264/AAC 达到需求指标。

## 6. 阶段 3：发送端快速播放

工作项：

1. 设备列表、上次设备置顶、配对、手动 IP 和自动重连 UI。
2. 播放列表添加、排序、删除、持久化和当前状态回显。
3. Windows/Android 流式 HTTPS Range server，含安装级证书、HEAD、三种单 Range、强 ETag、
   If-Match、授权、503 + Retry-After、并发限制和背压。
4. Android ContentResolver Range adapter；不可 seek 来源使用明确降级交互。
5. 外部 URL 输入、scheme/capability 校验和错误提示。
6. Windows Domain/Private/Public 防火墙首次授权说明、程序级最小范围安装器规则和
   UDP 单播回复诊断。
7. 媒体服务重启时 generation/token/端口原子轮换，接收端重新 HEAD 并从原位置恢复；
   伪造媒体证书必须在发送 Authorization 前失败。

完成条件：本地 4 GiB+ 视频无需预复制即可起播、seek 和循环；Android/Windows 不出现整文件
内存读取；播放器状态和错误与接收端一致。

## 7. 阶段 4：照片讲解

工作项：

1. Android 拍照/相册、Windows 文件选择、裁剪/旋转/删除。
2. 图片尺寸计算、后台压缩、方向处理和内容摘要。
3. batch start 占位、typed batch/item ready response、item failed 汇总、update
   removedPhotoIds、32-byte chunk 头、ack、complete/cancel。
4. 接收端临时文件、摘要校验、原子完成、loading 槽位和清理。
5. 单图全屏、多图宫格、放大、切图、缩放、`mode.set/mode.state` 和媒体上下文恢复。
6. 512 MiB/最近 5 批配额、临时文件计入、当前批次保护和启动回收。
7. 设备级 batch/transfer 标识、10 分钟跨会话保留、批次重建、resume query/state/status；
   发送端按单照片串行传输，每 32 chunks/2 MiB 等待累计 ACK。
8. 二进制 contract fixtures 覆盖 fresh/resume/重复/跳号 index、取消后的 tombstone 尾包、
   重复帧 ACK/停滞边界、未 ready ID、`protocol.error` 信封、结构损坏头部和滥用限速。

完成条件：1-9 张照片任意单项失败不会造成永久 loading；断线后已收照片保留，恢复后可续传；
大图不会按原尺寸全部解码导致 OOM。

## 8. 阶段 5：韧性与性能

工作项：

1. Wi-Fi/有线/热点切换、IP 变化、发送端休眠/唤醒和应用切后台。
2. 缓存满、磁盘不足、源文件删除/变化、URL 失效和不支持编码。
3. 有界重试、队列、buffer 和文件句柄生命周期审计。
4. 性能埋点：发现、连接、首帧、seek、切换、吞吐、解码掉帧、CPU、内存和温度。
5. 低配 API 24 投影仪及主流 Windows/Android 发送设备矩阵测试。
6. 8/24 小时长稳和网络故障注入。

完成条件：`docs/acceptance.md` 的媒体 MVP 条目全部通过并形成可复查性能报告。

## 9. 阶段 6：屏幕镜像

前置条件：阶段 5 通过，媒体播放发布候选稳定。

工作项：

1. 从参考项目抽取最小 Android MediaProjection/MediaCodec 能力。
2. 抽取 Windows DXGI Desktop Duplication/Media Foundation 能力。
3. 定义 H.264/AAC frame protocol、无序低重传媒体通道和 WS fallback。
4. Android receiver MediaCodec 解码、音频播放、Surface 和模式切换。
5. 背压、主动丢帧、关键帧请求、带宽反馈和方向/分辨率协商。
6. 1080p30、端到端 <=150 ms 的实机验收。

完成条件：镜像与媒体/照片模式反复切换无资源泄漏；Windows/Android 发送端均达到目标。

## 10. 验证命令规划

工程生成后提供以下脚本，内部只调用项目工具，不写本机绝对路径：

```powershell
.\scripts\format.ps1
.\scripts\analyze.ps1
.\scripts\test.ps1
.\scripts\build-debug.ps1
```

每个脚本有明确超时、透传退出码，并支持仅检查单端。构建适配通过命令行参数或进程环境提供，
不得改写 tracked Gradle/SDK/Qt 配置。

## 11. 风险与前置验证

| 风险 | 验证/缓解 |
|---|---|
| Android URI 不可随机读取 | 阶段 3 先做 ContentResolver seek spike；明确可复制降级 |
| Windows 防火墙阻止发现/控制/媒体 | Domain/Private/Public 分别验证 UDP 单播回复、WSS、HTTPS；安装器最小范围规则和手动 IP 降级 |
| 投影仪硬解能力虚报 | 实际 configure/decode 探针 + 能力降级，不只读 codec list |
| 定制 ROM 杀后台 Service | 前台服务、白名单指导、Activity 前台保活和设备矩阵 |
| API 29+ 禁止后台拉起 Activity | 开机只保证前台服务；能力探测、常驻通知和设备策略路径分别验收 |
| Cache 索引损坏/磁盘满 | 原子元数据、启动校验、保留安全余量、可清缓存 |
| 文件原路径内容变化命中旧缓存 | assetContentId/强 ETag/If-Match contract test，跨重启验证不混用字节 |
| RTSP 被误接入文件缓存 | 独立 MediaSource 路径，缓存状态固定 unsupported，断网行为单测 |
| 照片临时文件耗尽空间 | 512 MiB 总配额含临时文件、当前批次保护、启动清理和最近 5 批回收 |
| TCP 队头阻塞影响镜像 | 镜像媒体使用无序有限重传通道，WSS 只作降级 |
| URL 源站慢被误判应用慢 | 拆分 DNS/connect/TTFB/decoder/first-frame 指标 |
| 范围支持不规范 | HTTPS contract tests 覆盖 HEAD、开放/闭合/后缀 Range、206/412/416/428/503、If-Match 和断流 |

## 12. 评审与变更控制

本方案完成后使用独立 `cc-review.review_changes` 评审。评审者只给出 findings，不修改文件。
若 verdict 为 `changes_requested`，逐项核实、修复、运行相关检查，并用同一 session ID 调用
`continue_review`；最多 6 轮。只有 verdict 为 `approved` 后才进入阶段 0 实现。
