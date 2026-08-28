# LAN Media Cast 总体架构

## 1. 设计结论

系统采用三条职责清晰的局域网通道：

1. UDP 查询/单播响应：只负责设备发现。
2. 证书固定的 WSS：负责会话、控制、状态、照片传输和恢复。
3. 媒体读取通道：本地媒体由发送端 HTTPS Range 服务提供；外部 URL 由接收端直连。

HTTP Range（本地链路使用 HTTPS）是本地文件的内部传输实现，不是产品媒体来源限制。选择它是为了复用 Media3
成熟的随机读取、seek、缓冲和缓存机制，避免自定义 TCP 流重新实现远程文件系统。

## 2. 总体结构

```text
Flutter 发送端                                  Kotlin Android 接收端
+---------------------------+                  +-----------------------------+
| DeviceDiscovery           | -- UDP query --> | DiscoveryResponder          |
| ConnectionController      | <===== WSS =====> | CastSessionServer           |
| PlaylistController        |                  | PlaybackCoordinator         |
| LocalMediaHttpsServer     | <-- HTTPS Range -| Media3 + Bounded Cache      |
| PhotoUploadController     | == WSS chunks => | PhotoExplainCoordinator     |
| MirrorCapture (Phase 2)   | == H264/AAC ===> | MediaCodec (Phase 2)        |
+---------------------------+                  +-----------------------------+
```

## 3. 发送端

### 3.1 Flutter 业务层

- `DeviceDiscovery`：多网卡 UDP 扫描、去重、设备过期和上次设备置顶。
- `ConnectionController`：配对、握手、心跳、单会话状态和自动重连。
- `PlaylistController`：列表编辑、播放模式、revision 和状态合并。
- `PlaybackRemote`：命令请求、超时、幂等重试和状态快照。
- `PhotoUploadController`：图片处理、批次元数据、分块传输、ACK 和取消。
- `MediaSourceRegistry`：把文件、URL 和未来来源统一为版本化 `MediaSource`。

### 3.2 本地媒体服务

- 双向配对和 WSS 会话认证成功后启动或复用会话级 HTTPS 服务，绑定局域网接口和临时端口。
- 路径只包含不透明 `assetId`，不暴露文件系统路径。
- 支持 `GET`、`HEAD`、单区间 `Range`、`206` 和 `416`。
- 使用 256-bit 随机会话令牌；令牌放在 Authorization Header，日志必须脱敏。
- HTTPS 服务使用发送端安装级证书；证书指纹通过已认证 WSS 公布，接收端固定该指纹。
- 本地证书以叶证书 DER SHA-256 精确匹配替代 CA/主机名校验；Dart 回调只能接受预期 pin，
  禁止无条件信任或把此策略复用到外部 URL。
- Windows 使用流式随机文件读取。
- Android 通过 ContentResolver/文件描述符提供随机读取；不可 seek 的来源应明确报错或在用户
  同意后落入有界临时文件，不能静默复制超大视频。
- 响应遵守背压，不预读完整文件；连接断开时及时关闭文件句柄。

### 3.3 平台差异

Flutter 共享 UI、状态机和协议。平台插件仅承载必要能力：

- Android：持久 URI 权限、ContentResolver Range 读取、前台服务和后续 MediaProjection。
- Windows：本地随机文件读取、私有网络防火墙引导和后续 DXGI 捕获。

## 4. 接收端

接收端使用 Kotlin + Android Views，避免在老旧投影仪上引入不必要的 UI 运行时和启动成本。

### 4.1 核心组件

- `CastServerService`：前台服务，持有发现、WSS、连接恢复和网络监听。
- `DiscoveryResponder`：接收查询并从入站网卡单播回复实际控制端口；仅在 Wi-Fi 发现
  生命周期持有 `WifiManager.MulticastLock`，离开前台服务时可靠释放。
- `CastSessionServer`：安装级 TLS 证书、单活动会话、双向配对、协议协商、大小限制和心跳。
- `PlaybackCoordinator`：媒体状态机、列表 revision、模式切换和错误策略。
- `MediaSourceFactory`：本地 Range 使用可注入连接专用 TrustManager/HostnameVerifier 的
  OkHttpDataSource（或等价实现）做精确 pin；外部 HTTP/HTTPS、HLS、DASH、RTSP 保持独立适配。
- `CastCacheManager`：Media3 `SimpleCache`、配额、保护项、LRU 和缓存状态统计。
- `PhotoExplainCoordinator`：批次接收、临时文件、原子完成、宫格和全屏切图。
- `StatusBannerController`：连接/网络/媒体错误横幅，不参与媒体布局测量。

### 4.2 播放状态机

连接状态与播放状态分开建模：

```text
ConnectionState: discovering -> pairing -> connected -> reconnecting -> disconnected

PlaybackState:
  idle ------select/play------> preparing ----first frame----> playing <----> paused
                                  ^   |                           |  ^
                                  |   | load gap                  |  | data recovered
                       retry/repeat   v                           v  |
  error --------retry---------- preparing <----select/next---- buffering
                                  ^                              |
                                  | repeatOne/repeatAll          | permanent error
  completed ---------------------+-------------------------------+----> error
```

`playOnce` 到达 completed 后保持末帧；repeat 模式从 completed 回到 preparing。切换 item 或用户
显式重试时重置永久错误计数，网络型 buffering 恢复不消耗永久错误配额。

连接进入 `reconnecting/disconnected` 时不得直接把播放状态改为 `idle`。只有用户停止、
播放列表被明确清空或当前模式资源被替换时，才释放播放上下文。

### 4.3 业务模式

`media`、`photo`、`mirror` 互斥：

- `media -> photo`：暂停并保存媒体位置，释放不必要的视频渲染资源，显示照片。
- `photo -> media`：恢复列表、位置和进入照片前的播放/暂停意图。
- `media/photo -> mirror`：阶段二才启用，明确释放上一模式的高资源组件。
- 模式切换通过串行调度器执行，避免播放器、Surface 和网络回调并发释放。

## 5. 网络拓扑

### 5.1 端口

- UDP 发现默认端口：39880。
- WSS 首选端口：39881；占用时依次尝试 39882-39890，并在发现响应中公布实际端口。
- 发送端媒体 HTTPS 服务使用系统分配的临时端口，在会话认证后单独公布。

端口是默认值而非设备身份。设备身份使用首次安装生成并持久化的 UUID。

### 5.2 发现

发送端向每个可用局域网接口的定向广播地址发送查询，并以全局广播作为兜底。接收端不做
每秒广播；它根据数据报来源单播回复。发送端以 `deviceId` 去重，并保留同一设备的多个
候选地址，连接时执行有界 Happy Eyeballs 式竞速。

无法获得真实子网掩码时才回退 `/24 -> /16 -> global broadcast`。Android 接收端优先使用
`LinkProperties` 的真实 prefix length，避免在 VLSM 网络上猜测网段。

Windows 发送端需要接收入站 UDP 单播响应并提供入站 HTTPS 媒体服务。阶段 1 就验证 Domain、
Private、Public 三种防火墙配置；安装器使用程序级最小范围规则。策略禁止广播单播响应时，
扫描页必须在超时后给出防火墙诊断和手动 IP 降级，不能只显示空列表。

### 5.3 会话

WSS 使用接收端安装级自签名证书。首次连接时接收端生成随机 6 位连接码并只显示在投影画面，
用户在发送端输入正确号码后自动建立可信关系，投影仪端无需遥控器确认；之后发送端固定接收端
证书指纹，接收端保存发送端可信 token。可信重连必须同时满足证书 pin 和 token。由于连接使用
动态 IPv4，本地链路明确以当前叶证书 DER 摘要精确匹配替代 CA/主机名校验，禁止无条件
HostnameVerifier 或应用级信任所有证书。

会话认证完成前不公布媒体端点或 bearer token。接收端只提升一个连接为活动会话；其他连接
收到 `receiver_busy` 后关闭。心跳只判断控制链路，不控制缓存播放。

有副作用命令使用 session 作用域的单调 sequence。接收端最多保留最近 256 个结果且每项最长
保留 60 秒；窗口外的旧 sequence 返回 `duplicate_expired` 而不重复执行。重连创建新 session，
不自动重放旧 session 的未确认命令，先以接收端播放快照和发送端列表 revision 对账。

## 6. 媒体与缓存

### 6.1 本地视频

1. 发送端注册文件并生成 `assetId`、`assetContentId`、媒体元数据和授权端点。
2. 会话 ready 后通过 `media.endpoint.announce` 公布 HTTPS 端点、session 内单调 generation、
   token 和证书指纹；媒体服务重启时原子切换端点并从原位置恢复。
3. 播放列表快照把 assetId 和内容版本 cache key 发给接收端。
4. Media3 按需发起 HEAD/Range；每个本地 item 通过 `ResolvingDataSource` 或
   `DataSpec.httpRequestHeaders` 注入自己的 If-Match，禁止写入共享 Factory 默认 Header。
5. `CacheDataSource` 同时写入接收端缓存；循环或 seek 优先读缓存。
6. 下一项预取使用较低优先级，不能挤占当前播放带宽。

### 6.2 外部 URL

HTTP/HTTPS progressive、HLS/DASH 点播可通过 DataSource 缓存；直播只保留短时窗口，不承诺
离线完整播放。RTSP 使用 RTP/RTCP 通道，不经过 CacheDataSource，固定上报缓存 unsupported，
不承诺离线续播或完整 seek。网页视频可由 Windows 发送端通过独立 yt-dlp sidecar 解析为
单路 URL 或独立音视频轨；后者由 Media3 `MergingMediaSource` 合并。协议只允许传递
播放所需的 `User-Agent`、`Referer`、`Origin`、`Accept` 和
`Accept-Language`，禁止 Cookie、Authorization 和 DRM 凭证。接收端必须按媒体项隔离 Header。

### 6.3 缓存策略

- 视频和照片共用一个存储协调器。令 `reclaimable = freeBytes + currentVideoBytes +
  currentPhotoBytes`，`allocatable = max(0, reclaimable - 1 GiB)`。照片不静态预留 512 MiB；
  `photoDemand = min(512 MiB, currentPhotoBytes + knownPendingRemainingBytes + unknownMetaHeadroom)`，
  活动批次尚有未知 meta 时 `unknownMetaHeadroom = 64 MiB`，否则为 0。再取
  `videoCandidate = min(10 GiB, reclaimable * 20%)`、`videoQuota = min(videoCandidate,
  max(0, allocatable - photoDemand))`。两类实际占用与预留总和不得大于 allocatable；无照片时
  视频可以借用全部未使用照片额度。
- 视频缓存启停使用不含 pending/headroom 的长期容量
  `longTermVideoCapacity = min(videoCandidate, max(0, allocatable - currentPhotoBytes))`，并带
  迟滞：长期容量 <256 MiB 持续 30 秒才禁用，>=320 MiB 持续 60 秒才重新启用，非紧急切换
  间隔至少 60 秒。活动照片批次只会
  暂停视频缓存新写入/调整目标配额，不改变启用状态或存储横幅。禁用只停止新缓存写入，未命中
  数据直接联网读取，已有有效区段仍可读；仅为保证系统余量回收未保护数据。系统余量已被突破
  时立即停止写入，不等待迟滞。
- failed/cancelled/removed transfer 立即从 knownPendingRemainingBytes 扣除并释放 headroom，
  不等待 10 分钟临时状态保留期；完成项把 pending 原子转为 currentPhotoBytes，总需求不跳变。
- photo 模式的保护顺序为“系统 1 GiB 余量、当前展示照片、当前批次待接收照片、暂停视频的
  当前/下一项、其余 LRU”。进入照片模式或收到 item meta 后，先回收旧缓存及暂停视频的可重拉
  区段满足 photoDemand；只有这些区段回收后仍不足才拒绝照片。media 模式下当前/下一视频恢复
  到旧照片和一般 LRU 之前。无法保住系统余量时停止全部新写入并提示，不继续填盘。
- media 模式下当前项和下一项的已用区段设为保护优先级，其余条目按 LRU 回收；photo 模式
  明确服从上一条模式相关顺序，可回收暂停视频的可重拉区段。
- 缓存写入失败不应中断仍可直接读取的网络播放，但必须提示存储问题。
- 部分缓存记录可播放的 byte ranges，而不是把 `partial` 误认为完整离线可用。
- `assetContentId` 与 ETag 同源，由稳定来源标识、size、mtime 和首尾采样摘要生成；
  `cacheKey = senderId:assetContentId`。ETag 变化必须使用新 cacheKey，旧条目按 LRU 淘汰。
- cacheKey 与会话令牌解耦；重连更换令牌后仍命中相同内容的原缓存。

## 7. 照片讲解

照片使用完整文件传输，因为体积有限且离线展示需要完整数据：

1. 发送端先发仅含 batchId、count 和有序 photoId 的 `photo.batch.start`，接收端立即创建
   最多 9 个 loading 槽位。
2. 每张图片处理完成后发送 `photo.item.meta`（photoId、transferId、size、hash、chunkCount），
   收到 `photo.item.ready` 后再分块；存储/写入失败通过明确错误释放槽位，发送端再用
   `photo.batch.update` 列出 removedPhotoIds。
3. 接收端写临时文件，校验大小和摘要后原子改名。
4. 单图自动进入全屏，多图进入宫格；控制操作按 batch revision 同步。
5. 断线时已到达图片继续展示，未完成 transfer 保留 10 分钟；重连通过 resume query/state
   取得 nextChunkIndex 后续传，未到达槽位显示顶部横幅和局部 loading。
6. 照片配额 512 MiB，默认保留最近 5 个完成批次；统一存储协调器先保留 1 GiB 系统余量，
   再按 §6.3 统一分配照片和视频额度。当前展示批次不回收。
7. 发送端按单照片串行传输，每 2 MiB/32 chunks 等待累计 ACK；接收端在 32 chunks、250 ms
   或最后一块任一条件满足时同步并确认，给 ping/pong 和控制命令留下调度机会。

## 8. 异常与恢复

### 8.1 控制断线

- 立即进入 `reconnecting` 并显示橙色横幅。
- 播放器继续读取缓存；若 HTTPS 通道仍可用，可以继续拉取但不得认为控制已恢复。
- 磁盘缓存新写入已禁用且 HTTPS/网络也不可用时，仍先读取已有有效区段并显示“正在播放缓存
  内容”；到达缓存缺口后才保留末帧进入 buffering，横幅改为“已有缓存耗尽，等待网络恢复”。
- 自动重连使用 0.5/1/2/4/8 秒退避，之后每 10 秒一次，加入随机抖动。
- 重连成功后双方交换 playlist revision、播放快照和媒体服务新令牌。

### 8.2 网络中断

- 当前缓存够用：继续播放并显示横幅。
- 读取到缓存缺口：保留末帧，进入 buffering，不跳项。
- 网络恢复：同一 item/position 恢复，成功出帧后清除 loading。

### 8.3 错误分类

| 分类 | 典型错误 | 行为 |
|---|---|---|
| 网络暂态 | 无网络、连接超时/重置、DNS 暂时失败、HTTP 503 | 保持 Surface 和末帧，状态 buffering，按有界退避无限等待网络恢复，不消耗永久错误配额 |
| 资源暂态 | 媒体服务并发 503 + Retry-After | 按服务端时间重试，不计永久错误 |
| 资源永久 | HTTP 404/412/416、文件删除/变化、权限拒绝 | 1/2/4 秒最多 3 次，随后 error |
| 解码永久 | 不支持容器/codec、decoder 初始化失败 | 1 次能力复核后 error，不循环创建 decoder |

实现使用自定义 Media3 `LoadErrorHandlingPolicy`；网络暂态不能返回停止重试的哨兵值。
进入 buffering 不释放视频 Surface。切换 item 或用户显式重试才重置永久错误计数。

## 9. 安全

- 无账号不等于无访问控制。控制使用 WSS，首次配对由接收端显示随机 6 位连接码，发送端输入
  正确号码后固定证书 pin 并保存可信关系，投影仪端无需遥控器操作。
- 配对 challenge 有效期 120 秒且只能成功确认一次；连续错误同时按来源 IP 和全局限速，
  到期时清除大屏连接码并重新建立 challenge。
- 媒体 endpoint/token 只能在 `session.ready` 后公布，至少 256 bit、绑定 sessionId，连接结束
  或配对撤销后失效。媒体 host 固定取控制 WSS 对端 IP，协议中的地址字段不得覆盖它。
- 本地媒体使用 HTTPS，接收端固定发送端通过 WSS 公布的证书指纹。
- 本地 WSS/HTTPS 的 SSL 校验对象仅限当前连接的预期 pin；外部 URL 继续使用系统 CA 和正常
  主机名校验，任何无条件信任证书的回调都视为安全缺陷。
- 只允许访问已注册 assetId，拒绝 `..`、绝对路径和编码绕过。
- 限制 JSON、URL、列表、照片、二进制 chunk 和并发请求大小。
- 用户显式输入的外部 `http://` 源仍是明文，UI 必须标识为不安全来源；Android manifest
  通过全局 cleartext 开关允许该产品能力，因为 network security config 无法预先枚举
  用户输入的任意主机。应用层只为经验证的外部 HTTP 媒体创建请求；本地 WSS/HTTPS
  端点固定要求 TLS 和证书 pin，不能降级为明文。

## 10. 开机启动边界

当前通用 APK 在用户打开接收端后启动前台服务，不声明
`RECEIVE_BOOT_COMPLETED`。Android 15 对从 `BOOT_COMPLETED` 启动 `mediaPlayback`
前台服务有额外限制，通用应用不伪装成可靠开机自启。

投影仪发行版的开机自启需要厂商白名单、设备所有者策略或系统签名能力，并从设置页
明确展示当前设备是否支持。

投影仪发行版实现时，`BOOT_COMPLETED` 只启动接收端服务。API 29+ 不承诺从后台
直接拉起沉浸式 Activity；支持设备策略或系统签名时才可自动进入。

## 11. 第二阶段镜像

`SasCalculator` 及共享 `sas_vector.json` 仅是第二阶段低延迟镜像配对方案的预留互操作向量，
不属于 v1 媒体投放握手。v1 只使用接收端显示的随机 6 位连接码、证书 pin 和可信 token；
生产流程不得把 SAS 测试通过解释为当前配对链路已使用 SAS。

镜像复用现项目经过验证的采集/编解码思路，但只抽取必要能力，不复制认证、远控、PPT、
批注等模块：

- Windows：DXGI Desktop Duplication + Media Foundation H.264/AAC。
- Android：MediaProjection + MediaCodec H.264/AAC。
- 接收端：MediaCodec 硬解、Surface 低延迟渲染。
- 视频目标 1080p30、6 Mbps CBR、1 秒 IDR、Annex-B、每个 IDR 带 SPS/PPS。
- 控制走 WSS；媒体优先使用无序、有限重传通道，WSS 二进制帧兜底。
- 始终有有界队列、主动丢帧和关键帧恢复，禁止延迟无限堆积。
