import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/transfer_task.dart';
import '../models/device.dart';
import '../engine/commands.dart';
import '../engine/transfer_engine.dart';
import '../util/logger.dart';
import '../platform/foreground_service_manager.dart';
import '../platform/content_uri_reader.dart';
import 'settings_provider.dart';
import 'connection_provider.dart';
import '../models/history_record.dart';
import '../storage/history_repository.dart';

/// 传输队列 Provider
final transferQueueProvider = StateProvider<List<TransferTask>>((ref) => []);

/// 活跃传输 Provider
final activeTransferProvider = StateProvider<TransferTask?>((ref) => null);

/// 传输 notifier
final transferNotifierProvider =
    NotifierProvider<TransferNotifier, void>(TransferNotifier.new);

class TransferNotifier extends Notifier<void> {
  SendPort? _engineSendPort;
  Future<Isolate>? _engineIsolate;
  // stored to prevent StreamSubscription GC
  // ignore: unused_field
  StreamSubscription<dynamic>? _engineSub;
  final _uuid = const Uuid();

  @override
  void build() {}

  /// 启动 Engine Isolate，返回 engine 命令端口
  Future<SendPort> _ensureEngine() {
    if (_engineIsolate != null && _ensureEngineReady != null) {
      return _ensureEngineReady!;
    }

    // 清理旧 engine
    _engineIsolate?.then((i) => i.kill());
    _engineIsolate = null;
    _engineSendPort = null;

    final receivePort = ReceivePort();
    _engineIsolate = Isolate.spawn(
      TransferEngine.entry,
      receivePort.sendPort,
    );

    // 监听 engine Isolate 未处理错误，防止 Isolate 静默终止
    _engineIsolate!.then((isolate) {
      isolate.addErrorListener(receivePort.sendPort);
    });

    final readyCompleter = Completer<SendPort>();
    _engineSub = receivePort.listen((message) {
      // Isolate 未处理错误 — List 格式 [error, stackTrace]
      if (message is List) {
        Logger.log('[TF] ENGINE ISOLATE CRASH: ${message.isNotEmpty ? message[0] : 'unknown error'}');
        if (message.length > 1) {
          Logger.log('[TF] ENGINE STACK: ${message[1]}');
        }
        // Notify UI of engine crash
        final active = ref.read(activeTransferProvider);
        if (active != null) {
          ref.read(activeTransferProvider.notifier).update((task) {
            if (task != null) {
              task.status = TransferStatus.failed;
              task.errorMessage = 'Engine crashed: ${message.isNotEmpty ? message[0] : 'unknown'}';
            }
            return task?.clone();
          });
        }
        _engineIsolate = null;
        _engineSendPort = null;
        _ensureEngineReady = null;
        return;
      }
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String?;
        final data = message['data'] as Map<String, dynamic>? ?? {};

        if (type == 'engine_ready' && data['enginePort'] is SendPort) {
          _engineSendPort = data['enginePort'] as SendPort;
          if (!readyCompleter.isCompleted) {
            readyCompleter.complete(_engineSendPort);
          }
          return;
        }

        _handleEngineEvent(message);
      }
    });

    _ensureEngineReady = readyCompleter.future;
    return _ensureEngineReady!;
  }

  Future<SendPort>? _ensureEngineReady;

  /// 处理 Engine 事件
  void _handleEngineEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final data = event['data'] as Map<String, dynamic>? ?? {};
    final transferId = data['transferId'] as String? ?? '-';

    // Log all non-progress events for debugging
    if (type != 'progress') {
      Logger.log('[TF] engine event: type=$type transferId=$transferId data=${data['message'] ?? data['success'] ?? data['phase'] ?? ''}');
    }

    switch (type) {
      case 'engine_ready':
        break;
      case 'file_list_chunk':
        _onFileListChunk(data);
        break;
      case 'phase_change':
        _onPhaseChange(data);
        break;
      case 'mode_change':
        _onModeChange(data);
        break;
      case 'progress':
        _onProgress(data);
        break;
      case 'file_complete':
        _onFileComplete(data);
        break;
      case 'transfer_complete':
        _onTransferComplete(data);
        break;
      case 'request_chunk':
        _onRequestChunk(data);
        break;
      case 'error':
        _onError(data);
        break;
      case 'concurrency_changed':
        _onConcurrencyChanged(data);
        break;
    }
  }

  void _onFileListChunk(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String;
    final active = ref.read(activeTransferProvider);
    if (active?.transferId != transferId) return;

    final files = (data['files'] as List? ?? []).cast<Map<String, dynamic>>();
    final totalSize = data['totalSize'] as int? ?? 0;

    // 引擎推送全部文件列表
    ref.read(activeTransferProvider.notifier).update((task) {
      if (task == null) return null;
      task.totalSize = totalSize;
      task.files = files.map((f) => FileTransferItem(
        fileId: f['fileId'] as String? ?? '',
        relativePath: f['relativePath'] as String? ?? '',
        size: f['size'] as int? ?? 0,
      )).toList();
      if (task.files.isNotEmpty) {
        task.fileCount = task.files.length; // 文件夹递归后的真实数量
      }
      // 同步更新队列中的同一条目
      final queue = ref.read(transferQueueProvider);
      final idx = queue.indexWhere((t) => t.transferId == transferId);
      if (idx >= 0) {
        queue[idx].totalSize = totalSize;
        queue[idx].fileCount = task.fileCount;
        ref.read(transferQueueProvider.notifier).state = [...queue];
      }
      return task.clone();
    });
  }

  void _onPhaseChange(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String;
    final active = ref.read(activeTransferProvider);
    if (active?.transferId != transferId) return;

    final phase = data['phase'] as String?;
    ref.read(activeTransferProvider.notifier).update((task) {
      if (task == null) return null;
      switch (phase) {
        case 'connecting':
          task.status = TransferStatus.connecting;
          break;
        case 'awaiting_accept':
          task.status = TransferStatus.awaitingAccept;
          break;
        case 'transferring':
          task.status = TransferStatus.transferring;
          break;
        case 'rejected':
          task.status = TransferStatus.rejected;
          task.errorMessage = data['message'] as String? ?? 'Receiver declined';
          break;
      }
      return task.clone();
    });

    if (phase == 'rejected' && active != null) {
      _saveHistory(active, 'rejected');
    }
  }

  void _onModeChange(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String;
    final active = ref.read(activeTransferProvider);
    if (active?.transferId != transferId) return;

    ref.read(activeTransferProvider.notifier).update((task) {
      if (task == null) return null;
      task.mode = _parseMode(data['mode'] as String?);
      task.totalSize = data['totalSize'] as int? ?? task.totalSize;
      task.status = TransferStatus.transferring;
      return task.clone();
    });
  }

  void _onProgress(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String;
    final active = ref.read(activeTransferProvider);
    if (active?.transferId != transferId) return;

    ref.read(activeTransferProvider.notifier).update((task) {
      if (task == null) return null;
      final newBytes = data['bytesTransferred'] as int?;
      if (newBytes != null && newBytes > 0) {
        task.bytesTransferred = newBytes;
      }
      final newTotal = data['totalSize'] as int?;
      if (newTotal != null && newTotal > 0) {
        task.totalSize = newTotal;
      }
      task.avgSpeed = (data['speed'] as num?)?.toDouble() ?? task.avgSpeed;
      final peak = (data['peakSpeed'] as num?)?.toDouble() ?? 0;
      if (peak > task.peakSpeed) task.peakSpeed = peak;
      return task.clone();
    });

    // 更新前台通知进度
    if (ForegroundServiceManager().isRunning) {
      final task = ref.read(activeTransferProvider);
      if (task != null) {
        ForegroundServiceManager().updateNotification(
          title: '发送到${task.peerDeviceName ?? ""}',
          body: '${(task.bytesTransferred / 1024 / 1024).toStringAsFixed(0)} / '
              '${(task.totalSize / 1024 / 1024).toStringAsFixed(0)} MB',
          progress: task.bytesTransferred,
          progressMax: task.totalSize,
        );
      }
    }
  }

  void _onFileComplete(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String;
    final fileId = data['fileId'] as String;
    final success = data['success'] as bool? ?? true;

    ref.read(activeTransferProvider.notifier).update((task) {
      if (task == null || task.transferId != transferId) return null;
      final file = task.files.where((f) => f.fileId == fileId).firstOrNull;
      if (file != null) {
        file.status =
            success ? TransferStatus.completed : TransferStatus.failed;
        // Ensure progress shows 100% even if last debounced update missed the final bytes
        if (success) file.bytesTransferred = file.size;
      }
      return task.clone();
    });
  }

  Future<void> _saveHistory(TransferTask task, String status) async {
    try {
      final repo = HistoryRepository();
      await repo.insert(HistoryRecord(
        transferId: task.transferId,
        deviceId: task.targetDeviceId,
        deviceName: task.peerDeviceName ?? task.targetDeviceId,
        batchName: task.batchName,
        totalSize: task.totalSize,
        fileCount: task.fileCount,
        success: status == 'completed',
        errorMessage: task.errorMessage,
        peakSpeed: task.peakSpeed,
        avgSpeed: task.avgSpeed,
        status: status,
        timestamp: DateTime.now(),
        savePath: task.savePath,
      ));
    } catch (_) {
      // 历史记录写入失败不阻断主流程
    }
  }

  void _onTransferComplete(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String;
    final active = ref.read(activeTransferProvider);

    if (active?.transferId == transferId) {
      ref.read(activeTransferProvider.notifier).update((task) {
        if (task != null) {
          task.status = TransferStatus.completed;
          task.bytesTransferred = task.totalSize;
        }
        return task?.clone();
      });

      if (active != null) {
        _saveHistory(active, 'completed');
      }

      // 从队列中移除
      final queue = ref.read(transferQueueProvider);
      ref.read(transferQueueProvider.notifier).state =
          queue.where((t) => t.transferId != transferId).toList();
    }

    // 队列为空时停止前台服务（如有并发接收，其进度事件会自动重启）
    if (ref.read(transferQueueProvider).isEmpty) {
      ForegroundServiceManager().stop();
    }

    // 关闭 content URI 通道，销毁 Engine Isolate
    ContentUriReader.closeAllContentStreams();
    _engineIsolate?.then((i) => i.kill());
    _engineIsolate = null;
    _engineSendPort = null;
    _ensureEngineReady = null;
  }

  void _onError(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String?;
    final message = data['message'] as String? ?? 'Unknown error';

    if (transferId != null) {
      ref.read(activeTransferProvider.notifier).update((task) {
        if (task?.transferId == transferId) {
          task!.status = TransferStatus.failed;
          task.errorMessage = message;
        }
        return task?.clone();
      });
      final active = ref.read(activeTransferProvider);
      if (active?.transferId == transferId && active != null) {
        _saveHistory(active, 'failed');
      }

      // Remove from queue
      final queue = ref.read(transferQueueProvider);
      ref.read(transferQueueProvider.notifier).state =
          queue.where((t) => t.transferId != transferId).toList();
    }

    // Clean up if no more transfers in queue
    if (ref.read(transferQueueProvider).isEmpty) {
      ContentUriReader.closeAllContentStreams();
      ForegroundServiceManager().stop();
      _engineIsolate?.then((i) => i.kill());
      _engineIsolate = null;
      _engineSendPort = null;
      _ensureEngineReady = null;
    }
  }

  void _onConcurrencyChanged(Map<String, dynamic> data) {
    final transferId = data['transferId'] as String?;
    final concurrency = data['concurrency'] as int? ?? 0;
    if (transferId != null) {
      ref.read(activeTransferProvider.notifier).update((task) {
        if (task?.transferId == transferId) {
          task!.concurrentCount = concurrency;
        }
        return task?.clone();
      });
    }
  }

  void _onRequestChunk(Map<String, dynamic> data) async {
    final transferId = data['transferId'] as String? ?? '';
    final fileId = data['fileId'] as String? ?? '';
    final uri = data['uri'] as String? ?? '';
    final chunkIndex = data['chunkIndex'] as int? ?? 0;
    final offset = data['offset'] as int? ?? 0;
    final length = data['length'] as int? ?? 0;

    try {
      final chunk = await ContentUriReader.readChunk(uri, offset, length);
      _engineSendPort?.send({
        'type': 'chunk_data',
        'payload': {
          'transferId': transferId,
          'fileId': fileId,
          'chunkIndex': chunkIndex,
          'offset': offset,
          'data': chunk,
          'error': chunk == null ? 'Read failed' : null,
        },
      });
    } catch (e) {
      _engineSendPort?.send({
        'type': 'chunk_data',
        'payload': {
          'transferId': transferId,
          'fileId': fileId,
          'chunkIndex': chunkIndex,
          'offset': offset,
          'error': '$e',
        },
      });
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 公共操作
  // ═══════════════════════════════════════════════════════════

  Future<void> startTransfer({
    required List<String> paths,
    List<Map<String, dynamic>>? contentFiles,
    required Device targetDevice,
    bool folderMode = false,
    required WidgetRef ref,
  }) async {
    // ── Android 文件夹模式：在主 Isolate 展开目录 ──
    // FilePicker.getDirectoryPath() 在 Android 通过 SAF 获取，
    // 返回的是 /tree/primary:... 格式的虚拟路径，Engine Isolate
    // 中 FileSystemEntity.typeSync() 无法识别导致 _files 为空。
    // 在主 Isolate 中用 Directory.list() 递归展开为 contentFiles 数组，
    // 每条带 realPath（真实路径）+ relativePath，Engine 直接打开文件。
    List<String> finalPaths = paths;
    List<Map<String, dynamic>>? finalContentFiles = contentFiles;
    bool finalFolderMode = folderMode;

    if (folderMode && Platform.isAndroid && paths.length == 1) {
      try {
        final dir = Directory(paths.first);
        if (await dir.exists()) {
          final expanded = <Map<String, dynamic>>[];
          final dirPath = dir.path;
          await for (final entity in dir.list(recursive: true)) {
            if (entity is File) {
              final abs = entity.path;
              var rel = abs.substring(dirPath.length).replaceAll('\\', '/');
              if (rel.startsWith('/')) rel = rel.substring(1);
              expanded.add({
                'uri': '',
                'name': rel,
                'size': await entity.length(),
                'realPath': abs,
              });
            }
          }
          if (expanded.isNotEmpty) {
            finalContentFiles = expanded;
            finalPaths = [];
            // folderMode 保留 true，接收端根据 relativePath 创建子目录
          }
        }
      } catch (e) {
        Logger.log('[TF] pre-scan directory failed: $e');
      }
    }

    // 并行：启动引擎 + 为 content URI 解析 fd 直读路径
    final engineReady = _ensureEngine();

    // 为无 realPath 的 content URI 打开文件描述符，
    // 让 Engine Isolate 通过 /proc/self/fd/$fd 直读，消除 Isolate 往返开销
    final resolvedContentFiles = <Map<String, dynamic>>[];
    if (finalContentFiles != null) {
      for (final f in finalContentFiles) {
        final uri = f['uri'] as String? ?? '';
        final realPath = f['realPath'] as String?;
        if (realPath == null && uri.isNotEmpty && ContentUriReader.isSupported) {
          final fd = await ContentUriReader.openContentFd(uri);
          if (fd >= 0) {
            resolvedContentFiles.add({...f, 'fd': fd});
            continue;
          }
        }
        resolvedContentFiles.add(f);
      }
    }

    await engineReady;

    final transferId = _uuid.v4();
    final settings = ref.read(settingsRepositoryProvider);

    // 创建任务 — batchName 统一用文件数量
    final count = resolvedContentFiles.isNotEmpty
        ? resolvedContentFiles.length
        : finalPaths.length;
    final batchName = finalFolderMode
        ? '${count} 个文件（文件夹）'
        : '$count 个文件';
    final task = TransferTask(
      transferId: transferId,
      senderDeviceId: settings.deviceId ?? 'unknown',
      targetDeviceId: targetDevice.deviceId,
      peerDeviceName: targetDevice.name,
      batchName: batchName,
      totalSize: 0,
      fileCount: count,
      files: [],
      folderMode: finalFolderMode,
      status: TransferStatus.scanning,
      savePath: ref.read(downloadPathProvider),
    );

    // 放入队列
    ref.read(transferQueueProvider.notifier).update((queue) => [...queue, task]);

    // 设为活跃任务
    ref.read(activeTransferProvider.notifier).state = task;

    // 发送命令到 Engine
    final tempDir = (await getTemporaryDirectory()).path;
    _engineSendPort?.send({
      'type': EngineCommandType.startTransfer,
      'payload': {
        'transferId': transferId,
        'paths': finalPaths,
        'contentFiles': resolvedContentFiles,
        'targetIp': targetDevice.ip,
        'targetPort': targetDevice.port,
        'folderMode': finalFolderMode,
        'senderDeviceId': settings.deviceId ?? 'unknown',
        'senderDeviceName': settings.deviceName,
        'downloadPath': ref.read(downloadPathProvider),
        'speedLimit': ref.read(speedLimitProvider),
        'concurrentCount': ref.read(concurrentCountProvider),
        'retryCount': settings.retryCount,
        'tempDir': tempDir,
        'logDir': tempDir,
      },
    });
  }

  void pauseTransfer(String transferId) {
    _engineSendPort?.send({
      'type': EngineCommandType.pause,
      'payload': {'transferId': transferId},
    });

    ref.read(activeTransferProvider.notifier).update((task) {
      if (task?.transferId == transferId) {
        task!.status = TransferStatus.paused;
      }
      return task?.clone();
    });
  }

  void resumeTransfer(String transferId) {
    _engineSendPort?.send({
      'type': EngineCommandType.resume,
      'payload': {'transferId': transferId},
    });

    ref.read(activeTransferProvider.notifier).update((task) {
      if (task?.transferId == transferId) {
        task!.status = TransferStatus.transferring;
      }
      return task?.clone();
    });
  }

  void cancelTransfer(String transferId) {
    ContentUriReader.closeAllContentStreams();

    _engineSendPort?.send({
      'type': EngineCommandType.cancel,
      'payload': {'transferId': transferId},
    });

    // 从活跃任务中移除
    final active = ref.read(activeTransferProvider);
    if (active?.transferId == transferId) {
      if (active != null) {
        _saveHistory(active, 'cancelled');
      }
      ref.read(activeTransferProvider.notifier).state = null;
    }

    // 从队列中移除
    final queue = ref.read(transferQueueProvider);
    ref.read(transferQueueProvider.notifier).state =
        queue.where((t) => t.transferId != transferId).toList();
  }

  /// 运行时动态调整传输限速（供设置变更 / 电池保护触发）
  ///
  /// 发送端：直接调整发送 Engine 的 TokenBucket
  /// 接收端：通过 RecvEngine 发送 TRANSFER_SPEED_LIMIT 帧通知发送端
  void updateSpeedLimit(int bytesPerSecond) {
    final active = ref.read(activeTransferProvider);
    final receive = ref.read(receiveTransferProvider);

    if (active != null) {
      // 本机是发送端 — 直接调整 Engine TokenBucket
      _engineSendPort?.send({
        'type': EngineCommandType.setSpeedLimit,
        'payload': {
          'transferId': active.transferId,
          'speedLimit': bytesPerSecond,
        },
      });
    }

    if (receive != null) {
      // 本机是接收端 — 转发到 RecvEngine，由其发送 TRANSFER_SPEED_LIMIT 帧给发送端
      ref.read(connectionStateProvider.notifier).setReceiveSpeedLimit(
        receive.transferId, bytesPerSecond,
      );
    }
  }

  TransferMode _parseMode(String? mode) {
    return switch (mode) {
      'sequential' => TransferMode.sequential,
      'concurrent' => TransferMode.concurrent,
      'mixed' => TransferMode.mixed,
      _ => TransferMode.concurrent,
    };
  }
}
