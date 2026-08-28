# LAN Media Cast 验收标准

## 1. 证据要求

每次验收记录：

- commit/工作区版本标识；
- 接收端品牌、型号、SoC、Android 版本、分辨率和可用存储；
- 发送端型号、OS、网络接口；
- 路由器/热点、频段、信号强度和是否启用客户端隔离；
- 媒体容器、编码、profile、分辨率、帧率、码率和大小；
- P50/P95、CPU、内存、掉帧、温度和日志关联 ID。

未取得实测数据的性能项标记“待验证”，不能写成已达到。

## 2. 工程基线

- [ ] 新环境按 README 可构建 receiver Android debug APK。
- [ ] 新环境可构建 sender Android debug APK 和 Windows debug/release bundle。
- [ ] Dart format/analyze/test 全部通过。
- [ ] Kotlin unit test/lint/build 全部通过。
- [ ] 两端读取同一 protocol fixtures，合法/非法/边界样例结果一致。
- [ ] 仓库不包含 SDK 绝对路径、签名、token、缓存或生成二进制。
- [ ] Gradle wrapper 使用腾讯镜像且 SHA-256 校验固定；空缓存下载与已有缓存构建都成功。
- [ ] Android network security config 不允许本地 WSS/HTTPS 链路降级，用户显式外部 HTTP
  来源可用并显示不安全提示。

## 3. 发现与连接

- [ ] 接收端启动到可发现，典型设备 <=2.5 s。
- [ ] 发送端扫描 P95 <=1.5 s；相同 deviceId 多网卡只显示一次。
- [ ] 手动 IPv4+端口可连接。
- [ ] 首次配对由接收端显示随机 6 位连接码，发送端输入正确号码后才能 ready，投影仪端无需
  遥控器操作；可信重连同时验证证书 pin 和 token，且不再要求输入连接码。
- [ ] 证书摘要只来自当前 TLS 握手而非 payload；接收端重装新证书和第三方伪造证书
  均在发送 trustedToken 前终止连接并提示身份变化，无条件信任证书检查能被测试检出。
- [ ] challenge 超过 120 秒或重复使用被拒绝；来源锁定和全局限速均生效，换 IP 不能绕过。
- [ ] `session.pairing_required` 不包含连接码；错误号码可重试，连续 5 次错误后锁定 30 秒。
- [ ] 第二个发送端收到 receiver_busy，不等待通用超时。
- [ ] WSS 首选端口占用时自动换端口，发现/手动连接使用实际端口。
- [ ] Wi-Fi、有线、热点切换后地址刷新且可重连。
- [ ] Android Wi-Fi 息屏/亮屏和服务启停后仍可发现，`MulticastLock` 无泄漏。
- [ ] Windows Domain/Private/Public 三种防火墙配置分别覆盖 UDP 查询与入站单播响应、WSS
  控制和 HTTPS 媒体；阻断时可诊断并通过手动 IP 降级。
- [ ] 伪造超大/畸形 UDP 和 WSS 消息不会造成崩溃或大内存增长。
- [ ] `session.hello` 在 ready 前不泄露媒体端点、媒体证书或 bearer token；端点消息中的
  host 字段和伪造 Host 均不能覆盖 WSS 对端 IP。

## 4. 本地媒体

- [ ] Windows/Android 可选择 4 GiB 以上视频，不整文件读入内存或预复制后才起播。
- [ ] HTTPS HEAD、完整 GET、`bytes=N-M`、`bytes=N-`、`bytes=-S`、非法/多区间和越界
  Range 分别符合 200/206/416 及 Content-Range 契约。
- [ ] GET 缺少 If-Match 返回 428、错误 ETag 返回 412；文件变化后 assetContentId、强 ETag
  和 cacheKey 同步变化，不能继续读取旧内容。
- [ ] 同一播放器实例连续播放并预取不同 ETag 的本地项，每项 If-Match 独立，不因共享
  DataSource Factory Header 产生 412。
- [ ] 会话/单资产并发超限返回 503 + Retry-After，并按暂态错误恢复而非消耗永久错误配额。
- [ ] 5 GHz LAN 下 1080p H.264/AAC 首帧 P95 <=2 s。
- [ ] 暂停、恢复、停止、上一项、下一项、seek 状态一致。
- [ ] 已缓存 seek 首帧 P95 <=500 ms。
- [ ] 源文件删除或修改返回 source_changed/item_not_found，不播放错误内容。
- [ ] 媒体 HTTPS 证书与 announce pin 不匹配时，在发送 Authorization 前停止读取并上报
  身份错误；该连接配置不影响外部 URL 的正常 CA/主机名校验。
- [ ] 媒体服务中途重启后 generation、token、端口原子轮换，当前项重新 HEAD/If-Match 并
  从原 position 恢复；迟到的旧 generation 不覆盖新端点。
- [ ] 发送端媒体服务断开后文件句柄和请求任务及时释放。

## 5. URL 媒体

- [ ] HTTP/HTTPS progressive、HLS、DASH、RTSP 各有成功样例。
- [ ] 直播源不会因无结束事件自动跳到下一项。
- [ ] 404、TLS、超时、无效 manifest、RTSP 断流都有明确错误。
- [ ] 不支持编码返回 unsupported_media，并包含可用于诊断的 codec 信息。
- [ ] 源站耗时与应用/解码耗时分别统计。
- [ ] RTSP 和直播缓存状态为 unsupported，断网时不错误承诺离线继续或完整 seek。
- [ ] Android 7 公共 HTTPS 根证书不兼容时提示“证书不受信任”，本地 pin 链路不受系统 CA 影响。

## 6. 播放列表

- [ ] 空列表加入首项自动播放。
- [ ] 排序、删除、清空和立即选播同步到接收端。
- [ ] repeatOne、repeatAll、playOnce 边界行为准确。
- [ ] playOnce 结束后暂停并保留末帧。
- [ ] 已预取相邻视频切换 P95 <=300 ms。
- [ ] 同 revision 不同 payload 被拒绝；同 session 内相同 commandSeq/id 只执行一次。
- [ ] 幂等结果最多保留最近 256 项且最长 60 秒；已淘汰旧 sequence 返回 duplicate_expired，
  相同 sequence 换 id 返回 sequence_conflict，均不重复副作用。
- [ ] 发送端重启后恢复列表；失效文件保留并标识不可用。

## 7. 缓存与断线

- [ ] 断开控制连接后，已缓存视频继续播放。
- [ ] 顶部橙色半透明横幅不改变视频尺寸和宽高比。
- [ ] 缓存区段耗尽时保留末帧并显示轻量 loading。
- [ ] 网络恢复后从原 position 续播，不从头开始。
- [ ] 下一项未缓存时不自动跳过。
- [ ] 当前项/下一项在一般 LRU 淘汰中受保护。
- [ ] 达到缓存配额或安全余量时正确回收，不填满系统磁盘。
- [ ] longTermVideoCapacity 持续低于 256 MiB 时停止新缓存写入，高于 320 MiB 后按迟滞重新
  启用；活动照片的 videoQuota 变化只暂停写入/调整回收目标，不改变启用状态。
- [ ] 可回收空间为 1.5-2 GiB 等边界值时，视频配额 + 照片配额不突破 1 GiB 系统余量；
  外部应用突然占用空间时停止新写入并按统一优先级回收。
- [ ] reclaimable 约 1.7 GiB 且无照片占用/活动批次时视频缓存仍启用；进入照片模式后才按
  实际照片、已知待传大小和 64 MiB headroom 动态回收。
- [ ] 一次照片批次不导致视频缓存启停或存储横幅抖动；禁用 <256 MiB/30 秒、重新启用
  >=320 MiB/60 秒且非紧急切换间隔 >=60 秒，禁用不清空已有有效区段。
- [ ] 缓存写失败不影响仍可直接联网播放，且显示存储提示。
- [ ] 新缓存写入禁用时提示“已有缓存耗尽后将等待网络”；断线但当前区段已缓存时继续播放，
  到达缺口后才进入 buffering，横幅不误报。
- [ ] 接收端重启保留缓存和进度，但不自动发声。
- [ ] 恢复连接绿色横幅约 2 秒后消失。
- [ ] 同一路径文件跨发送端/接收端重启后被替换，不命中旧 cacheKey，不拼接新旧字节。

## 8. 照片讲解

- [ ] Android 拍照/相册和 Windows 文件选择可形成 1-9 张批次。
- [ ] 裁剪、旋转、删除后上传结果与发送端一致。
- [ ] batch start 仅含有序 photoId 即可立即显示正确数量 loading 槽位，不依赖 size/hash。
- [ ] item meta 后 chunk 可由 transferId 映射到唯一 photoId；32-byte 头、payloadLength、
  chunkCount 和 last flag 的合法/非法 fixtures 两端结果一致。
- [ ] batch/item ready 和 resume state 各自是唯一带 replyTo 的 typed response；完整信封
  fixtures 一致，未 ready 前二进制 chunk 被拒绝。
- [ ] resume state 的 batchStatus 与五种 item status fixtures 两端一致；批次不存在时以原
  batchId 重发 start 后重建槽位，不直接向未知 batch 发送 meta。
- [ ] 五种 resume item status 的 transferId/nextChunkIndex nullability 与固定值完全符合协议表。
- [ ] 传输失败后 resume 固定返回 awaitingMeta/null/null，不残留旧 transferId。
- [ ] 单项处理失败时 batch update 的 removedPhotoIds 删除准确槽位，不永久 loading。
- [ ] chunk ACK 只确认已持久化数据；摘要错误不会发布半成品。
- [ ] 单图全屏，多图宫格；放大、切图和缩放一致。
- [ ] 大图按显示尺寸下采样，无 OOM。
- [ ] 断线时已到达图片继续显示；10 分钟内新 session 通过 resume query/state 从已持久化的
  nextChunkIndex 续传，超时清理后以新 transferId 重传。
- [ ] 接收端进程重启或批次整体超过 10 分钟后返回 notFound，发送端可重建批次且无永久
  loading 槽位。
- [ ] meta 阶段 storage_low 错误响应或传输中途不可重试 item.failed 均释放槽位并同步
  removedPhotoIds，不停在 loading。
- [ ] 视频缓存占满配额后进入照片模式，先回收暂停视频的可重拉区段，仍可在总空间允许时
  完成 1-9 张批次。
- [ ] 受限带宽下发送 9 张照片时，在途数据不超过 32 chunks/2 MiB，控制帧优先，心跳不超时
  且不会形成重连循环。
- [ ] 发送端每次最多发送 32 chunks 并等待覆盖该窗口的累计 ACK，不会无界发送照片数据。
- [ ] fresh/续传首帧分别从 0/nextChunkIndex 开始；较小重复 index 只重 ACK，较大跳号产生
  不可重试 invalid_message item.failed，不永久 loading。
- [ ] 重复 chunk 不计入未确认窗口，ACK 最多每 250 ms 一次；32 帧/10 秒或持续无前进 10 秒
  后确定取消 transfer，不形成 ACK 放大或永久 loading。
- [ ] 取消 transfer 后的合法在途 tombstone chunk 不落盘、不关闭 WSS、不影响其他 transfer；
  未 ready/未知 ID 有界计数，只有结构不可解析或超过滥用阈值才关闭 WSS。
- [ ] 未 ready/未知 ID 与结构损坏头部分别产生完整 `protocol.error` fixture，无 replyTo/commandSeq，
  code/reason/nullable transferId 两端一致。
- [ ] 退出照片模式恢复进入前的视频 item、position 和播放意图。
- [ ] `mode.set/mode.state` 在媒体/照片间往返状态一致，首期 mirror 请求明确返回 unsupported_mode。
- [ ] 照片完成批次、临时文件合计不超过 512 MiB，默认回收至最近 5 批且不删除当前展示批次。

## 9. 音量与状态

- [ ] 0-100 映射到系统媒体音量并回传实际值。
- [ ] 静音后取消静音恢复静音前音量。
- [ ] playing 状态约 500 ms 更新一次位置，不造成 UI/网络洪泛。
- [ ] 同 session 内迟到的低 sequence 状态不会覆盖新状态；新 session 从 1 开始时不会被旧
  session 的高 sequence 丢弃。
- [ ] 命令超时、拒绝和执行错误在发送端有明确反馈。
- [ ] 控制断线期间 seek 等即时控制被禁用且不排队；重连以后接收端位置作为事实源。

## 10. UI 与设备行为

- [ ] 等待页展示设备名、IPv4、网络名、端口和配对状态。
- [ ] 横幅高度 36-44 dp、文字可读、画面不重排、控件不被永久遮挡。
- [ ] 旋转、分辨率变化和系统栏短暂出现后恢复沉浸式。
- [ ] 接收端默认横屏；所有视频等比放大并居中裁切铺满，无横向或纵向拉伸；照片保持完整
  等比适配，允许 letterbox/pillarbox。
- [ ] 保持屏幕常亮；退出应用后释放相关标志和服务资源。
- [ ] 开机启动开关在支持设备上有效，不支持时给出明确状态。
- [ ] API 29+ 普通应用开机只启动前台服务，不声称必然自动拉起 Activity；设备策略支持与
  不支持的设备分别显示准确能力状态。

## 11. 错误与恢复

- [ ] 网络暂态长期存在时保留末帧持续 buffering、有界退避且不消耗永久错误次数。
- [ ] 资源永久错误按 1/2/4 秒最多重试 3 次，然后停在当前项；解码永久错误能力复核 1 次。
- [ ] 媒体错误红色横幅包含媒体名、原因和重试状态。
- [ ] 自动重连退避有上限和抖动，不形成连接风暴。
- [ ] 发送端应用退出、receiver 进程重启、路由器断电恢复均有确定结果。
- [ ] 文件、socket、timer、subscription、Surface 和 decoder 无重复释放或泄漏。

## 12. 性能与长稳

- [ ] 控制操作状态回显 P95 <=150 ms。
- [ ] 必达设备稳定播放 1080p30 H.264/AAC。
- [ ] 1080p H.264 20 Mbps CBR 连续稳定播放。
- [ ] 30 分钟播放重缓冲占比 <0.5% 且次数 <=1；解码掉帧率 <0.5%。
- [ ] 音画同步绝对偏差 P95 <40 ms。
- [ ] 硬件支持时验证 1080p60/4K，并准确上报能力，不虚假承诺。
- [ ] 视频大小从 100 MiB 增加到 20 GiB 时内存峰值不按文件大小增长。
- [ ] 列表循环 8 小时无崩溃、无句柄持续增长、内存无单调上升。
- [ ] 24 小时故障注入测试后仍可发现、连接和播放。

## 13. 第二阶段镜像

- [ ] Android MediaProjection 和 Windows DXGI 均可发送。
- [ ] 接收端硬解码 1080p30，无持续积帧。
- [ ] 端到端 P95 <=150 ms，测试方法和采样设备有记录。
- [ ] 带宽不足时优先降码率/帧率，不让延迟无限增加。
- [ ] 丢帧后通过 IDR 恢复，SPS/PPS 与每个 IDR 一同可用。
- [ ] 镜像、媒体和照片模式反复切换 100 次无崩溃或资源泄漏。
