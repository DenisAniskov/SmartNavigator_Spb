import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_consent_store.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_model_roles.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';
import 'package:smart_navigator_spb/ui/widgets/assistant_sheet.dart';

import 'assistant_test_support.dart';

const _noticeMarker = 'резервной моделью';
const _unavailableMarker = 'Карта и навигация продолжают работать';

/// Streaming fake mirroring the production transport: the sheet talks to
/// [AssistantProvider], which only treats an [AssistantStreamCompleted] event
/// as a confirmed answer. Tests decide per scenario what the stream emits.
class _StreamingFake implements StreamingAssistantService {
  final List<StreamController<AssistantStreamEvent>> controllers = [];

  StreamController<AssistantStreamEvent> get current => controllers.last;

  @override
  Future<AssistantReply> send({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) => throw StateError('streaming must be used');

  @override
  Stream<AssistantStreamEvent> stream({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) {
    final controller = StreamController<AssistantStreamEvent>();
    controllers.add(controller);
    return controller.stream;
  }
}

AssistantReply _reply({
  String? model,
  String answer = 'Подтверждённый ответ.',
}) => AssistantReply.fromJson({
  'status': 'ok',
  'answer': answer,
  'model': model,
  'places': <dynamic>[],
  'actions': <dynamic>[],
  'warnings': <String>[],
  'usage': <String, dynamic>{'cost_usd': 0, 'cost_verified': true},
});

Future<(AssistantProvider, _StreamingFake)> _mount(
  WidgetTester tester, {
  bool dark = false,
  double textScale = 1,
  Size size = const Size(360, 640),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = _StreamingFake();
  final provider = AssistantProvider(
    assistantService: service,
    consentStore: MemoryAssistantConsentStore(
      version: AssistantConsentStore.currentVersion,
    ),
  );
  addTearDown(provider.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AssistantProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: AssistantSheet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (provider, service);
}

Future<void> _ask(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip('Отправить вопрос'));
  await tester.pump();
}

/// Loads the bundled Roboto so overflow checks at large text scale match the
/// device metrics: the default test font draws every glyph as a full em
/// square, which alone overflows the narrow loading bubble (same approach as
/// branding_1_0_test.dart).
Future<void> _loadProductionFonts(WidgetTester tester) async {
  final dir = _flutterFontDir();
  if (dir == null) return;
  await tester.runAsync(() async {
    for (final family in ['Roboto', 'Ahem']) {
      final loader = FontLoader(family);
      for (final file in ['roboto-regular.ttf', 'roboto-bold.ttf']) {
        final bytes = await File('$dir/$file').readAsBytes();
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      }
      await loader.load();
    }
  });
}

String? _flutterFontDir() {
  final properties = File('android/local.properties');
  if (!properties.existsSync()) return null;
  for (final line in properties.readAsLinesSync()) {
    if (!line.startsWith('flutter.sdk=')) continue;
    final sdk = line.substring('flutter.sdk='.length).trim().replaceAll(
      r'\',
      '/',
    );
    final dir = '$sdk/bin/cache/artifacts/material_fonts';
    if (Directory(dir).existsSync()) return dir;
  }
  return null;
}

void main() {
  group('AssistantModelRoles', () {
    test('recognises only the confirmed backup id', () {
      expect(AssistantModelRoles.isBackup(AssistantModelRoles.backup), isTrue);
    });

    test('never flags the primary, null or unknown ids', () {
      expect(
        AssistantModelRoles.isBackup(AssistantModelRoles.primary),
        isFalse,
      );
      expect(AssistantModelRoles.isBackup(null), isFalse);
      expect(AssistantModelRoles.isBackup(''), isFalse);
      expect(
        AssistantModelRoles.isBackup('nvidia/nemotron-3-super-120b-a12b:free'),
        isFalse,
      );
      expect(
        // Exact match only: a case variant is an unrecognised id.
        AssistantModelRoles.isBackup('NVIDIA/nemotron-3.5-lightning:free'),
        isFalse,
      );
    });
  });

  testWidgets('completed primary answer shows no backup notice', (
    tester,
  ) async {
    final (_, service) = await _mount(tester);
    await _ask(tester, 'Что посмотреть?');
    service.current.add(
      const AssistantStreamStarted(model: AssistantModelRoles.primary),
    );
    service.current.add(const AssistantStreamDelta('Частичный текст '));
    // The streaming bubble keeps a spinner on screen, so the frame pumps
    // manually instead of waiting for animations to settle.
    await tester.pump(const Duration(milliseconds: 40));
    // Provisional text carries no notice.
    expect(find.textContaining(_noticeMarker), findsNothing);

    service.current.add(
      AssistantStreamCompleted(_reply(model: AssistantModelRoles.primary)),
    );
    await service.current.close();
    await tester.pumpAndSettle();

    expect(find.textContaining('Подтверждённый ответ'), findsOneWidget);
    expect(find.textContaining(_noticeMarker), findsNothing);
  });

  testWidgets('completed backup answer shows the notice exactly once', (
    tester,
  ) async {
    final (_, service) = await _mount(tester);
    await _ask(tester, 'Что посмотреть?');
    service.current.add(
      const AssistantStreamStarted(model: AssistantModelRoles.backup),
    );
    service.current.add(const AssistantStreamDelta('Предварительный '));
    service.current.add(const AssistantStreamDelta('текст'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.textContaining('Предварительный текст'), findsOneWidget);
    expect(find.textContaining(_noticeMarker), findsNothing);

    service.current.add(
      AssistantStreamCompleted(_reply(model: AssistantModelRoles.backup)),
    );
    await service.current.close();
    await tester.pumpAndSettle();

    expect(find.textContaining('Подтверждённый ответ'), findsOneWidget);
    expect(find.textContaining('Предварительный'), findsNothing);
    expect(find.textContaining(_noticeMarker), findsOneWidget);
  });

  testWidgets('unknown and missing model ids never get the notice', (
    tester,
  ) async {
    final (_, service) = await _mount(tester);
    await _ask(tester, 'Вопрос про мосты');
    service.current.add(
      AssistantStreamCompleted(
        _reply(model: 'future/unknown-model:free', answer: 'Ответ раз.'),
      ),
    );
    await service.current.close();
    await tester.pumpAndSettle();
    expect(find.textContaining('Ответ раз.'), findsOneWidget);
    expect(find.textContaining(_noticeMarker), findsNothing);

    await _ask(tester, 'Ещё вопрос');
    service.current.add(
      AssistantStreamCompleted(_reply(model: null, answer: 'Ответ два.')),
    );
    await service.current.close();
    await tester.pumpAndSettle();
    expect(find.textContaining('Ответ два.'), findsOneWidget);
    expect(find.textContaining(_noticeMarker), findsNothing);
  });

  testWidgets(
    'a stream dropped before completed becomes an error without a notice',
    (tester) async {
      final (_, service) = await _mount(tester);
      await _ask(tester, 'Вопрос');
      service.current.add(
        const AssistantStreamStarted(model: AssistantModelRoles.backup),
      );
      service.current.add(const AssistantStreamDelta('Обрыв посреди'));
      await tester.pump(const Duration(milliseconds: 40));
      await service.current.close();
      await tester.pumpAndSettle();

      expect(find.textContaining('Обрыв посреди'), findsNothing);
      expect(find.textContaining(_unavailableMarker), findsOneWidget);
      expect(find.textContaining(_noticeMarker), findsNothing);
      expect(find.text('Повторить'), findsOneWidget);
    },
  );

  testWidgets('cancel discards the answer and never shows the notice', (
    tester,
  ) async {
    final (_, service) = await _mount(tester);
    await _ask(tester, 'Вопрос');
    service.current.add(const AssistantStreamDelta('Начало ответа'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byTooltip('Отменить ответ'));
    await tester.pumpAndSettle();
    expect(find.text('Запрос отменён.'), findsOneWidget);

    // A late confirmed reply after the cancel must be dropped entirely.
    service.current.add(
      AssistantStreamCompleted(_reply(model: AssistantModelRoles.backup)),
    );
    await service.current.close();
    await tester.pumpAndSettle();

    expect(find.textContaining('Подтверждённый ответ'), findsNothing);
    expect(find.textContaining(_noticeMarker), findsNothing);
    expect(find.text('Запрос отменён.'), findsOneWidget);
  });

  testWidgets(
    '429 shows the limit message, retry works once and never loops',
    (tester) async {
      final (_, service) = await _mount(tester);
      await _ask(tester, 'Вопрос');
      service.current.add(
        const AssistantStreamError(
          'rate_limited',
          'Лимит запросов к ИИ-помощнику исчерпан. Повторите позже.',
        ),
      );
      await service.current.close();
      await tester.pumpAndSettle();

      expect(find.textContaining('Лимит запросов'), findsOneWidget);
      expect(find.textContaining(_noticeMarker), findsNothing);
      expect(find.text('Повторить'), findsOneWidget);

      // Manual retry re-sends the question exactly once. The retry turn
      // shows the loading spinner, so only a single frame is pumped here.
      await tester.tap(find.text('Повторить'));
      await tester.pump();
      expect(service.controllers, hasLength(2));

      service.current.add(
        AssistantStreamCompleted(_reply(model: AssistantModelRoles.primary)),
      );
      await service.current.close();
      await tester.pumpAndSettle();

      expect(find.textContaining('Подтверждённый ответ'), findsOneWidget);
      expect(find.textContaining('Лимит запросов'), findsNothing);
      // A finished turn triggers no further requests on its own.
      expect(service.controllers, hasLength(2));
      await tester.pump(const Duration(seconds: 3));
      expect(service.controllers, hasLength(2));
    },
  );

  testWidgets(
    'the notice of an earlier backup answer survives the next turn',
    (tester) async {
      final (_, service) = await _mount(tester);
      await _ask(tester, 'Первый вопрос');
      service.current.add(
        AssistantStreamCompleted(_reply(model: AssistantModelRoles.backup)),
      );
      await service.current.close();
      await tester.pumpAndSettle();
      expect(find.textContaining(_noticeMarker), findsOneWidget);

      await _ask(tester, 'Второй вопрос');
      service.current.add(
        AssistantStreamCompleted(
          _reply(model: AssistantModelRoles.primary, answer: 'Ответ второй.'),
        ),
      );
      await service.current.close();
      await tester.pumpAndSettle();

      expect(find.textContaining('Ответ второй.'), findsOneWidget);
      // Only the first bubble keeps the notice.
      expect(find.textContaining(_noticeMarker), findsOneWidget);
    },
  );

  for (final config in [(false, 1.0), (true, 1.0), (true, 1.6)]) {
    testWidgets(
      'backup notice renders ${config.$1 ? 'dark' : 'light'} '
      'at ${config.$2}x on a small screen',
      (tester) async {
        await _loadProductionFonts(tester);
        final (_, service) = await _mount(
          tester,
          dark: config.$1,
          textScale: config.$2,
          size: const Size(320, 480),
        );
        await _ask(tester, 'Вопрос');
        service.current.add(
          AssistantStreamCompleted(_reply(model: AssistantModelRoles.backup)),
        );
        await service.current.close();
        await tester.pumpAndSettle();

        expect(find.textContaining(_noticeMarker), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
