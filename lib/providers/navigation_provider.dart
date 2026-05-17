import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前底部导航 Tab 索引 Provider（用于检测页面可见性）
final currentTabProvider = StateProvider<int>((ref) => 0);
