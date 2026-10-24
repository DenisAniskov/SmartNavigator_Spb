import 'dart:io';
import 'dart:math' show sqrt;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/about_app_section.dart';
import 'package:smart_navigator_spb/ui/widgets/theme_mode_button.dart';

class _MemoryPreferenceStore implements ThemePreferenceStore {
  _MemoryPreferenceStore([this.value]);

  AppThemePreference? value;

  @override
  Future<AppThemePreference?> read() async => value;

  @override
  Future<void> write(AppThemePreference preference) async {
    value = preference;
  }
}

class _MemoryStorage implements GuestKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _Catalog extends PlacesRepository {
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => const [];

  @override
  Future<List<CategoryModel>> getCategories() async => const [];
}

Directory _packageRoot() {
  final candidate = Directory.current;
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('Flutter package root not found');
}

String _res(String relative) =>
    '${_packageRoot().path}/android/app/src/main/res/$relative';

String _android(String relative) =>
    '${_packageRoot().path}/android/app/$relative';

(int, int) _pngSize(String path) {
  final bytes = File(path).readAsBytesSync();
  expect(bytes.length, greaterThan(24), reason: 'truncated PNG: $path');
  expect(bytes.sublist(1, 4), equals([80, 78, 71]), reason: 'not a PNG: $path');
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return (data.getUint32(16), data.getUint32(20));
}

int _pngColorType(String path) => File(path).readAsBytesSync()[25];

/// Decodes a PNG off the fake-async zone. Image decoding needs the real event
/// loop, so the call has to run through [WidgetTester.runAsync].
Future<(Uint8List, int, int)> _rgbaPixels(
  WidgetTester tester,
  String path,
) async {
  final bytes = File(path).readAsBytesSync();
  final decoded = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = (Uint8List.fromList(data!.buffer.asUint8List()), image.width, image.height);
    image.dispose();
    codec.dispose();
    return result;
  });
  return decoded!;
}

/// Mounts the production map screen for header/authoring checks. Shared with
/// the optional preview capture so both render the identical widget tree.
Future<void> mountMapHeader(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  required AppThemePreference preference,
  GlobalKey? boundaryKey,
  String? fontFamily,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  MapKitService.isMapKitInitialized = false;

  final theme = ThemeProvider(store: _MemoryPreferenceStore(preference));
  addTearDown(theme.dispose);
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: _Catalog(),
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  await guest.completeOnboarding();
  final places = PlacesProvider(repository: _Catalog(), guest: guest);
  final routing = RoutingProvider();
  addTearDown(places.dispose);
  addTearDown(routing.dispose);

  final app = Consumer<ThemeProvider>(
    builder: (context, appearance, _) => MaterialApp(
      theme: _withFamily(AppTheme.lightTheme, fontFamily),
      darkTheme: _withFamily(AppTheme.darkTheme, fontFamily),
      themeMode: appearance.themeMode,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: const MainMapScreen(),
    ),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ],
      child: boundaryKey == null
          ? app
          : RepaintBoundary(key: boundaryKey, child: app),
    ),
  );
  await tester.pumpAndSettle();
}

/// Path of the font files bundled with the Flutter SDK, taken from the Android
/// build's own `local.properties`. Cyrillic metrics only match the device when
/// the real Roboto is loaded: the default test font draws every glyph as a full
/// em square and would make the width checks meaningless.
///
/// The Android build downloads the material font artifacts. A checkout that has
/// never built Android (a CI runner, for example) has the artifact directory but
/// not the files, so the directory alone does not mean the fonts are usable:
/// width checks need real font files, and without them they stay skipped.
String? _flutterFontDir() {
  const requiredFiles = [
    'roboto-regular.ttf',
    'roboto-bold.ttf',
    'materialicons-regular.otf',
  ];
  final properties = File('${_packageRoot().path}/android/local.properties');
  if (!properties.existsSync()) return null;
  for (final line in properties.readAsLinesSync()) {
    if (!line.startsWith('flutter.sdk=')) continue;
    final sdk = line.substring('flutter.sdk='.length).trim().replaceAll(
      r'\',
      '/',
    );
    final dir = '$sdk/bin/cache/artifacts/material_fonts';
    if (Directory(dir).existsSync() &&
        requiredFiles.every(
          (file) => File('$dir/$file').existsSync(),
        )) {
      return dir;
    }
  }
  return null;
}

Future<bool> _loadProductionFonts(WidgetTester tester) async {
  final dir = _flutterFontDir();
  if (dir == null) return false;
  await tester.runAsync(() async {
    for (final family in ['Roboto', 'Ahem']) {
      final loader = FontLoader(family);
      for (final file in ['roboto-regular.ttf', 'roboto-bold.ttf']) {
        final bytes = await File('$dir/$file').readAsBytes();
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      }
      await loader.load();
    }
    final iconBytes = await File('$dir/materialicons-regular.otf').readAsBytes();
    final icons = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await icons.load();
  });
  return true;
}

/// The test environment replaces the platform default font with a glyph-less
/// one, so the preview capture can pin the production family explicitly. Layout
/// metrics stay untouched: only the family name changes. The button themes need
/// it too, because the production theme gives them a family-less text style
/// that the device would resolve to Roboto.
ThemeData _withFamily(ThemeData base, String? fontFamily) {
  if (fontFamily == null) return base;
  final buttonStyle = (base.textTheme.labelLarge ?? const TextStyle())
      .copyWith(fontFamily: fontFamily);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: fontFamily),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: fontFamily,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(buttonStyle),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(buttonStyle),
      ),
    ),
  );
}

void main() {
  test('the approved brand strings are in place', () {
    expect(AppStrings.appTitle, 'Петербург в деталях');
    expect(AppStrings.appCreator, 'Создатель: Денис Аниськов');
    expect(
      AppStrings.appTagline,
      'Пешеходный навигатор для знакомства с Санкт-Петербургом',
    );
    expect(AppStrings.appSlogan, 'Замечай больше. Открывай Петербург.');
  });

  test('Android metadata keeps the package id and exposes the new brand', () {
    final manifest = File(
      _android('src/main/AndroidManifest.xml'),
    ).readAsStringSync();
    expect(manifest, contains('android:label="@string/app_name"'));
    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher_round"'));
    expect(manifest, isNot(contains('SmartNavigator SPb')));

    final strings = File(_res('values/strings.xml')).readAsStringSync();
    expect(strings, contains('<string name="app_name">Петербург в деталях</string>'));

    final gradle = File(_android('build.gradle')).readAsStringSync();
    expect(gradle, contains("namespace 'ru.smartnavigator.spb'"));
    expect(gradle, contains("applicationId 'ru.smartnavigator.spb'"));

    final pubspec = File('${_packageRoot().path}/pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 1.1.0+2'));
    expect(pubspec, contains('Петербург в деталях'));
  });

  test('adaptive icons declare background, foreground and monochrome layers', () {
    for (final name in ['ic_launcher.xml', 'ic_launcher_round.xml']) {
      final xml = File(_res('mipmap-anydpi-v26/$name')).readAsStringSync();
      expect(xml, contains('<background android:drawable="@mipmap/ic_launcher_background"'));
      expect(xml, contains('<foreground android:drawable="@mipmap/ic_launcher_foreground"'));
      expect(xml, contains('<monochrome android:drawable="@mipmap/ic_launcher_monochrome"'));
    }
  });

  test('every density contains correctly sized launcher resources', () {
    const densities = {
      'mipmap-mdpi': (48, 108),
      'mipmap-hdpi': (72, 162),
      'mipmap-xhdpi': (96, 216),
      'mipmap-xxhdpi': (144, 324),
      'mipmap-xxxhdpi': (192, 432),
    };
    for (final entry in densities.entries) {
      final (legacy, adaptive) = entry.value;
      expect(_pngSize(_res('${entry.key}/ic_launcher.png')), (legacy, legacy));
      expect(
        _pngSize(_res('${entry.key}/ic_launcher_round.png')),
        (legacy, legacy),
      );
      expect(
        _pngSize(_res('${entry.key}/ic_launcher_foreground.png')),
        (adaptive, adaptive),
      );
      expect(
        _pngSize(_res('${entry.key}/ic_launcher_background.png')),
        (adaptive, adaptive),
      );
      expect(
        _pngSize(_res('${entry.key}/ic_launcher_monochrome.png')),
        (adaptive, adaptive),
      );
    }
    expect(_pngColorType(_res('mipmap-xxxhdpi/ic_launcher_foreground.png')), 6);
    expect(_pngColorType(_res('mipmap-xxxhdpi/ic_launcher_monochrome.png')), 6);
    expect(_pngColorType(_res('mipmap-xxxhdpi/ic_launcher_background.png')), 2);
    expect(_pngColorType(_res('mipmap-xxxhdpi/ic_launcher.png')), 6);
  });

  testWidgets('adaptive foreground stays inside the 66 dp safe circle', (
    tester,
  ) async {
    final (pixels, width, height) = await _rgbaPixels(
      tester,
      _res('mipmap-xxxhdpi/ic_launcher_foreground.png'),
    );
    expect(width, 432);
    expect(height, 432);
    var maxDistanceSquared = 0.0;
    var visible = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final alpha = pixels[(y * width + x) * 4 + 3];
        if (alpha <= 12) continue;
        visible++;
        final dx = x + 0.5 - width / 2;
        final dy = y + 0.5 - height / 2;
        final distanceSquared = dx * dx + dy * dy;
        if (distanceSquared > maxDistanceSquared) {
          maxDistanceSquared = distanceSquared;
        }
      }
    }
    final maxDistance = sqrt(maxDistanceSquared);
    expect(visible, greaterThan(10000));
    expect(maxDistance, lessThanOrEqualTo(432 * 33 / 108 + 1.0));
  });

  testWidgets('adaptive background is opaque blue with no white corners', (
    tester,
  ) async {
    final (pixels, width, height) = await _rgbaPixels(
      tester,
      _res('mipmap-xxxhdpi/ic_launcher_background.png'),
    );
    for (final (x, y) in [
      (0, 0),
      (width - 1, 0),
      (0, height - 1),
      (width - 1, height - 1),
    ]) {
      final offset = (y * width + x) * 4;
      final r = pixels[offset];
      final g = pixels[offset + 1];
      final b = pixels[offset + 2];
      final a = pixels[offset + 3];
      expect(a, 255, reason: 'background corner must be opaque');
      expect(
        r > 235 && g > 235 && b > 235,
        isFalse,
        reason: 'background corner must not be white',
      );
      expect(b, greaterThan(r), reason: 'corner must stay in the blue field');
    }
  });

  testWidgets('monochrome layer is a single-color alpha mask', (tester) async {
    final (pixels, width, height) = await _rgbaPixels(
      tester,
      _res('mipmap-xxxhdpi/ic_launcher_monochrome.png'),
    );
    var visible = 0;
    for (var i = 0; i < width * height; i++) {
      final offset = i * 4;
      final a = pixels[offset + 3];
      if (a <= 10) continue;
      visible++;
      expect(pixels[offset], lessThanOrEqualTo(2));
      expect(pixels[offset + 1], lessThanOrEqualTo(2));
      expect(pixels[offset + 2], lessThanOrEqualTo(2));
    }
    expect(visible, greaterThan(1000));
    for (final (x, y) in [
      (0, 0),
      (width - 1, 0),
      (0, height - 1),
      (width - 1, height - 1),
    ]) {
      expect(pixels[(y * width + x) * 4 + 3], lessThanOrEqualTo(10));
    }
  });

  testWidgets('legacy icon has transparent corners and no baked white', (
    tester,
  ) async {
    final (pixels, width, height) = await _rgbaPixels(
      tester,
      _res('mipmap-xxxhdpi/ic_launcher.png'),
    );
    var nearWhite = 0;
    for (var i = 0; i < width * height; i++) {
      final offset = i * 4;
      final a = pixels[offset + 3];
      if (a <= 20) continue;
      if (pixels[offset] > 235 &&
          pixels[offset + 1] > 235 &&
          pixels[offset + 2] > 235) {
        nearWhite++;
      }
    }
    expect(nearWhite, 0);
    for (final (x, y) in [
      (0, 0),
      (width - 1, 0),
      (0, height - 1),
      (width - 1, height - 1),
    ]) {
      expect(pixels[(y * width + x) * 4 + 3], lessThanOrEqualTo(10));
    }
  });

  for (final scenario in [
    (
      label: '320x480 textScale 1.0 light',
      size: const Size(320, 480),
      scale: 1.0,
      preference: AppThemePreference.light,
      // 320 dp leaves ~116 dp beside four 48 dp actions: the full name cannot
      // fit there, so the long-standing ellipsis behaviour stays.
      wholeName: false,
      titleSize: 15.0,
    ),
    (
      label: '320x480 textScale 1.6 dark',
      size: const Size(320, 480),
      scale: 1.6,
      preference: AppThemePreference.dark,
      wholeName: false,
      titleSize: 15.0,
    ),
    (
      label: '320x480 textScale 2.0 light',
      size: const Size(320, 480),
      scale: 2.0,
      preference: AppThemePreference.light,
      wholeName: false,
      titleSize: 15.0,
    ),
    (
      label: '360x640 textScale 1.0 dark',
      size: const Size(360, 640),
      scale: 1.0,
      preference: AppThemePreference.dark,
      wholeName: true,
      titleSize: 15.0,
    ),
    (
      label: '412x915 textScale 1.0 light',
      size: const Size(412, 915),
      scale: 1.0,
      preference: AppThemePreference.light,
      wholeName: true,
      titleSize: 17.0,
    ),
    (
      label: '412x915 textScale 1.6 dark',
      size: const Size(412, 915),
      scale: 1.6,
      preference: AppThemePreference.dark,
      wholeName: false,
      titleSize: 17.0,
    ),
  ]) {
    testWidgets('map header keeps title, authorship and theme at ${scenario.label}', (
      tester,
    ) async {
      final realFonts = await _loadProductionFonts(tester);
      await mountMapHeader(
        tester,
        size: scenario.size,
        textScale: scenario.scale,
        preference: scenario.preference,
        fontFamily: realFonts ? 'Roboto' : null,
      );

      final titleFinder = find.text(AppStrings.appTitle);
      final creatorFinder = find.byKey(const Key('app_creator'));
      final themeFinder = find.byKey(const Key('theme_mode_button'));
      expect(titleFinder, findsOneWidget);
      expect(creatorFinder, findsOneWidget);
      expect(find.text(AppStrings.appCreator), findsOneWidget);
      expect(themeFinder, findsOneWidget);
      expect(find.byTooltip('Выбрать старт'), findsOneWidget);
      expect(find.byTooltip('Прогулка'), findsOneWidget);
      expect(find.byTooltip('Дополнительные действия'), findsOneWidget);

      final title = tester.getRect(titleFinder);
      final creator = tester.getRect(creatorFinder);
      final themeButton = tester.getRect(themeFinder);
      expect(title.right, lessThanOrEqualTo(themeButton.left));
      expect(creator.top, greaterThanOrEqualTo(title.bottom - 1));
      expect(creator.right, lessThanOrEqualTo(scenario.size.width));
      expect(themeButton.width, greaterThanOrEqualTo(48));
      expect(themeButton.height, greaterThanOrEqualTo(48));

      final titleWidget = tester.widget<Text>(titleFinder);
      final creatorWidget = tester.widget<Text>(creatorFinder);
      expect(creatorWidget.style!.fontSize, lessThan(titleWidget.style!.fontSize!));
      expect(
        creatorWidget.style!.color,
        equals(
          (scenario.preference == AppThemePreference.dark
                  ? AppTheme.darkTheme
                  : AppTheme.lightTheme)
              .colorScheme
              .onSurfaceVariant,
        ),
      );
      expect(titleWidget.style!.fontSize, scenario.titleSize);
      final titleParagraph = tester.renderObject<RenderParagraph>(titleFinder);
      if (realFonts) {
        if (scenario.wholeName) {
          expect(
            titleParagraph.didExceedMaxLines,
            isFalse,
            reason: 'full brand name must stay visible at ${scenario.label}',
          );
        }
        final creatorParagraph = tester.renderObject<RenderParagraph>(
          creatorFinder,
        );
        expect(
          creatorParagraph.didExceedMaxLines,
          isFalse,
          reason: 'authorship must stay readable at ${scenario.label}',
        );
        // The authorship line may shrink to stay whole; it must never magnify
        // and must keep nearly the full requested size at 2.0 text scale.
        final natural = TextPainter(
          text: TextSpan(
            text: AppStrings.appCreator,
            style: creatorWidget.style,
          ),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(scenario.scale),
        )..layout();
        expect(creator.width, lessThanOrEqualTo(natural.width + 1));
        expect(
          creator.width / natural.width,
          greaterThanOrEqualTo(0.9),
          reason: 'authorship must not be squashed at ${scenario.label}',
        );
        final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
        expect(
          creator.bottom,
          lessThanOrEqualTo(appBarBottom + 0.5),
          reason: 'authorship must stay inside the header at ${scenario.label}',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('authorship is read as plain text, not as a button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await mountMapHeader(
        tester,
        size: const Size(360, 640),
        textScale: 1.0,
        preference: AppThemePreference.light,
      );
      final node = tester.getSemantics(
        find.byKey(const Key('app_creator')),
      );
      expect(node.label, contains(AppStrings.appCreator));
      expect(node.flagsCollection.isButton, isFalse);
      expect(node.flagsCollection.isLink, isFalse);
      expect(find.byType(ThemeModeButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('about section shows the new name, authorship and version', (
    tester,
  ) async {
    for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AboutAppSection(
                loadVersion: () async => '1.0.0 (сборка 1)',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('О приложении'), findsOneWidget);
      expect(find.text(AppStrings.appTitle), findsOneWidget);
      expect(find.text(AppStrings.appCreator), findsOneWidget);
      expect(find.text(AppStrings.appTagline), findsOneWidget);
      expect(find.text('Версия 1.0.0 (сборка 1)'), findsOneWidget);
      expect(find.textContaining('SmartNavigator'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
