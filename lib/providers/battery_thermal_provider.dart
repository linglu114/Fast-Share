import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'platform_provider.dart';
import 'settings_provider.dart';
import 'transfer_provider.dart';
import '../ui/widgets/performance_guard_indicator.dart';
import '../util/logger.dart';

/// 电池 / 温度保护状态
class BatteryThermalState {
  final int? batteryLevel;
  final String? thermalState;
  final List<PerformanceLimit> activeLimits;
  final bool isLowBattery;
  final bool isCriticalBattery;
  final bool isThermalCritical;
  final bool autoLimitApplied;
  final bool dialogDismissedByUser;

  const BatteryThermalState({
    this.batteryLevel,
    this.thermalState,
    this.activeLimits = const [],
    this.isLowBattery = false,
    this.isCriticalBattery = false,
    this.isThermalCritical = false,
    this.autoLimitApplied = false,
    this.dialogDismissedByUser = false,
  });

  BatteryThermalState copyWith({
    int? batteryLevel,
    String? thermalState,
    List<PerformanceLimit>? activeLimits,
    bool? isLowBattery,
    bool? isCriticalBattery,
    bool? isThermalCritical,
    bool? autoLimitApplied,
    bool? dialogDismissedByUser,
    bool clearBatteryLevel = false,
    bool clearThermalState = false,
  }) {
    return BatteryThermalState(
      batteryLevel: clearBatteryLevel ? null : (batteryLevel ?? this.batteryLevel),
      thermalState: clearThermalState ? null : (thermalState ?? this.thermalState),
      activeLimits: activeLimits ?? this.activeLimits,
      isLowBattery: isLowBattery ?? this.isLowBattery,
      isCriticalBattery: isCriticalBattery ?? this.isCriticalBattery,
      isThermalCritical: isThermalCritical ?? this.isThermalCritical,
      autoLimitApplied: autoLimitApplied ?? this.autoLimitApplied,
      dialogDismissedByUser: dialogDismissedByUser ?? this.dialogDismissedByUser,
    );
  }
}

/// 电池 / 温度保护 Notifier
///
/// 每 30 秒轮询 [PlatformInterface.getBatteryLevel] 和
/// [PlatformInterface.getThermalState]，与用户阈值比较，驱动
/// [PerformanceGuardIndicator] 和自动限速。
///
/// 决策规则：
/// - 低电量（≤ lowBatteryThreshold，> criticalBatteryThreshold）：仅显示 indicator
/// - 极低电量（≤ criticalBatteryThreshold）：自动限速 1 MB/s + 弹窗（用户可取消）
/// - 过热（thermalState ≥ severe 且 thermalProtection 开启）：自动限速 1 MB/s
/// - 恢复后自动复原用户原始限速
class BatteryThermalNotifier extends Notifier<BatteryThermalState> {
  static const int _pollIntervalSec = 30;
  static const int autoLimitBytes = 1048576; // 1 MB/s
  static const _thermalCritical = {'severe', 'critical', 'emergency', 'shutdown'};

  Timer? _timer;

  @override
  BatteryThermalState build() {
    _timer = Timer.periodic(
      const Duration(seconds: _pollIntervalSec),
      (_) => _poll(),
    );
    ref.onDispose(() => _timer?.cancel());
    // 立即执行首次轮询
    Future.microtask(_poll);
    return const BatteryThermalState();
  }

  /// 用户取消了极低电量弹窗的限速
  void dismissCriticalDialog() {
    _restoreUserLimit();
    state = state.copyWith(
      dialogDismissedByUser: true,
      autoLimitApplied: false,
      activeLimits: _computeLimits(isLowBattery: state.isLowBattery,
          isCriticalBattery: true, // 仍处于极端电量，但不限速了
          isThermalCritical: state.isThermalCritical,
          autoLimitApplied: false),
    );
  }

  // ═══ 轮询 ═══

  Future<void> _poll() async {
    try {
      final platform = ref.read(platformProvider);
      final int? batteryLevel = await platform.getBatteryLevel();
      final String? thermalState = await platform.getThermalState();

      Logger.log('[BATT] poll: battery=$batteryLevel thermal=$thermalState');

      // 无传感器（台式机）：不做任何事
      if (batteryLevel == null && thermalState == null) return;

      final lowThreshold = ref.read(lowBatteryProvider);
      final criticalThreshold = ref.read(criticalBatteryProvider);
      final thermalEnabled = ref.read(thermalProtectionProvider);

      final isLow = batteryLevel != null &&
          batteryLevel <= lowThreshold &&
          batteryLevel > criticalThreshold;

      final isCritical = batteryLevel != null &&
          batteryLevel <= criticalThreshold;

      final isThermal = thermalEnabled &&
          thermalState != null &&
          _thermalCritical.contains(thermalState);

      final needLimit = (isCritical && !state.dialogDismissedByUser) || isThermal;

      Logger.log('[BATT] decision: isLow=$isLow isCritical=$isCritical isThermal=$isThermal needLimit=$needLimit thEnabled=$thermalEnabled lowTh=$lowThreshold critTh=$criticalThreshold');

      // 在 Notifier 内部直接操作速度上限（不通过 UI 层间接）
      if (needLimit && !state.autoLimitApplied) {
        Logger.log('[BATT] APPLY auto limit 1MB/s');
        _applyAutoLimit();
      } else if (!needLimit && state.autoLimitApplied) {
        Logger.log('[BATT] RESTORE user speed limit');
        _restoreUserLimit();
      }

      // 电量恢复 → 重置弹窗状态
      final dialogReset = !isCritical ? false : state.dialogDismissedByUser;

      state = state.copyWith(
        batteryLevel: batteryLevel,
        thermalState: thermalState,
        isLowBattery: isLow && !isCritical,
        isCriticalBattery: isCritical,
        isThermalCritical: isThermal,
        autoLimitApplied: needLimit,
        dialogDismissedByUser: dialogReset,
        activeLimits: _computeLimits(
          isLowBattery: isLow && !isCritical,
          isCriticalBattery: isCritical,
          isThermalCritical: isThermal,
          autoLimitApplied: needLimit,
        ),
      );
    } catch (e) {
      Logger.log('[BATT] poll error: $e');
    }
  }

  // ═══ 限速控制 ═══

  void _applyAutoLimit() {
    final userLimit = ref.read(speedLimitProvider);
    Logger.log('[BATT] _applyAutoLimit: userLimit=$userLimit autoLimit=$autoLimitBytes');
    if (userLimit == 0 || userLimit > autoLimitBytes) {
      ref.read(transferNotifierProvider.notifier).updateSpeedLimit(autoLimitBytes);
    }
  }

  void _restoreUserLimit() {
    final userLimit = ref.read(speedLimitProvider);
    Logger.log('[BATT] _restoreUserLimit: restoring to $userLimit');
    ref.read(transferNotifierProvider.notifier).updateSpeedLimit(userLimit);
  }

  // ═══ PerformanceLimit 构建 ═══

  List<PerformanceLimit> _computeLimits({
    required bool isLowBattery,
    required bool isCriticalBattery,
    required bool isThermalCritical,
    required bool autoLimitApplied,
  }) {
    final limits = <PerformanceLimit>[];
    if (isCriticalBattery) {
      limits.add(const PerformanceLimit(
        type: PerformanceLimitType.battery,
        title: '极低电量',
        description: '电池电量严重不足，已自动限制传输速度',
      ));
    } else if (isLowBattery) {
      limits.add(const PerformanceLimit(
        type: PerformanceLimitType.battery,
        title: '低电量',
        description: '建议连接充电器',
      ));
    }
    if (isThermalCritical) {
      limits.add(const PerformanceLimit(
        type: PerformanceLimitType.thermal,
        title: '设备过热',
        description: '设备温度过高，已自动限制传输速度以保护硬件',
      ));
    }
    if (autoLimitApplied && !isCriticalBattery && !isThermalCritical) {
      // 降级并发等其他限制场景
    }
    if (autoLimitApplied && (isCriticalBattery || isThermalCritical)) {
      limits.add(const PerformanceLimit(
        type: PerformanceLimitType.speedLimit,
        title: '速度已限制',
        description: '传输速度限制为 1 MB/s',
      ));
    }
    return limits;
  }
}

/// 电池 / 温度保护 Provider
final batteryThermalProvider =
    NotifierProvider<BatteryThermalNotifier, BatteryThermalState>(
        BatteryThermalNotifier.new);
