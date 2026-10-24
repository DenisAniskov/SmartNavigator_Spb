import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/network/catalog_retry_policy.dart';
import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';

enum PlacesStatus { initial, loading, success, error }

/// On-demand catalog load with bounded auto-recovery (P2).
///
/// Recovery policy, in one place so it stays auditable:
/// - only honestly transient failures (timeouts, connection loss, 5xx, 429)
///   may repeat, at most [CatalogRetryPolicy.maxAutomaticRetries] times per
///   filter generation with an exponential backoff (~2s/5s/10s, ±15% jitter)
///   and the server's bounded Retry-After for 429;
/// - permanent failures (bad request, auth, 404, corrupt data) never repeat
///   automatically;
/// - returning to the foreground after a failure performs at most ONE
///   recovery request, with a cooldown against rapid resumes;
/// - after the automatic budget is exhausted, a lightweight DNS probe of the
///   backend host (no request to the backend) arms a single recovery attempt
///   when the internet returns;
/// - every user action (filter, search, manual retry) restarts the budget
///   and invalidates pending retries through the existing [_requestId] guard,
///   so a superseded generation can never overwrite newer results. While a
///   load is in flight the manual UI action is disabled, which keeps one
///   request per filter state without changing the «newest wins» semantics.
class PlacesProvider extends ChangeNotifier {
  final PlacesRepository _repository;

  PlacesProvider({
    PlacesRepository? repository,
    GuestExperienceProvider? guest,
    DateTime Function()? clock,
    double Function()? jitter,
    Future<bool> Function()? connectivityProbe,
  }) : _repository = repository ?? PlacesRepository(),
       _clock = clock ?? DateTime.now,
       _jitter = jitter ?? _defaultJitter,
       _guest = guest {
    _connectivityProbe =
        connectivityProbe ?? (() => _defaultConnectivityProbe(_repository));
    if (guest != null) {
      _selectedCategories.addAll(guest.categories);
      _isUnusualOnly = guest.preferUnusual;
      guest.addListener(_guestPreferencesChanged);
    }
    loadPlaces();
    loadCategories();
  }

  static final Random _defaultRandom = Random();
  static double _defaultJitter() => _defaultRandom.nextDouble();

  /// DNS resolution of the backend host: a connectivity signal that never
  /// sends a request to Railway itself. Only consulted while the app is in
  /// the foreground and the catalog is in a confirmed transient failure.
  static Future<bool> _defaultConnectivityProbe(
    PlacesRepository repository,
  ) async {
    try {
      final host = repository.connectivityHost;
      if (host.isEmpty) return false;
      final addresses = await InternetAddress.lookup(
        host,
        type: InternetAddressType.any,
      );
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static const foregroundRecoveryCooldown = Duration(seconds: 30);
  static const connectivityProbeInterval = Duration(seconds: 15);

  PlacesStatus _status = PlacesStatus.initial;
  List<PlaceModel> _places = const [];
  List<CategoryModel> _categories = const [];
  final Set<PlaceCategoryEnum> _selectedCategories = {};
  bool _isUnusualOnly = false;
  String _searchQuery = '';
  PlaceModel? _selectedPlace;
  String? _errorMessage;
  int _requestId = 0;
  bool _disposed = false;
  Timer? _searchTimer;
  final GuestExperienceProvider? _guest;

  // P2 recovery state.
  final DateTime Function() _clock;
  final double Function() _jitter;
  late final Future<bool> Function() _connectivityProbe;
  bool _foreground = true;
  bool _isRetrying = false;
  bool _isStale = false;
  DateTime? _nextRetryAt;
  int _automaticAttempts = 0;
  Timer? _retryTimer;
  Timer? _connectivityTimer;
  DateTime? _lastRecoveryAt;

  /// Filters of the last SUCCESSFUL catalog: the stale snapshot is shown
  /// only while the current filters still match it.
  String? _snapshotSignature;

  void _guestPreferencesChanged() {
    final guest = _guest!;
    if (_disposed ||
        (setEquals(_selectedCategories, guest.categories) &&
            _isUnusualOnly == guest.preferUnusual)) {
      return;
    }
    _selectedCategories
      ..clear()
      ..addAll(guest.categories);
    _isUnusualOnly = guest.preferUnusual;
    // Same pagination, cancellation, stale-response guard and errors as filters.
    unawaited(loadPlaces());
  }

  PlacesStatus get status => _status;
  List<PlaceModel> get places => _places;
  List<CategoryModel> get categories => _categories;
  Set<PlaceCategoryEnum> get selectedCategories =>
      Set.unmodifiable(_selectedCategories);
  bool get isUnusualOnly => _isUnusualOnly;
  String get searchQuery => _searchQuery;
  PlaceModel? get selectedPlace => _selectedPlace;
  String? get errorMessage => _errorMessage;

  bool get isLoading => _status == PlacesStatus.loading;
  bool get hasError => _status == PlacesStatus.error;
  bool get isEmpty => _status == PlacesStatus.success && _places.isEmpty;

  /// An automatic recovery is scheduled or already in flight.
  bool get isRetrying => _isRetrying;

  /// The displayed catalog is the last successful snapshot of the SAME
  /// filters; a refresh failed transiently and recovery is under way.
  bool get isStale => _isStale;

  /// When the next automatic attempt fires (UI hint, no countdown).
  DateTime? get nextRetryAt => _nextRetryAt;

  String get _filtersSignature {
    final categories = _selectedCategories.map((c) => c.key).toList()..sort();
    return '${categories.join(',')}|unusual=$_isUnusualOnly|q='
        '${_searchQuery.trim()}';
  }

  Future<void> loadPlaces({
    bool automatic = false,
    bool singleAttempt = false,
  }) async {
    if (_disposed) return;
    _searchTimer?.cancel();
    final signature = _filtersSignature;
    if (!automatic) {
      // A user action restarts the automatic budget and kills pending
      // retries; the superseded generation can never overwrite its result.
      _retryTimer?.cancel();
      _retryTimer = null;
      _nextRetryAt = null;
      _isRetrying = false;
      _automaticAttempts = 0;
    }
    _isRetrying = automatic;
    final requestId = ++_requestId;
    _status = PlacesStatus.loading;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _repository.getPlaces(
        categories: _selectedCategories.isEmpty
            ? null
            : _selectedCategories.toList(),
        isUnusual: _isUnusualOnly ? true : null,
        searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
      );
      if (_disposed || requestId != _requestId) return;
      // Preserve the old immutable snapshot for the map's update comparison,
      // even if the repository retains and later mutates its result list.
      _places = List.unmodifiable(result);
      if (!_places.any((p) => p.id == _selectedPlace?.id)) {
        _selectedPlace = null;
      }
      _retryTimer?.cancel();
      _retryTimer = null;
      _connectivityTimer?.cancel();
      _connectivityTimer = null;
      _nextRetryAt = null;
      _isRetrying = false;
      _isStale = false;
      _automaticAttempts = 0;
      _snapshotSignature = signature;
      _status = PlacesStatus.success;
    } catch (e, stackTrace) {
      if (_disposed || requestId != _requestId) return;
      // Phase A6.6: a raw exception dump can carry the request URI with the
      // user's filter and query text into logcat, so only the failure type is
      // printed; the sanitized message is already produced by placesUiError.
      debugPrint('PlacesProvider error: ${e.runtimeType}\n$stackTrace');
      final message = placesUiError(e);
      final keepSnapshot =
          _places.isNotEmpty && _snapshotSignature == signature;
      if (!keepSnapshot) {
        _places = const [];
        _selectedPlace = null;
      }
      _isStale = keepSnapshot;
      _connectivityTimer?.cancel();
      _connectivityTimer = null;
      _nextRetryAt = null;

      final retryIndex = _automaticAttempts + 1;
      final delay = singleAttempt
          ? null
          : CatalogRetryPolicy.isTransient(e)
          ? CatalogRetryPolicy.automaticDelay(
              error: e,
              retryIndex: retryIndex,
              random: _jitter,
            )
          : null;
      if (delay != null && _foreground) {
        // Transient failure in the foreground: recover automatically on the
        // bounded schedule.
        _automaticAttempts = retryIndex;
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () => _runScheduledRetry(requestId));
        _nextRetryAt = _clock().add(delay);
        _isRetrying = true;
      } else {
        // Either a permanent failure, the automatic budget is spent, or the
        // app left the foreground while the request was in flight: an honest
        // message and the manual retry stay. In the transient case the
        // connectivity watch arms one single recovery when the internet
        // returns (foreground only — _startConnectivityWatch guards it); in
        // the background case the budget is preserved and the foreground
        // return performs the single recovery instead. Permanent failures
        // never retry on their own.
        _isRetrying = false;
        _automaticAttempts = delay != null
            ? retryIndex
            : CatalogRetryPolicy.maxAutomaticRetries;
        if (!singleAttempt && CatalogRetryPolicy.isTransient(e)) {
          _startConnectivityWatch();
        }
      }
      _errorMessage = keepSnapshot ? null : message;
      _status = keepSnapshot ? PlacesStatus.success : PlacesStatus.error;
    }
    notifyListeners();
  }

  Future<void> _runScheduledRetry(int requestId) async {
    _retryTimer = null;
    _nextRetryAt = null;
    // A backgrounded app performs no automatic network requests, even if the
    // failure that scheduled this timer arrived after setForeground(false).
    if (_disposed || !_foreground || _requestId != requestId) return;
    if (_status == PlacesStatus.loading) return;
    await loadPlaces(automatic: true);
  }

  /// Foreground return after a failure: at most one justified recovery
  /// request, with a cooldown against rapid repeated resumes.
  Future<void> setForeground(bool foreground) async {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      // No timers and no requests may survive a hidden app.
      _retryTimer?.cancel();
      _retryTimer = null;
      _connectivityTimer?.cancel();
      _connectivityTimer = null;
      _nextRetryAt = null;
      _isRetrying = false;
      return;
    }
    if (_status == PlacesStatus.loading || _isRetrying) return;
    if (_status != PlacesStatus.error && !_isStale) return;
    final now = _clock();
    final last = _lastRecoveryAt;
    if (last != null && now.difference(last) < foregroundRecoveryCooldown) {
      return;
    }
    _lastRecoveryAt = now;
    await loadPlaces(automatic: true, singleAttempt: true);
  }

  /// Watches (foreground only) for the internet returning after a confirmed
  /// transient failure. The probe is DNS-only, so the backend is never
  /// polled; the recovery itself is a single bounded request.
  void _startConnectivityWatch() {
    if (_disposed || !_foreground) return;
    if (_connectivityTimer != null) return;
    _scheduleConnectivityProbe(connectivityProbeInterval);
  }

  void _scheduleConnectivityProbe(Duration delay) {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer(delay, _probeConnectivity);
  }

  Future<void> _probeConnectivity() async {
    _connectivityTimer = null;
    if (_disposed ||
        !_foreground ||
        _status == PlacesStatus.loading ||
        _isRetrying) {
      return;
    }
    if (_status != PlacesStatus.error && !_isStale) return;
    final requestId = _requestId;
    final online = await _connectivityProbe();
    if (_disposed || !_foreground) return;
    // The world may have moved on while the DNS answer was in flight: a
    // newer generation (filter, search, manual retry) or a fresh success
    // owns the catalog now, so a late probe result must neither fire a
    // request nor arm a needless timer.
    if (_requestId != requestId ||
        _status == PlacesStatus.loading ||
        _isRetrying) {
      return;
    }
    if (_status != PlacesStatus.error && !_isStale) return;
    if (!online) {
      _scheduleConnectivityProbe(connectivityProbeInterval);
      return;
    }
    // The internet is back: exactly one recovery attempt, then the watch
    // stops; a repeated failure re-arms it through the normal failure path.
    await loadPlaces(automatic: true, singleAttempt: true);
  }

  Future<void> loadCategories() async {
    try {
      final result = await _repository.getCategories();
      if (_disposed) return;
      _categories = List.unmodifiable(result);
      notifyListeners();
    } catch (_) {}
  }

  void toggleCategory(PlaceCategoryEnum category) {
    if (_selectedCategories.contains(category)) {
      _selectedCategories.remove(category);
    } else {
      _selectedCategories.add(category);
    }
    loadPlaces();
    if (_guest != null) unawaited(_guest.setCategories(selectedCategories));
  }

  void clearCategories() {
    _selectedCategories.clear();
    loadPlaces();
    if (_guest != null) unawaited(_guest.setCategories(selectedCategories));
  }

  void toggleUnusualOnly() {
    _isUnusualOnly = !_isUnusualOnly;
    loadPlaces();
    if (_guest != null) unawaited(_guest.setPreferUnusual(_isUnusualOnly));
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    ++_requestId; // Invalidate responses for the previous text immediately.
    _searchTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRetryAt = null;
    _isRetrying = false;
    _places = const [];
    _selectedPlace = null;
    _status = PlacesStatus.loading;
    _errorMessage = null;
    notifyListeners();
    _searchTimer = Timer(const Duration(milliseconds: 300), loadPlaces);
  }

  void selectPlace(PlaceModel? place) {
    _selectedPlace = place;
    notifyListeners();
  }

  void clearFilters() {
    _selectedCategories.clear();
    _isUnusualOnly = false;
    _searchQuery = '';
    loadPlaces();
    if (_guest != null) {
      unawaited(
        _guest.setCatalogPreferences(
          categories: selectedCategories,
          preferUnusual: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _retryTimer?.cancel();
    _connectivityTimer?.cancel();
    _guest?.removeListener(_guestPreferencesChanged);
    _disposed = true;
    ++_requestId;
    super.dispose();
  }
}
