# LAN Media Cast 通信协议 v1

## 1. 目标

协议 v1 覆盖设备发现、一次性连接码配对、单会话连接、媒体端点公布、播放列表、播放控制、
状态恢复、照片传输和缓存状态。屏幕镜像复用相同信令信封，但媒体帧在第二阶段单独定义。

所有整数使用十进制 JSON 数字；二进制头中的多字节整数使用网络字节序（big-endian）。
字符串使用 UTF-8。时间戳使用 UTC Unix epoch milliseconds。

## 2. 版本与限制

| 项目 | 限制 |
|---|---|
| 协议版本 | 1 |
| UDP 数据报 | <= 1400 bytes |
| WSS JSON 文本帧 | <= 64 KiB |
| WSS 二进制帧 | <= 128 KiB |
| URL | <= 4096 UTF-8 bytes |
| 播放列表 | <= 500 items |
| 设备名/媒体名 | <= 256 UTF-8 bytes |
| 照片批次 | <= 9 items |
| 照片传输 chunk | <= 64 KiB payload |
| 心跳周期/超时 | 5 s / 15 s |

超限消息返回结构化错误并关闭存在滥用风险的连接。接收端不得在校验前按对端声明的长度分配
同等大小内存。

## 3. UDP 发现

默认目标端口为 39880。发送端向每张 LAN 网卡的定向广播地址发送查询，接收端向数据报的
源地址和源端口单播回复。Android 接收端在发现服务存活期间持有
`WifiManager.MulticastLock`，停止服务时释放。

### 3.1 查询

```json
{
  "v": 1,
  "type": "discover.query",
  "requestId": "8d4a095e-9849-4fc0-9563-53dca684027f",
  "senderId": "e5cb742f-1fb5-4558-a8d8-5113035101e2",
  "senderName": "Teacher-PC"
}
```

### 3.2 响应

```json
{
  "v": 1,
  "type": "discover.response",
  "requestId": "8d4a095e-9849-4fc0-9563-53dca684027f",
  "deviceId": "a8dce123-eb78-4ad0-80a8-1d8f8e58609b",
  "deviceName": "Projector-01",
  "wssPort": 39881,
  "busy": false,
  "pairingRequired": true,
  "protocolMin": 1,
  "protocolMax": 1,
  "capabilities": ["media", "photo", "hls", "dash", "rtsp", "cache"]
}
```

发送端以 UDP 包源 IP 为首选地址，不盲信 payload 中的地址。若接收端通过多次查询从不同
网卡回复，发送端把这些源 IP 合并到同一 `deviceId` 的候选列表。

## 4. WSS 信封与幂等性

控制连接地址为 `wss://<receiver-ip>:<advertised-port>/v1/control`。首次配对连接按第 5 节
完成证书校验；可信重连必须先验证已固定的接收端证书指纹。

```json
{
  "v": 1,
  "type": "player.play",
  "id": "4b9d0e42-62dd-4572-a25f-aa84e193e31f",
  "sessionId": "f8737670-820d-493d-b6b8-647672e16e84",
  "commandSeq": 18,
  "ts": 1787702400000,
  "payload": {}
}
```

- `v`：协商后的协议版本。
- `type`：一个或多个小写消息名段；多段使用点号分隔，当前通用命令响应为单段 `response`。
- `id`：消息 UUID；有副作用的命令必须携带。
- `sessionId`：握手完成后必填。
- `commandSeq`：会话内从 1 开始严格递增，仅握手完成后有副作用的发送端命令必填；
  `session.hello` 和配对消息不使用该字段。
- `ts`：用于诊断，不用于安全判定或消息排序。
- `payload`：对象；无参数时使用空对象。

响应使用同一信封并增加 `replyTo`：

```json
{
  "v": 1,
  "type": "response",
  "id": "025695da-3ce7-40a3-817f-a95164f3b2b6",
  "replyTo": "4b9d0e42-62dd-4572-a25f-aa84e193e31f",
  "sessionId": "f8737670-820d-493d-b6b8-647672e16e84",
  "ts": 1787702400024,
  "payload": {"ok": true}
}
```

默认命令响应的 `type` 为 `response`。本协议显式定义的 typed response
（`photo.batch.ready`、`photo.item.ready`、`photo.batch.resume.state`）也必须带 `replyTo` 和
`payload.ok`，在超时、幂等缓存和“每个命令恰好一个直接响应”语义上等同 `response`；不得先回
ok 再另发 typed response。以后新增 typed response 必须在本清单和 fixtures 同步登记。

无法关联到命令 id 的二进制帧错误使用主动诊断信封，不伪造 `replyTo`：

```json
{
  "v": 1,
  "type": "protocol.error",
  "id": "event-uuid",
  "sessionId": "uuid",
  "ts": 1787702403000,
  "payload": {
    "ok": false,
    "code": "invalid_state",
    "reason": "unknown_transfer",
    "transferId": "uuid-or-null"
  }
}
```

`protocol.error` 不含 `replyTo` 或 `commandSeq`，不占用命令的唯一直接响应名额，也不进入命令
幂等缓存。session ready 后 `sessionId` 必须非空；握手前必须为 null。`transferId` 字段必须存在，
无法安全取得时为 null。当前 `reason` 枚举为 `malformed_binary_header|unknown_transfer|internal_error`，详细文本
只写本地日志。同一 code/reason 的主动诊断最多每秒 1 条，但滥用计数覆盖所有输入。合法/非法
完整信封必须进入 fixtures；发送端收到未知 code/reason 时记录诊断，不关闭连接或猜测副作用。

接收端按 `sessionId` 保存最多最近 256 个命令结果，每项最长保留 60 秒，任一界限到达即淘汰。
相同 `commandSeq` 和
相同 `id` 返回缓存结果，不重复副作用；相同 sequence 但 id 不同返回 `sequence_conflict`。
小于等于已接收最高 sequence、但结果已淘汰的请求返回 `duplicate_expired`，绝不重新执行。
超出窗口的正常新命令仍可执行，并淘汰最旧结果。新会话的 `commandSeq` 重新从 1 开始。

断线时旧会话未确认命令不得换新 id 或新 sequence 在新会话自动重放；重连后先按第 5.4 节
对账，再由用户显式重试。这样幂等缓存有界，也不会把迟到命令作用到新会话。

错误响应示例：

```json
{
  "v": 1,
  "type": "response",
  "id": "6429a436-f2d1-412d-8559-8684228016ee",
  "replyTo": "4b9d0e42-62dd-4572-a25f-aa84e193e31f",
  "sessionId": "f8737670-820d-493d-b6b8-647672e16e84",
  "ts": 1787702400024,
  "payload": {
    "ok": false,
    "error": {"code": "invalid_state", "message": "No playable item"}
  }
}
```

`message` 只用于日志和开发提示；正式 UI 根据 `code` 本地化。

### 4.1 `diagnostics.logs.get`

已配对的发送端可以通过控制连接获取接收端最近的诊断日志，不需要 ADB，也不改变播放状态。
接收端只在内存中保留最多 256 KiB；请求按 UTF-8 字节偏移读取，每块最多 16 KiB：

```json
{
  "v": 1,
  "type": "diagnostics.logs.get",
  "id": "uuid",
  "sessionId": "uuid",
  "commandSeq": 19,
  "ts": 1787702400200,
  "payload": {"offset": 0, "maxBytes": 16384}
}
```

成功响应的 `payload` 包含 `format: "text"`、`offset`、`nextOffset`、`totalBytes`、`eof` 和
`data`。发送端重复请求直到 `eof=true`，并将内容保存到本机日志目录。日志传输沿用 WSS
证书固定和会话幂等保护。

`offset = 0` 表示开始一次新的取回，接收端据此冻结当前缓冲区快照；后续 `offset > 0` 的请求
一律从同一份快照读取，直到 `eof=true` 释放。取回期间接收端仍在写日志（处理本命令本身就会
产生一条），若逐块重新读取实时缓冲区，写满后的淘汰会使偏移整体前移，导致丢行、重复或在多字节
字符中间截断。分块边界始终对齐 UTF-8 字符。`data` 中的 Bearer token、Cookie、私钥和完整 URL
已由接收端脱敏。

`offset` 必须非负，`maxBytes` 取值范围 1…16384，越界返回 `invalid_message`。当单个 UTF-8
字符长度超过 `maxBytes` 时，接收端返回该完整字符（可能略超预算），以保证 `nextOffset`
始终前进。

`offset > 0` 但快照已释放（上一次取回已完成，或接收端进程已重启）时返回 `invalid_state`，
发送端从 `offset = 0` 重新取回一次。此时绝不能改用新快照拼接：响应内部各偏移仍会自洽，
发送端无从发现日志已经错位。发送端另需校验整个取回过程中 `totalBytes` 保持不变——逐块
重读实时缓冲区的接收端会让该值漂移，这是唯一能在发送端侧发现错位的信号。

接收端对未通过会话校验前的解码失败只保留有限条数，其余仅进 logcat。否则占住控制连接的
未配对对端可以用畸形帧刷满有界缓冲，把真正的诊断信息挤出去。

## 5. 握手与配对

### 5.1 TLS 身份

接收端首次安装时生成自签名 TLS 证书。首次连接尚无 pin 时，发送端只把该连接用于配对，
只有接收端生成的随机连接码验证成功后才固定本次握手证书指纹并提升为可信会话。
后续连接若证书指纹不匹配，必须在发送任何可信 token 前终止连接并提示身份变化。

局域网端点使用会变化的裸 IP，自签名证书不承诺 IP SAN。对本协议的本地 WSS/HTTPS 链路，
身份校验定义为“当前 TLS 握手叶证书 DER 的 SHA-256 与期望 pin 精确匹配”，该检查替代公共 CA
链和主机名校验。Dart 只能在 `badCertificateCallback` 中对当前证书计算摘要并与预期值常量时间
比较；Android 必须使用仅接受预期摘要的连接专用 TrustManager 和 HostnameVerifier。禁止无条件
返回 true、信任任意自签名证书、复用到外部 URL，或安装进应用/系统全局信任库。

首次配对尚无预期 pin 时，仅允许本次握手取得的单张证书进入受限配对状态；在随机连接码验证
完成前不得发送可信 token 或业务命令。可信重连以已保存 pin 为预期值。媒体 HTTPS 以最近一次
已认证 `media.endpoint.announce` 中的 pin 为预期值。

pin 按解析出的 `deviceId` 和地址派生的手动 id 双写，查找时两者都要考虑：先手动连接、后经发现
连接同一接收端（或相反）必须命中同一条 pin。

指纹不匹配是终止性的，重试不可能成功，因此发送端必须停止自动重连并等待用户裁决，不得进入
退避重连循环。用户显式确认重新信任后，必须**同时**删除该接收端的 pin 和 token，使新身份只能
通过重新配对建立——旧 token 是签发给上一个身份的，不得向新身份重放。发送端不得在未经用户确认
的情况下自动清除 pin，否则证书固定会被降级为可被攻击者单方面重置的机制。

### 5.2 `session.hello`

发送端连接后 3 秒内发送。此消息不得携带媒体服务地址、证书指纹或 bearer token。

```json
{
  "v": 1,
  "type": "session.hello",
  "id": "uuid",
  "ts": 1787702400000,
  "payload": {
    "senderId": "persistent-install-uuid",
    "senderName": "Teacher-PC",
    "protocolMin": 1,
    "protocolMax": 1,
    "trustedToken": null,
    "capabilities": ["playlist", "photo", "https-range"]
  }
}
```

接收端可能返回：

- `session.pairing_required`：只包含 `challengeId` 和 `challengeExpiresAt`，不向发送端公布
  连接码或证书指纹。
- `session.ready`：包含 `sessionId`、接收端 `deviceId`/`deviceName`、可信设备新 token、接收端能力、初始模式和状态快照。手动 IP 连接据此升级为稳定设备身份。
- `session.receiver_busy`：包含当前会话的非敏感设备名和可重试建议。
- `session.unsupported_version`：包含接收端支持区间。
- `session.rejected`：配对锁定、设备撤销、证书变化或策略拒绝。

`trustedToken` 只在发送端已成功验证已固定证书的 WSS 连接中发送。token 至少 256 bit，仅保存在
平台安全存储，不进入日志、崩溃信息或普通偏好文件。

### 5.3 接收端随机连接码

接收端使用密码学安全随机数均匀生成 `000000` 至 `999999` 的 6 位十进制连接码，只在投影
画面显示。发送端不得从 `session.pairing_required`、发现响应或证书字段推导该号码；用户在
发送端输入后，通过当前 WSS 连接发送：

```json
{
  "v": 1,
  "type": "session.pair.confirm",
  "id": "uuid",
  "ts": 1787702401000,
  "payload": {"challengeId": "uuid", "pairingCode": "042731"}
}
```

号码正确时接收端立即返回成功响应和 `session.ready`，投影仪端不再要求遥控器确认。challenge
有效期 120 秒，成功后只能消费一次；错误号码可在有效期内重试。同一来源 IP 5 次失败在 30 秒
内锁定；全局 5 分钟内 20 次失败后停止新配对。换 IP 不绕过全局限制。连接码只在首次建立可信
关系或接收端身份变化后需要输入，后续连接使用固定证书和可信 token。

### 5.4 恢复

重连从 `session.hello` 开始，新 `sessionId` 的命令与状态 sequence 均重新计数。成功后双方比较：

- sender playlist revision；
- receiver playlist revision；
- active item ID、position 和 playback state；
- 当前业务模式；
- 当前照片 batchId、batch revision、未完成 transferId 和 nextChunkIndex。

发送端列表是编辑事实源，接收端播放位置和播放状态是播放事实源。列表 revision 不一致时发送端
下发完整快照；位置以接收端为准。断线期间发送端禁用 seek 和其他需要即时接收端状态的控制，
不保存“待执行 seek”。旧会话未确认命令不在新会话自动重放；照片续传使用第 11.2 节的显式
查询，而不是重放旧 session 的 photo 命令。新会话 ready 后发送端重新 announce 当前媒体端点。

## 6. 媒体端点与播放列表

### 6.1 `media.endpoint.announce`

发送端收到 `session.ready` 后才能公布本地媒体 HTTPS 端点：

```json
{
  "v": 1,
  "type": "media.endpoint.announce",
  "id": "uuid",
  "sessionId": "uuid",
  "commandSeq": 1,
  "ts": 1787702400100,
  "payload": {
    "scheme": "https",
    "port": 52143,
    "generation": 1,
    "certificateSha256": "base64url-sha256",
    "bearerToken": "base64url-256-bit-random"
  }
}
```

消息不允许携带 host。接收端必须使用当前控制 WSS socket 的对端 IP 组合媒体 URL，不能被
payload、Host header 或播放列表覆盖。`generation` 在 session 内从 1 严格递增，最近成功响应的
announce 是所有本地 MediaSource 的唯一端点事实源；MediaSource 不保存 generation。

媒体服务中途重启时，发送端启动新端口和 token 后再发 generation + 1 的 announce。接收端
原子替换所有本地项共用的端点，取消旧网络请求，对当前项重新 HEAD/If-Match 并从原 position
恢复；缓存 key 不变。旧 generation 的迟到 announce 返回 `stale_generation`。接收端按第 5.1 节
固定 `certificateSha256`；token 绑定当前 `sessionId` 和 generation，会话结束、端点再次重启或
配对撤销后失效。

### 6.2 MediaSource

本地媒体：

```json
{
  "kind": "local",
  "assetId": "uuid",
  "assetContentId": "base64url-sha256",
  "cacheKey": "senderId:base64url-sha256",
  "name": "lesson.mp4",
  "mime": "video/mp4",
  "size": 4281093351,
  "path": "/v1/media/uuid"
}
```

`assetContentId` 与 HTTP ETag 同源，由稳定来源标识、size、mtime 和首尾采样摘要生成；来源
内容变化必须生成新的值。`cacheKey` 固定为 `senderId:assetContentId`，不得只使用文件路径或
长期稳定 assetId。`path` 必须是相对媒体服务根路径，协议不传发送端真实文件路径。

远程媒体：

```json
{
  "kind": "url",
  "url": "https://media.example/lesson.m3u8",
  "name": "Lesson live",
  "formatHint": "hls",
  "cacheKey": "web:base64url-sha256:primary",
  "httpHeaders": {
    "User-Agent": "Mozilla/5.0 ...",
    "Referer": "https://video.example/lesson"
  }
}
```

音视频分轨时，主 URL 为视频轨，并增加音频轨：

```json
{
  "kind": "url",
  "name": "Lesson",
  "url": "https://media.example/video-only.mp4",
  "cacheKey": "web:base64url-sha256:primary",
  "audioTrack": {
    "url": "https://media.example/audio-only.m4a",
    "cacheKey": "web:base64url-sha256:audio",
    "httpHeaders": {"Referer": "https://video.example/lesson"}
  }
}
```

接收端直连远程 URL；不从 endpoint announce 组合其 host。RTSP 和直播固定上报缓存
`unsupported`，协议不承诺断网后继续播放。`httpHeaders` 仅允许 `User-Agent`、`Referer`、
`Origin`、`Accept` 和 `Accept-Language`，最多 5 个；单值最多 2048 UTF-8 字节，总计最多
4096 字节，值必须是无首尾空白的可见 ASCII。接收端必须拒绝 `Cookie`、
`Authorization`、未知 Header、控制字符和非字符串值。主轨与 `audioTrack` 分别验证
Header；音频轨不支持 RTSP。RTSP 不允许携带 `httpHeaders`。

### 6.3 `playlist.replace`

```json
{
  "v": 1,
  "type": "playlist.replace",
  "id": "uuid",
  "sessionId": "uuid",
  "commandSeq": 2,
  "ts": 1787702400200,
  "payload": {
    "revision": 12,
    "repeatMode": "repeatAll",
    "activeItemId": "item-uuid",
    "items": [
      {"id": "item-uuid", "source": {"kind": "local", "assetId": "asset-uuid"}}
    ]
  }
}
```

revision 必须严格递增。相同 revision + 相同 payload 幂等；相同 revision + 不同 payload 返回
`revision_conflict`。首期列表编辑统一发送完整快照，最多 500 项，避免跨端 patch 顺序歧义。

## 7. 模式与播放命令

### 7.1 业务模式

`mode.set` payload 为 `{"mode":"media|photo|mirror"}`；接收端按 commandSeq 串行完成资源切换，
响应命令后发送 `mode.state`，包含 `mode`、`previousMode` 和可选 `error`，不另设 mode revision。
进入 `photo` 时保存并暂停媒体上下文；回到 `media` 时恢复原 item、position 和进入照片前的
播放/暂停意图。v1 首期请求 `mirror` 返回 `unsupported_mode`，第二阶段再启用。

### 7.2 播放命令

| type | payload | 说明 |
|---|---|---|
| `player.play` | `{}` | 播放或从 buffering 自动等待 |
| `player.pause` | `{}` | 暂停并保留画面 |
| `player.stop` | `{}` | 停止并回到媒体待播状态 |
| `player.seek` | `{"positionMs":12345}` | 点播源跳转 |
| `player.select` | `{"itemId":"uuid","autoplay":true}` | 选择列表项 |
| `player.next` | `{}` | 用户显式下一项，直播也允许 |
| `player.previous` | `{}` | 上一项 |
| `player.repeat` | `{"mode":"repeatOne|repeatAll|playOnce"}` | 播放模式 |
| `player.volume` | `{"value":60}` | 0-100，返回映射后的实际值 |
| `player.mute` | `{"muted":true}` | 静音开关 |

所有命令按第 4 节携带 `commandSeq`。默认超时 3 秒；进入 preparing 的命令可以先确认接受，
再通过状态事件报告首帧或错误。

## 8. 状态事件

### 8.1 `player.state`

```json
{
  "v": 1,
  "type": "player.state",
  "id": "uuid",
  "sessionId": "uuid",
  "ts": 1787702400000,
  "payload": {
    "sequence": 109,
    "playlistRevision": 12,
    "itemId": "item-uuid",
    "state": "playing",
    "positionMs": 8342,
    "durationMs": 245000,
    "bufferedPositionMs": 28700,
    "volume": 57,
    "muted": false,
    "repeatMode": "repeatAll",
    "retryAttempt": 0,
    "error": null
  }
}
```

`sequence` 只在当前 `sessionId` 内单调递增，新会话从 1 重新开始。发送端必须先按 sessionId
分组，sessionId 变化时重置最后 sequence；不得用旧会话的高值丢弃新会话状态。playing 时位置
约每 500 ms 更新一次，paused 时只在状态变化时发送。

状态值：`idle`、`preparing`、`playing`、`paused`、`buffering`、`completed`、`error`。

### 8.2 `cache.state`

```json
{
  "v": 1,
  "type": "cache.state",
  "id": "uuid",
  "sessionId": "uuid",
  "ts": 1787702400000,
  "payload": {
    "itemId": "item-uuid",
    "state": "partial",
    "cachedBytes": 104857600,
    "contentLength": 4281093351,
    "ranges": [[0, 104857599]]
  }
}
```

状态为 `none|partial|complete|unsupported`。`ranges` 最多返回 32 段；超过时合并为摘要，避免
消息无限增长。RTSP 和直播必须报告 `unsupported`。

### 8.3 `connection.degraded`

接收端 UI 的横幅由本地连接/网络状态驱动，不依赖发送端命令。接收端可以把相同诊断回传给
发送端，字段包括 `reason`、`cachedPlaybackAvailable` 和 `retryAt`。

## 9. 心跳

- 双方每 5 秒发送 `session.ping`，payload 带 nonce 和发送时间。
- 对端立即回复 `session.pong`，回显 nonce。
- 15 秒没有收到任何有效消息则控制状态进入 reconnecting 并关闭旧 socket。
- 任意有效消息更新最后活动时间；心跳不能延长已过期的配对 challenge。
- 心跳超时不得清空播放列表、缓存或强制停止播放器。

## 10. HTTPS Range 媒体服务

### 10.1 内容身份

所有 `HEAD` 和 `GET` 都要求 bearer 授权。`HEAD` 返回：

```http
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 4281093351
Content-Type: video/mp4
ETag: "<assetContentId>"
```

ETag 是双引号包围的强 validator，值与播放列表的 `assetContentId` 完全对应。接收端开始读取
前先 `HEAD`，后续所有 `GET` 必须携带取得的 `If-Match`；缺少返回 `428 Precondition Required`，
不匹配返回 `412 Precondition Failed` 并触发列表项刷新。

### 10.2 Range 请求

```http
GET /v1/media/<assetId> HTTP/1.1
Host: <wss-peer-ip>:<announced-port>
Authorization: Bearer <session-token>
If-Match: "<assetContentId>"
Range: bytes=1048576-2097151
```

服务端必须支持一个字节区间的三种形式：

- `bytes=N-M`：闭区间；M 超过文件末尾时截断。
- `bytes=N-`：从 N 到文件末尾。
- `bytes=-S`：最后 S 字节；S 大于长度时返回完整文件区间。

合法 Range 返回 `206`、准确 `Content-Range` 和 `Content-Length`。无 Range 的 GET 允许并返回
`200`，但仍要求 `If-Match` 且使用流式响应。多区间、语法错误、N 越界或 S 为 0 返回 `416`
和 `Content-Range: bytes */<length>`。

每个会话最多 4 个并发媒体请求，单资产最多 2 个。超过限制返回 `503 Service Unavailable` 和
整数秒 `Retry-After`，属于资源暂态错误，不计入永久错误重试次数。读取块和 socket 写入遵守
背压，断开时取消读取。

### 10.3 授权与固定

- bearer token 与 endpoint generation 在新会话或发送端媒体服务重启后更新。
- token 仅授权当前播放列表已注册 assetId。
- 接收端按第 5.1 节对当前 HTTPS 叶证书做 DER SHA-256 精确匹配；与 announce 不符时在发送
  Authorization 前停止读取。连接专用 SSL 配置不得影响外部 URL 的系统 CA/主机名校验。
- 媒体 host 始终使用当前 WSS 对端 IP；不得信任消息或 URL 中的替代 host。
- token、Authorization、URL query 和真实文件路径不得写日志。

## 11. 照片传输

### 11.1 两阶段信令

本节的发送端 start/meta JSON 示例只展示 `payload`，typed response 示例展示完整信封。所有
发送端 photo 信令都是握手后的有副作用命令，必须装入第 4 节完整信封并携带当前 session 的
`sessionId`、`id` 和 `commandSeq`。

`photo.batch.start` 只声明占位顺序，不要求图片处理已完成：

```json
{
  "batchId": "uuid",
  "revision": 1,
  "count": 3,
  "photoIds": [
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
    "33333333-3333-4333-8333-333333333333"
  ]
}
```

接收端校验 1-9 项后立即创建 loading 槽位，并以如下唯一直接响应回复 start：

```json
{
  "v": 1,
  "type": "photo.batch.ready",
  "id": "uuid",
  "replyTo": "batch-start-command-id",
  "sessionId": "uuid",
  "ts": 1787702401000,
  "payload": {"ok": true, "batchId": "uuid", "revision": 1}
}
```

每张处理完成的图片再发 `photo.item.meta`：

```json
{
  "batchId": "uuid",
  "revision": 1,
  "photoId": "11111111-1111-4111-8111-111111111111",
  "transferId": "uuid",
  "name": "board.jpg",
  "mime": "image/jpeg",
  "width": 1920,
  "height": 1080,
  "size": 482190,
  "sha256": "base64url-sha256",
  "chunkCount": 8
}
```

接收端以如下唯一直接响应回复 meta；随后发送端才能从该 index 发二进制 chunk：

```json
{
  "v": 1,
  "type": "photo.item.ready",
  "id": "uuid",
  "replyTo": "item-meta-command-id",
  "sessionId": "uuid",
  "ts": 1787702401100,
  "payload": {
    "ok": true,
    "batchId": "uuid",
    "photoId": "11111111-1111-4111-8111-111111111111",
    "transferId": "uuid",
    "nextChunkIndex": 0
  }
}
```

其他信令：

- `photo.batch.update`：携带递增 revision 和明确的 `removedPhotoIds`；接收端删除对应槽位，
  不能只依赖下调后的 count 猜测是哪一项。
- `photo.chunk.ack`：按 transferId 累计确认 `nextChunkIndex`，只确认已持久化数据；最后一块的 ACK
  只表示字节已写入，不表示照片校验成功。
- `photo.item.complete`：接收端校验 size/SHA-256 并原子发布单项后发送；发送端必须收到同一
  transferId 的该事件后才能把单项记为完成。
- `photo.item.failed`：接收端取消可识别 transfer 后发送，payload 带 photoId、transferId、
  errorCode、retryable 和 attempt；v1 中 retryable 固定为 false、attempt 固定为 0。发送端汇总
  失败项并继续处理同批次的其他照片，最后用一次 batch update 精确移除失败槽位。
- `photo.batch.complete`：所有未删除项均发布后发送。
- `photo.batch.cancel`：任一方取消并清理未完成临时文件。
- `photo.operation`：按 batch revision 执行放大、退出放大、上一张、下一张和缩放复位。

| errorCode | retryable | 接收端槽位 | 发送端动作 |
|---|---|---|---|
| `storage_low` / `write_failed` / `transfer_corrupt` | false | 显示错误后移除 | 递增 batch revision，以 removedPhotoIds 同步并提示 |
| `invalid_message`（可映射 transfer） | false | 显示错误后移除 | 递增 batch revision，以 removedPhotoIds 同步并提示 |

接收端在处理 `photo.item.meta` 时按声明 size 预留空间；不足则返回 `storage_low` 错误响应并立即
释放 photoId 槽位。发送端按上表处理 meta 错误或 `photo.item.failed`，不能让槽位永久 loading。

### 11.2 跨会话续传

`batchId`、`photoId` 和 `transferId` 由发送端生成，作用域为接收端 deviceId + 可信 senderId，
不随 sessionId 改变，也不能由其他发送端查询。控制断开后，接收端持久化批次元数据、槽位和
未完成临时文件：transfer 在最后有效 chunk 或 meta 后保留 10 分钟，批次在最后一个 item 活动
后保留 10 分钟；进程重启也执行同一规则，超过后才清理。该保留只适用于等待重连的可续传
状态；明确 failed、cancelled 或 removed 的 transfer 立即删除临时文件并释放需求/空间统计。

新会话进入 photo 模式后，发送端发送 `photo.batch.resume.query`，payload 包含 batchId、已知
revision 和 transferId 列表。接收端将 `photo.batch.resume.state` 作为该 query 的唯一 typed
response 返回；完整信封形状如下：

```json
{
  "v": 1,
  "type": "photo.batch.resume.state",
  "id": "uuid",
  "replyTo": "resume-query-command-id",
  "sessionId": "uuid",
  "ts": 1787702402000,
  "payload": {
    "ok": true,
    "batchId": "uuid",
    "batchStatus": "active",
    "revision": 2,
    "removedPhotoIds": [],
    "items": [
      {
        "photoId": "11111111-1111-4111-8111-111111111111",
        "status": "awaitingMeta",
        "transferId": null,
        "nextChunkIndex": null
      }
    ]
  }
}
```

`batchStatus` 为：

- `active`：批次存在且可继续，返回当前 revision、removedPhotoIds 和 items。
- `complete`：批次已完整发布，发送端不再传输。
- `notFound`：批次已过期、被清理或状态丢失；items 为空。

payload 始终包含 `batchId`、`batchStatus`、`revision`、`removedPhotoIds` 和 `items`。
`active|complete` 的 revision 为非负整数；`notFound` 的 revision 必须为 null，且两个数组必须
为空。字段不得因 null 或空数组而省略。

`items` 按 photoId 返回以下固定形状；两个 nullable 字段必须存在，使用 JSON null 而不是省略：

| status | transferId | nextChunkIndex | 发送端动作 |
|---|---|---|---|
| `awaitingMeta` | null | null | 继续处理并发送 meta |
| `ready` | 非空 | 0 | 从 0 发送 |
| `partial` | 非空 | 1..chunkCount-1 | 从返回 index 继续 |
| `complete` | 非空 | chunkCount | 不再发送 |
| `removed` | null | null | 已由更高 batch revision 删除，不再发送 |

当 `batchStatus=notFound` 时，发送端必须以原 batchId、当前 revision 和仍需展示的有序 photoIds
重发 `photo.batch.start` 重建槽位，再使用新 transferId 走 meta/ready/chunk。接收端对未知 batchId
的 `photo.item.meta` 返回顶层 `item_not_found`，绝不自动建批。新 session 的 commandSeq 从 1
计数，不影响设备级传输标识。上述 query/state 和每种 status 都必须有合法/非法 fixture。

### 11.3 32-byte 二进制头与发送窗口

```text
Offset  Size  Field
0       4     Magic ASCII "LMC1"
4       1     Version (0x01)
5       1     Kind (0x10 = photo chunk)
6       2     Flags unsigned BE (bit 0 = last chunk)
8       16    transferId UUID, RFC 4122 raw bytes
24      4     chunkIndex unsigned BE
28      4     payloadLength unsigned BE
32      ...   payload
```

帧长度必须恰好为 `32 + payloadLength`，payloadLength 最大 64 KiB。新 payload 的 `chunkIndex`
必须等于接收端为该 transfer 记录的 expectedNextChunkIndex：首次 fresh ready 后为 0，断点续传时
为 item ready/resume state 返回的 nextChunkIndex，持久化后逐帧递增。小于 expected 的重复 frame
不再次落盘，也不计入每 transfer/全局未确认 chunk 或 payload 窗口；接收端最多每 250 ms 合并
重发一次当前 nextChunkIndex ACK。每个 transfer 单独统计重复帧：10 秒内达到 32 帧，或收到重复
帧时距上次成功持久化前进已满 10 秒，立即按 §11.1 的 `invalid_message` 行取消 transfer 并发送
不可重试 item.failed，防止槽位永久 loading。大于 expected 的跳号 frame 同样按该行处理。
前进计时基准在 item ready/resume state 发出时初始化，此后只有成功持久化 expected frame 才
刷新，避免重连后的首个重复帧立即触发旧时间戳。最后一帧必须设置 last flag，且其 index 必须
为 `chunkCount - 1`。

transferId 将 chunk 唯一映射到 `photo.item.meta` 中的 photoId，接收端按以下顺序处理异常：

- 头部结构本身无法安全解析（magic/version/kind/帧长/payloadLength 无效）：发送
  `protocol.error(code=invalid_message, reason=malformed_binary_header, transferId=null)` 并关闭
  WSS；已知 transfer 保持可续传。
- 头部结构合法，transferId 属于已取消/完成/removed 的 tombstone：静默丢弃尾包，不落盘、
  不关闭 WSS、不影响其他 transfer。每个连接最多保留最近 256 个 tombstone、最长 60 秒；同一
  tombstone 的尾包超过 32 帧后关闭异常连接。
- 头部结构合法，但 transferId 从未 ready 或未知：丢弃并发送
  `protocol.error(code=invalid_state, reason=unknown_transfer, transferId=<parsed>)`；同一连接 10 秒内
  超过 32 帧才视为滥用并关闭 WSS。
- 可映射到活动 transfer，但字段顺序、chunkIndex、last/chunkCount 语义不一致：丢弃 frame、
  取消 transfer，并按 §11.1 的 `invalid_message` 行发送不可重试 item.failed。

fixtures 必须覆盖 fresh index 0、从 nextChunkIndex=N 续传、index<N 重复不改变窗口且 ACK 合并、
重复帧 32/10 秒与无前进 10 秒边界、index>N 跳号、取消后的 tombstone 尾包、未知未 ready ID
的 `protocol.error` 和结构不可解析头部的 `protocol.error`。

接收端对每个有新数据的 transfer 在“累计持久化 32 chunks、距上次 ACK 250 ms、遇到最后一块”
任一条件先到时先同步临时文件，再发送累计 ACK。发送端按单 transfer 串行上传，每次最多发送
32 chunks（最大 2 MiB）后必须等待覆盖该窗口的累计 ACK，因而不会把照片数据无限排在心跳和
控制命令之前；最后一个窗口继续等待 `photo.item.complete` 或 `photo.item.failed`，不能以最终 ACK
判定成功。接收端不根据 socket 到达时序猜测 ACK 是否已被发送端收到；它只校验连续 index、
last/chunkCount 和帧结构，并按上述重复帧/跳号规则处置。

完成时校验声明大小和 SHA-256，再原子改名。照片总配额 512 MiB，默认保留最近 5 个完成批次；
当前展示批次受保护，临时文件计入配额，启动时仅清理超过 10 分钟的未完成 transfer。

## 12. 错误分类与错误码

| 分类 | 示例 | 接收端行为 |
|---|---|---|
| 网络暂态 | 无网络、连接超时/重置、DNS 暂时失败、HTTP 503 | 保持末帧和 buffering，按有界退避持续等待，不消耗永久错误配额 |
| 资源暂态 | 本地媒体并发 503 + Retry-After | 按服务端建议时间重试，不消耗永久错误配额 |
| 资源永久 | HTTP 404/412/416、文件删除/变化、权限拒绝 | 1/2/4 秒最多 3 次，随后 error |
| 解码永久 | 不支持容器/codec、decoder 初始化失败 | 能力复核 1 次后 error |

切换 item 或用户显式重试才重置永久错误次数。网络暂态即使长期存在也不自动跳过当前项。

| code | 含义 |
|---|---|
| `invalid_message` | JSON、字段或二进制头无效 |
| `message_too_large` | 超过协议限制 |
| `unsupported_version` | 无共同协议版本 |
| `pairing_required` | 需要配对 |
| `pairing_failed` | 连接码错误或配对状态无效 |
| `pairing_expired` | 连接码已过期，需要重新建立 challenge |
| `pairing_locked` | 失败过多，暂时锁定 |
| `receiver_busy` | 已有活动发送端 |
| `invalid_session` | session/token 失效 |
| `identity_mismatch` | 当前 TLS 叶证书摘要与已固定/已公布 pin 不一致 |
| `invalid_state` | 当前状态不允许命令或二进制输入 |
| `sequence_conflict` | 相同 commandSeq 使用了不同 id |
| `duplicate_expired` | 重复命令结果已超出有界幂等窗口 |
| `revision_conflict` | 列表或批次 revision 冲突 |
| `stale_generation` | 媒体端点 generation 不是当前 session 的新值 |
| `unsupported_mode` | 当前版本未启用请求的业务模式 |
| `item_not_found` | 项目或资产不存在 |
| `source_unreachable` | 媒体来源不可达 |
| `source_changed` | 本地文件在注册后变化 |
| `unsupported_media` | 容器/编码不受设备支持 |
| `storage_low` | 缓存/照片空间不足 |
| `write_failed` | 已预留资源的持久化写入失败 |
| `transfer_corrupt` | 大小或摘要校验失败 |
| `timeout` | 操作超时 |
| `internal_error` | 未分类内部错误，日志带 correlation ID |

## 13. 固定样例与兼容

实现时在 `protocol/fixtures/v1/` 保存每种消息的合法、边界和非法固定样例。Kotlin 与 Dart
必须读取同一份 fixtures 进行解析/序列化测试。新增可选字段保持向后兼容；删除、改类型或改变
语义必须升级协议版本。
