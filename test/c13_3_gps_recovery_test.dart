import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

/// Location fake with independent position and service-status streams. The
/// counters prove that recovery never opens a second position subscription.
class _RecoveryLocation implements BaseDeviceLocationService {
  _RecoveryLocation() {
    positions = StreamController<UserLocationSnapshot>.broadcast(
      onListen: () => positionListens++,
      onCancel: () => positionCancels++,
    );
    serviceStatus = StreamController<bool>.broadcast(
      onListen: () => serviceListens++,
      onCancel: () => serviceCancels++,
    );
  }

  bool serviceEnabled = true;
  bool failCurrent = false;
  LocationPermissionStatus permission = LocationPermissionStatus.grantedPrecise;
  UserLocationSnapshot? current;
  late final StreamController<UserLocationSnapshot> positions;
  late final StreamController<bool> serviceStatus;

  int positionListens = 0, positionCancels = 0;
  int serviceListens = 0, serviceCancels = 0;
  int permissionRequests = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      serviceEnabled ? permission : LocationPermissionStatus.serviceDisabled;

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    permissionRequests++;
    return checkPermission();
  }

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async => null;

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async {
    if (!serviceEnabled || failCurrent) {
      throw StateError('location unavailable');
    }
    return current ?? _fix();
  }

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => positions.stream;

  @override
  Stream<bool> getServiceStatusStream() => serviceStatus.stream;

  Future<void> close() async {
    await positions.close();
    await serviceStatus.close();
  }
}

int _sequence = 0;

UserLocationSnapshot _fix({
  double latitude = 60.0,
  double longitude = 30.0,
  double? accuracy = 8,
  bool cached = false,
  Duration age = const Duration(seconds: 1),
  DateTime? timestamp,
}) => UserLocationSnapshot(
  coordinate: GeoCoord(latitude, longitude),
  accuracy: accuracy,
  timestamp:
      timestamp ??
      DateTime.now().subtract(age).add(Duration(milliseconds: ++_sequence)),
  isCached: cached,
);

const _route = PedestrianRouteModel(
  distanceMeters: 600,
  durationSeconds: 400,
  geometryPoints: [GeoCoord(60.0000, 30.0), GeoCoord(60.0027, 30.0)],
  steps: [],
  legs: [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'Эрмитаж',
      distanceMeters: 600,
      durationSeconds: 400,
      geometryPoints: [GeoCoord(60.0000, 30.0), GeoCoord(60.0027, 30.0)],
    ),
  ],
  placesCount: 1,
);

void main() {
  late _RecoveryLocation device;
  late NavigationProvider nav;

  setUp(() {
    _sequence = 0;
    device = _RecoveryLocation();
    nav = NavigationProvider(locationService: device);
  });

  tearDown(() async {
    nav.dispose();
    await device.close();
    UserLocationSnapshot.clock = DateTime.now;
  });

  test('GPS off at start keeps route and resumes the same session', () async {
    device
      ..serviceEnabled = false
      ..current = _fix(latitude: 60.00005);

    await nav.startNavigation(_route);

    expect(nav.status, NavigationStatus.waitingForGps);
    expect(nav.isActive, isFalse);
    expect(nav.state.route, isNotNull);
    final retainedRoute = nav.state.route;
    expect(nav.state.errorMessage, contains('Включите геолокацию'));
    expect(nav.locksPlanning, isTrue);

    device.serviceEnabled = true;
    device.current = _fix(latitude: 60.0001);
    device.serviceStatus.add(true);
    await pumpEventQueue();

    expect(nav.status, NavigationStatus.active);
    expect(nav.isActive, isTrue);
    expect(nav.state.route, same(retainedRoute));
    expect(nav.state.isGpsLost, isFalse);
    expect(nav.state.progressOnCurrentLegMeters, greaterThan(0));
  });

  test('active navigation survives a GPS outage and reattaches once', () async {
    device.current = _fix(latitude: 60.00005);
    await nav.startNavigation(_route);
    expect(nav.status, NavigationStatus.active);
    expect(device.positionListens, 1);
    expect(device.serviceListens, 1);

    device.serviceEnabled = false;
    device.serviceStatus.add(false);
    await pumpEventQueue();

    expect(nav.status, NavigationStatus.waitingForGps);
    expect(nav.state.route, isNotNull);
    expect(device.positionCancels, 1);

    device.serviceEnabled = true;
    device.current = _fix(latitude: 60.0004);
    device.serviceStatus.add(true);
    await pumpEventQueue();

    expect(nav.status, NavigationStatus.active);
    expect(device.positionListens, 2);
    expect(device.serviceListens, 1, reason: 'no duplicate service stream');
    expect(device.positionListens - device.positionCancels, 1);
  });

  test('service restoration alone never resumes guidance', () async {
    device.current = _fix(latitude: 60.00005);
    await nav.startNavigation(_route);
    device.serviceEnabled = false;
    device.serviceStatus.add(false);
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.waitingForGps);

    // No usable one-shot fix; the status stream alone must not activate.
    device
      ..serviceEnabled = true
      ..failCurrent = true;
    device.serviceStatus.add(true);
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.waitingForGps);

    // Stale and cached frames are also not proof of recovery.
    device.positions.add(
      _fix(latitude: 60.0005, age: const Duration(seconds: 40)),
    );
    device.positions.add(_fix(latitude: 60.0005, cached: true));
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.waitingForGps);

    device.positions.add(_fix(latitude: 60.0005));
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.active);
  });

  test(
    'navigation start asks for access once, recovery never re-asks',
    () async {
      device
        ..serviceEnabled = false
        ..permission = LocationPermissionStatus.denied;
      await nav.startNavigation(_route);
      expect(nav.status, NavigationStatus.waitingForGps);
      // P1: navigation itself settles the permission even while the service
      // probe is off — exactly one request per start.
      expect(device.permissionRequests, 1);

      device.serviceEnabled = true;
      device.serviceStatus.add(true);
      await pumpEventQueue();
      expect(nav.status, NavigationStatus.waitingForGps);
      // No repeated system dialogs while the access is still missing.
      expect(device.permissionRequests, 1);
      expect(device.positionListens, 0);

      device.permission = LocationPermissionStatus.grantedPrecise;
      // The watchdog reconciles access; a direct status event is the platform
      // signal used in production when the user returns from settings.
      device.serviceStatus.add(true);
      await pumpEventQueue();
      expect(device.permissionRequests, 1);
      expect(nav.status, NavigationStatus.active);
    },
  );

  test('rapid on/off toggles never create duplicate subscriptions', () async {
    device.current = _fix(latitude: 60.00005);
    await nav.startNavigation(_route);
    expect(device.positionListens, 1);

    for (var i = 0; i < 4; i++) {
      device.serviceEnabled = false;
      device.serviceStatus.add(false);
      device.serviceEnabled = true;
      device.serviceStatus.add(true);
    }
    device.current = _fix(latitude: 60.0002);
    await pumpEventQueue();

    expect(
      device.positionListens - device.positionCancels,
      lessThanOrEqualTo(1),
    );
    expect(device.serviceListens, 1);
    expect(nav.status, NavigationStatus.active);
  });

  test('stopping while waiting releases both streams', () async {
    device.serviceEnabled = false;
    await nav.startNavigation(_route);
    expect(nav.status, NavigationStatus.waitingForGps);

    nav.stopNavigation();
    await pumpEventQueue();

    expect(nav.status, NavigationStatus.idle);
    expect(device.positionCancels, 0);
    expect(device.serviceCancels, 1);

    // A late platform event cannot resurrect the ended session.
    device.serviceEnabled = true;
    device.serviceStatus.add(true);
    device.current = _fix();
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.idle);
    expect(nav.state.route, isNull);
  });

  test('background pause while waiting and resume keeps the route', () async {
    device.serviceEnabled = false;
    await nav.startNavigation(_route);
    final retained = nav.state.route;

    nav.pauseNavigation();
    expect(nav.status, NavigationStatus.paused);
    await nav.resumeNavigation();
    expect(nav.status, NavigationStatus.waitingForGps);
    expect(nav.state.route, same(retained));

    device.serviceEnabled = true;
    device.current = _fix();
    device.serviceStatus.add(true);
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.active);
    expect(nav.state.route, same(retained));
  });

  test('a stale fix cannot confirm arrival after recovery', () async {
    const shortRoute = PedestrianRouteModel(
      distanceMeters: 20,
      durationSeconds: 20,
      geometryPoints: [GeoCoord(60.0, 30.0), GeoCoord(60.0001, 30.0)],
      steps: [],
      legs: [
        RouteLegModel(
          fromTitle: 'Старт',
          toTitle: 'Цель',
          distanceMeters: 20,
          durationSeconds: 20,
          geometryPoints: [GeoCoord(60.0, 30.0), GeoCoord(60.0001, 30.0)],
        ),
      ],
      placesCount: 1,
    );
    device.current = _fix(latitude: 60.00001);
    await nav.startNavigation(shortRoute);
    device.serviceEnabled = false;
    device.serviceStatus.add(false);
    await pumpEventQueue();
    expect(nav.status, NavigationStatus.waitingForGps);

    // A stale endpoint fix after the outage cannot complete the leg.
    device.serviceEnabled = true;
    device.failCurrent = true;
    device.serviceStatus.add(true);
    await pumpEventQueue();
    device.positions.add(
      _fix(latitude: 60.0001, age: const Duration(seconds: 30)),
    );
    await pumpEventQueue();
    expect(nav.isCompleted, isFalse);
    expect(nav.status, NavigationStatus.waitingForGps);
  });

  test('route geometry errors stay terminal errors, not GPS waiting', () async {
    const broken = PedestrianRouteModel(
      distanceMeters: 10,
      durationSeconds: 10,
      geometryPoints: [GeoCoord(60, 30), GeoCoord(60, 30)],
      steps: [],
    );
    await nav.startNavigation(broken);
    expect(nav.status, NavigationStatus.error);
    expect(nav.state.isWaitingForGps, isFalse);
  });

  testWidgets('waiting state is visible and offers a way to finish', (
    tester,
  ) async {
    device.serviceEnabled = false;
    await nav.startNavigation(_route);
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
    expect(find.textContaining('Включите геолокацию'), findsWidgets);
    expect(find.text('Завершить'), findsOneWidget);
    await tester.tap(find.text('Завершить'));
    await tester.pumpAndSettle();
    // The confirmation dialog is the existing end-session path.
    expect(find.text('Завершить прогулку?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(nav.status, NavigationStatus.waitingForGps);
    nav.stopNavigation();
    await tester.pump();
  });
}
