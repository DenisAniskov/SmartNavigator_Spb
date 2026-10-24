import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';

/// Abstract contract for device location service to allow mocking in unit/widget tests.
abstract class BaseDeviceLocationService {
  Future<bool> isLocationServiceEnabled();
  Future<LocationPermissionStatus> checkPermission();

  /// Settles the location permission and may surface the system dialog. It
  /// must NOT be gated by location-service availability: service state
  /// describes providers, not the user's access choice, and a false probe
  /// must never silently skip the dialog (P1). Availability is checked by
  /// the caller after the permission is settled.
  Future<LocationPermissionStatus> requestPermission();
  Future<UserLocationSnapshot?> getLastKnownPosition();
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  });
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  });

  /// Emits the platform's location-service availability. A session that lost
  /// GPS keeps this subscription so enabling the service can resume it without
  /// rebuilding the route. Non-device implementations may leave it empty.
  Stream<bool> getServiceStatusStream() => const Stream<bool>.empty();
}

/// Production implementation of [BaseDeviceLocationService] using the `geolocator` plugin.
class DeviceLocationService implements BaseDeviceLocationService {
  @override
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    final isEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isEnabled) {
      return LocationPermissionStatus.serviceDisabled;
    }
    final permission = await Geolocator.checkPermission();
    return _mapPermission(permission);
  }

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    // No service-availability gate here: the probe describes provider state,
    // not the user's access choice, and a false or transiently failing probe
    // must never silently skip the system dialog (P1). The caller checks
    // service availability after the permission is settled.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      permission = await Geolocator.requestPermission();
    }
    return _mapPermission(permission);
  }

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (pos == null) return null;
      return UserLocationSnapshot(
        coordinate: GeoCoord(pos.latitude, pos.longitude),
        accuracy: pos.accuracy,
        altitude: pos.altitude,
        heading: pos.heading,
        speed: pos.speed,
        timestamp: pos.timestamp,
        isCached: true,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async {
    final isEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isEnabled) {
      throw const LocationServiceDisabledException();
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: timeLimit,
      ),
    );

    return UserLocationSnapshot(
      coordinate: GeoCoord(pos.latitude, pos.longitude),
      accuracy: pos.accuracy,
      altitude: pos.altitude,
      heading: pos.heading,
      speed: pos.speed,
      timestamp: pos.timestamp,
    );
  }

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) {
    final locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilterMeters,
      intervalDuration: Duration(milliseconds: intervalDurationMs),
    );

    return Geolocator.getPositionStream(locationSettings: locationSettings).map(
      (pos) => UserLocationSnapshot(
        coordinate: GeoCoord(pos.latitude, pos.longitude),
        accuracy: pos.accuracy,
        altitude: pos.altitude,
        heading: pos.heading,
        speed: pos.speed,
        timestamp: pos.timestamp,
        isCached: false,
      ),
    );
  }

  @override
  Stream<bool> getServiceStatusStream() => Geolocator.getServiceStatusStream()
      .map((status) => status == ServiceStatus.enabled);

  Future<LocationPermissionStatus> _mapPermission(
    LocationPermission permission,
  ) async {
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        final accuracy = await Geolocator.getLocationAccuracy();
        return accuracy == LocationAccuracyStatus.reduced
            ? LocationPermissionStatus.grantedCoarse
            : LocationPermissionStatus.grantedPrecise;
      case LocationPermission.denied:
        return LocationPermissionStatus.denied;
      case LocationPermission.deniedForever:
        return LocationPermissionStatus.permanentlyDenied;
      case LocationPermission.unableToDetermine:
        return LocationPermissionStatus.notRequested;
    }
  }
}
