/// Engine Isolate 通信协议：命令与事件定义 (架构设计 v2.0 §3.3)
///
/// UI Isolate → Engine Isolate: EngineCommand
/// Engine Isolate → UI Isolate: EngineEvent

/// UI 发往 Engine 的命令
class EngineCommand {
  final String type;
  final Map<String, dynamic> payload;

  const EngineCommand({required this.type, required this.payload});

  factory EngineCommand.fromJson(Map<String, dynamic> json) =>
      EngineCommand(type: json['type'] as String, payload: json['payload'] as Map<String, dynamic>? ?? {});

  Map<String, dynamic> toJson() => {'type': type, 'payload': payload};
}

/// Engine 发往 UI 的事件
class EngineEvent {
  final String type;
  final Map<String, dynamic> data;

  const EngineEvent({required this.type, required this.data});

  factory EngineEvent.fromJson(Map<String, dynamic> json) =>
      EngineEvent(type: json['type'] as String, data: json['data'] as Map<String, dynamic>? ?? {});

  Map<String, dynamic> toJson() => {'type': type, 'data': data};
}

// ═══════════════════════════════════════════════════════════
// 命令类型常量
// ═══════════════════════════════════════════════════════════

class EngineCommandType {
  static const String startTransfer = 'start_transfer';
  static const String pause = 'pause';
  static const String resume = 'resume';
  static const String cancel = 'cancel';
  static const String shutdown = 'shutdown';
  static const String setSpeedLimit = 'set_speed_limit';
}

// ═══════════════════════════════════════════════════════════
// 事件类型常量
// ═══════════════════════════════════════════════════════════

class EngineEventType {
  static const String progress = 'progress';
  static const String speed = 'speed';
  static const String fileComplete = 'file_complete';
  static const String fileListChunk = 'file_list_chunk';
  static const String transferComplete = 'transfer_complete';
  static const String error = 'error';
  static const String phaseChange = 'phase_change';
  static const String modeChange = 'mode_change';
  static const String lowPerformance = 'low_performance';
  static const String diskFull = 'disk_full';
  static const String concurrencyChanged = 'concurrency_changed';
}
