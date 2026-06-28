# 瞬息 (FastShare) — 局域网文件传输应用

跨平台局域网文件传输，基于 Flutter + 自定义 FLP 协议。

## 平台支持

- **Android** 8.0+ (API 26)
- **Windows** 10 1809+

## 核心特性

- **零配置发现**：UDP 广播自动扫描同局域网设备，WiFi 锁保持在线
- **二维码连接**：生成/扫描二维码快速建立连接，支持短码输入
- **高速传输**：TCP 明文高速传输，8MB 分块，滑动窗口流控，跑满带宽
- **双 Isolate 引擎**：发送/接收各自运行在独立 Isolate，UI 线程零阻塞
- **自适应传输策略**：大文件（≥100MB）顺序传输，小文件自动并发（3~8 并发），混合模式
- **性能保护**：256KB IO 缓冲、24MB 滑动窗口（3 chunk）、令牌桶限速、电量/温度感知
- **设备信任**：6 位配对码验证 + SHA256 Token 持久化
- **剪贴板共享**：通过 TCP 连接一键推送文本
- **深色模式**：跟随系统 + 手动切换，全页面 Material 3 适配
- **文件夹保留结构**：发送文件夹完整保留目录层级
- **国产 ROM 适配**：存储权限引导对话框覆盖 HyperOS / ColorOS / OriginOS / MagicOS

## 下载

从 [GitHub Releases](https://github.com/linglu114/Fast-Share/releases) 下载最新版本。

| 版本 | 适用 |
|------|------|
| `fastshare-vX.X.X-arm64-v8a.apk` | 大部分手机（~52 MB） |
| `fastshare-vX.X.X-armeabi-v7a.apk` | 2015 年前老手机 |
| `fastshare-vX.X.X-x86_64.apk` | 模拟器 |
| `fastshare-vX.X.X-all.apk` | 全架构合一（~88 MB） |
| `fastshare-vX.X.X-windows-x64.zip` | Windows 解压即用 |

> Android 端首次启动会弹出引导对话框，按指引授予「所有文件访问」权限后即可正常收发。

## 快速开始

```bash
# 安装依赖
flutter pub get

# Windows 运行
flutter run -d windows

# Android 运行
flutter run -d android

# Release 构建（全平台）
.\scripts\build_release.ps1
```

## 项目结构

```
fastshare/
├── lib/
│   ├── main.dart                     # 应用入口，权限请求，DB/日志初始化
│   ├── app.dart                      # MaterialApp 根组件，4-tab 导航，存储权限引导
│   ├── models/                       # 数据模型
│   ├── engine/                       # 传输引擎 (独立 Isolate)
│   │   ├── transfer_engine.dart      # 发送端 — 文件扫描/读取/分片/CRC32/Socket 写入
│   │   ├── receive_engine.dart       # 接收端 — 帧解析/磁盘写入/ACK 生成
│   │   ├── frame.dart                # FLP Frame — 封装/解析 (magic/CRC32/16B 头)
│   │   ├── session.dart              # Session Layer — HELLO/PING/PONG
│   │   ├── transfer_control.dart     # Control Layer — OFFER/ACCEPT/PAUSE/RESUME
│   │   ├── pairing.dart              # 配对协议 — 6 位码 + SHA256
│   │   ├── performance_guard.dart    # 滑动窗口 + 令牌桶限速 + 动态并发
│   │   └── commands.dart             # Isolate 命令/事件定义
│   ├── business/                     # 业务逻辑 (UI Isolate)
│   │   ├── discovery/                # UDP 广播设备发现
│   │   ├── connection/               # TCP 连接池 + 配对 + 传输协商
│   │   ├── clipboard/                # 剪贴板推送/接收
│   │   └── network_manager.dart      # 多网卡选择 + 手动 IP
│   ├── network/                      # TCP 服务器 (端口 34568)
│   ├── platform/                     # 平台抽象层 (Android + Windows)
│   ├── providers/                    # Riverpod 状态管理 (9 providers)
│   ├── storage/                      # SQLite + SharedPreferences 持久化
│   ├── ui/                           # 用户界面
│   │   ├── pages/devices/            # 设备与发现页
│   │   ├── pages/transfer/           # 传输页
│   │   ├── pages/history/            # 传输历史页
│   │   └── pages/settings/           # 设置页
│   └── util/                         # 工具 (常量/日志/格式化)
├── scripts/
│   └── build_release.ps1             # Release 构建脚本
├── FLP v1.2 协议.md                  # 协议规范
├── 架构设计v2.md                     # 架构设计文档
└── 项目需求v2.1.md                   # 需求规格说明书
```

## 通信协议

FLP（FastShare LAN Protocol）v1.2 — 四层自定义协议：

| 层 | 职责 |
|---|---|
| Frame Layer | 统一帧封装 (magic/CRC32/16B header) |
| Session Layer | TCP 握手 HELLO/ACK + 心跳 PING/PONG |
| Control Layer | 传输协商 OFFER/ACCEPT/REJECT，控制 PAUSE/RESUME/CANCEL，剪贴板推送 |
| Data Layer | 分块传输 CHUNK/ACK/NACK，断点续传 |

- 控制消息：UTF-8 JSON 封装在 FLP Frame 中
- 数据块：48 字节二进制头部 + 原始数据，零校验和标记
- 分块大小：8MB，滑动窗口 3 chunk（24MB 在途）
- 默认端口：TCP 34568，UDP 45679

详见 [`FLP v1.2 协议.md`](FLP%20v1.2%20%E5%8D%8F%E8%AE%AE.md)

## 技术栈

- Flutter 3.41 / Dart 3.11
- Riverpod 2.4 状态管理
- SQLite (sqflite + sqflite_common_ffi)
- 双独立 Isolate 传输引擎
- 自定义二进制协议 FLP v1.2 (Big Endian)
- UDP 广播设备发现
- MethodChannel 平台桥接
- permission_handler 权限管理

## 许可证

GNU General Public License v3.0 — 详见 [LICENSE](LICENSE)
