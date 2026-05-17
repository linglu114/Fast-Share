# FastShare — 局域网文件传输应用

跨平台局域网文件传输，基于 Flutter + 自定义 FLP 协议。

## 平台支持

- **Android** 8.0+ (API 26)
- **Windows** 10 1809+
- 架构预留 macOS / iOS / Linux 扩展

## 核心特性

- **零配置发现**：UDP 广播自动扫描同局域网设备
- **三种传输模式**：顺序/自动并发/混合，100MB 阈值自动判定
- **极速传输**：TCP 明文高速传输，1MB 分块，跑满带宽
- **断点续传**：中断后自动恢复，无需重传
- **智能限速**：令牌桶算法 + 动态并发调整
- **性能保护**：256KB IO 缓冲、64MB 滑动窗口、电量/温度感知
- **设备信任**：6 位配对码验证 + SHA256 Token 持久化
- **深色模式**：跟随系统 + 手动切换

## 快速开始

```bash
# 安装依赖
cd fastshare
flutter pub get

# Windows 运行
flutter run -d windows

# Android 运行
flutter run -d android
```

## 项目结构

```
fastshare/
├── lib/
│   ├── main.dart              # 应用入口
│   ├── app.dart               # 主框架 + 深色模式
│   ├── models/                # 数据模型
│   │   ├── device.dart        # 设备模型
│   │   ├── transfer_task.dart # 传输任务/文件
│   │   └── history_record.dart
│   ├── engine/                # 传输引擎 (独立 Isolate)
│   │   ├── transfer_engine.dart   # Engine 入口 + 传输会话
│   │   ├── frame.dart             # FLP Frame Layer
│   │   ├── session.dart           # Session Layer
│   │   ├── commands.dart          # 命令/事件定义
│   │   ├── transfer_control.dart  # Transfer Control
│   │   ├── pairing.dart           # 配对协议
│   │   ├── performance_guard.dart # IO/内存/并发保护
│   │   └── stress_test.dart       # 压力测试工具
│   ├── business/              # 业务逻辑
│   │   ├── discovery/         # 设备发现
│   │   ├── connection/        # 连接管理
│   │   ├── clipboard/         # 剪贴板共享
│   │   └── network_manager.dart
│   ├── network/               # 网络层
│   │   └── tcp_server.dart    # TCP 服务器/客户端
│   ├── platform/              # 平台抽象层
│   │   ├── platform_interface.dart
│   │   ├── platform_windows.dart
│   │   └── platform_android.dart
│   ├── storage/               # 持久化
│   │   ├── database.dart      # SQLite
│   │   ├── history_repository.dart
│   │   ├── settings_repository.dart
│   │   └── trusted_device_repository.dart
│   ├── providers/             # Riverpod 状态管理
│   │   ├── settings_provider.dart
│   │   └── transfer_provider.dart
│   └── ui/                    # 用户界面
│       ├── pages/
│       │   ├── devices/       # 设备与发现
│       │   ├── transfer/      # 传输 + 接收确认
│       │   ├── history/       # 历史记录
│       │   └── settings/      # 设置
│       └── widgets/           # 可复用组件
└── pubspec.yaml
```

## 通信协议

FLP（FastShare LAN Protocol）v1.2 — 四层自定义协议：

| 层 | 职责 |
|---|---|
| Frame Layer | 统一帧封装 (magic/CRC32) |
| Session Layer | TCP 握手/心跳/认证 |
| Control Layer | 传输请求/接收确认/暂停恢复 |
| Data Layer | 分块/ACK/NACK/断点续传 |

详见 [`FLP v1.2.md`](../FLP%20v1.2.md)

## 压力测试

```dart
import 'engine/stress_test.dart';

final tool = StressTestTool();

// 生成 1000 个文件 (1KB~10MB)
final files = await tool.generateFiles(count: 1000);

// 生成嵌套文件夹结构
final folder = await tool.generateFolderStructure(depth: 5, filesPerDir: 50);

// 清理
await tool.cleanup();
```

## 技术栈

- Flutter 3.41 / Dart 3.11
- Riverpod 状态管理
- SQLite 本地存储
- 独立 Isolate 传输引擎
- 自定义二进制协议 (Big Endian)
- mDNS 备选方案 (UDP 广播)

## 许可证

MIT
