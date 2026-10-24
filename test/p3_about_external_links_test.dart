import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/ui/widgets/about_app_section.dart';

/// P3 regression: the About section links to the official website and the
/// PUBLIC GitHub repository. Links open only on an explicit tap, pass the
/// exact bare HTTPS URLs, never crash on launcher failures and swallow rapid
/// re-taps while a launch is in flight.
class _RecordingLauncher {
  final calls = <Uri>[];
  Completer<bool> gate = Completer<bool>()..complete(true);
  bool result = true;
  Object? throwOnce;

  Future<bool> call(Uri url) {
    if (throwOnce != null) {
      final error = throwOnce!;
      throwOnce = null;
      throw error;
    }
    calls.add(url);
    return gate.future.then((_) => result);
  }
}

/// Top-level tear-off: a constant expression, so const subtrees can use it.
Future<String?> fixedVersionLoader() async => '1.0.0';

void main() {
  testWidgets('1: both links are present in the About section', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(loadVersion: () async => '1.0.0'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Официальный сайт'), findsOneWidget);
    expect(find.text('spb-in-details.vercel.app'), findsOneWidget);
    expect(find.text('GitHub проекта'), findsOneWidget);
    expect(find.text('Исходный код и публичные выпуски'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsNWidgets(2));
  });

  testWidgets('2: the website tap passes the exact HTTPS URL', (tester) async {
    final launcher = _RecordingLauncher();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(
            loadVersion: () async => null,
            launchUrl: launcher.call,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Официальный сайт'));
    await tester.pump();
    expect(launcher.calls, [
      Uri.parse('https://spb-in-details.vercel.app/'),
    ]);
  });

  testWidgets('3: the GitHub tap passes the exact public URL', (tester) async {
    final launcher = _RecordingLauncher();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(
            loadVersion: () async => null,
            launchUrl: launcher.call,
          ),
        ),
      ),
    );
    await tester.tap(find.text('GitHub проекта'));
    await tester.pump();
    expect(launcher.calls, [
      Uri.parse('https://github.com/DenisAniskov/SPb_in_Details_public'),
    ]);
    expect(AppStrings.projectGithubUrl, contains('SPb_in_Details_public'));
  });

  testWidgets('4/5: a launcher failure shows the honest SnackBar, no crash', (
    tester,
  ) async {
    final launcher = _RecordingLauncher()..result = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(
            loadVersion: () async => null,
            launchUrl: launcher.call,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Официальный сайт'));
    await tester.pump();
    expect(
      find.textContaining('Не удалось открыть ссылку'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // A throwing launcher is handled the same way.
    launcher.throwOnce = StateError('no browser');
    await tester.tap(find.text('GitHub проекта'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('6: rapid re-taps open the browser once', (tester) async {
    final launcher = _RecordingLauncher()
      ..gate = Completer<bool>(); // the first launch stays in flight
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(
            loadVersion: () async => null,
            launchUrl: launcher.call,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Официальный сайт'));
    await tester.pump();
    await tester.tap(find.text('Официальный сайт'), warnIfMissed: false);
    await tester.tap(find.text('Официальный сайт'), warnIfMissed: false);
    await tester.pump();
    expect(launcher.calls, hasLength(1));

    launcher.gate.complete(true);
    await tester.pump();
    expect(launcher.calls, hasLength(1), reason: 'still exactly one open');
  });

  testWidgets('7: title, author and dynamic version stay in place', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(loadVersion: () async => '1.0.0'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.appTitle), findsOneWidget);
    expect(find.text(AppStrings.appCreator), findsOneWidget);
    expect(find.text(AppStrings.appTagline), findsOneWidget);
    expect(find.text('Версия 1.0.0'), findsOneWidget);
  });

  testWidgets('8: renders on a small screen with a large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: const Scaffold(
          // Production placement: the settings screen scrolls this block.
          body: SingleChildScrollView(
            child: AboutAppSection(loadVersion: fixedVersionLoader),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Официальный сайт'), findsOneWidget);
    expect(find.text('GitHub проекта'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('9: ${dark ? 'dark' : 'light'} theme renders correctly', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(
            body: AboutAppSection(loadVersion: () async => '1.0.0'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Официальный сайт'), findsOneWidget);
      expect(find.text('GitHub проекта'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('10: opening the settings never launches a browser by itself', (
    tester,
  ) async {
    final launcher = _RecordingLauncher();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(
            loadVersion: () async => '1.0.0',
            launchUrl: launcher.call,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(launcher.calls, isEmpty, reason: 'no automatic launches');
  });

  testWidgets('a11y: link semantics are exposed for TalkBack', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutAppSection(loadVersion: () async => null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // TalkBack merges the link node; the widget configures the label.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label ==
                'Официальный сайт «Петербург в деталях», открывается во '
                'внешнем браузере' &&
            w.properties.link == true &&
            w.properties.button == true,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label ==
                'GitHub проекта «Петербург в деталях», открывается во '
                'внешнем браузере' &&
            w.properties.link == true &&
            w.properties.button == true,
      ),
      findsOneWidget,
    );
  });
}