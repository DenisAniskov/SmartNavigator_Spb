import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

/// P1 regression: navigation start itself must offer the location permission
/// dialog regardless of how the start point was chosen and regardless of the
/// location-service probe outcome.
///
/// Root cause (proved before the fix): startNavigation probed the service
/// availability FIRST and skipped requestPermission entirely when the probe
/// was false (and DeviceLocationService.requestPermission had its own probe
/// gate), while the waiting state and the watchdog only ever re-CHECK the
/// permission. The only UI paths that ever asked were the map's
/// «Моё местоположение» / centering actions — exactly the observed bug.
///
/// The fake below models the FIXED real-service semantics: requestPermission
/// settles the user's access choice regardless of the service state.
class _P1FakeLocation implements BaseDeviceLocationService {
  bool serviceEnabled = true;

  /// The current permission state as the OS reports it.
  LocationPermissionStatus permission = LocationPermissionStatus.denied;

  /// What the system dialog settles to; null falls back to [permission].
  LocationPermissionStatus? requestResult;

  /// When set, the system dialog is open: the request stays pending until
  /// the gate completes (the user answering the dialog).
  Completer<LocationPermissionStatus>? requestGate;

  UserLocationSnapshot? current;

  late final StreamController<UserLocationSnapshot> positions =
      StreamController<UserLocationSnapshot>.broadcast(
        onListen: () => positionListens++,
        onCancel: () => positionCancels++,
      );
  final StreamController<bool> serviceStatusEvents =
      StreamController<bool>.broadcast();

  int permissionRequests = 0, positionListens = 0, positionCancels = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermissionStatus> checkPermission() async => permission;

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    permissionRequests++;
    final gate = requestGate;
    if (gate != null) return gate.future;
    return requestResult ?? permission;
  }

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async => null;

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async {
    if (!serviceEnabled) throw StateError('location service is off');
    return current ?? _fix();
  }

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => positions.stream;

  @override
  Stream<bool> getServiceStatusStream() => serviceStatusEvents.stream;

  Future<void> close() async {
    await positions.close();
    await serviceStatusEvents.close();
  }
}

int _sequence = 0;

UserLocationSnapshot _fix({double latitude = 59.9305}) => UserLocationSnapshot(
  coordinate: GeoCoord(latitude, 30.33),
  accuracy: 8,
  timestamp: DateTime.now()
      .subtract(const Duration(seconds: 1))
      .add(Duration(milliseconds: ++_sequence)),
);

PedestrianRouteModel _route({String fromTitle = 'Площадь Восстания'}) {
  const a = GeoCoord(59.93, 30.33);
  const b = GeoCoord(59.935, 30.33);
  return PedestrianRouteModel(
    distanceMeters: 550,
    durationSeconds: 420,
    geometryPoints: const [a, b],
    steps: const [],
    legs: [
      RouteLegModel(
        fromTitle: fromTitle,
        toTitle: 'Казанский собор',
        distanceMeters: 550,
        durationSeconds: 420,
        geometryPoints: const [a, b],
      ),
    ],
    placesCount: 1,
  );
}

PlaceModel _place() => const PlaceModel(
  id: 7,
  title: 'Казанский собор',
  shortDescription: 'Описание',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.9343,
  longitude: 30.3249,
  address: 'СПб',
  recommendedVisitMinutes: 20,
);

class _InstantRoutes extends MapKitService {
  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async => _route();
}

Widget _sheetHost(RoutingProvider routing, NavigationProvider nav) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ChangeNotifierProvider<NavigationProvider>.value(value: nav),
    ],
    child: const MaterialApp(home: Scaffold(body: RouteDetailsSheet())),
  );
}

void main() {
  setUp(() {
    _sequence = 0;
    MapKitService.isMapKitInitialized = false;
  });

  group('startNavigation permission order', () {
    late _P1FakeLocation device;
    late NavigationProvider nav;

    setUp(() {
      device = _P1FakeLocation();
      nav = NavigationProvider(locationService: device);
    });

    tearDown(() async {
      nav.dispose();
      await device.close();
    });

    test(
      'manual start, first navigation, askable permission: one dialog',
      () async {
        device.permission = LocationPermissionStatus.denied;
        await nav.startNavigation(_route());
        expect(device.permissionRequests, 1);
        expect(nav.status, NavigationStatus.waitingForGps);
        expect(nav.isActive, isFalse);
        expect(nav.state.errorMessage, contains('Нет разрешения'));
        final retained = nav.state.route;
        expect(retained, isNotNull);

        // The user grants later (e.g. via the map's my-location action); the
        // SAME session resumes with a fresh fix and no second dialog.
        device
          ..permission = LocationPermissionStatus.grantedPrecise
          ..current = _fix(latitude: 59.9301);
        device.serviceStatusEvents.add(true);
        await pumpEventQueue();
        expect(nav.status, NavigationStatus.active);
        expect(nav.state.route, same(retained));
        expect(device.permissionRequests, 1, reason: 'no repeated dialog');
      },
    );

    test(
      'service probe false with askable permission still offers the dialog',
      () async {
        // The reported repro: a false service probe must never silently skip
        // the permission request — the old code made zero requests here.
        device
          ..serviceEnabled = false
          ..permission = LocationPermissionStatus.denied;
        await nav.startNavigation(_route());
        expect(
          device.permissionRequests,
          1,
          reason: 'P1: the request is not gated by the service probe',
        );
        expect(nav.status, NavigationStatus.waitingForGps);
        expect(nav.isActive, isFalse);

        device
          ..serviceEnabled = true
          ..permission = LocationPermissionStatus.grantedPrecise
          ..current = _fix();
        device.serviceStatusEvents.add(true);
        await pumpEventQueue();
        expect(nav.status, NavigationStatus.active);
        expect(device.permissionRequests, 1);
      },
    );

    test('«Моё местоположение» start keeps the chosen origin', () async {
      final route = _route(fromTitle: 'Моё местоположение');
      device
        ..permission = LocationPermissionStatus.grantedPrecise
        ..current = _fix(latitude: 59.931);
      await nav.startNavigation(route);
      expect(nav.status, NavigationStatus.active);
      expect(device.permissionRequests, 1);
      // The frozen session route keeps the user-chosen origin and geometry;
      // GPS only ever becomes the live position, never the start point.
      expect(nav.state.route!.legs.first.fromTitle, 'Моё местоположение');
      expect(
        nav.state.route!.legs.first.geometryPoints.first.latitude,
        route.legs.first.geometryPoints.first.latitude,
      );
      expect(
        nav.state.route!.legs.first.geometryPoints.last.longitude,
        route.legs.first.geometryPoints.last.longitude,
      );
    });

    test('permission granted earlier navigates immediately', () async {
      device.permission = LocationPermissionStatus.grantedPrecise;
      await nav.startNavigation(_route());
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isGpsLost, isFalse);
      expect(nav.state.errorMessage, isNull);
      expect(device.permissionRequests, 1);
    });

    test('denial keeps waiting with an honest message', () async {
      device.permission = LocationPermissionStatus.denied;
      await nav.startNavigation(_route());
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(
        nav.state.errorMessage,
        contains('Навигация продолжится после разрешения'),
      );
      nav.stopNavigation();
    });

    test('permanent denial points to settings without opening them', () async {
      device.permission = LocationPermissionStatus.permanentlyDenied;
      await nav.startNavigation(_route());
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.state.errorMessage, contains('настройках'));
      nav.stopNavigation();
    });

    test('service off with granted permission waits for location', () async {
      device
        ..serviceEnabled = false
        ..permission = LocationPermissionStatus.grantedPrecise;
      await nav.startNavigation(_route());
      expect(
        device.permissionRequests,
        1,
        reason: 'settled silently — access already granted',
      );
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.state.errorMessage, contains('Включите геолокацию'));
      expect(nav.state.route, isNotNull);

      device
        ..serviceEnabled = true
        ..current = _fix();
      device.serviceStatusEvents.add(true);
      await pumpEventQueue();
      expect(nav.status, NavigationStatus.active);
    });

    test('coarse (approximate) permission is enough to navigate', () async {
      device.permission = LocationPermissionStatus.grantedCoarse;
      await nav.startNavigation(_route());
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isGpsLost, isFalse);
      expect(device.permissionRequests, 1);
    });

    test(
      'rapid re-taps while the dialog is open never double-request',
      () async {
        device.permission = LocationPermissionStatus.denied;
        device.requestGate = Completer<LocationPermissionStatus>();
        final first = nav.startNavigation(_route());
        await pumpEventQueue();

        final second = nav.startNavigation(_route());
        await second;
        expect(device.permissionRequests, 1);

        // The dialog answer IS the new permission state on a real device.
        device.permission = LocationPermissionStatus.grantedPrecise;
        device.requestGate!.complete(LocationPermissionStatus.grantedPrecise);
        await first;
        await pumpEventQueue();
        expect(nav.status, NavigationStatus.active);
        expect(device.permissionRequests, 1);
      },
    );

    test(
      'stopping the session while the dialog is open leaves nothing running',
      () async {
        device.permission = LocationPermissionStatus.denied;
        device.requestGate = Completer<LocationPermissionStatus>();
        final pending = nav.startNavigation(_route());
        await pumpEventQueue();

        nav.stopNavigation();
        device.requestGate!.complete(LocationPermissionStatus.grantedPrecise);
        await pending;
        await pumpEventQueue();

        expect(nav.status, NavigationStatus.idle);
        expect(nav.state.route, isNull);
        expect(device.positionListens, 0);
        expect(device.permissionRequests, 1);
      },
    );

    test('app resume never re-asks and keeps the session', () async {
      device.permission = LocationPermissionStatus.grantedPrecise;
      await nav.startNavigation(_route());
      final retained = nav.state.route;
      expect(nav.status, NavigationStatus.active);

      nav.pauseNavigation();
      await nav.resumeNavigation();
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.route, same(retained));

      device.positions.add(_fix(latitude: 59.9302));
      await pumpEventQueue();
      expect(nav.state.isGpsLost, isFalse);
      expect(device.permissionRequests, 1, reason: 'resume stays silent');
    });
  });

  group('route details sheet', () {
    testWidgets('planning and sheet rendering never touch the permission', (
      tester,
    ) async {
      final device = _P1FakeLocation()
        ..permission = LocationPermissionStatus.grantedPrecise;
      final nav = NavigationProvider(locationService: device);
      final routing = RoutingProvider(mapKitService: _InstantRoutes());
      addTearDown(nav.dispose);
      addTearDown(routing.dispose);
      addTearDown(device.close);

      await routing.buildRouteTo(_place());
      expect(routing.hasRoute, isTrue);
      expect(
        device.permissionRequests,
        0,
        reason: 'plain route planning never requests GPS',
      );

      await tester.pumpWidget(_sheetHost(routing, nav));
      await tester.pumpAndSettle();
      expect(find.text('Начать маршрут'), findsOneWidget);
      expect(device.permissionRequests, 0);
      expect(device.positionListens, 0);
      expect(nav.status, NavigationStatus.idle);
    });

    testWidgets(
      'manual start point: tapping the real button offers the dialog once',
      (tester) async {
        final device = _P1FakeLocation();
        final nav = NavigationProvider(locationService: device);
        final routing = RoutingProvider(mapKitService: _InstantRoutes());
        addTearDown(nav.dispose);
        addTearDown(routing.dispose);
        addTearDown(device.close);

        await routing.buildRouteTo(_place());
        await tester.pumpWidget(_sheetHost(routing, nav));
        await tester.pumpAndSettle();
        expect(device.permissionRequests, 0);

        await tester.tap(find.text('Начать маршрут'));
        await tester.pumpAndSettle();

        expect(
          device.permissionRequests,
          1,
          reason: 'navigation itself asks — the chosen start point is manual',
        );
        expect(nav.status, NavigationStatus.waitingForGps);
        expect(nav.state.errorMessage, contains('разрешения'));
        final button = tester.widget<ElevatedButton>(
          find.ancestor(
            of: find.text('Начать маршрут'),
            matching: find.byType(ElevatedButton),
          ),
        );
        expect(
          button.onPressed,
          isNull,
          reason: 'the waiting session owns the start action',
        );
        nav.stopNavigation();
      },
    );

    testWidgets('waiting state explains the missing access honestly', (
      tester,
    ) async {
      final device = _P1FakeLocation();
      final nav = NavigationProvider(locationService: device);
      addTearDown(nav.dispose);
      addTearDown(device.close);

      await nav.startNavigation(_route());
      expect(nav.status, NavigationStatus.waitingForGps);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NavigationProvider>.value(
            value: nav,
            child: const Scaffold(body: LiveNavigationSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ожидаем местоположение'), findsOneWidget);
      expect(find.textContaining('Навигация продолжится'), findsWidgets);
      nav.stopNavigation();
      await tester.pump();
    });
  });
}
