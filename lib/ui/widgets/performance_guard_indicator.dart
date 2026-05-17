import 'package:flutter/material.dart';

/// 性能限制提示组件 (需求 §23)
///
/// 主界面统一图标，展示 Engine 返回的限速原因。
/// 所有限速/限制原因统一在一处显示，点击查看详情，不弹窗打断用户。
class PerformanceGuardIndicator extends StatelessWidget {
  final List<PerformanceLimit> activeLimits;
  final VoidCallback? onTap;

  const PerformanceGuardIndicator({
    super.key,
    this.activeLimits = const [],
    this.onTap,
  });

  bool get hasActiveLimits => activeLimits.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!hasActiveLimits) return const SizedBox.shrink();

    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: activeLimits.map((l) => l.title).join(', '),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _getColor().withAlpha(30),
            shape: BoxShape.circle,
          ),
          child: Icon(
            _getIcon(),
            size: 20,
            color: _getColor(),
          ),
        ),
      ),
    );
  }

  IconData _getIcon() {
    for (final limit in activeLimits) {
      switch (limit.type) {
        case PerformanceLimitType.battery:
          return Icons.battery_alert;
        case PerformanceLimitType.thermal:
          return Icons.thermostat;
        case PerformanceLimitType.memory:
          return Icons.memory;
        case PerformanceLimitType.speedLimit:
          return Icons.speed;
        case PerformanceLimitType.concurrentDowngrade:
          return Icons.slow_motion_video;
      }
    }
    return Icons.warning_amber;
  }

  Color _getColor() {
    for (final limit in activeLimits) {
      switch (limit.type) {
        case PerformanceLimitType.battery:
        case PerformanceLimitType.thermal:
          return Colors.orange;
        case PerformanceLimitType.memory:
          return Colors.red;
        default:
          return Colors.amber;
      }
    }
    return Colors.grey;
  }
}

/// 性能限制详情弹窗
class PerformanceGuardDetailsDialog extends StatelessWidget {
  final List<PerformanceLimit> limits;

  const PerformanceGuardDetailsDialog({
    super.key,
    required this.limits,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.info_outline, size: 20),
          SizedBox(width: 8),
          Text('性能限制'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: limits.map((limit) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(_iconFor(limit.type), size: 18, color: _colorFor(limit.type)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(limit.title,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    Text(limit.description,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
        )).toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  IconData _iconFor(PerformanceLimitType type) => switch (type) {
    PerformanceLimitType.battery => Icons.battery_alert,
    PerformanceLimitType.thermal => Icons.thermostat,
    PerformanceLimitType.memory => Icons.memory,
    PerformanceLimitType.speedLimit => Icons.speed,
    PerformanceLimitType.concurrentDowngrade => Icons.slow_motion_video,
  };

  Color _colorFor(PerformanceLimitType type) => switch (type) {
    PerformanceLimitType.battery ||
    PerformanceLimitType.thermal => Colors.orange,
    PerformanceLimitType.memory => Colors.red,
    _ => Colors.amber,
  };
}

/// 性能限制类型
enum PerformanceLimitType {
  battery,
  thermal,
  memory,
  speedLimit,
  concurrentDowngrade,
}

/// 性能限制条目
class PerformanceLimit {
  final PerformanceLimitType type;
  final String title;
  final String description;

  const PerformanceLimit({
    required this.type,
    required this.title,
    required this.description,
  });
}
