---

# FastShare LAN Protocol Specification (FLP) v1.2

**协议名称**：FLP（FastShare LAN Protocol）
**协议版本**：v1.2
**发布日期**：2026-05-14
**传输层**：TCP（未来可扩展 QUIC）
**适用范围**：局域网设备发现、配对、文件/文件夹传输、断点续传、剪贴板共享
**目标平台**：Android / Windows（未来可扩展 iOS/macOS/Linux）

---

# 0. 设计目标

FLP 的目标是提供一个：

- **高吞吐**：尽可能跑满局域网带宽（千兆/万兆）
- **高可靠**：断线可恢复、粘包可解析、错误可追踪
- **易扩展**：协议版本可协商，允许新增消息类型而不破坏旧实现
- **低开销**：避免 TCP 上 JSON 行协议造成的解析复杂度
- **跨平台一致**：Android 与 Windows 行为一致
- **架构适配**：天然适配 Flutter Isolate 分离架构，避免 UI 卡顿

---

# 1. 名词与标识符定义

## 1.1 标识符

| 名称         | 类型 | 长度 | 说明                                 |
| ------------ | ---- | ---- | ------------------------------------ |
| `deviceId`   | UUID | 16B  | 设备永久唯一标识（首次生成后持久化） |
| `sessionId`  | UUID | 16B  | 本次 TCP 连接会话 ID（每次连接生成） |
| `transferId` | UUID | 16B  | 一次批量传输任务的 ID                |
| `fileId`     | UUID | 16B  | 单个文件的传输 ID（由发送端生成）    |

- `deviceId` 必须永久存储，不可随意变更
- `transferId` 必须在一次批次任务中全局唯一
- `fileId` 必须在 transferId 范围内唯一

---

## 1.2 角色定义

- **Sender**：发起传输任务的一方
- **Receiver**：接收传输任务的一方

同一 TCP 连接可双向发送，因此角色可以动态变化。

---

# 2. 协议分层

FLP 分为四层：

1. **Discovery Layer**：mDNS / QR / 手动输入 IP
2. **Session Layer**：TCP 建连、握手、心跳、认证
3. **Control Layer**：传输请求、接收确认、暂停恢复、取消
4. **Data Layer**：文件分块、滑动窗口 ACK、断点续传

---

# 3. Frame Layer（统一帧封装）

FLP 所有消息必须使用统一 Frame 结构封装。
禁止在 TCP 上直接发送 JSON 行或裸二进制流。

---

## 3.1 Frame Header 格式

**字节序**：Big Endian（网络字节序）

```
+----------------+----------------+----------------+----------------+
| magic (4B)     | frameVer (1B)  | type (1B)      | flags (2B)     |
+----------------+----------------+----------------+----------------+
| length (4B)                    | reserved (4B)                  |
+----------------+----------------+----------------+----------------+
| payload (length bytes)
+------------------------------------------------------------------+
| checksum (4B)                                                    |
+------------------------------------------------------------------+
```

---

## 3.2 Header 字段说明

| 字段       | 长度 | 说明                                            |
| ---------- | ---- | ----------------------------------------------- |
| `magic`    | 4B   | 固定值 `0x46 0x53 0x50 0x31`（ASCII `"FSP1"`）  |
| `frameVer` | 1B   | Frame 格式版本号，当前固定为 `0x01`             |
| `type`     | 1B   | 消息类型（见第 4 章）                           |
| `flags`    | 2B   | 标志位（见 3.3）                                |
| `length`   | 4B   | payload 长度（最大不得超过 `MAX_FRAME_LENGTH`） |
| `reserved` | 4B   | 保留字段，必须为 0                              |
| `payload`  | N    | 消息体                                          |
| `checksum` | 4B   | CRC32(header + payload)，不包含 checksum 字段   |

> **说明**：
> `frameVer` 仅表示 Frame 结构版本，通常长期不变。
> 协议语义版本协商由 HELLO 中 `protocolVersion/supportedVersions` 负责（见第 5 章）。

---

## 3.3 Flags 定义

flags 为 16bit bitmask：

| Bit  | 名称                | 说明                   |
| ---- | ------------------- | ---------------------- |
| 0    | `FLAG_ACK_REQUIRED` | 接收方必须回复 ACK     |
| 1    | `FLAG_COMPRESSED`   | payload 已压缩（预留） |
| 2    | `FLAG_ENCRYPTED`    | payload 已加密（预留） |
| 3    | `FLAG_ERROR`        | 表示此帧为错误响应     |
| 4-15 | reserved            | 保留                   |

---

## 3.4 Payload 编码约定

FLP 支持两类 payload：

- **控制类消息**：推荐使用 **CBOR**，允许 JSON 作为兼容实现
- **数据类消息**：必须使用二进制结构体

控制消息必须支持忽略未知字段（forward compatible）。

---

## 3.5 帧长度限制

必须实现最大帧长度限制，避免内存攻击：

- `MAX_FRAME_LENGTH = 16MB`（推荐默认）
- 超出限制必须直接断开连接并返回 ERROR（若可能）

---

# 4. Message Types（消息类型）

## 4.1 Type 枚举表

| type(hex) | 名称              | 用途                     |
| --------: | ----------------- | ------------------------ |
|      0x01 | HELLO             | 会话握手                 |
|      0x02 | HELLO_ACK         | 会话确认                 |
|      0x03 | PING              | 心跳                     |
|      0x04 | PONG              | 心跳回应                 |
|      0x10 | PAIR_REQUEST      | 请求配对                 |
|      0x11 | PAIR_CONFIRM      | 确认配对                 |
|      0x12 | PAIR_RESULT       | 配对结果                 |
|      0x20 | TRANSFER_OFFER    | 提供传输任务（文件列表） |
|      0x21 | TRANSFER_ACCEPT   | 接收方同意               |
|      0x22 | TRANSFER_REJECT   | 接收方拒绝               |
|      0x23 | TRANSFER_CANCEL   | 取消传输                 |
|      0x24 | TRANSFER_PAUSE    | 暂停传输                 |
|      0x25 | TRANSFER_RESUME   | 恢复/断点续传请求        |
|      0x30 | FILE_META         | 单文件元数据             |
|      0x31 | FILE_DATA         | 文件分块数据             |
|      0x32 | FILE_ACK          | 分块确认（滑动窗口）     |
|      0x33 | FILE_NACK         | 缺块请求（补发）         |
|      0x34 | FILE_COMPLETE     | 文件完成确认             |
|      0x35 | TRANSFER_COMPLETE | 批次完成                 |
|      0x40 | CLIPBOARD_PUSH    | 剪贴板推送               |
|      0x41 | CLIPBOARD_ACK     | 剪贴板确认               |
|      0x50 | ERROR             | 错误响应                 |

---

# 5. Session Layer（会话层）

## 5.1 HELLO（0x01）

连接建立后必须立即发送 HELLO。

payload（CBOR/JSON）：

```json
{
  "deviceId": "uuid",
  "sessionId": "uuid",
  "deviceName": "My PC",
  "platform": "windows|android",
  "appVersion": "2.0.0",

  "protocolVersion": 1,
  "supportedVersions": [1],

  "authToken": "optional_base64",

  "capabilities": {
    "resume": true,
    "clipboard": true,
    "aggregate": true
  }
}
```

字段说明：

- `protocolVersion`：当前客户端默认使用的协议语义版本
- `supportedVersions`：客户端支持的协议语义版本集合（必须包含 protocolVersion）
- `authToken`：若设备已配对，必须携带 token，否则必须拒绝连接
- `capabilities`：能力声明，用于后续协商

---

## 5.2 协议版本协商规则（新增）

双方握手必须遵循以下规则：

1. 接收方从 `supportedVersions` 中选择最大共同版本作为最终版本
2. 若无共同版本，必须拒绝连接并返回 `UNSUPPORTED_PROTOCOL`
3. 协商结果必须在 HELLO_ACK 中返回 `negotiatedVersion`

---

## 5.3 HELLO_ACK（0x02）

payload：

```json
{
  "deviceId": "uuid",
  "sessionId": "uuid",
  "accepted": true,
  "negotiatedVersion": 1,
  "message": "ok"
}
```

若拒绝：

```json
{
  "accepted": false,
  "reason": "UNSUPPORTED_PROTOCOL|AUTH_FAILED"
}
```

---

## 5.4 心跳机制（PING/PONG）

- 默认间隔：3 秒发送 PING
- 超时：10 秒未收到 PONG 则认为连接断开

PING payload：

```json
{
  "timestamp": 1710000000
}
```

PONG payload：

```json
{
  "timestamp": 1710000000
}
```

---

# 6. Pairing（配对协议）

配对用于生成身份认证 token，以防止局域网冒充设备。

## 6.1 PAIR_REQUEST（0x10）

```json
{
  "deviceId": "uuid",
  "deviceName": "Phone",
  "pairCode": "123456",
  "nonce": "base64_16bytes"
}
```

---

## 6.2 PAIR_CONFIRM（0x11）

```json
{
  "pairCode": "123456",
  "nonce": "same_nonce",
  "confirm": true
}
```

---

## 6.3 PAIR_RESULT（0x12）

```json
{
  "success": true,
  "token": "base64_32bytes"
}
```

---

## 6.4 Token 生成规则（强制要求）

双方 token 必须一致：

```
token = SHA256(deviceIdA + deviceIdB + nonce + pairCode)
```

生成后必须永久存储（绑定对方 deviceId）。

后续 HELLO 必须携带 token，否则拒绝连接。

---

# 7. Transfer Control（批次传输控制）

## 7.1 TRANSFER_OFFER（0x20）

Sender 发起批次传输请求：

```json
{
  "transferId": "uuid",
  "senderDeviceId": "uuid",
  "batchName": "CameraBackup",
  "totalSize": 123456789,
  "fileCount": 12,
  "folderMode": true,
  "files": [
    {
      "fileId": "uuid",
      "relativePath": "DCIM/IMG_0001.JPG",
      "size": 5234523,
      "mtime": 1710000000,
      "hash": "optional"
    }
  ]
}
```

说明：

- `relativePath` 必须使用 `/` 分隔符（跨平台统一）
- Receiver 存储时自行转换为平台路径

---

## 7.2 TRANSFER_ACCEPT（0x21）

Receiver 同意传输：

```json
{
  "transferId": "uuid",
  "savePath": "Download/FastShare/",
  "overwritePolicy": "rename|overwrite|skip"
}
```

---

## 7.3 TRANSFER_REJECT（0x22）

```json
{
  "transferId": "uuid",
  "reason": "USER_REJECTED"
}
```

---

## 7.4 TRANSFER_CANCEL（0x23）

```json
{
  "transferId": "uuid",
  "reason": "USER_CANCEL|DISK_FULL|NETWORK_ERROR"
}
```

---

## 7.5 TRANSFER_PAUSE（0x24）

```json
{
  "transferId": "uuid"
}
```

---

## 7.6 TRANSFER_RESUME（0x25）

恢复或断点续传请求：

```json
{
  "transferId": "uuid"
}
```

---

# 8. File Transfer（文件传输协议）

## 8.1 FILE_META（0x30）

Sender 发送文件元信息：

```json
{
  "transferId": "uuid",
  "fileId": "uuid",
  "relativePath": "DCIM/IMG_0001.JPG",
  "size": 5234523,
  "chunkSize": 1048576,
  "hashAlgo": "xxhash64|blake3|sha256",
  "fileHash": "optional"
}
```

---

## 8.2 FILE_DATA（0x31）

FILE_DATA payload 必须为二进制结构体：

```
+----------------+----------------+----------------+----------------+
| transferId(16B)| fileId(16B)    | chunkIndex(4B) | offset(8B)     |
+----------------+----------------+----------------+----------------+
| dataLength(4B) | dataBytes(N)                                   |
+-----------------------------------------------------------------+
| chunkHash(8B)                                                   |
+-----------------------------------------------------------------+
```

字段说明：

- `chunkIndex`：从 0 开始递增
- `offset`：文件偏移
- `dataLength`：本 chunk 数据长度
- `chunkHash`：xxHash64(dataBytes)

约束：

- `offset` 必须等于 `chunkIndex * chunkSize`（除最后一块）
- 若不符合，Receiver 必须拒绝写入并返回 ERROR

---

## 8.3 FILE_ACK（0x32）

Receiver 回复 ACK（必须支持滑动窗口确认）：

```json
{
  "transferId": "uuid",
  "fileId": "uuid",
  "ackOffset": 8388608,
  "receivedRanges": [[0, 8388608]]
}
```

---

## 8.4 FILE_NACK（0x33）

Receiver 发现缺块或校验失败时，发送 NACK：

```json
{
  "transferId": "uuid",
  "fileId": "uuid",
  "missingRanges": [
    [1048576, 2097152],
    [5242880, 6291456]
  ]
}
```

Sender 收到后必须补发 missingRanges 对应的数据。

---

## 8.5 FILE_COMPLETE（0x34）

文件写入完成后，Receiver 必须发送：

```json
{
  "transferId": "uuid",
  "fileId": "uuid",
  "success": true,
  "finalHash": "optional"
}
```

若失败：

```json
{
  "transferId": "uuid",
  "fileId": "uuid",
  "success": false,
  "reason": "IO_ERROR|DISK_FULL"
}
```

---

## 8.6 TRANSFER_COMPLETE（0x35）

批次传输结束后，Receiver 发送：

```json
{
  "transferId": "uuid",
  "success": true,
  "failedFiles": 0
}
```

---

# 9. Resume（断点续传）

断点续传必须使用 missingRanges 或 receivedRanges。

## 9.1 Resume 流程

网络断开后重新连接：

1. 双方重新建立 TCP 连接
2. HELLO / HELLO_ACK 完成认证
3. Sender 发送 TRANSFER_RESUME
4. Receiver 返回每个 fileId 的 receivedRanges
5. Sender 根据 missingRanges 补发

---

## 9.2 Resume 信息结构（推荐）

Receiver 可在 TRANSFER_RESUME 回复中附带：

```json
{
  "transferId": "uuid",
  "files": [
    {
      "fileId": "uuid",
      "receivedRanges": [[0, 10485760]]
    }
  ]
}
```

---

# 10. Aggregate Stream（小文件聚合，可选）

当启用聚合模式时，Sender 可将多个小文件封装为流式结构，避免频繁握手。

## 10.1 Aggregate 文件流结构

```
[fileHeader][fileBytes][fileHeader][fileBytes]...
```

fileHeader 格式：

```
pathLen(2B) + pathBytes(pathLen) + fileSize(8B) + fileHash(8B)
```

---

# 11. Clipboard Sharing（剪贴板共享）

## 11.1 CLIPBOARD_PUSH（0x40）

```json
{
  "text": "https://example.com",
  "timestamp": 1710000000
}
```

---

## 11.2 CLIPBOARD_ACK（0x41）

```json
{
  "success": true
}
```

---

# 12. ERROR（错误响应）

## 12.1 ERROR（0x50）

```json
{
  "code": "DISK_FULL",
  "message": "Not enough storage",
  "transferId": "uuid optional",
  "fileId": "uuid optional"
}
```

---

## 12.2 标准错误码表

| code                   | 含义           |
| ---------------------- | -------------- |
| `UNSUPPORTED_PROTOCOL` | 协议版本不支持 |
| `AUTH_FAILED`          | token 校验失败 |
| `USER_REJECTED`        | 用户拒绝       |
| `DISK_FULL`            | 磁盘空间不足   |
| `PERMISSION_DENIED`    | 权限不足       |
| `FILE_NOT_FOUND`       | 文件不存在     |
| `IO_ERROR`             | IO 错误        |
| `NETWORK_ERROR`        | 网络异常       |
| `TIMEOUT`              | 超时           |
| `INTERNAL_ERROR`       | 内部错误       |

---

# 13. Compatibility（兼容性规则）

## 13.1 未知消息类型处理

若收到未知 `type`：

- 必须忽略该帧
- 不得断开连接

---

## 13.2 未知字段处理

控制消息 payload 中出现未知字段：

- 必须忽略
- 不得报错

---

# 14. Recommended Defaults（推荐默认参数）

| 参数                     | 默认值                   |
| ------------------------ | ------------------------ |
| chunkSize                | 1MB（PC），256KB（手机） |
| windowSize（在途 chunk） | 32                       |
| ackInterval              | 每 200ms 或累计 4MB      |
| pingInterval             | 3 秒                     |
| pingTimeout              | 10 秒                    |
| maxFrameLength           | 16MB                     |

---

# 15. Isolate Architecture Integration（新增章节）

FLP 推荐实现方式与 Flutter 多 Isolate 架构强绑定，以确保 UI 性能稳定。

## 15.1 Isolate 分工建议

- **UI Isolate（Flutter Main）**
  - 仅负责 UI 渲染
  - 仅负责 Riverpod 状态管理
  - 仅发送 EngineCommand（start/pause/resume/cancel）
  - 仅接收 EngineEvent（progress/speed/error）

- **Engine Isolate（Transfer Engine）**
  - 负责 FLP Frame 的构建与解析
  - 负责 Socket 读写（或委托给 Network Isolate）
  - 负责 chunk 校验、滑动窗口 ACK、断点续传
  - 负责队列调度、限速、动态并发

- **Network Isolate（可选）**
  - 专门负责 Socket I/O 与心跳维护
  - Engine 与 Network 通过消息队列交换数据块

---

## 15.2 强制实现约束（新增）

为保证 UI 不被阻塞，必须满足以下约束：

1. **UI Isolate 不得直接持有或操作 Socket**
2. **所有 FLP Frame 的解析与构建必须运行在非 UI Isolate**
3. 所有 chunk 校验（CRC32/xxHash）必须运行在 Engine 或 Network Isolate
4. 心跳 PING/PONG 必须由 Engine Isolate 或 Network Isolate 维护
5. UI Isolate 仅接收“已处理好的进度事件”，不得参与协议解析

---

# 16. Token Storage Security（新增章节）

Token 属于身份认证凭证，一旦泄露可导致局域网内冒充设备。

## 16.1 存储安全要求（强烈建议）

- Token 必须存储在应用私有安全存储区域
- 禁止存储于共享目录、可公开读取目录或外置存储

平台建议：

- **Android**：
  - 推荐 Android Keystore / EncryptedSharedPreferences
  - 或存储在 app 私有目录（至少不可被普通应用读取）

- **Windows**：
  - 推荐存储在 `%AppData%/<AppName>/trusted_devices.json`
  - 可使用 DPAPI 加密（推荐，但非强制）

---

## 16.2 Token 生命周期建议

- token 丢失、被清除、或用户主动删除信任设备后必须重新配对
- token 不应随 transferId/sessionId 改变

---

# 17. State Machine（简版）

```
CONNECTED
  -> HELLO / HELLO_ACK (版本协商 + token 校验)
  -> (optional PAIR)
  -> TRANSFER_OFFER
  -> TRANSFER_ACCEPT / TRANSFER_REJECT
  -> foreach file:
       FILE_META
       FILE_DATA stream
       FILE_ACK / FILE_NACK
       FILE_COMPLETE
  -> TRANSFER_COMPLETE
  -> IDLE
```

---

# 18. Discovery（附录）

## 18.1 mDNS 发现

服务名称：

```
_fastshare._tcp.local
```

TXT 字段：

| key    | 示例            |
| ------ | --------------- |
| id     | deviceId        |
| name   | deviceName      |
| port   | 45678           |
| ver    | protocolVersion |
| avatar | avatarHash      |

---

## 18.2 QR Code 格式

QR 内容为 JSON：

```json
{
  "ip": "192.168.1.5",
  "port": 45678,
  "deviceId": "uuid",
  "name": "MyPC",
  "ver": 1
}
```

---

# 19. 安全性说明

- FLP 默认不加密文件内容（符合需求）
- 必须实现 token 认证防止冒充设备
- token 仅用于认证，不用于加密数据

未来扩展加密可使用：

- 配对时交换公钥
- 会话协商 AES-GCM key
- Frame flags 标记 `FLAG_ENCRYPTED`

---

# 20. 强制实现约束（总表）

1. 必须实现 Frame 粘包解析
2. 必须限制最大帧长度
3. 控制消息必须 forward compatible（忽略未知字段）
4. FILE_DATA 必须支持 offset 写入（允许乱序到达）
5. 必须支持断点续传 missingRanges / receivedRanges
6. UI Isolate 不得直接接触 Socket 或协议解析

---

# 21. MVP 子集建议

最低可运行实现必须包含：

- HELLO / HELLO_ACK（含版本协商）
- PING / PONG
- TRANSFER_OFFER / ACCEPT / REJECT
- FILE_META / FILE_DATA / FILE_ACK
- FILE_COMPLETE / TRANSFER_COMPLETE
- ERROR
- PAIR + token（强烈推荐）

---

**文档结束**
FastShare LAN Protocol Specification (FLP) v1.2

---
