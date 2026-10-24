import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/utils/off_route_detector.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/pedestrian_guidance_service.dart';

class NavigationProvider extends ChangeNotifier {
  final BaseDeviceLocationService _locationService;
  final RoutingProvider? _routing;
  final BasePedestrianRouteService? _routeService;
  NavigationProvider({
    BaseDeviceLocationService? locationService,
    RoutingProvider? routingProvider,
    BasePedestrianRouteService? routeService,
  }) : _locationService = locationService ?? DeviceLocationService(),
       _routing = routingProvider,
       _routeService = routeService ?? MapKitService();
  LiveNavigationState _state = const LiveNavigationState();
  LiveNavigationState get state => _state;
  PedestrianGuidanceModel get guidance =>
      const PedestrianGuidanceService().guidanceFor(state);
  NavigationStatus get status => _state.status;
  bool get isActive => _state.isActive;
  bool get isCompleted => _state.isCompleted;
  bool get locksPlanning =>
      status == NavigationStatus.starting ||
      status == NavigationStatus.rerouting ||
      isActive ||
      _state.isWaitingForGps ||
      _state.isPaused;
  int get currentLegIndex => _state.currentLegIndex;
  RouteLegModel? get currentLeg => _state.currentLeg;
  double get remainingDistanceMeters =>
      _state.remainingDistanceOnCurrentLegMeters;
  static const arrivalRadiusMeters = 25.0,
      offRouteThresholdMeters = 50.0,
      returnToRouteThresholdMeters = 35.0,
      maxProgressRewindMeters = 15.0;

  /// Auto-arrival needs two validated fixes within [arrivalRadiusMeters] of
  /// the leg endpoint. MapKit may snap a waypoint to the nearest
  /// pedestrian-accessible point and urban GPS can keep the device slightly
  /// outside that radius while the user already stands at the POI; without an
  /// explicit fallback such an arrival could never be confirmed. The manual
  /// action requires both a small remaining distance and a fresh validated
  /// position within that margin of the endpoint. A frozen near-end projection
  /// cannot authorize arrival after the user walks far away or GPS expires.
  ///
  /// POLICY (RC2 decision, kept as-is): a leg whose TOTAL length is already
  /// within the bound can honestly offer «Я на месте» at t=0 — no minimum
  /// progress is required. Any minimum-progress or movement rule would remove
  /// the rescue exactly in the scenario it exists for: a snapped waypoint or
  /// urban-canyon fix leaves the projection legitimately near zero while the
  /// user stands at the POI. The action is an explicit user assertion gated by
  /// a fresh, validated, non-cached fix, and on a ≤150 m leg the user is
  /// always within 150 m of the stop; the bounded tradeoff (a short
  /// intermediate stop can be confirmed without movement) is accepted.
  static const manualArrivalMaxMeters = 150.0;
  static const requiredArrivalFixes = 2;
  static const requiredOffRouteFixes = 3, requiredOnRouteFixes = 2;
  static const offRouteSustainDuration = Duration(seconds: 5);
  StreamSubscription<UserLocationSnapshot>? _subscription;
  StreamSubscription<bool>? _serviceStatusSubscription;
  Timer? _watchdog;
  bool _disposed = false,
      _foreground = true,
      _recovering = false,
      _recoverAgain = false;
  int _revision = 0, _arrivals = 0;
  int? _checkingRevision;
  DateTime? _lastTimestamp;
  double? _pendingJump;
  List<RouteLegModel> _legs = [];
  List<double> _lengths = [];
  final OffRouteDetector _detector = OffRouteDetector(
    offRouteThresholdMeters: offRouteThresholdMeters,
    returnToRouteThresholdMeters: returnToRouteThresholdMeters,
    requiredOffRouteFixes: requiredOffRouteFixes,
    offRouteSustainDuration: offRouteSustainDuration,
    requiredOnRouteFixes: requiredOnRouteFixes,
  );
  double get _total => _lengths.fold(0.0, (a, b) => a + b);
  bool _validRun(int revision) =>
      !_disposed && _foreground && revision == _revision;
  bool get _observesLocation =>
      isActive || _state.isWaitingForGps || _state.isRerouting;
  bool _granted(LocationPermissionStatus p) =>
      p == LocationPermissionStatus.grantedPrecise ||
      p == LocationPermissionStatus.grantedCoarse;

  /// Intrinsic fix quality: rejects cached, stale, non-finite, out-of-range
  /// and low-accuracy snapshots regardless of session state.
  bool _isValidFix(UserLocationSnapshot? fix) {
    if (fix == null) return false;
    final p = fix.coordinate;
    return !fix.isCached &&
        fix.isFresh(maxAge: const Duration(seconds: 15)) &&
        p.latitude.isFinite &&
        p.longitude.isFinite &&
        p.latitude.abs() <= 90 &&
        p.longitude.abs() <= 180 &&
        (fix.accuracy == null ||
            (fix.accuracy!.isFinite &&
                fix.accuracy! >= 0 &&
                fix.accuracy! <= 50));
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _clearFixStreaks() {
    _arrivals = 0;
    _pendingJump = null;
    _detector.clearPendingFixes();
  }

  /// A recoverable loss of location. The route, leg index and progress stay
  /// intact; only guidance and arrival/off-route confirmation are suspended
  /// until a fresh validated fix is accepted.
  void _enterGpsWaiting(String message, {bool detachPositionStream = true}) {
    _clearFixStreaks();
    if (detachPositionStream) _detachPositionStream();
    // A native reroute may outlive its authorization. The old route stays on
    // screen, so an in-flight replacement must not commit behind the waiting
    // state.
    if (_state.isRerouting) _cancelRerouteRequest();
    _state = _state.copyWith(
      status: NavigationStatus.waitingForGps,
      isGpsLost: true,
      isOffRoute: false,
      errorMessage: message,
      clearProjectedPoint: true,
    );
    _publish();
    // Waiting is still an observed session: keep the service-change stream
    // alive so enabling GPS resumes it without waiting for the watchdog.
    _ensureServiceStatusSubscription(_revision);
  }

  void _detachPositionStream() {
    final old = _subscription;
    _subscription = null;
    if (old != null) unawaited(old.cancel());
  }

  void _release() {
    _detachPositionStream();
    final oldStatus = _serviceStatusSubscription;
    _serviceStatusSubscription = null;
    if (oldStatus != null) unawaited(oldStatus.cancel());
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// Aborts a native reroute request left in flight when the session ends.
  void _cancelRerouteRequest() {
    if (_state.isRerouting) _routeService?.cancel();
  }

  Future<void> startNavigation(PedestrianRouteModel route) async {
    if (_disposed || !_foreground || locksPlanning) return;
    _release();
    final revision = ++_revision;
    _arrivals = 0;
    _lastTimestamp = null;
    _pendingJump = null;
    _detector.reset();
    _legs = route.legs.isEmpty
        ? [
            RouteLegModel(
              fromTitle: 'Старт',
              toTitle: _routing?.destinationTitle ?? 'Точка назначения',
              distanceMeters: route.distanceMeters,
              durationSeconds: route.durationSeconds,
              geometryPoints: route.geometryPoints,
            ),
          ]
        : route.legs;
    if (route.errorMessage != null ||
        _legs.any(
          (l) =>
              l.geometryPoints.length < 2 ||
              l.geometryPoints.any(
                (p) =>
                    !p.latitude.isFinite ||
                    !p.longitude.isFinite ||
                    p.latitude.abs() > 90 ||
                    p.longitude.abs() > 180,
              ),
        )) {
      _state = const LiveNavigationState(
        status: NavigationStatus.error,
        errorMessage: 'Маршрут не содержит корректной геометрии для навигации.',
      );
      _publish();
      return;
    }
    _legs = List.unmodifiable(
      _legs.map(
        (l) => RouteLegModel(
          fromTitle: l.fromTitle,
          toTitle: l.toTitle,
          distanceMeters: l.distanceMeters,
          durationSeconds: l.durationSeconds,
          geometryPoints: List.unmodifiable(l.geometryPoints),
          maneuvers: List.unmodifiable(l.maneuvers),
          visitMinutes: l.visitMinutes,
          scenic: l.scenic,
        ),
      ),
    );
    _lengths = _legs
        .map((l) => RouteProjectionUtils.polylineLengthMeters(l.geometryPoints))
        .toList();
    if (_lengths.any((l) => !l.isFinite || l <= 0)) {
      _state = const LiveNavigationState(
        status: NavigationStatus.error,
        errorMessage: 'Маршрут не содержит пешеходного участка.',
      );
      _publish();
      return;
    }
    final frozen = PedestrianRouteModel(
      distanceMeters: _total,
      durationSeconds: route.durationSeconds,
      geometryPoints: List.unmodifiable(route.geometryPoints),
      steps: List.unmodifiable(route.steps),
      legs: _legs,
      placesCount: route.placesCount,
      walkKind: route.walkKind,
    );
    _state = LiveNavigationState(
      status: NavigationStatus.starting,
      route: frozen,
      remainingDistanceOnCurrentLegMeters: _lengths.first,
      totalRemainingMeters: _total,
      isGpsLost: true,
    );
    // The frozen geometry is what this session walks: the routing provider
    // must know it, so a mid-walk shade refresh describes THIS ground and a
    // rebuilt route can never leave a stale estimate on the map (§15.5).
    _routing?.setNavigationRoute(frozen);
    _routing?.setNavigationLocked(true);
    _publish();
    // Subscribe before the first availability check so toggling GPS while the
    // one-shot fix is pending is not lost.
    _ensureServiceStatusSubscription(revision);
    try {
      // P1: settle the location permission BEFORE probing the service. The
      // probe describes provider availability, not the user's access choice,
      // and can report the service off (fused-provider flake, both OS
      // provider flags off) while the permission is still askable — gating
      // the request behind it made a fresh install start a session silently
      // with no dialog, and the waiting state never asks again. The dialog
      // is offered at most once per start; recovery only re-checks silently.
      final permission = await _locationService.requestPermission();
      if (!_validRun(revision)) return;
      if (!_granted(permission)) {
        _enterGpsWaiting(switch (permission) {
          LocationPermissionStatus.permanentlyDenied =>
            'Доступ к местоположению запрещён. Разрешите его в настройках.',
          LocationPermissionStatus.serviceDisabled =>
            'Ожидаем местоположение. Включите геолокацию.',
          _ =>
            'Нет разрешения на доступ к геолокации. Навигация '
                'продолжится после разрешения.',
        });
        _startWatchdog(revision);
        return;
      }
      final enabled = await _locationService.isLocationServiceEnabled();
      if (!_validRun(revision)) return;
      if (!enabled) {
        _enterGpsWaiting('Ожидаем местоположение. Включите геолокацию.');
        _startWatchdog(revision);
        return;
      }
      UserLocationSnapshot? fix;
      try {
        fix = await _locationService.getCurrentPosition(
          timeLimit: const Duration(seconds: 5),
        );
      } catch (_) {
        /* Wait for a fresh stream fix; never use cached fallback. */
      }
      if (!_validRun(revision)) return;
      final currentPermission = await _locationService.checkPermission();
      if (!_validRun(revision)) return;
      if (!_granted(currentPermission)) {
        _enterGpsWaiting(
          'Проверьте доступ к геолокации. Навигация продолжится после '
          'разрешения.',
        );
        _startWatchdog(revision);
        return;
      }
      _state = _state.copyWith(status: NavigationStatus.active);
      if (fix != null) _process(fix);
      if (!isCompleted) {
        _subscribe(revision);
        _startWatchdog(revision);
        _ensureServiceStatusSubscription(revision);
      }
      _publish();
    } catch (_) {
      if (_validRun(revision)) {
        _enterGpsWaiting(
          'Геолокация временно недоступна. Ожидаем восстановления.',
        );
        _subscribe(revision);
        _startWatchdog(revision);
        _ensureServiceStatusSubscription(revision);
      }
    }
  }

  void _subscribe(int revision) {
    if (!_validRun(revision) || !_observesLocation || _subscription != null) {
      return;
    }
    _subscription = _locationService
        .getPositionStream(distanceFilterMeters: 0, intervalDurationMs: 2000)
        .listen(
          (fix) {
            if (_validRun(revision) && _observesLocation) _process(fix);
          },
          onError: (Object _) {
            if (!_validRun(revision)) return;
            final old = _subscription;
            _subscription = null;
            if (old != null) unawaited(old.cancel());
            _enterGpsWaiting(
              'Геолокация временно недоступна. Ожидаем восстановления.',
              detachPositionStream: false,
            );
          },
          onDone: () {
            if (_validRun(revision)) _subscription = null;
          },
        );
  }

  /// Platform service-change subscription. It is created once per session and
  /// only while location is observed, so recovery never opens parallel
  /// position subscriptions.
  void _ensureServiceStatusSubscription(int revision) {
    if (!_validRun(revision) ||
        !_observesLocation ||
        _serviceStatusSubscription != null) {
      return;
    }
    _serviceStatusSubscription = _locationService
        .getServiceStatusStream()
        .listen(
          (enabled) {
            if (!_validRun(revision) || !_observesLocation) return;
            if (!enabled) {
              _enterGpsWaiting('Ожидаем местоположение. Включите геолокацию.');
              return;
            }
            unawaited(_recoverLocation(revision));
          },
          onError: (Object _) {
            if (_validRun(revision)) _serviceStatusSubscription = null;
          },
          onDone: () {
            if (_validRun(revision)) _serviceStatusSubscription = null;
          },
        );
  }

  /// Re-checks permission and reattaches the position stream. The session
  /// stays in [NavigationStatus.waitingForGps] until a fresh, validated fix is
  /// accepted by [_process]; restoring the service alone is not proof of a
  /// usable position.
  Future<void> _recoverLocation(int revision) async {
    if (!_validRun(revision) ||
        !_observesLocation ||
        !(_state.isWaitingForGps || _state.isGpsLost)) {
      return;
    }
    if (_recovering) {
      // Rapid on/off/on toggles: the last enabling event must still win after
      // the in-flight permission/fix check completes.
      _recoverAgain = true;
      return;
    }
    _recovering = true;
    try {
      final permission = await _locationService.checkPermission();
      if (!_validRun(revision) || !_observesLocation) return;
      if (!_granted(permission)) {
        final message = permission == LocationPermissionStatus.permanentlyDenied
            ? 'Доступ к местоположению запрещён. Разрешите его в настройках.'
            : 'Нет разрешения на доступ к геолокации. Навигация продолжится '
                  'после разрешения.';
        if (!_state.isWaitingForGps) {
          _enterGpsWaiting(message);
        } else if (_state.errorMessage != message) {
          // The service is back, but access is still missing: keep the same
          // waiting session and only correct the explanation.
          _state = _state.copyWith(errorMessage: message);
          _publish();
        }
        return;
      }
      _subscribe(revision);
      _ensureServiceStatusSubscription(revision);
      if (!_state.isWaitingForGps) return;
      _state = _state.copyWith(errorMessage: 'Ожидаем свежий сигнал GPS.');
      _publish();
      // A one-shot fix is the fastest way to resume; it is still validated by
      // [_process] (freshness, accuracy, timestamp ordering).
      try {
        final fix = await _locationService.getCurrentPosition(
          timeLimit: const Duration(seconds: 5),
        );
        if (!_validRun(revision) || !_observesLocation) return;
        if (!_isValidFix(fix) || !_state.isWaitingForGps) return;
        if (_lastTimestamp == null || fix.timestamp.isAfter(_lastTimestamp!)) {
          _process(fix);
        } else if (!fix.timestamp.isBefore(_lastTimestamp!)) {
          // The platform returned the same live measurement that was already
          // accepted before the outage. It is fresh and valid, so guidance may
          // resume, but progress/arrival must not be processed twice.
          _state = _state.copyWith(
            status: NavigationStatus.active,
            currentLocation: fix,
            isGpsLost: false,
            clearError: true,
          );
          _publish();
        }
      } catch (_) {
        // The position stream remains the authoritative recovery path.
      }
    } catch (_) {
      if (_validRun(revision) && !_state.isWaitingForGps) {
        _enterGpsWaiting(
          'Геолокация временно недоступна. Ожидаем восстановления.',
        );
      }
    } finally {
      _recovering = false;
      if (_recoverAgain) {
        _recoverAgain = false;
        if (_validRun(revision)) {
          unawaited(_recoverLocation(revision));
        }
      }
    }
  }

  void _startWatchdog(int revision) {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkAccess(revision),
    );
  }

  Future<void> _checkAccess(int revision) async {
    if (!_validRun(revision) ||
        !_observesLocation ||
        _checkingRevision == revision) {
      return;
    }
    _checkingRevision = revision;
    try {
      final permission = await _locationService.checkPermission();
      if (!_validRun(revision)) return;
      if (!_granted(permission)) {
        final message = permission == LocationPermissionStatus.serviceDisabled
            ? 'Ожидаем местоположение. Включите геолокацию.'
            : 'Доступ к местоположению запрещён. Разрешите его в настройках.';
        if (!_state.isWaitingForGps) {
          _enterGpsWaiting(message);
        } else if (_state.errorMessage != message) {
          _state = _state.copyWith(errorMessage: message);
          _publish();
        }
        _ensureServiceStatusSubscription(revision);
        return;
      }
      _subscribe(revision);
      _ensureServiceStatusSubscription(revision);
      // Freshness belongs to the fix's measurement time, not receipt time:
      // a position already 14 s old cannot buy another 15 s of GPS health.
      if (!_isValidFix(_state.currentLocation) && !_state.isWaitingForGps) {
        _enterGpsWaiting(
          'Ожидаем свежий сигнал GPS.',
          detachPositionStream: false,
        );
      }
    } catch (_) {
      if (_validRun(revision) && !_state.isWaitingForGps) {
        _enterGpsWaiting(
          'Не удалось проверить геолокацию. Ожидаем восстановления.',
        );
      }
    } finally {
      if (_checkingRevision == revision) _checkingRevision = null;
    }
  }

  void _process(UserLocationSnapshot fix) {
    if (!_observesLocation || _disposed || !_foreground) return;
    if (!_isValidFix(fix) ||
        (_lastTimestamp != null && !fix.timestamp.isAfter(_lastTimestamp!))) {
      _clearFixStreaks();
      return;
    }
    final p = fix.coordinate;
    final elapsed = _lastTimestamp == null
        ? 0.0
        : fix.timestamp.difference(_lastTimestamp!).inMilliseconds / 1000.0;
    if (elapsed > 10) _clearFixStreaks();
    _lastTimestamp = fix.timestamp;
    // Recovery is complete only here: a fresh, validated fix (not merely the
    // service switch or a cached/one-shot position) lifts the waiting state.
    if (_state.isWaitingForGps) {
      _state = _state.copyWith(
        status: NavigationStatus.active,
        isGpsLost: false,
        clearError: true,
      );
    }
    // Continue observing live GPS while MapKit builds a replacement. Route
    // progress stays on the old geometry until that result is committed.
    if (_state.isRerouting || _state.isWaitingForNextLegConfirmation) {
      _state = _state.copyWith(
        currentLocation: fix,
        isGpsLost: false,
        clearError: true,
      );
      _publish();
      return;
    }
    final leg = _legs[currentLegIndex];
    final projection = RouteProjectionUtils.projectOntoPolyline(
      point: p,
      polyline: leg.geometryPoints,
    );
    final beyondThreshold =
        projection.distanceFromRouteMeters > offRouteThresholdMeters;
    _detector.registerFix(fix.timestamp, projection.distanceFromRouteMeters);
    final confirmedOffRoute = _detector.isConfirmedOffRoute;
    var progress = projection.progressMeters;
    final previous = _state.progressOnCurrentLegMeters;
    // Confirm large forward jumps with a second consistent fix; a normal fix
    // clears the candidate. One erroneous fix cannot permanently latch progress.
    final jumpLimit = math.max(60.0, elapsed * 3 + 15);
    if (!beyondThreshold && progress - previous > jumpLimit) {
      if (_pendingJump == null || (progress - _pendingJump!).abs() > 30) {
        _pendingJump = progress;
        _arrivals = 0;
        _state = _state.copyWith(
          currentLocation: fix,
          projectedPoint: projection.nearestPoint,
          distanceFromRouteMeters: projection.distanceFromRouteMeters,
          isOffRoute: confirmedOffRoute,
          isGpsLost: false,
          clearError: true,
        );
        _publish();
        return;
      }
    }
    _pendingJump = null;
    if (beyondThreshold) {
      progress = previous;
      _arrivals = 0;
    }
    if (progress < previous && previous - progress <= maxProgressRewindMeters) {
      progress = previous;
    }
    progress = progress.clamp(0.0, _lengths[currentLegIndex]);
    final completed = _lengths.take(currentLegIndex).fold(0.0, (a, b) => a + b);
    _state = _state.copyWith(
      currentLocation: fix,
      projectedPoint: projection.nearestPoint,
      progressOnCurrentLegMeters: progress,
      currentManeuverIndex: _advanceManeuverIndex(leg, progress),
      remainingDistanceOnCurrentLegMeters: _lengths[currentLegIndex] - progress,
      totalProgressMeters: completed + progress,
      totalRemainingMeters: _total - completed - progress,
      distanceFromRouteMeters: projection.distanceFromRouteMeters,
      isOffRoute: confirmedOffRoute,
      isGpsLost: false,
      clearError: true,
    );
    // Physical proximity AND near-end geometry are required. Projection onto
    // an endpoint from far away must never trigger arrival.
    final near =
        RouteProjectionUtils.distanceBetween(p, leg.geometryPoints.last) <=
            arrivalRadiusMeters &&
        projection.remainingDistanceMeters <= arrivalRadiusMeters &&
        projection.distanceFromRouteMeters <= arrivalRadiusMeters;
    _arrivals = near ? _arrivals + 1 : 0;
    if (_arrivals >= requiredArrivalFixes) _completeCurrentLeg();
    _publish();
  }

  /// Advance only after accepted GPS progress passes the event by a small
  /// margin. The cursor never rewinds with geometry jitter or large rewinds;
  /// a replacement leg resets it. No timer or raw GPS proximity advances it.
  int _advanceManeuverIndex(RouteLegModel leg, double progress) {
    var index = _state.currentManeuverIndex;
    while (index < leg.maneuvers.length &&
        progress >
            leg.maneuvers[index].offsetMeters + maxProgressRewindMeters) {
      index++;
    }
    return index;
  }

  /// Shared leg-completion transition for the automatic two-fix arrival and
  /// the explicit manual confirmation. Completing the final leg also tears the
  /// session down: the revision bump rejects late fixes and the stream,
  /// watchdog and planning lock are released.
  void _completeCurrentLeg() {
    final leg = _legs[currentLegIndex];
    final last = currentLegIndex == _legs.length - 1;
    final completed = _lengths.take(currentLegIndex).fold(0.0, (a, b) => a + b);
    _arrivals = 0;
    _pendingJump = null;
    _detector.reset();
    _state = _state.copyWith(
      status: last ? NavigationStatus.completed : NavigationStatus.active,
      arrivedPlaceTitle: leg.toTitle,
      isWaitingForNextLegConfirmation: !last,
      isOffRoute: false,
      progressOnCurrentLegMeters: _lengths[currentLegIndex],
      remainingDistanceOnCurrentLegMeters: 0,
      totalProgressMeters: completed + _lengths[currentLegIndex],
      totalRemainingMeters: last
          ? 0
          : _total - completed - _lengths[currentLegIndex],
    );
    if (last) {
      ++_revision;
      _release();
      _routing?.setNavigationRoute(null);
      _routing?.setNavigationLocked(false);
    }
  }

  /// Explicit user-confirmed arrival at the current leg endpoint («Я на
  /// месте»). A nearby off-route fix can still rescue endpoint snapping, but
  /// stale GPS or a remote deviation cannot reuse frozen geometry progress.
  /// The strict automatic two-fix policy stays untouched.
  bool get canConfirmArrivalManually {
    if (!isActive ||
        _state.isWaitingForNextLegConfirmation ||
        _state.isGpsLost ||
        _state.remainingDistanceOnCurrentLegMeters > manualArrivalMaxMeters ||
        !_isValidFix(_state.currentLocation)) {
      return false;
    }
    final endpoint = currentLeg?.geometryPoints.last;
    return endpoint != null &&
        RouteProjectionUtils.distanceBetween(
              _state.currentLocation!.coordinate,
              endpoint,
            ) <=
            manualArrivalMaxMeters;
  }

  void confirmArrivalManually() {
    if (!canConfirmArrivalManually) return;
    _completeCurrentLeg();
    _publish();
  }

  void continueToNextLeg() {
    if (!isActive ||
        !_state.isWaitingForNextLegConfirmation ||
        currentLegIndex + 1 >= _legs.length) {
      return;
    }
    final next = currentLegIndex + 1;
    _arrivals = 0;
    _pendingJump = null;
    _detector.reset();
    _state = _state.copyWith(
      currentLegIndex: next,
      currentManeuverIndex: 0,
      progressOnCurrentLegMeters: 0,
      remainingDistanceOnCurrentLegMeters: _lengths[next],
      isOffRoute: false,
      distanceFromRouteMeters: 0,
      clearArrivedPlace: true,
      isWaitingForNextLegConfirmation: false,
    );
    _publish();
  }

  /// Manual rerouting (v2.2): the ONLY path that rebuilds route geometry after
  /// a confirmed off-route. Never invoked automatically by the detector.
  ///
  /// Atomic semantics: the current session, route and legs stay intact until a
  /// validated MapKit result exists; only then is the current leg replaced.
  /// On any failure the old route remains and the session returns to active.
  Future<void> rerouteToNextStop() async {
    if (_disposed || !_foreground) return;
    // Double tap cannot enter twice: the first call switched status to
    // rerouting, and only a successful/failed completion restores active.
    if (status != NavigationStatus.active || !_state.isOffRoute) return;
    final revision = _revision;
    _clearFixStreaks();
    _state = _state.copyWith(
      status: NavigationStatus.rerouting,
      clearError: true,
    );
    _publish();
    try {
      if (!await _checkRerouteAccess(revision)) return;
      try {
        final fix = await _locationService.getCurrentPosition(
          timeLimit: const Duration(seconds: 5),
        );
        if (!_validRun(revision)) return;
        // The one-shot request may finish after a newer streamed fix. The
        // normal timestamp guard keeps the newest accepted position.
        _process(fix);
      } catch (_) {
        // Fall back to the last validated live fix from the session stream.
      }
      if (!_validRun(revision)) return;
      if (_state.isWaitingForGps) return;
      if (!await _checkRerouteAccess(revision)) return;
      if (_state.isWaitingForGps) return;
      final origin = _rerouteOrigin(_state.currentLocation);
      if (origin == null) {
        _rerouteFailed(
          'Не удалось определить текущее местоположение. '
          'Проверьте сигнал GPS и попробуйте ещё раз.',
        );
        return;
      }
      final legIndex = _state.currentLegIndex;
      final leg = _legs[legIndex];
      final target = leg.geometryPoints.last;
      final result = await _routeService!.calculatePointToPointRoute(
        startPoint: RoutePointModel(
          id: 'reroute_origin',
          title: 'Текущее местоположение',
          subtitle: '',
          latitude: origin.latitude,
          longitude: origin.longitude,
          isPreset: false,
        ),
        destinationPoint: RoutePointModel(
          id: 'reroute_target_$legIndex',
          title: leg.toTitle,
          subtitle: '',
          latitude: target.latitude,
          longitude: target.longitude,
          isPreset: false,
        ),
      );
      if (!_validRun(revision)) return;
      if (_state.isWaitingForGps) return;
      if (!await _checkRerouteAccess(revision)) return;
      if (_state.isWaitingForGps) return;
      if (!_isValidFix(_state.currentLocation)) {
        _rerouteFailed(
          'Нет свежего сигнала GPS. Старый маршрут сохранён. '
          'Дождитесь местоположения и попробуйте ещё раз.',
          gpsLost: true,
        );
        return;
      }
      _applyReroute(legIndex, result);
    } catch (_) {
      if (!_validRun(revision)) return;
      _rerouteFailed(
        'Не удалось перестроить маршрут. Проверьте подключение к сети '
        'и попробуйте ещё раз.',
      );
    }
  }

  /// The reroute origin must be a fresh, precise, valid live position: either
  /// a one-shot fix or the newest streamed fix. Cached snapshots never qualify.
  GeoCoord? _rerouteOrigin(UserLocationSnapshot? fix) {
    return _isValidFix(fix) ? fix!.coordinate : null;
  }

  Future<bool> _checkRerouteAccess(int revision) async {
    final permission = await _locationService.checkPermission();
    if (!_validRun(revision)) return false;
    if (_granted(permission)) return true;
    // A rejected reroute keeps the old geometry and enters the recoverable
    // waiting state instead of ending the session. The watchdog and service
    // stream can reattach once access returns.
    _enterGpsWaiting(
      permission == LocationPermissionStatus.serviceDisabled
          ? 'Ожидаем местоположение. Включите геолокацию. Старый маршрут сохранён.'
          : 'Проверьте доступ к геолокации. Старый маршрут сохранён.',
    );
    return false;
  }

  void _rerouteFailed(String message, {bool gpsLost = false}) {
    // A GPS-driven transition already owns the session state; an in-flight
    // reroute failure must not turn waiting back into active.
    if (_state.isWaitingForGps) return;
    _state = _state.copyWith(
      status: NavigationStatus.active,
      isGpsLost:
          gpsLost || _state.isGpsLost || !_isValidFix(_state.currentLocation),
      errorMessage: message,
    );
    _publish();
  }

  /// Validates the MapKit result and only then atomically replaces the current
  /// leg. Legs already walked and legs after the current one keep their
  /// original MapKit geometry, so the remaining stop order is preserved.
  void _applyReroute(int legIndex, PedestrianRouteModel result) {
    final sourceLeg = result.legs.isNotEmpty ? result.legs.first : null;
    final points = sourceLeg?.geometryPoints ?? result.geometryPoints;
    final hasBadGeometry =
        points.length < 2 ||
        points.any(
          (p) =>
              !p.latitude.isFinite ||
              !p.longitude.isFinite ||
              p.latitude.abs() > 90 ||
              p.longitude.abs() > 180,
        );
    final length = hasBadGeometry
        ? 0.0
        : RouteProjectionUtils.polylineLengthMeters(points);
    if (result.errorMessage != null ||
        hasBadGeometry ||
        !length.isFinite ||
        length <= 0) {
      _rerouteFailed(
        'MapKit вернул некорректную геометрию маршрута. '
        'Старый маршрут сохранён, попробуйте ещё раз.',
      );
      return;
    }
    final oldLeg = _legs[legIndex];
    final newLeg = RouteLegModel(
      fromTitle: 'Текущее местоположение',
      toTitle: oldLeg.toTitle,
      distanceMeters: sourceLeg?.distanceMeters ?? result.distanceMeters,
      durationSeconds: sourceLeg?.durationSeconds ?? result.durationSeconds,
      geometryPoints: List.unmodifiable(points),
      // Replacement-leg maneuvers keep their verified native offsets (they
      // were validated against this exact geometry at request time) and are
      // re-stamped with the rebuilt leg's index; every maneuver that belonged
      // to the obsolete geometry is discarded with it.
      maneuvers: List.unmodifiable(
        (sourceLeg?.maneuvers ?? const <PedestrianManeuverModel>[]).map(
          (m) => m.withLegIndex(legIndex),
        ),
      ),
      visitMinutes: oldLeg.visitMinutes,
    );
    final rebuilt = List<RouteLegModel>.of(_legs);
    rebuilt[legIndex] = newLeg;
    _legs = List.unmodifiable(rebuilt);
    _lengths = _legs
        .map((l) => RouteProjectionUtils.polylineLengthMeters(l.geometryPoints))
        .toList();
    final frozen = PedestrianRouteModel(
      distanceMeters: _total,
      durationSeconds: _legs.fold(0, (sum, l) => sum + l.durationSeconds),
      geometryPoints: List.unmodifiable(_legs.expand((l) => l.geometryPoints)),
      // Legacy route-global display strings have no verified leg association.
      // Never carry them from obsolete geometry onto a replacement route.
      steps: const [],
      legs: _legs,
      placesCount: _state.route?.placesCount ?? 1,
      // The walk kind is the user's request and survives a reroute; the
      // rebuilt stage itself honestly loses its scenic metadata.
      walkKind: _state.route?.walkKind ?? WalkKind.normal,
    );
    // Session (tourist) progress = legs already completed; current-geometry
    // progress restarts from zero on the rebuilt leg. No old route-distance
    // value is transferred onto the new geometry.
    final completed = _lengths.take(legIndex).fold(0.0, (a, b) => a + b);
    _detector.reset();
    _arrivals = 0;
    _pendingJump = null;
    _state = _state.copyWith(
      status: NavigationStatus.active,
      route: frozen,
      currentManeuverIndex: 0,
      progressOnCurrentLegMeters: 0,
      remainingDistanceOnCurrentLegMeters: _lengths[legIndex],
      totalProgressMeters: completed,
      totalRemainingMeters: _total - completed,
      distanceFromRouteMeters: 0,
      isOffRoute: false,
      clearError: true,
      clearProjectedPoint: true,
    );
    // A rebuilt leg is a different ground: any shade estimate over the old
    // geometry is dropped by the routing provider before the map redraws.
    _routing?.setNavigationRoute(frozen);
    _publish();
  }

  void pauseNavigation() {
    _foreground = false;
    if (!locksPlanning) return;
    ++_revision;
    _release();
    _cancelRerouteRequest();
    _arrivals = 0;
    _pendingJump = null;
    // A backgrounded pause invalidates off-route certainty; fresh fixes must
    // re-confirm it after resume.
    _detector.reset();
    _state = _state.copyWith(
      status: NavigationStatus.paused,
      isGpsLost: true,
      isOffRoute: false,
    );
    _publish();
  }

  Future<void> resumeNavigation() async {
    _foreground = true;
    if (!_state.isPaused || _disposed) return;
    final revision = ++_revision;
    try {
      final permission = await _locationService.checkPermission();
      if (!_validRun(revision)) return;
      _lastTimestamp = null;
      if (!_granted(permission)) {
        _enterGpsWaiting(
          permission == LocationPermissionStatus.serviceDisabled
              ? 'Ожидаем местоположение. Включите геолокацию.'
              : 'Доступ к местоположению запрещён. Разрешите его в настройках.',
        );
        _startWatchdog(revision);
        _ensureServiceStatusSubscription(revision);
        return;
      }
      _state = _state.copyWith(
        status: NavigationStatus.active,
        isGpsLost: true,
        errorMessage: 'Ожидаем свежий сигнал GPS.',
      );
      _subscribe(revision);
      _startWatchdog(revision);
      _ensureServiceStatusSubscription(revision);
      _publish();
    } catch (_) {
      if (_validRun(revision)) {
        _enterGpsWaiting(
          'Геолокация временно недоступна. Ожидаем восстановления.',
        );
        _subscribe(revision);
        _startWatchdog(revision);
        _ensureServiceStatusSubscription(revision);
      }
    }
  }

  void stopNavigation() {
    ++_revision;
    _release();
    _cancelRerouteRequest();
    _arrivals = 0;
    _lastTimestamp = null;
    _pendingJump = null;
    _routing?.setNavigationRoute(null);
    _routing?.setNavigationLocked(false);
    _state = const LiveNavigationState();
    _publish();
  }

  @visibleForTesting
  void injectLocationForTesting(UserLocationSnapshot snapshot) {
    _process(snapshot);
  }

  /// The path the walker still has AHEAD, as the session itself measures it:
  /// the current leg cut at the engine's accepted progress, then every
  /// following leg in its original order.
  ///
  /// This is a SESSION measurement, not a planning artifact. It is rebuilt
  /// from the engine's own progress (never from raw GPS), its walking time is
  /// the native leg duration scaled by the remaining share of the leg — the
  /// same distance-proportional mapping the shade backend uses inside a leg —
  /// and its visit times are the stops still ahead. Manoeuvre offsets describe
  /// the FULL leg, so they are not carried onto cut geometry where every turn
  /// would sit at the wrong distance. Nothing here mutates the session, the
  /// route, the progress or the planning lock.
  PedestrianRouteModel? buildRemainingRoute() {
    final liveSession =
        isActive ||
        _state.isWaitingForGps ||
        _state.isPaused ||
        _state.isRerouting ||
        status == NavigationStatus.starting;
    final source = _state.route;
    if (_disposed || !liveSession || source == null || _legs.isEmpty) {
      return null;
    }
    final index = currentLegIndex;
    if (index < 0 || index >= _legs.length) return null;
    final legs = <RouteLegModel>[];
    for (var i = index; i < _legs.length; ++i) {
      final leg = _legs[i];
      if (i != index) {
        legs.add(leg);
        continue;
      }
      final tail = RouteProjectionUtils.polylineTail(
        leg.geometryPoints,
        _state.progressOnCurrentLegMeters,
      );
      if (tail.length < 2) continue; // nothing of this leg is left
      final tailLength = RouteProjectionUtils.polylineLengthMeters(tail);
      final fullLength = _lengths[index];
      if (!tailLength.isFinite || tailLength <= 0 || fullLength <= 0) {
        continue;
      }
      final seconds = (leg.durationSeconds * (tailLength / fullLength)).round();
      legs.add(
        RouteLegModel(
          fromTitle: 'Текущее местоположение',
          toTitle: leg.toTitle,
          distanceMeters: tailLength,
          durationSeconds: seconds < 1 ? 1 : seconds,
          geometryPoints: tail,
          maneuvers: const [],
          visitMinutes: leg.visitMinutes,
          scenic: leg.scenic,
        ),
      );
    }
    if (legs.isEmpty) return null;
    var distance = 0.0;
    var duration = 0;
    final points = <GeoCoord>[];
    for (final leg in legs) {
      distance += leg.distanceMeters;
      duration += leg.durationSeconds;
      points.addAll(leg.geometryPoints);
    }
    return PedestrianRouteModel(
      distanceMeters: distance,
      durationSeconds: duration,
      geometryPoints: List.unmodifiable(points),
      steps: const [],
      legs: List.unmodifiable(legs),
      placesCount: source.placesCount,
      walkKind: source.walkKind,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    _release();
    _cancelRerouteRequest();
    // Teardown is quiet: routing listeners are being unmounted.
    _routing?.setNavigationRoute(null, notify: false);
    _routing?.setNavigationLocked(false, notify: false);
    super.dispose();
  }
}
