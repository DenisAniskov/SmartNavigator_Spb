import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/network/catalog_retry_policy.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';

const _place = PlaceModel(
  id: 6,
  title: 'Русский музей',
  shortDescription: 'Музей',
  category: PlaceCategoryEnum.art,
  latitude: 59.93858,
  longitude: 30.33072,
  address: 'Адрес',
  recommendedVisitMinutes: 20,
);

const _place2 = PlaceModel(
  id: 7,
  title: 'Исаакиевский собор',
  shortDescription: 'Собор',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.9398,
  longitude: 30.3146,
  address: 'Адрес',
  recommendedVisitMinutes: 30,
);

RequestOptions get _req => RequestOptions(path: '/places');

DioException _timeout() =>
    DioException(requestOptions: _req, type: DioExceptionType.receiveTimeout);
DioException _connectionError() =>
    DioException(requestOptions: _req, type: DioExceptionType.connectionError);
DioException _status(
  int code, {
  Map<String, List<String>> headers = const {},
}) => DioException(
  requestOptions: _req,
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: _req,
    statusCode: code,
    headers: Headers.fromMap(headers),
  ),
);
Object _socket() => const SocketException('network is unreachable');

/// Script outcome: a request that never completes.
class _Hang {
  const _Hang();
}

/// Scripted catalog: outcome [i] is a List (success) or an Object to throw.
/// Beyond the script the last outcome repeats.
class _ScriptedCatalog extends PlacesRepository {
  _ScriptedCatalog(this.outcomes);

  final List<Object> outcomes;
  final requests = <String>[];
  int probeCalls = 0;
  int call = 0;

  Object _outcome() =>
      outcomes[outcomes.length == 1 ? 0 : call.clamp(0, outcomes.length - 1)];

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async {
    final signature = '${categories?.length ?? 0}|$isUnusual|$searchQuery';
    requests.add(signature);
    final outcome = _outcome();
    if (outcome is _Hang) {
      return Completer<List<PlaceModel>>().future;
    }
    call++;
    if (outcome is List) {
      return List<PlaceModel>.from(outcome);
    }
    throw outcome;
  }

  @override
  Future<List<CategoryModel>> getCategories() async => const [];

  Future<bool> nextProbe() async {
    probeCalls++;
    return true;
  }
}

PlacesProvider _provider(
  _ScriptedCatalog repo, {
  DateTime Function()? clock,
  Future<bool> Function()? probe,
}) => PlacesProvider(
  repository: repo,
  clock: clock,
  jitter: () => 0.5, // factor exactly 1.0: deterministic backoff
  connectivityProbe: probe ?? repo.nextProbe,
);

void main() {
  setUp(() {
    MapKitService.isMapKitInitialized = false;
  });

  group('CatalogRetryPolicy', () {
    test('classifies transient vs permanent failures', () {
      expect(CatalogRetryPolicy.isTransient(_timeout()), isTrue);
      expect(CatalogRetryPolicy.isTransient(_connectionError()), isTrue);
      expect(CatalogRetryPolicy.isTransient(_socket()), isTrue);
      expect(CatalogRetryPolicy.isTransient(TimeoutException('t')), isTrue);
      expect(CatalogRetryPolicy.isTransient(_status(502)), isTrue);
      expect(CatalogRetryPolicy.isTransient(_status(503)), isTrue);
      expect(CatalogRetryPolicy.isTransient(_status(504)), isTrue);
      expect(CatalogRetryPolicy.isTransient(_status(429)), isTrue);
      expect(CatalogRetryPolicy.isTransient(_status(400)), isFalse);
      expect(CatalogRetryPolicy.isTransient(_status(401)), isFalse);
      expect(CatalogRetryPolicy.isTransient(_status(403)), isFalse);
      expect(CatalogRetryPolicy.isTransient(_status(404)), isFalse);
      expect(
        CatalogRetryPolicy.isTransient(const FormatException('bad')),
        isFalse,
      );
      expect(
        CatalogRetryPolicy.isTransient(
          DioException(requestOptions: _req, type: DioExceptionType.cancel),
        ),
        isFalse,
      );
    });

    test('bounded backoff with jitter and no fifth attempt', () {
      double factorFor(double r) => 0.85 + 0.3 * r;
      final d1 = CatalogRetryPolicy.automaticDelay(
        error: _timeout(),
        retryIndex: 1,
        random: () => 0,
      )!;
      expect(d1, const Duration(milliseconds: 2000 * 85 ~/ 100));
      final d3 = CatalogRetryPolicy.automaticDelay(
        error: _timeout(),
        retryIndex: 3,
        random: () => 1,
      )!;
      expect(d3, const Duration(milliseconds: 11500));
      expect(
        CatalogRetryPolicy.automaticDelay(
          error: _timeout(),
          retryIndex: 4,
          random: () => 0.5,
        ),
        isNull,
        reason: 'at most three automatic retries',
      );
      expect(factorFor(0.5), 1.0);
    });

    test('Retry-After is honored, bounded and unparsable values ignored', () {
      final e429 = _status(
        429,
        headers: {
          'retry-after': ['7'],
        },
      );
      expect(
        CatalogRetryPolicy.retryAfterDelay(e429, now: DateTime.utc(2026)),
        const Duration(seconds: 7),
      );
      final big = _status(
        429,
        headers: {
          'retry-after': [
            HttpDate.format(DateTime.utc(2026).add(const Duration(hours: 2))),
          ],
        },
      );
      expect(
        CatalogRetryPolicy.retryAfterDelay(big, now: DateTime.utc(2026)),
        CatalogRetryPolicy.maxRetryAfter,
        reason: 'a server cannot schedule an unbounded wait',
      );
      final junk = _status(
        429,
        headers: {
          'retry-after': ['soon'],
        },
      );
      expect(CatalogRetryPolicy.retryAfterDelay(junk), isNull);
      final none = _status(429);
      expect(CatalogRetryPolicy.retryAfterDelay(none), isNull);
      expect(
        CatalogRetryPolicy.retryAfterDelay(
          _status(
            404,
            headers: {
              'retry-after': ['7'],
            },
          ),
        ),
        isNull,
        reason: 'Retry-After of a permanent status is meaningless',
      );
    });
  });

  group('PlacesProvider auto-recovery (fake async)', () {
    test('1: startup load succeeds and publishes the full catalog', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          <PlaceModel>[_place, _place2],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.success);
        expect(provider.places, hasLength(2));
        expect(provider.errorMessage, isNull);
        expect(repo.requests, hasLength(1));
      });
    });

    test('2: first attempt times out, automatic retry succeeds', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          _timeout(),
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.error);
        expect(provider.isRetrying, isTrue);

        async.elapse(const Duration(seconds: 2));
        expect(repo.requests, hasLength(2));
        expect(provider.status, PlacesStatus.success);
        expect(provider.places, hasLength(1));
        expect(provider.isRetrying, isFalse);
        expect(provider.nextRetryAt, isNull);
      });
    });

    test('3: repeated transient failures stop after the bounded budget', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([_socket()]);
        var probeCalls = 0;
        final provider = PlacesProvider(
          repository: repo,
          jitter: () => 0.5,
          connectivityProbe: () async {
            probeCalls++;
            return false; // still offline: the watch never fires a request
          },
        );
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));

        async.elapse(const Duration(seconds: 2));
        expect(repo.requests, hasLength(2));
        async.elapse(const Duration(seconds: 5));
        expect(repo.requests, hasLength(3));
        async.elapse(const Duration(seconds: 10));
        expect(
          repo.requests,
          hasLength(4),
          reason: 'initial attempt + three automatic retries',
        );
        expect(provider.status, PlacesStatus.error);
        expect(provider.isRetrying, isFalse);

        // No further backend requests even after a long wait: only the
        // DNS connectivity watch keeps running (probe, not the backend).
        async.elapse(const Duration(minutes: 2));
        expect(repo.requests, hasLength(4));
        expect(probeCalls, greaterThan(0));
      });
    });

    test('4: HTTP 404 and corrupt data never retry automatically', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([_status(404)]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.error);

        async.elapse(const Duration(minutes: 1));
        expect(repo.requests, hasLength(1));
        expect(repo.probeCalls, 0, reason: 'permanent failure arms no watch');
      });
    });

    test('4b: catalog corruption (FormatException) is permanent', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          const FormatException('Incomplete catalog pagination'),
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(minutes: 1));
        expect(repo.requests, hasLength(1));
        expect(provider.status, PlacesStatus.error);
        expect(provider.errorMessage, contains('некорректный каталог'));
      });
    });

    test('5: HTTP 429 honors the server Retry-After', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          _status(
            429,
            headers: {
              'retry-after': ['7'],
            },
          ),
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.isRetrying, isTrue);

        // The local backoff would fire at ~2s; Retry-After must win.
        async.elapse(const Duration(seconds: 3));
        expect(repo.requests, hasLength(1));
        async.elapse(const Duration(seconds: 4));
        expect(repo.requests, hasLength(2));
        expect(provider.status, PlacesStatus.success);
      });
    });

    test('6: connection loss recovers once when the internet returns', () {
      fakeAsync((async) {
        var online = false;
        var probeCalls = 0;
        final repo = _ScriptedCatalog([
          _connectionError(),
          _connectionError(),
          _connectionError(),
          _connectionError(),
          <PlaceModel>[_place],
        ]);
        final provider = PlacesProvider(
          repository: repo,
          jitter: () => 0.5,
          connectivityProbe: () async {
            probeCalls++;
            return online;
          },
        );
        addTearDown(provider.dispose);
        async.elapse(const Duration(seconds: 20));
        expect(repo.requests, hasLength(4));
        expect(provider.status, PlacesStatus.error);

        // DNS watch: offline probes re-arm; the first ONLINE probe fires
        // exactly one recovery request.
        async.elapse(const Duration(seconds: 15));
        expect(probeCalls, 1);
        expect(repo.requests, hasLength(4), reason: 'probe said offline');
        async.elapse(const Duration(seconds: 15));
        expect(probeCalls, 2);
        expect(repo.requests, hasLength(4), reason: 'still offline');
        online = true;
        async.elapse(const Duration(seconds: 15));
        expect(probeCalls, 3);
        expect(repo.requests, hasLength(5));
        expect(provider.status, PlacesStatus.success);
        expect(probeCalls, 3, reason: 'watch stops after recovery');
      });
    });

    test('7: foreground return triggers one recovery with a cooldown', () {
      fakeAsync((async) {
        var now = DateTime(2026, 1, 1, 12);
        final repo = _ScriptedCatalog([_status(404)]);
        final provider = _provider(repo, clock: () => now);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.error);

        provider.setForeground(false);
        repo.outcomes[0] = <PlaceModel>[_place];
        provider.setForeground(true);
        async.elapse(const Duration(milliseconds: 10));
        expect(repo.requests, hasLength(2));
        expect(provider.status, PlacesStatus.success);

        // Rapid repeated resumes inside the cooldown do nothing.
        provider.setForeground(false);
        provider.setForeground(true);
        async.elapse(const Duration(milliseconds: 10));
        expect(repo.requests, hasLength(2));
      });
    });

    test('7b: foreground recovery is skipped while the catalog is healthy', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        provider.setForeground(false);
        provider.setForeground(true);
        async.elapse(const Duration(milliseconds: 10));
        expect(repo.requests, hasLength(1));
      });
    });

    test('8: filter change cancels the scheduled retry for old filters', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          _timeout(),
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.isRetrying, isTrue);

        provider.toggleCategory(PlaceCategoryEnum.art);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.success);
        expect(repo.requests.last, '1|null|null');

        // The old scheduled retry must never fire for the old filters.
        async.elapse(const Duration(seconds: 30));
        expect(repo.requests, hasLength(2));
        expect(provider.places, hasLength(1));
      });
    });

    test('9: fast typing still produces one debounced request', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        expect(repo.requests, hasLength(1));

        provider.setSearchQuery('Н');
        async.elapse(const Duration(milliseconds: 100));
        provider.setSearchQuery('Нев');
        async.elapse(const Duration(milliseconds: 100));
        provider.setSearchQuery('Невский');
        async.elapse(const Duration(milliseconds: 400));
        expect(repo.requests, hasLength(2));
        expect(repo.requests.last, '0|null|Невский');
      });
    });

    test('10: a late stale response never overwrites newer results', () {
      fakeAsync((async) {
        final repo = _PendingCatalog();
        final provider = PlacesProvider(repository: repo);
        addTearDown(provider.dispose);
        // Constructor request (old filters) still pending; a newer manual
        // load completes first, then the stale one resolves.
        provider.loadPlaces();
        repo.complete(1, [_place]);
        async.elapse(const Duration(milliseconds: 10));
        repo.complete(0, [_place2]);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.places.single.id, _place.id);
      });
    });

    test('11: same-filter refresh failure keeps the last good snapshot', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));
        provider.selectPlace(_place);
        expect(provider.status, PlacesStatus.success);

        repo.outcomes[0] = _socket();
        provider.loadPlaces();
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.places, hasLength(1), reason: 'snapshot preserved');
        expect(provider.selectedPlace?.id, _place.id);
        expect(provider.isStale, isTrue);
        expect(provider.status, PlacesStatus.success);
        expect(provider.errorMessage, isNull);

        repo.outcomes[0] = <PlaceModel>[_place, _place2];
        async.elapse(const Duration(seconds: 2));
        expect(provider.isStale, isFalse);
        expect(provider.places, hasLength(2));
      });
    });

    test('11b: a filter change never shows the old snapshot as matching', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([
          <PlaceModel>[_place],
        ]);
        final provider = _provider(repo);
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));

        repo.outcomes[0] = _socket();
        provider.toggleCategory(PlaceCategoryEnum.art);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.places, isEmpty, reason: 'different filters');
        expect(provider.isStale, isFalse);
        expect(provider.status, PlacesStatus.error);
      });
    });

    test('15: dispose kills every scheduled retry and watch', () {
      fakeAsync((async) {
        final repo = _ScriptedCatalog([_socket()]);
        final provider = _provider(repo);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.isRetrying, isTrue);
        provider.dispose();
        // Neither the backoff timer nor the connectivity watch may fire a
        // request after dispose; fakeAsync would also fail on a stray timer.
        async.elapse(const Duration(minutes: 5));
        expect(repo.requests, hasLength(1));
        expect(repo.probeCalls, 0);
      });
    });

    test('15b: a failure arriving in the background never requests in it', () {
      fakeAsync((async) {
        final repo = _PendingCatalog();
        final provider = PlacesProvider(
          repository: repo,
          jitter: () => 0.5,
          connectivityProbe: repo.nextProbe,
        );
        addTearDown(provider.dispose);
        async.elapse(const Duration(milliseconds: 10));

        // The app hides while the constructor request is still in flight;
        // its late transient failure must not schedule a background retry.
        provider.setForeground(false);
        repo.fail(0, const SocketException('offline in background'));
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.error);
        expect(
          provider.isRetrying,
          isFalse,
          reason: 'a backgrounded app schedules no automatic work',
        );

        async.elapse(const Duration(minutes: 5));
        expect(
          repo.requests,
          hasLength(1),
          reason: 'no automatic network request while backgrounded',
        );

        // Returning to the screen performs exactly one recovery.
        provider.setForeground(true);
        async.elapse(const Duration(milliseconds: 10));
        expect(repo.requests, hasLength(2));
        repo.complete(1, [_place]);
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.success);
        expect(provider.places, hasLength(1));
      });
    });

    test('15c: a late DNS result cannot fire a stale recovery', () {
      fakeAsync((async) {
        var probeCalls = 0;
        final lateProbe = Completer<bool>();
        Future<bool> probe() async {
          probeCalls++;
          return lateProbe.future;
        }

        final repo = _ScriptedCatalog([
          _socket(),
          _socket(),
          _socket(),
          _socket(),
          <PlaceModel>[_place],
        ]);
        final provider = PlacesProvider(
          repository: repo,
          jitter: () => 0.5,
          connectivityProbe: probe,
        );
        addTearDown(provider.dispose);
        async.elapse(const Duration(seconds: 20));
        expect(repo.requests, hasLength(4));
        expect(provider.status, PlacesStatus.error);

        // The watch probes and its DNS answer hangs. Meanwhile the user
        // retries manually and the catalog recovers.
        async.elapse(const Duration(seconds: 15));
        expect(probeCalls, 1);
        provider.loadPlaces();
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.success);
        expect(repo.requests, hasLength(5));

        // The late "online" answer arrives: no request, no new watch timer.
        lateProbe.complete(true);
        async.elapse(const Duration(minutes: 1));
        expect(repo.requests, hasLength(5));
        expect(probeCalls, 1, reason: 'no needless re-arm after success');
      });
    });

    test('15d: a late DNS result cannot fire beside a manual load', () {
      fakeAsync((async) {
        var probeCalls = 0;
        final lateProbe = Completer<bool>();
        Future<bool> probe() async {
          probeCalls++;
          return lateProbe.future;
        }

        final repo = _ScriptedCatalog([
          _socket(),
          _socket(),
          _socket(),
          _socket(),
          const _Hang(),
        ]);
        final provider = PlacesProvider(
          repository: repo,
          jitter: () => 0.5,
          connectivityProbe: probe,
        );
        addTearDown(provider.dispose);
        async.elapse(const Duration(seconds: 35));
        expect(repo.requests, hasLength(4));
        expect(probeCalls, 1);

        // A manual retry starts (and hangs) while the DNS answer pends.
        provider.loadPlaces();
        async.elapse(const Duration(milliseconds: 10));
        expect(provider.status, PlacesStatus.loading);
        lateProbe.complete(true);
        async.elapse(const Duration(minutes: 1));
        expect(
          repo.requests,
          hasLength(5),
          reason: 'only the manual request, no probe-triggered one',
        );
        expect(probeCalls, 1);
      });
    });
  });

  test('16: a catalog failure never breaks GPS navigation', () async {
    final device = _GrantedLocation();
    final nav = NavigationProvider(locationService: device);
    addTearDown(nav.dispose);
    final places = PlacesProvider(repository: _ScriptedCatalog([_socket()]));
    addTearDown(places.dispose);
    await places.loadPlaces();
    expect(places.status, PlacesStatus.error);

    await nav.startNavigation(_route);
    expect(nav.status, NavigationStatus.active);
    expect(places.status, PlacesStatus.error, reason: 'independent domains');
  });

  group('main map recovery UI', () {
    testWidgets(
      '13/14: the manual retry button works and repeated taps stay single',
      (tester) async {
        // Permanent data failure on the first load: the honest message and
        // the visible retry button appear, with no automatic re-asking.
        final repo = _ScriptedCatalog([
          const FormatException('Invalid catalog page'),
          const _Hang(),
        ]);
        final places = PlacesProvider(
          repository: repo,
          jitter: () => 0.5,
          connectivityProbe: repo.nextProbe,
        );
        addTearDown(places.dispose);
        final guest = await _onboardedGuest();
        addTearDown(guest.dispose);
        await tester.pumpWidget(_host(places, guest));
        await tester.pump(const Duration(milliseconds: 10));

        expect(
          find.textContaining('Не удалось загрузить достопримечательности'),
          findsOneWidget,
        );
        final button = find.text('Повторить загрузку');
        expect(button, findsOneWidget);
        expect(repo.requests, hasLength(1));

        // The manual retry hangs: while it is in flight the button is
        // disabled, so repeated activation cannot spawn parallel requests.
        // (MainMapScreen keeps a transparent overlay above the panel that
        // swallows test pointers, so the real handler is invoked directly.)
        final retryButton = find.ancestor(
          of: find.text('Повторить загрузку'),
          matching: find.byType(FilledButton),
        );
        final enabled = tester.widget<FilledButton>(retryButton);
        expect(enabled.onPressed, isNotNull);
        enabled.onPressed!();
        await tester.pump(const Duration(milliseconds: 10));
        expect(repo.requests, hasLength(2));
        // While the retry is in flight the whole failure block (and its
        // button) is replaced by the loading state, so no repeated tap can
        // even target it — structurally no parallel identical requests.
        await tester.pump(const Duration(milliseconds: 10));
        expect(find.text('Повторить загрузку'), findsNothing);
        expect(places.isLoading, isTrue);
        expect(repo.requests, hasLength(2));
      },
    );

    testWidgets('stale snapshot note appears and clears on recovery', (
      tester,
    ) async {
      final repo = _ScriptedCatalog([
        <PlaceModel>[_place],
        _socket(),
        <PlaceModel>[_place, _place2],
      ]);
      final places = PlacesProvider(
        repository: repo,
        jitter: () => 0.5,
        connectivityProbe: repo.nextProbe,
      );
      addTearDown(places.dispose);
      final guest = await _onboardedGuest();
      addTearDown(guest.dispose);
      await tester.pumpWidget(_host(places, guest));
      await tester.pump(const Duration(milliseconds: 10));
      expect(places.status, PlacesStatus.success);

      // Same-filter refresh fails: the places stay and the honest stale
      // note appears.
      places.loadPlaces();
      await tester.pump(const Duration(milliseconds: 10));
      expect(places.isStale, isTrue);
      expect(places.places, isNotEmpty);
      expect(
        find.textContaining('Показаны ранее загруженные места'),
        findsOneWidget,
      );
      expect(find.text('Повторить'), findsOneWidget);

      // The automatic retry succeeds: the note disappears on its own.
      await tester.pump(const Duration(seconds: 2));
      expect(places.isStale, isFalse);
      expect(
        find.textContaining('Показаны ранее загруженные места'),
        findsNothing,
      );
    });
  });
}

const _route = PedestrianRouteModel(
  distanceMeters: 500,
  durationSeconds: 400,
  geometryPoints: [GeoCoord(59.93, 30.33), GeoCoord(59.935, 30.33)],
  steps: [],
  legs: [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'Цель',
      distanceMeters: 500,
      durationSeconds: 400,
      geometryPoints: [GeoCoord(59.93, 30.33), GeoCoord(59.935, 30.33)],
    ),
  ],
  placesCount: 1,
);

class _GrantedLocation implements BaseDeviceLocationService {
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.grantedPrecise;
  @override
  Future<LocationPermissionStatus> requestPermission() async =>
      LocationPermissionStatus.grantedPrecise;
  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async => null;
  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async => UserLocationSnapshot(
    coordinate: const GeoCoord(59.9301, 30.3301),
    accuracy: 8,
    timestamp: DateTime.now().subtract(const Duration(seconds: 1)),
  );
  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => const Stream.empty();
  @override
  Stream<bool> getServiceStatusStream() => const Stream.empty();
}

/// Two pending requests with manual completion (scenario 10).
class _PendingCatalog extends PlacesRepository {
  final pending = <Completer<List<PlaceModel>>>[];
  final requests = <String>[];
  int probeCalls = 0;

  Future<bool> nextProbe() async {
    probeCalls++;
    return true;
  }

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) {
    requests.add('${categories?.length ?? 0}|$isUnusual|$searchQuery');
    final c = Completer<List<PlaceModel>>();
    pending.add(c);
    return c.future;
  }

  void complete(int index, List<PlaceModel> places) =>
      pending[index].complete(places);

  void fail(int index, Object error) => pending[index].completeError(error);

  @override
  Future<List<CategoryModel>> getCategories() async => const [];
}

Future<GuestExperienceProvider> _onboardedGuest() async {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _GuestMemoryStorage()),
    repository: _ScriptedCatalog([
      <PlaceModel>[_place],
    ]),
    catalogScope: 'https://catalog.example/api/v1',
  );
  await guest.initialize();
  await guest.completeOnboarding();
  return guest;
}

Widget _host(PlacesProvider places, GuestExperienceProvider guest) {
  final routing = RoutingProvider(mapKitService: _NoRoutes());
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
      ChangeNotifierProvider<PlacesProvider>.value(value: places),
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
    ],
    child: const MaterialApp(home: MainMapScreen()),
  );
}

class _GuestMemoryStorage implements GuestKeyValueStore {
  String? value;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String value) async {}
}

class _NoRoutes extends MapKitService {
  @override
  void cancel() {}
}
