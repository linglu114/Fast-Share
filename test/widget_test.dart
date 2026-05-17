import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fastshare/storage/settings_repository.dart';
import 'package:fastshare/providers/settings_provider.dart';
import 'package:fastshare/app.dart';

void main() {
  testWidgets('App renders with bottom navigation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settingsRepo = SettingsRepository(prefs);

    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
      ],
    );
    addTearDown(() => container.dispose());

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FastShareApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('传输'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
