import 'package:uuid/uuid.dart';

/// 设备模型
class Device {
  final String deviceId;
  final String name;
  final String platform; // android | windows
  final String ip;
  final int port;
  final int protocolVersion;
  final String? avatarHash;
  final bool isOnline;
  final DateTime lastSeen;

  const Device({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.ip,
    required this.port,
    required this.protocolVersion,
    this.avatarHash,
    this.isOnline = true,
    required this.lastSeen,
  });

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      deviceId: json['deviceId'] as String,
      name: json['name'] as String,
      platform: json['platform'] as String,
      ip: json['ip'] as String,
      port: json['port'] as int,
      protocolVersion: json['protocolVersion'] as int? ?? 1,
      avatarHash: json['avatarHash'] as String?,
      isOnline: json['isOnline'] as bool? ?? true,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int),
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'platform': platform,
        'ip': ip,
        'port': port,
        'protocolVersion': protocolVersion,
        'avatarHash': avatarHash,
        'isOnline': isOnline,
        'lastSeen': lastSeen.millisecondsSinceEpoch,
      };

  Device copyWith({
    String? deviceId,
    String? name,
    String? platform,
    String? ip,
    int? port,
    int? protocolVersion,
    String? avatarHash,
    bool? isOnline,
    DateTime? lastSeen,
  }) {
    return Device(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      avatarHash: avatarHash ?? this.avatarHash,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Device &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// 本机设备信息
class LocalDevice {
  final String deviceId;
  String name;
  String? avatarHash;

  LocalDevice({
    String? deviceId,
    required this.name,
    this.avatarHash,
  }) : deviceId = deviceId ?? const Uuid().v4();
}
