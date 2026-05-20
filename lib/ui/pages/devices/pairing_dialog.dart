import 'dart:async';
import 'package:flutter/material.dart';

/// 配对 PIN 码显示对话框
///
/// - 发起端（isConnector=true）：确认/取消按钮，30s 超时变为倒计时关闭
/// - 接收端（isConnector=false）：拒绝按钮 + 等待对方确认；30s 超时显示倒计时"知道了"
class PairingPinDialog extends StatefulWidget {
  final String deviceName;
  final String pairCode;
  final bool isConnector;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final VoidCallback? onReject;

  const PairingPinDialog({
    super.key,
    required this.deviceName,
    required this.pairCode,
    required this.isConnector,
    this.onConfirm,
    this.onCancel,
    this.onReject,
  });

  @override
  State<PairingPinDialog> createState() => _PairingPinDialogState();
}

class _PairingPinDialogState extends State<PairingPinDialog> {
  static const _timeoutSeconds = 30;
  static const _countdownSeconds = 5;

  Timer? _timer;
  bool _timedOut = false;
  int _countdown = _countdownSeconds;

  @override
  void initState() {
    super.initState();
    // 30s 超时计时器
    _timer = Timer(const Duration(seconds: _timeoutSeconds), _onTimeout);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onTimeout() {
    if (!mounted) return;
    setState(() {
      _timedOut = true;
      _countdown = _countdownSeconds;
    });
    _startCountdown();
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _timer?.cancel();
        return;
      }
      if (_countdown <= 1) {
        _timer?.cancel();
        Navigator.of(context).pop();
        return;
      }
      setState(() => _countdown--);
    });
  }

  void _dismiss() {
    _timer?.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.isConnector ? Icons.link : Icons.phonelink_setup,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.isConnector ? '设备配对' : '配对请求',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isConnector
                  ? '与 "${widget.deviceName}" 配对'
                  : '"${widget.deviceName}" 想要与你配对',
              style: const TextStyle(fontSize: 15),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            Text(
              '双方应显示相同的验证码：',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            _PinDisplay(pairCode: widget.pairCode),
            const SizedBox(height: 12),
            _buildStatusLine(),
          ],
        ),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildStatusLine() {
    if (_timedOut) {
      return Text(
        '连接超时，请核对验证码后重试',
        style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
      );
    }
    if (widget.isConnector) {
      return Text(
        '确认对方显示的验证码与此一致后点击确认',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      );
    }
    return Text(
      '等待对方确认中...',
      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
    );
  }

  List<Widget> _buildActions() {
    if (widget.isConnector) {
      // 发起端：始终有取消 + 确认按钮（超时后确认按钮变为倒计时关闭）
      return [
        TextButton(
          onPressed: widget.onCancel ?? _dismiss,
          child: const Text('取消'),
        ),
        if (_timedOut)
          FilledButton(
            onPressed: _dismiss,
            child: Text('知道了 ($_countdown)'),
          )
        else
          FilledButton(
            onPressed: widget.onConfirm,
            child: const Text('确认配对'),
          ),
      ];
    }

    // 接收端：显示拒绝按钮，超时后变为倒计时关闭
    if (_timedOut) {
      return [
        FilledButton(
          onPressed: _dismiss,
          child: Text('知道了 ($_countdown)'),
        ),
      ];
    }
    return [
      OutlinedButton(
        onPressed: widget.onReject ?? _dismiss,
        style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        child: const Text('拒绝'),
      ),
    ];
  }
}

/// PIN 数字显示组件，自适应宽度避免溢出弹窗
class _PinDisplay extends StatelessWidget {
  final String pairCode;
  const _PinDisplay({required this.pairCode});

  @override
  Widget build(BuildContext context) {
    final digits = pairCode.split('');
    // Allow horizontal scrolling if the code is too wide for the dialog
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: digits.map((digit) {
            return Container(
              width: 36,
              height: 48,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withAlpha(60),
                ),
              ),
              child: Center(
                child: Text(
                  digit,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
