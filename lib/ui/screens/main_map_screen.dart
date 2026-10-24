import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yandex_maps_mapkit/image.dart' as map_image;
import 'package:yandex_maps_mapkit/mapkit.dart' as ymk;
import 'package:yandex_maps_mapkit/mapkit_factory.dart' as mapkit_factory;
import 'package:yandex_maps_mapkit/yandex_map.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/config/simulator_gate.dart';
import 'package:smart_navigator_spb/core/constants/map_constants.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/providers/city_viewpoint_provider.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/ui/controllers/camera_follow_controller.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';
import 'package:smart_navigator_spb/ui/widgets/my_location_button.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/shade_routing_engine.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/widgets/source_attribution.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/screens/favorites_screen.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/simulation_control_panel.dart';
import 'package:smart_navigator_spb/ui/widgets/category_filter_chips.dart';
import 'package:smart_navigator_spb/ui/widgets/external_point_preview_card.dart';
import 'package:smart_navigator_spb/ui/widgets/guest_launch_gate.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';
import 'package:smart_navigator_spb/ui/widgets/viewpoint_preview_card.dart';
import 'package:smart_navigator_spb/ui/widgets/assistant_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/voice_search_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';
import 'package:smart_navigator_spb/ui/widgets/theme_mode_button.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';

/// Native legs can begin at different points after a manual reroute. Keeping
/// them separate prevents the map from drawing an unrouted connector.
@visibleForTesting
Iterable<List<GeoCoord>> routePolylineGeometries(PedestrianRouteModel route) {
  final geometries = route.legs.isEmpty
      ? [route.geometryPoints]
      : route.legs.map((leg) => leg.geometryPoints);
  return geometries.where((points) => points.length >= 2);
}

enum NavigationMapLegRole { planned, current, upcoming, completed }

/// Leg endpoints and lines use the same immutable route snapshot. In
/// particular, a reroute never joins the old endpoint to the new origin.
class NavigationMapLeg {
  const NavigationMapLeg(this.leg, this.index, this.role);

  final RouteLegModel leg;
  final int index;
  final NavigationMapLegRole role;
}

@visibleForTesting
Iterable<NavigationMapLeg> navigationMapLegs(
  PedestrianRouteModel route, {
  int? currentLegIndex,
  int completedStops = 0,
}) sync* {
  for (var index = 0; index < route.legs.length; index++) {
    final leg = route.legs[index];
    if (leg.geometryPoints.length < 2) continue;
    final role = currentLegIndex == null
        ? NavigationMapLegRole.planned
        : index < completedStops
        ? NavigationMapLegRole.completed
        : index == currentLegIndex
        ? NavigationMapLegRole.current
        : NavigationMapLegRole.upcoming;
    yield NavigationMapLeg(leg, index, role);
  }
}

/// Map label of the simulated walker badge (Phase C4.1).
@visibleForTesting
const String simulatedWalkerLabel = 'Симуляция';

/// Reuses the application's MapKit surface while keeping selection entirely
/// local. Closing the picker never changes the route visible under the wizard.
Future<RoutePointModel?> chooseGuidedWalkStartOnMap(BuildContext context) {
  final routing = context.read<RoutingProvider>();
  if (routing.navigationLocked) return Future.value();
  return Navigator.of(context).push<RoutePointModel>(
    MaterialPageRoute<RoutePointModel>(
      builder: (pickerContext) => Scaffold(
        appBar: AppBar(title: const Text('Выберите точку отправления')),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Нажмите на карту, чтобы выбрать старт. Кнопка «Назад» отменяет выбор.',
              ),
            ),
            Expanded(
              child: _NativeMap(
                choosingStart: true,
                planningLocked: routing.navigationLocked,
                places: const [],
                selectedPlace: null,
                startPoint: routing.startPoint,
                route: null,
                onSelect: (_) {},
                onSelectExternal: (_) {},
                onStart: (point) {
                  if (routing.navigationLocked) return;
                  Navigator.of(pickerContext).pop(
                    RoutePointModel(
                      id: 'guided_map_start',
                      title: 'Точка на карте',
                      subtitle: 'Выбрано пользователем',
                      latitude: point.latitude,
                      longitude: point.longitude,
                      isPreset: false,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Only existing catalog markers can become tourist stops. External map
/// metadata is never silently converted into an invented catalog record.
Future<PlaceModel?> chooseGuidedWalkPlaceOnMap(
  BuildContext context,
  List<PlaceModel> places,
) {
  final routing = context.read<RoutingProvider>();
  if (routing.navigationLocked) return Future.value();
  return Navigator.of(context).push<PlaceModel>(
    MaterialPageRoute<PlaceModel>(
      builder: (pickerContext) => Scaffold(
        appBar: AppBar(title: const Text('Выберите место прогулки')),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Нажмите на отметку достопримечательности из каталога.',
              ),
            ),
            Expanded(
              child: _NativeMap(
                choosingStart: false,
                planningLocked: routing.navigationLocked,
                places: places,
                selectedPlace: null,
                startPoint: routing.startPoint,
                route: null,
                onSelect: (place) {
                  if (!routing.navigationLocked) {
                    Navigator.of(pickerContext).pop(place);
                  }
                },
                onSelectExternal: (_) {},
                onStart: (_) {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The simulated walker marker is shown only in explicitly opted-in
/// simulator builds while a navigation session publishes a projected
/// position. The real-GPS user location layer is never touched: the blue
/// dot keeps showing the device's actual position, and the labeled badge
/// makes the test position unmistakable.
@visibleForTesting
bool showSimulatedWalkerMarker({
  required bool simulatorEnabled,
  required bool navigationSessionActive,
  required bool hasProjectedPosition,
}) => simulatorEnabled && navigationSessionActive && hasProjectedPosition;

class MainMapScreen extends StatefulWidget {
  const MainMapScreen({super.key});
  @override
  State<MainMapScreen> createState() => _MainMapScreenState();
}

class _MainMapScreenState extends State<MainMapScreen>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  bool _launchIntentHandled = false;
  bool _smartWalkOpen = false;
  bool _voiceSearchOpen = false;
  bool _assistantOpen = false;
  bool _categoriesExpanded = false;

  /// The single entry point for the existing Smart Walk wizard. The visible
  /// map action, the one-shot first-launch intent and the repeated
  /// introduction all use it, so a double activation can never stack sheets.
  void _openSmartWalk() {
    if (_smartWalkOpen) return;
    final routing = context.read<RoutingProvider>();
    if (routing.navigationLocked) return;
    _dismissTerminalNavigation();
    _smartWalkOpen = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SmartWalkWizardSheet(),
    ).whenComplete(() => _smartWalkOpen = false);
  }

  Future<void> _openSettings() async {
    final action = await Navigator.of(context).push<OnboardingAction>(
      MaterialPageRoute<OnboardingAction>(
        builder: (_) => const GuestSettingsScreen(),
      ),
    );
    if (!mounted || action == null) return;
    _handleOnboardingAction(action);
  }

  void _handleOnboardingAction(OnboardingAction action) {
    if (action == OnboardingAction.showMap) return;
    // Both the introduction and settings have already been closed. Wait for
    // the map's frame after that transition instead of using a timer; the
    // navigation lock is re-checked inside _openSmartWalk in case it appeared
    // while the result was in flight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openSmartWalk();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_launchIntentHandled) return;
    final intent = GuestLaunchIntent.maybeOf(context);
    if (intent == null || !intent.smartWalk) return;
    _launchIntentHandled = true;
    // The map itself is built by now; opening the sheet in the very first
    // frame would run the wizard before this screen is ready. There is no
    // timer: consumption and opening happen in the same post-frame callback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      intent.onConsumed();
      _openSmartWalk();
    });
  }

  void _dismissTerminalNavigation() {
    final nav = Provider.of<NavigationProvider?>(context, listen: false);
    if (nav?.status == NavigationStatus.completed ||
        nav?.status == NavigationStatus.error) {
      nav!.stopNavigation();
    }
  }

  Future<void> _selectStart() async {
    _dismissTerminalNavigation();
    context.read<CityViewpointProvider?>()?.clear();
    await showDialog<void>(
      context: context,
      builder: (_) => const StartPointSelectorDialog(),
    );
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MapKitService.onStart();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<LocationProvider?>(
          context,
          listen: false,
        )?.checkPermissionStatus();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      MapKitService.onStart();
      Provider.of<LocationProvider?>(
        context,
        listen: false,
      )?.setForeground(true);
      // P2: at most one bounded catalog recovery per return to the
      // foreground; the provider throttles rapid resumes itself.
      Provider.of<PlacesProvider?>(context, listen: false)?.setForeground(true);
      Provider.of<NavigationProvider?>(
        context,
        listen: false,
      )?.resumeNavigation();
      if (!_voiceSearchOpen) {
        Provider.of<TtsProvider?>(
          context,
          listen: false,
        )?.resumeAfterAppLifecycle();
      }
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // No microphone work continues in the background.
      Provider.of<VoiceSearchController?>(context, listen: false)?.cancel();
      // Suspend speech before pausing navigation, so the pause state is not
      // announced from a backgrounded app.
      Provider.of<TtsProvider?>(
        context,
        listen: false,
      )?.suspendForAppLifecycle();
      Provider.of<NavigationProvider?>(
        context,
        listen: false,
      )?.pauseNavigation();
      Provider.of<LocationProvider?>(
        context,
        listen: false,
      )?.setForeground(false);
      // P2: no catalog recovery timers or requests survive a hidden app.
      Provider.of<PlacesProvider?>(
        context,
        listen: false,
      )?.setForeground(false);
      MapKitService.onStop();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    MapKitService.onStop();
    super.dispose();
  }

  void _onSearchChanged(
    String text,
    PlacesProvider places,
    SearchProvider? search,
  ) {
    places.setSearchQuery(text);
    search?.setSearchQuery(text);
  }

  void _onClearSearch(PlacesProvider places, SearchProvider? search) {
    _searchController.clear();
    places.setSearchQuery('');
    search?.clearSearch();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Opens the local microphone flow. The confirmed transcript is handed to
  /// the SAME search pipeline as typed input; no route is built here and no
  /// late recognition result can reach the field after the sheet is closed.
  Future<void> _openVoiceSearch() async {
    if (_voiceSearchOpen) return;
    final voice = context.read<VoiceSearchController?>();
    if (voice == null) return;
    _voiceSearchOpen = true;
    final tts = context.read<TtsProvider?>();
    tts?.pauseForRecognition();
    // Optional recognition hint for engines that support biasing. It never
    // selects a place; the final text still goes through ordinary search.
    final places = context.read<PlacesProvider>();
    voice.setBiasStrings(places.places.map((place) => place.title));
    try {
      await voice.start();
      if (!mounted) {
        await voice.cancel();
        return;
      }
      final query = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const VoiceSearchSheet(),
      );
      if (!mounted) return;
      if (query != null && query.isNotEmpty) {
        final search = context.read<SearchProvider?>();
        _searchController.text = query;
        _onSearchChanged(query, places, search);
        FocusManager.instance.primaryFocus?.unfocus();
      } else {
        await voice.cancel();
      }
      voice.reset();
    } finally {
      tts?.resumeAfterRecognition();
      _voiceSearchOpen = false;
    }
  }

  void _showTermsDialog() {
    showSourceLicensesDialog(context);
  }

  /// C13: the AI conversation is session-only. It never reads GPS, never
  /// chooses a route and never speaks; cards and Smart Walk are explicit taps.
  Future<void> _openAssistant({int? placeId, String? placeTitle}) async {
    if (_assistantOpen) return;
    final assistant = context.read<AssistantProvider?>();
    if (assistant == null) return;
    assistant.prepare(placeId: placeId, placeTitle: placeTitle);
    _assistantOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => AssistantSheet(
          onOpenPlace: _openAssistantPlace,
          onOpenSmartWalk: _openSmartWalk,
        ),
      );
    } finally {
      _assistantOpen = false;
    }
  }

  Future<void> _openAssistantPlace(AssistantPlaceReference reference) async {
    if (!mounted) return;
    final places = context.read<PlacesProvider>();
    final search = context.read<SearchProvider?>();
    final routing = context.read<RoutingProvider>();
    routing.clearRoute();
    search?.selectExternalPoint(null);
    _onClearSearch(places, search);
    PlaceModel? known;
    for (final place in places.places) {
      if (place.id == reference.id) {
        known = place;
        break;
      }
    }
    if (known != null) {
      places.selectPlace(known);
      return;
    }
    final repository = context.read<PlacesRepository?>();
    if (repository == null) return;
    try {
      final detail = await repository.getPlaceDetail(reference.id);
      if (detail != null && mounted) {
        places.selectPlace(detail);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть место. Повторите позже.'),
          ),
        );
      }
    }
  }

  /// Compact map-first action. Both the Smart Walk and AI entries share the
  /// same height and tap target; subtitles moved to tooltips/semantics so the
  /// top panel no longer consumes a large part of the screen.
  Widget _compactEntry({
    required Key key,
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? iconColor,
  }) {
    final palette = AppPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          minimumSize: const Size.fromHeight(48),
          tapTargetSize: MaterialTapTargetSize.padded,
          side: BorderSide(
            color: onPressed == null ? palette.divider : palette.primary,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(RoutingProvider routing) {
    final assistantAvailable = context.read<AssistantProvider?>() != null;
    return Row(
      children: [
        Expanded(
          child: _compactEntry(
            key: const Key('smart_walk_entry'),
            icon: Icons.auto_awesome,
            label: 'Умная прогулка',
            tooltip: 'Умная прогулка: подбор маршрута по вашим интересам',
            onPressed: routing.navigationLocked ? null : _openSmartWalk,
            iconColor: routing.navigationLocked
                ? null
                : AppPalette.of(context).accent,
          ),
        ),
        if (assistantAvailable) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _compactEntry(
              key: const Key('ai_assistant_entry'),
              icon: Icons.smart_toy_outlined,
              label: 'ИИ-помощник',
              tooltip: 'ИИ-помощник: спросите о городе и приложении',
              onPressed: _openAssistant,
              iconColor: AppPalette.of(context).primary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _searchRow(
    PlacesProvider places,
    SearchProvider? search,
    VoiceSearchController? voice,
  ) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Найти место или адрес',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: places.searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить поиск',
                      icon: const Icon(Icons.close),
                      onPressed: () => _onClearSearch(places, search),
                    ),
            ),
            onChanged: (val) => _onSearchChanged(val, places, search),
            onSubmitted: (_) => places.loadPlaces(),
          ),
        ),
        if (voice != null) ...[
          const SizedBox(width: 6),
          IconButton.filledTonal(
            tooltip: 'Голосовой поиск',
            onPressed: _openVoiceSearch,
            icon: const Icon(Icons.mic),
          ),
        ],
      ],
    );
  }

  Widget _categoriesAndSourcesRow(
    PlacesProvider places,
    LocationProvider? location,
  ) {
    final palette = AppPalette.of(context);
    final selectedCount = places.selectedCategories.length;
    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const Key('categories_toggle'),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () =>
              setState(() => _categoriesExpanded = !_categoriesExpanded),
          icon: Icon(
            _categoriesExpanded ? Icons.expand_less : Icons.tune,
            size: 18,
          ),
          label: Text(
            selectedCount == 0 ? 'Категории' : 'Категории · $selectedCount',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: _showTermsDialog,
          child: const Text(
            'Источники',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        if (!places.isLoading && !places.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'Найдено мест: ${places.places.length}',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
          ),
        if (location != null &&
            location.lastKnownLocation != null &&
            location.locationQuality != LocationQuality.precise)
          Tooltip(
            message:
                location.locationQualityMessage ??
                'Точность местоположения неизвестна.',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    location.locationQuality == LocationQuality.poor
                        ? Icons.gps_off
                        : Icons.my_location,
                    size: 13,
                    color: location.locationQuality == LocationQuality.poor
                        ? palette.error
                        : palette.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    location.lastKnownLocation?.accuracy == null
                        ? 'Геопозиция: точность неизвестна'
                        : 'Геопозиция: ±${location.lastKnownLocation!.accuracy!.round()} м',
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _compactErrors(
    PlacesProvider places,
    RoutingProvider routing,
    SearchProvider? search,
  ) {
    final palette = AppPalette.of(context);
    Widget line(String text) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 14, color: palette.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.error),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (places.hasError) ...[
          if (places.places.isEmpty) ...[
            // The catalog never arrived: one honest message and one obvious
            // way to recover. Lives in the top panel, so map controls,
            // route actions and navigation are never covered.
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.wifi_off, size: 14, color: palette.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Не удалось загрузить достопримечательности. '
                      'Проверьте интернет — мы попробуем подключиться снова.',
                      style: TextStyle(fontSize: 11, color: palette.error),
                    ),
                  ),
                ],
              ),
            ),
            if (places.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  places.errorMessage!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: palette.textMuted),
                ),
              ),
            if (places.isRetrying)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.textMuted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        places.nextRetryAt == null
                            ? 'Восстанавливаем соединение…'
                            : 'Восстанавливаем соединение… Повторим '
                                  'автоматически через несколько секунд.',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: places.isLoading ? null : () => places.loadPlaces(),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Повторить загрузку'),
              ),
            ),
          ] else
            line(places.errorMessage ?? 'Не удалось загрузить места'),
        ],
        if (places.isStale && !places.isLoading)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.history, size: 14, color: palette.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Не удалось обновить данные. Показаны ранее загруженные '
                    'места.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: places.isLoading
                      ? null
                      : () => places.loadPlaces(),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        if (routing.errorMessage != null) line(routing.errorMessage!),
        if (search?.errorMessage != null)
          line('Адреса Яндекса: ${search!.errorMessage}'),
        if (places.isEmpty && !places.isLoading && !places.hasError)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(Icons.search_off, size: 14, color: palette.textMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'По выбранным фильтрам мест нет',
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _startChoosingBanner(RoutingProvider routing) {
    final palette = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app, size: 16, color: palette.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Нажмите на карту, чтобы выбрать точку старта',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: palette.primary,
              ),
            ),
          ),
          TextButton(
            onPressed: routing.cancelStartSelection,
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }

  Widget _topOverlay(
    BoxConstraints constraints, {
    required PlacesProvider places,
    required RoutingProvider routing,
    required SearchProvider? search,
    required VoiceSearchController? voice,
    required LocationProvider? location,
    required bool isSearching,
  }) {
    final palette = AppPalette.of(context);
    return Material(
      key: const Key('map_top_overlay'),
      color: palette.surface.withValues(alpha: 0.97),
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: constraints.maxHeight * (isSearching ? 0.62 : 0.36),
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Column(
            children: [
              _searchRow(places, search, voice),
              const SizedBox(height: 6),
              _actionRow(routing),
              const SizedBox(height: 2),
              _categoriesAndSourcesRow(places, location),
              if (_categoriesExpanded) const CategoryFilterChips(),
              if (places.isLoading ||
                  routing.isCalculating ||
                  (search?.isGeocoding ?? false))
                const LinearProgressIndicator(
                  minHeight: 2,
                  semanticsLabel: 'Загрузка мест, адреса или маршрута',
                ),
              _compactErrors(places, routing, search),
              if (routing.isChoosingStart) _startChoosingBanner(routing),
              if (isSearching) _searchResults(places, search, constraints),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchResults(
    PlacesProvider places,
    SearchProvider? search,
    BoxConstraints constraints,
  ) {
    final palette = AppPalette.of(context);
    return Container(
      constraints: BoxConstraints(
        maxHeight: (constraints.maxHeight * 0.34).clamp(120, 260),
      ),
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(color: palette.divider),
      ),
      child: Material(
        color: palette.surface,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            if (places.places.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                color: palette.surfaceVariant.withValues(alpha: 0.5),
                child: Row(
                  children: [
                    Icon(Icons.tour, size: 14, color: palette.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Места в каталоге (${places.places.length})',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              for (final place in places.places)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    backgroundColor: place.category.color.withValues(
                      alpha: 0.2,
                    ),
                    child: Icon(
                      place.category.icon,
                      size: 14,
                      color: place.category.color,
                    ),
                  ),
                  title: Text(
                    place.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    place.category.displayName,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: palette.textMuted,
                  ),
                  onTap: () {
                    _dismissTerminalNavigation();
                    FocusManager.instance.primaryFocus?.unfocus();
                    context.read<RoutingProvider>().clearRoute();
                    _onClearSearch(places, search);
                    places.selectPlace(place);
                  },
                ),
            ],
            if (search?.isLoadingSuggest ?? false)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (search != null && search.suggestResults.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                color: palette.surfaceVariant.withValues(alpha: 0.5),
                child: Row(
                  children: [
                    Icon(Icons.location_on, size: 14, color: palette.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Адреса и места на карте (Яндекс)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              for (final item in search.suggestResults)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.place_outlined,
                    size: 18,
                    color: palette.accent,
                  ),
                  title: Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: item.subtitle != null
                      ? Text(
                          item.subtitle!,
                          style: const TextStyle(fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.distanceText != null)
                        Text(
                          item.distanceText!,
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textMuted,
                          ),
                        ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: palette.textMuted,
                      ),
                    ],
                  ),
                  onTap: search.isGeocoding
                      ? null
                      : () async {
                          _dismissTerminalNavigation();
                          FocusManager.instance.primaryFocus?.unfocus();
                          context.read<RoutingProvider>().clearRoute();
                          places.selectPlace(null);
                          final point = await search.resolveSuggestion(item);
                          if (point != null && mounted) {
                            _onClearSearch(places, search);
                            search.selectExternalPoint(point);
                          }
                        },
                ),
            ],
            if (places.places.isEmpty &&
                (search?.suggestResults.isEmpty ?? true) &&
                !places.isLoading &&
                !(search?.isLoadingSuggest ?? false))
              Padding(
                padding: const EdgeInsets.all(14),
                child: Center(
                  child: Text(
                    'Ничего не найдено',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomOverlay(
    BoxConstraints constraints,
    NavigationProvider? nav,
    PlacesProvider places,
    RoutingProvider routing,
    SearchProvider? search,
    CityViewpointSession? viewpointSession,
  ) {
    // The Scaffold has already resized the body for the keyboard, so the
    // panel stays reachable (and navigation keeps running) instead of
    // disappearing on every keyboard transition.
    Widget? panel;
    if (nav != null && nav.status != NavigationStatus.idle) {
      panel = const LiveNavigationSheet();
    } else if (viewpointSession != null && !routing.isChoosingStart) {
      panel = SingleChildScrollView(
        child: ViewpointPreviewCard(
          session: viewpointSession,
          onClose: () => context.read<CityViewpointProvider?>()?.clear(),
          onOpenPlace: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PlaceDetailScreen(place: viewpointSession.place),
            ),
          ),
          onBuildRoute: routing.navigationLocked
              ? null
              : () => _buildRouteToViewpoint(viewpointSession),
        ),
      );
    } else if (routing.hasRoute && !routing.isChoosingStart) {
      panel = const RouteDetailsSheet();
    } else if (search?.selectedExternalPoint != null &&
        !routing.isChoosingStart) {
      panel = SingleChildScrollView(
        child: ExternalPointPreviewCard(
          point: search!.selectedExternalPoint!,
          onClose: () => search.selectExternalPoint(null),
        ),
      );
    } else if (places.selectedPlace != null && !routing.isChoosingStart) {
      panel = SingleChildScrollView(
        child: PlacePreviewCard(place: places.selectedPlace!),
      );
    }
    final simulator =
        NavigationSimulatorGate.enabled &&
            Provider.of<SimulationController?>(context) != null
        ? ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: constraints.maxHeight * 0.30,
            ),
            child: SimulationControlPanel(
              controller: Provider.of<SimulationController>(context),
            ),
          )
        : null;
    if (panel == null && simulator == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (simulator != null) simulator,
        if (panel != null)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: constraints.maxHeight * 0.46,
            ),
            child: panel,
          ),
      ],
    );
  }

  /// Explicit C14 action: the existing pedestrian router builds a route from
  /// the current start point to the confirmed viewpoint. It is never called
  /// when a navigation session is active, and it does not touch the current
  /// route until the user presses the button.
  void _buildRouteToViewpoint(CityViewpointSession session) {
    final routing = context.read<RoutingProvider>();
    if (routing.navigationLocked) return;
    final viewpoint = session.viewpoint;
    final point = ExternalMapPoint(
      title: 'Точка обзора: ${session.place.title}',
      subtitle: viewpoint.name,
      address: viewpoint.name,
      latitude: viewpoint.latitude,
      longitude: viewpoint.longitude,
      source: 'city_viewpoint',
    );
    unawaited(routing.buildRouteToExternalPoint(point));
    context.read<CityViewpointProvider?>()?.clear();
  }

  Widget _fallbackMap(
    PlacesProvider places,
    SearchProvider? search,
    RoutingProvider routing,
  ) {
    return ListView(
      padding: const EdgeInsets.only(top: 150),
      children: [
        if (MediaQuery.viewInsetsOf(context).bottom == 0)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              MapKitService.initializationError ??
                  'Карта недоступна: требуется ключ MapKit.',
            ),
          ),
        for (final place in places.places)
          ListTile(
            title: Text(place.title),
            subtitle: Text(place.category.displayName),
            onTap: () {
              _dismissTerminalNavigation();
              routing.clearRoute();
              _onClearSearch(places, search);
              places.selectPlace(place);
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final places = context.watch<PlacesProvider>();
    final routing = context.watch<RoutingProvider>();
    final search = Provider.of<SearchProvider?>(context);
    final voice = Provider.of<VoiceSearchController?>(context, listen: false);
    final nav = Provider.of<NavigationProvider?>(context);
    final location = context.watch<LocationProvider?>();
    final viewpointProvider = context.watch<CityViewpointProvider?>();
    final viewpointSession = viewpointProvider?.session;

    // During a live navigation session the map shows the session's route:
    // after a manual reroute it differs from the planned routing.currentRoute,
    // and the rebuilt geometry must replace the old polyline on the map.
    final navRoute = (nav != null && nav.status != NavigationStatus.idle)
        ? nav.state.route
        : null;

    // Verified next-maneuver location for the map indicator. Null unless the
    // guidance is in the safe native presentation: off-route, GPS loss and
    // waiting states suppress the marker together with the instruction.
    GeoCoord? maneuverPoint;
    PedestrianManeuverKind? maneuverKind;
    if (nav != null && navRoute != null && nav.isActive) {
      final maneuver = nav.guidance.maneuver;
      final legIndex = nav.currentLegIndex;
      if (maneuver != null &&
          legIndex >= 0 &&
          legIndex < navRoute.legs.length) {
        maneuverPoint = maneuver.coordinateOnLeg(
          navRoute.legs[legIndex].geometryPoints,
        );
        maneuverKind = maneuver.kind;
      }
    }

    if (_searchController.text != places.searchQuery) {
      _searchController.text = places.searchQuery;
    }

    final isSearching =
        _searchController.text.trim().isNotEmpty && !routing.isChoosingStart;

    final textScaler = MediaQuery.textScalerOf(context);
    final textScale = textScaler.scale(1.0);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final theme = Theme.of(context);
    // The authorship line is a compact second AppBar row. It keeps a single
    // line and scales down by the few percent needed on a narrow screen with
    // 2.0 accessibility text, so the full name stays readable instead of being
    // clipped or pushing the map area down.
    const creatorLineFactor = 1.35;
    final creatorBarHeight = textScaler.scale(12) * creatorLineFactor + 8;
    final creatorStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 12,
      height: 1.2,
    );
    final titleFontSize = _brandTitleFontSize(context);
    return PopScope(
      // System Back hides the keyboard first and never exits the map with the
      // search field still focused.
      canPop: !keyboardOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          titleSpacing: 12,
          title: Text(
            AppStrings.appTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: titleFontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(creatorBarHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  height: textScaler.scale(12) * creatorLineFactor,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      AppStrings.appCreator,
                      key: const Key('app_creator'),
                      maxLines: 1,
                      style: creatorStyle,
                    ),
                  ),
                ),
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Выбрать старт',
              icon: const Icon(Icons.trip_origin),
              onPressed: routing.navigationLocked ? null : _selectStart,
            ),
            IconButton(
              tooltip: 'Прогулка',
              icon: Badge(
                isLabelVisible: routing.walkPlaces.isNotEmpty,
                label: Text('${routing.walkPlaces.length}'),
                child: const Icon(Icons.route),
              ),
              onPressed: () {
                _dismissTerminalNavigation();
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const WalkPlannerSheet(),
                );
              },
            ),
            const ThemeModeButton(),
            PopupMenuButton<String>(
              tooltip: 'Дополнительные действия',
              onSelected: (value) {
                if (value == 'refresh') places.loadPlaces();
                if (value == 'terms') _showTermsDialog();
                if (value == 'favorites') {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FavoritesScreen(),
                    ),
                  );
                }
                if (value == 'settings') {
                  _openSettings();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'favorites', child: Text('Избранное')),
                PopupMenuItem(value: 'settings', child: Text('Настройки')),
                PopupMenuItem(value: 'refresh', child: Text('Обновить места')),
                PopupMenuItem(
                  value: 'terms',
                  child: Text('Источники и условия'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final mapSurface = MapKitService.isMapKitInitialized
                  ? _NativeMap(
                      places: places.places,
                      selectedPlace: places.selectedPlace,
                      selectedExternalPoint: search?.selectedExternalPoint,
                      viewpoint: viewpointSession?.viewpoint,
                      onSelectExternal: (point) {
                        _dismissTerminalNavigation();
                        viewpointProvider?.clear();
                        routing.clearRoute();
                        places.selectPlace(null);
                        search?.selectExternalPoint(point);
                      },
                      startPoint: routing.startPoint,
                      route: navRoute ?? routing.currentRoute,
                      navigationLegIndex: navRoute == null
                          ? null
                          : nav?.currentLegIndex,
                      completedStops: navRoute == null
                          ? 0
                          : nav!.state.completedStopsCount,
                      navigationUserPoint: navRoute == null
                          ? null
                          : nav?.state.projectedPoint,
                      maneuverPoint: maneuverPoint,
                      simulationActive: NavigationSimulatorGate.enabled,
                      shadeLayers: routing.shadeOverlayReady
                          ? buildShadeOverlayLayers(routing.shadeAnalysis!)
                          : const [],
                      maneuverKind: maneuverKind,
                      choosingStart: routing.isChoosingStart,
                      planningLocked: routing.navigationLocked,
                      controlsTopPadding:
                          150 + (textScale - 1).clamp(0, 1) * 70,
                      onSelect: (place) {
                        _dismissTerminalNavigation();
                        viewpointProvider?.clear();
                        routing.clearRoute();
                        search?.selectExternalPoint(null);
                        places.selectPlace(place);
                      },
                      onStart: (point) async {
                        _dismissTerminalNavigation();
                        await routing.setMapStartPoint(
                          point.latitude,
                          point.longitude,
                          reverseGeocode: (lat, lon) async =>
                              search?.reverseGeocodeCoordinates(lat, lon),
                        );
                      },
                    )
                  : _fallbackMap(places, search, routing);
              // Map-first: the map always fills the body. Search, categories,
              // search results and the bottom sheets are overlays and never
              // shrink the map surface.
              return Stack(
                children: [
                  Positioned.fill(
                    child: KeyedSubtree(
                      key: const Key('map_surface'),
                      child: mapSurface,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _topOverlay(
                      constraints,
                      places: places,
                      routing: routing,
                      search: search,
                      voice: voice,
                      location: location,
                      isSearching: isSearching,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _bottomOverlay(
                      constraints,
                      nav,
                      places,
                      routing,
                      search,
                      viewpointSession,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NativeMap extends StatefulWidget {
  final bool choosingStart;
  final bool planningLocked;
  final List<PlaceModel> places;
  final PlaceModel? selectedPlace;
  final ExternalMapPoint? selectedExternalPoint;
  final RoutePointModel startPoint;
  final PedestrianRouteModel? route;
  final int? navigationLegIndex;
  final int completedStops;

  /// Last accepted projected navigation position. Drives the opt-in camera
  /// follow mode; it never triggers a re-render of map objects.
  final GeoCoord? navigationUserPoint;

  /// Verified location of the next native maneuver on the current leg, or
  /// null when guidance is in fallback/suspended presentation.
  final GeoCoord? maneuverPoint;
  final PedestrianManeuverKind? maneuverKind;

  /// Simulator builds only: draws the labeled virtual-walker badge at
  /// [navigationUserPoint]. Never true in production or ordinary debug runs.
  final bool simulationActive;

  /// Phase C7.1 shade overlay: pre-computed visual layers for the CURRENT
  /// route (empty when the overlay is off or the estimate is for other
  /// geometry). The map only draws them — it never computes shade.
  final List<ShadeOverlayLayer> shadeLayers;

  /// Keeps the zoom/location controls below the floating search panel.
  final double controlsTopPadding;

  /// C14 confirmed viewpoint selected in a place card. The map only draws and
  /// centres it; no route or navigation state is derived from it.
  final CityViewpoint? viewpoint;

  final ValueChanged<PlaceModel> onSelect;
  final ValueChanged<ExternalMapPoint> onSelectExternal;
  final ValueChanged<ymk.Point> onStart;

  const _NativeMap({
    required this.choosingStart,
    required this.planningLocked,
    required this.places,
    required this.selectedPlace,
    this.selectedExternalPoint,
    required this.startPoint,
    required this.route,
    this.navigationLegIndex,
    this.completedStops = 0,
    this.navigationUserPoint,
    this.maneuverPoint,
    this.maneuverKind,
    this.simulationActive = false,
    this.shadeLayers = const [],
    this.controlsTopPadding = 0,
    this.viewpoint,
    required this.onSelect,
    required this.onSelectExternal,
    required this.onStart,
  });

  @override
  State<_NativeMap> createState() => _NativeMapState();
}

class _NativeMapState extends State<_NativeMap>
    implements ymk.MapInputListener, ymk.MapCameraListener {
  ymk.MapWindow? _window;
  ymk.UserLocationLayer? _locationLayer;
  LocationProvider? _locationProvider;
  final List<ymk.MapObjectTapListener> _listeners = [];
  final Map<(Color, bool), map_image.ImageProvider> _icons = {};
  final Map<PedestrianManeuverKind, map_image.ImageProvider> _maneuverBadges =
      {};
  map_image.ImageProvider? _viewpointIcon;
  bool? _renderedDark;

  /// Simulator builds only: persistent virtual-walker placemark. Its
  /// geometry is updated in place on every accepted simulated fix — map
  /// objects are never recreated per GPS tick.
  ymk.PlacemarkMapObject? _walkerPlacemark;
  map_image.ImageProvider? _walkerBadgeIcon;

  /// Opt-in «Следить за мной» mode. UI-layer only: it consumes already
  /// accepted navigation positions and native gesture events, and stays
  /// completely outside the GPS navigation state machine.
  late final CameraFollowController _follow = CameraFollowController(
    onFollowMove: (point) => _animatedMove(
      ymk.Point(latitude: point.latitude, longitude: point.longitude),
    ),
  );

  map_image.ImageProvider _icon(Color color, {bool isSelected = false}) {
    final accentColor = AppPalette.of(context).accent;
    final keyColor = isSelected
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.1), color)
        : color;
    return _icons.putIfAbsent(
      (keyColor, isSelected),
      () => map_image.ImageProvider(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final size = isSelected ? 56.0 : 44.0;
        final center = Offset(size / 2, size / 2);

        // Shadow / Outer ring
        if (isSelected) {
          canvas.drawCircle(
            center,
            (size / 2) - 1,
            Paint()..color = accentColor,
          );
          canvas.drawCircle(
            center,
            (size / 2) - 4,
            Paint()..color = Colors.white,
          );
          canvas.drawCircle(center, (size / 2) - 7, Paint()..color = color);
        } else {
          canvas.drawCircle(
            center,
            (size / 2) - 1,
            Paint()..color = Colors.white,
          );
          canvas.drawCircle(center, (size / 2) - 4, Paint()..color = color);
        }

        final picture = recorder.endRecording();
        final image = await picture.toImage(size.toInt(), size.toInt());
        picture.dispose();
        return image;
      }),
    );
  }

  /// Distinct eye marker for a C14 viewpoint. It is not a catalog POI and has
  /// no tap listener, so it cannot be mistaken for a selectable place.
  map_image.ImageProvider _viewpointMarkerIcon() {
    final cache = _viewpointIcon;
    if (cache != null) return cache;
    final icon = map_image.ImageProvider(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const size = 52.0;
      const center = Offset(size / 2, size / 2);
      canvas.drawCircle(center, (size / 2) - 1, Paint()..color = Colors.white);
      canvas.drawCircle(
        center,
        (size / 2) - 4,
        Paint()..color = const Color(0xFF0F766E),
      );
      final eye = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      final path = Path()
        ..moveTo(center.dx - 10, center.dy)
        ..quadraticBezierTo(center.dx, center.dy - 9, center.dx + 10, center.dy)
        ..quadraticBezierTo(
          center.dx,
          center.dy + 9,
          center.dx - 10,
          center.dy,
        );
      canvas.drawPath(path, eye);
      canvas.drawCircle(center, 3.4, Paint()..color = Colors.white);
      final picture = recorder.endRecording();
      final image = await picture.toImage(size.toInt(), size.toInt());
      picture.dispose();
      return image;
    });
    _viewpointIcon = icon;
    return icon;
  }

  void _move(ymk.Point point, double zoom) {
    _window?.map.move(
      ymk.CameraPosition(point, zoom: zoom, azimuth: 0, tilt: 0),
    );
  }

  /// Smooth short follow animation. Azimuth and tilt stay at zero: the map is
  /// never rotated, because no reliable pedestrian heading is available.
  void _animatedMove(ymk.Point point) {
    final camera = _window?.map.cameraPosition;
    _window?.map.move(
      ymk.CameraPosition(
        point,
        zoom: camera?.zoom ?? MapConstants.placeDetailZoom,
        azimuth: 0,
        tilt: 0,
      ),
      animation: const ymk.Animation(
        type: ymk.AnimationType.Smooth,
        duration: 0.35,
      ),
    );
  }

  /// Small turn indicator for the verified next maneuver, drawn as a white
  /// badge with the typed maneuver glyph. Rendered only where native metadata
  /// established the location; never placed at a guessed intersection.
  map_image.ImageProvider _maneuverBadge(PedestrianManeuverKind kind) {
    return _maneuverBadges.putIfAbsent(
      kind,
      () => map_image.ImageProvider(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        const size = 36.0;
        const c = Offset(size / 2, size / 2);
        canvas.drawCircle(c, size / 2 - 1, Paint()..color = Colors.white);
        canvas.drawCircle(
          c,
          size / 2 - 2.5,
          Paint()
            ..color = AppColors.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        final glyph = Paint()
          ..color = AppColors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        const r = 9.0;
        switch (kind) {
          case PedestrianManeuverKind.straight:
            canvas.drawLine(c, c.translate(0, -r), glyph);
            final head = Path()
              ..moveTo(c.dx - 4.5, c.dy - r + 4.5)
              ..lineTo(c.dx, c.dy - r)
              ..lineTo(c.dx + 4.5, c.dy - r + 4.5);
            canvas.drawPath(head, glyph);
          case PedestrianManeuverKind.left:
            canvas.drawLine(c, c.translate(-r, 0), glyph);
            final head = Path()
              ..moveTo(c.dx - r + 4.5, c.dy - 4.5)
              ..lineTo(c.dx - r, c.dy)
              ..lineTo(c.dx - r + 4.5, c.dy + 4.5);
            canvas.drawPath(head, glyph);
          case PedestrianManeuverKind.right:
            canvas.drawLine(c, c.translate(r, 0), glyph);
            final head = Path()
              ..moveTo(c.dx + r - 4.5, c.dy - 4.5)
              ..lineTo(c.dx + r, c.dy)
              ..lineTo(c.dx + r - 4.5, c.dy + 4.5);
            canvas.drawPath(head, glyph);
          case PedestrianManeuverKind.crosswalk:
            final bar = Paint()
              ..color = AppColors.primary
              ..strokeWidth = 2.5
              ..strokeCap = StrokeCap.round;
            for (final dy in [-5.0, 0.0, 5.0]) {
              canvas.drawLine(c.translate(-6, dy), c.translate(6, dy), bar);
            }
          case PedestrianManeuverKind.stairsToUnderpass:
          case PedestrianManeuverKind.stairsToOverpass:
          case PedestrianManeuverKind.stairs:
          case PedestrianManeuverKind.stairsDown:
          case PedestrianManeuverKind.stairsUp:
            final steps = Path()
              ..moveTo(c.dx - 8, c.dy + 6)
              ..lineTo(c.dx - 8, c.dy + 2)
              ..lineTo(c.dx - 3, c.dy + 2)
              ..lineTo(c.dx - 3, c.dy - 2)
              ..lineTo(c.dx + 2, c.dy - 2)
              ..lineTo(c.dx + 2, c.dy - 6)
              ..lineTo(c.dx + 8, c.dy - 6);
            canvas.drawPath(steps, glyph);
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(size.toInt(), size.toInt());
        picture.dispose();
        return image;
      }),
    );
  }

  /// Distinct purple walker badge for the simulated pedestrian — visually
  /// separated from the real-GPS blue dot, route blue, start green and the
  /// amber accent.
  map_image.ImageProvider _walkerBadge() {
    return _walkerBadgeIcon ??= map_image.ImageProvider(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const size = 38.0;
      const c = Offset(size / 2, size / 2);
      canvas.drawCircle(c, size / 2 - 1, Paint()..color = Colors.white);
      canvas.drawCircle(
        c,
        size / 2 - 2.5,
        Paint()..color = AppColors.unusualBadge,
      );
      final figure = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      // Simple walking figure: head (19,13), torso, arms, legs. The badge
      // center is (19, 19) at the fixed 38 px size.
      canvas.drawCircle(
        const Offset(19, 13),
        2.6,
        Paint()..color = Colors.white,
      );
      canvas.drawLine(const Offset(19, 16), const Offset(19, 22), figure);
      canvas.drawLine(const Offset(14, 18), const Offset(24, 18), figure);
      canvas.drawLine(const Offset(19, 22), const Offset(15, 28), figure);
      canvas.drawLine(const Offset(19, 22), const Offset(23, 28), figure);
      final picture = recorder.endRecording();
      final image = await picture.toImage(size.toInt(), size.toInt());
      picture.dispose();
      return image;
    });
  }

  /// Creates, moves or removes the virtual-walker placemark. Called from the
  /// object render pass (state changes) and from didUpdateWidget for the
  /// per-fix position update, so the map never rebuilds its objects on GPS
  /// ticks. No tap listener: the badge must not intercept POI selection.
  void _syncWalkerPlacemark() {
    final map = _window?.map;
    if (map == null) return;
    final shouldShow = showSimulatedWalkerMarker(
      simulatorEnabled: widget.simulationActive,
      navigationSessionActive: widget.navigationLegIndex != null,
      hasProjectedPosition: widget.navigationUserPoint != null,
    );
    if (!shouldShow) {
      if (_walkerPlacemark != null && (_walkerPlacemark!.isValid())) {
        map.mapObjects.remove(_walkerPlacemark!);
      }
      _walkerPlacemark = null;
      return;
    }
    final point = widget.navigationUserPoint!;
    final nativePoint = ymk.Point(
      latitude: point.latitude,
      longitude: point.longitude,
    );
    final existing = _walkerPlacemark;
    if (existing != null && existing.isValid()) {
      existing.geometry = nativePoint;
      return;
    }
    final placemark = map.mapObjects.addPlacemarkWithPoint(nativePoint)
      ..setIcon(_walkerBadge())
      ..zIndex = 28
      ..setTextWithStyle(
        const ymk.TextStyle(
          size: 11,
          color: Color(0xFF5B21B6),
          outlineWidth: 1.5,
          outlineColor: Colors.white,
          placement: ymk.TextStylePlacement.Bottom,
          offsetFromIcon: true,
        ),
        text: simulatedWalkerLabel,
      );
    _walkerPlacemark = placemark;
  }

  void _renderObjects() {
    final map = _window?.map;
    if (map == null) return;
    map.mapObjects.clear();
    _listeners.clear();

    // Отрисовка POI каталога
    for (final place in widget.places) {
      final point = ymk.Point(
        latitude: place.latitude,
        longitude: place.longitude,
      );
      final isSelected = widget.selectedPlace?.id == place.id;
      final marker = map.mapObjects.addPlacemarkWithPoint(point)
        ..setIcon(_icon(place.category.color, isSelected: isSelected))
        ..zIndex = isSelected ? 20 : 10;

      // Показываем подпись только для выбранного места или на крупном масштабе (>= 15.0)
      if (isSelected) {
        marker.setText(place.title);
      }

      final listener = _PlaceTapListener(() {
        if (widget.choosingStart) {
          _chooseStart(point);
        } else {
          widget.onSelect(place);
        }
      });
      _listeners.add(listener);
      marker.addTapListener(listener);
    }

    // Отрисовка маркера выбранного внешнего адреса (если есть)
    final externalPoint = widget.selectedExternalPoint;
    if (externalPoint != null) {
      final extP = ymk.Point(
        latitude: externalPoint.latitude,
        longitude: externalPoint.longitude,
      );
      final marker = map.mapObjects.addPlacemarkWithPoint(extP)
        ..setIcon(_icon(Colors.amber.shade800))
        ..zIndex = 25
        ..setText(externalPoint.title);

      final listener = _PlaceTapListener(() {
        if (widget.choosingStart) {
          _chooseStart(extP);
        } else {
          widget.onSelectExternal(externalPoint);
        }
      });
      _listeners.add(listener);
      marker.addTapListener(listener);
    }

    // C14: confirmed viewpoint marker. Drawn after catalog pins so it stays
    // visible over a selected POI, and without a tap listener.
    final viewpoint = widget.viewpoint;
    if (viewpoint != null && viewpoint.hasValidCoordinates) {
      map.mapObjects.addPlacemarkWithPoint(
          ymk.Point(
            latitude: viewpoint.latitude,
            longitude: viewpoint.longitude,
          ),
        )
        ..setIcon(_viewpointMarkerIcon())
        ..zIndex = 26
        ..setTextWithStyle(
          const ymk.TextStyle(
            size: 11,
            color: Color(0xFF0F766E),
            outlineWidth: 1.5,
            outlineColor: Colors.white,
            placement: ymk.TextStylePlacement.Bottom,
            offsetFromIcon: true,
          ),
          text: 'Точка обзора',
        );
    }

    // Маркер точки старта (зелёная окружность)
    map.mapObjects.addCircle(
        ymk.Circle(
          ymk.Point(
            latitude: widget.startPoint.latitude,
            longitude: widget.startPoint.longitude,
          ),
          radius: 12,
        ),
      )
      ..fillColor = AppColors.routeStartMarker
      ..strokeColor = Colors.white
      ..strokeWidth = 2;

    // Native route geometry remains intact; tourist stop state changes the
    // visual emphasis only, with no work on ordinary GPS progress ticks.
    final route = widget.route;
    if (route != null) {
      final legPresentations = navigationMapLegs(
        route,
        currentLegIndex: widget.navigationLegIndex,
        completedStops: widget.completedStops,
      ).toList();
      final geometries = route.legs.isEmpty
          ? routePolylineGeometries(route).toList()
          : legPresentations.map((item) => item.leg.geometryPoints).toList();
      for (var index = 0; index < geometries.length; index++) {
        final geometry = geometries[index];
        final role = route.legs.isEmpty
            ? NavigationMapLegRole.planned
            : legPresentations[index].role;
        final color = switch (role) {
          NavigationMapLegRole.current => AppColors.routeColor,
          NavigationMapLegRole.upcoming => AppColors.routeColor.withValues(
            alpha: 0.5,
          ),
          NavigationMapLegRole.completed => AppPalette.of(
            context,
          ).textMuted.withValues(alpha: 0.45),
          NavigationMapLegRole.planned => AppColors.routeColor,
        };
        map.mapObjects.addPolylineWithGeometry(
            ymk.Polyline(
              geometry
                  .map(
                    (p) =>
                        ymk.Point(latitude: p.latitude, longitude: p.longitude),
                  )
                  .toList(),
            ),
          )
          ..setStrokeColor(color)
          ..style = ymk.LineStyle(
            strokeWidth: role == NavigationMapLegRole.current ? 7 : 5,
          );
      }
      // Phase C7.1 shade overlay: drawn ON TOP of the native route with a
      // thinner stroke, so the route itself is never hidden or altered and
      // markers/maneuvers keep their z-order above it.
      for (final layer in widget.shadeLayers) {
        if (layer.points.length < 2) continue;
        map.mapObjects.addPolylineWithGeometry(
            ymk.Polyline(
              layer.points
                  .map(
                    (p) =>
                        ymk.Point(latitude: p.latitude, longitude: p.longitude),
                  )
                  .toList(),
            ),
          )
          ..setStrokeColor(shadeOverlayColor(layer.state))
          ..style = const ymk.LineStyle(strokeWidth: 3);
      }

      if (widget.navigationLegIndex != null) {
        for (final item in legPresentations) {
          if (item.role == NavigationMapLegRole.completed) continue;
          final endpoint = item.leg.geometryPoints.last;
          final current = item.role == NavigationMapLegRole.current;
          map.mapObjects.addPlacemarkWithPoint(
              ymk.Point(
                latitude: endpoint.latitude,
                longitude: endpoint.longitude,
              ),
            )
            ..setIcon(
              _icon(
                current ? AppPalette.of(context).accent : AppColors.routeColor,
                isSelected: current,
              ),
            )
            ..zIndex = current ? 35 : 30
            ..setText(
              current
                  ? 'Сейчас: ${item.leg.toTitle}'
                  : '${item.index + 1}. ${item.leg.toTitle}',
            );
        }

        // Verified next-maneuver marker: only where native metadata
        // established the location. Low z-index and no tap listener, so it
        // never interferes with POI selection or the stop badges above.
        final maneuverPoint = widget.maneuverPoint;
        final maneuverKind = widget.maneuverKind;
        if (maneuverPoint != null && maneuverKind != null) {
          map.mapObjects.addPlacemarkWithPoint(
              ymk.Point(
                latitude: maneuverPoint.latitude,
                longitude: maneuverPoint.longitude,
              ),
            )
            ..setIcon(_maneuverBadge(maneuverKind))
            ..zIndex = 8;
        }
      }
    }

    // Simulator builds only: the labeled virtual-walker badge follows the
    // accepted simulated position (created/moved/removed here; per-fix
    // moves between renders go through didUpdateWidget without a rebuild).
    _syncWalkerPlacemark();
  }

  @override
  void didUpdateWidget(covariant _NativeMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Live GPS fixes rebuild the whole screen every ~2 s with identical map
    // inputs. Clearing and re-adding all native placemarks on each tick causes
    // visible churn, icon reloads and dropped taps, so objects are re-rendered
    // only when an input actually changed. Compare place elements because a
    // provider can return a new immutable list wrapper for the same catalog.
    // The accepted user point and camera-follow state are deliberately NOT
    // re-render inputs: following only animates the camera.
    final maneuverPoint = widget.maneuverPoint;
    final oldManeuverPoint = oldWidget.maneuverPoint;
    final maneuverMoved =
        (maneuverPoint?.latitude) != (oldManeuverPoint?.latitude) ||
        (maneuverPoint?.longitude) != (oldManeuverPoint?.longitude);
    final viewpoint = widget.viewpoint;
    final oldViewpoint = oldWidget.viewpoint;
    final viewpointMoved =
        (viewpoint?.latitude) != (oldViewpoint?.latitude) ||
        (viewpoint?.longitude) != (oldViewpoint?.longitude);
    final inputsChanged =
        !listEquals(oldWidget.places, widget.places) ||
        !identical(oldWidget.selectedPlace, widget.selectedPlace) ||
        !identical(
          oldWidget.selectedExternalPoint,
          widget.selectedExternalPoint,
        ) ||
        viewpointMoved ||
        !identical(oldWidget.startPoint, widget.startPoint) ||
        !identical(oldWidget.route, widget.route) ||
        oldWidget.navigationLegIndex != widget.navigationLegIndex ||
        oldWidget.completedStops != widget.completedStops ||
        maneuverMoved ||
        oldWidget.maneuverKind != widget.maneuverKind ||
        !listEquals(oldWidget.shadeLayers, widget.shadeLayers) ||
        oldWidget.choosingStart != widget.choosingStart;
    if (inputsChanged) _renderObjects();

    // Camera follow consumes the accepted position without touching map
    // objects. The controller decides whether the step is worth animating.
    final userPoint = widget.navigationUserPoint;
    final oldUserPoint = oldWidget.navigationUserPoint;
    final userPointChanged =
        (userPoint?.latitude) != (oldUserPoint?.latitude) ||
        (userPoint?.longitude) != (oldUserPoint?.longitude);
    if (userPointChanged && userPoint != null && _follow.following) {
      _follow.onAcceptedPosition(userPoint);
    }
    // Per-fix walker badge move without touching any other map object.
    if (userPointChanged) _syncWalkerPlacemark();

    if (viewpoint != null && viewpointMoved) {
      _move(
        ymk.Point(latitude: viewpoint.latitude, longitude: viewpoint.longitude),
        MapConstants.placeDetailZoom,
      );
    }

    final selected = widget.selectedPlace;
    if (selected != null && oldWidget.selectedPlace?.id != selected.id) {
      _move(
        ymk.Point(latitude: selected.latitude, longitude: selected.longitude),
        MapConstants.placeDetailZoom,
      );
    }

    final extSelected = widget.selectedExternalPoint;
    if (extSelected != null &&
        (oldWidget.selectedExternalPoint?.latitude != extSelected.latitude ||
            oldWidget.selectedExternalPoint?.longitude !=
                extSelected.longitude)) {
      _move(
        ymk.Point(
          latitude: extSelected.latitude,
          longitude: extSelected.longitude,
        ),
        MapConstants.placeDetailZoom,
      );
    }
  }

  @override
  void onMapTap(ymk.Map map, ymk.Point point) {
    if (widget.choosingStart) _chooseStart(point);
  }

  @override
  void onMapLongTap(ymk.Map map, ymk.Point point) {
    _chooseStart(point);
  }

  /// Manual map interaction (drag, zoom, rotate, fling) stops the automatic
  /// camera follow. Programmatic moves report Application and are ignored.
  @override
  void onCameraPositionChanged(
    ymk.Map map,
    ymk.CameraPosition cameraPosition,
    ymk.CameraUpdateReason cameraUpdateReason,
    bool finished,
  ) {
    if (cameraUpdateReason == ymk.CameraUpdateReason.Gestures) {
      _follow.onCameraGesture();
    }
  }

  void _chooseStart(ymk.Point point) {
    // Planning is locked during a live navigation session: a long tap must
    // neither request a start change nor hint that one happened.
    if (widget.planningLocked) return;
    widget.onStart(point);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Точка старта выбрана на карте'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _initUserLocationLayer() {
    final window = _window;
    if (window == null) return;
    try {
      _locationLayer ??= mapkit_factory.mapkit.createUserLocationLayer(window);
      _locationLayer?.setDefaultSource();
      _locationLayer?.setVisible(true);
      _locationLayer?.headingModeActive = false;
      _locationLayer?.autoZoomEnabled = false;
    } catch (error) {
      debugPrint('MapKit user location layer failure: ${error.runtimeType}');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<LocationProvider?>(context, listen: false);
    if (!identical(provider, _locationProvider)) {
      _locationProvider?.removeListener(_syncUserLocationLayer);
      _locationProvider = provider;
      provider?.addListener(_syncUserLocationLayer);
    }
    // Marker bitmaps are baked once and cached: the selected ring is drawn
    // with the themed accent, so a light/dark switch must invalidate the
    // cache and re-render the placemarks with the new palette.
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_renderedDark != null && dark != _renderedDark && _window != null) {
      _icons.clear();
      _viewpointIcon = null;
      _renderObjects();
    }
    _renderedDark = dark;
    _syncUserLocationLayer();
  }

  void _syncUserLocationLayer() {
    if (!mounted || _window == null) return;
    final allowed =
        (_locationProvider?.isPermissionGranted ?? false) &&
        (_locationProvider?.isForeground ?? false);
    if (allowed) {
      _initUserLocationLayer();
    } else if (_locationLayer?.isValid() ?? false) {
      _locationLayer?.setVisible(false);
    }
  }

  Future<void> _onMyLocationPressed() async {
    final locProvider = context.read<LocationProvider>();
    final start = widget.startPoint;
    final route = widget.route;
    final snapshot = await locProvider.requestLocationAndLocate();
    if (!mounted || widget.startPoint != start || widget.route != route) return;

    if (snapshot != null) {
      _initUserLocationLayer();
      _move(
        ymk.Point(
          latitude: snapshot.coordinate.latitude,
          longitude: snapshot.coordinate.longitude,
        ),
        MapConstants.placeDetailZoom,
      );
      // Never present centering as a precision claim when the reported
      // accuracy is low. The old message is kept only for a precise fix.
      final qualityMessage = locProvider.locationQualityMessage;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              qualityMessage ?? 'Камера отцентрирована на вашем местоположении',
            ),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } else {
      final error = locProvider.errorMessage;
      if (error != null) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(error),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(label: 'OK', onPressed: () {}),
            ),
          );
      }
    }
  }

  @override
  void dispose() {
    _locationProvider?.removeListener(_syncUserLocationLayer);
    if (_locationLayer?.isValid() ?? false) _locationLayer?.setVisible(false);
    _locationLayer = null;
    final map = _window?.map;
    if (map != null) {
      map.removeInputListener(this);
      map.removeCameraListener(this);
    }
    _follow.dispose();
    _walkerPlacemark = null;
    _walkerBadgeIcon = null;
    _listeners.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLocating = context.select<LocationProvider, bool>(
      (p) => p.isLocating,
    );
    final navigationActive =
        widget.navigationLegIndex != null && widget.navigationUserPoint != null;

    return Stack(
      children: [
        YandexMap(
          onMapCreated: (window) {
            _window = window;
            window.map.addInputListener(this);
            window.map.addCameraListener(this);
            _move(
              const ymk.Point(
                latitude: MapConstants.spbCenterLat,
                longitude: MapConstants.spbCenterLon,
              ),
              MapConstants.defaultZoom,
            );
            _renderObjects();
            _syncUserLocationLayer();
          },
        ),
        Positioned(
          right: 8,
          top: widget.controlsTopPadding + 8,
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  FloatingActionButton(
                    heroTag: 'zoomIn',
                    tooltip: 'Приблизить',
                    mini: false,
                    child: const Icon(Icons.add),
                    onPressed: () {
                      final camera = _window?.map.cameraPosition;
                      if (camera != null) {
                        _move(camera.target, (camera.zoom + 1).clamp(0, 19));
                      }
                    },
                  ),
                  FloatingActionButton(
                    heroTag: 'zoomOut',
                    tooltip: 'Отдалить',
                    mini: false,
                    child: const Icon(Icons.remove),
                    onPressed: () {
                      final camera = _window?.map.cameraPosition;
                      if (camera != null) {
                        _move(camera.target, (camera.zoom - 1).clamp(0, 19));
                      }
                    },
                  ),
                  MyLocationButton(
                    isLocating: isLocating,
                    onPressed: _onMyLocationPressed,
                  ),
                ],
              ),
              // «Следить за мной»: opt-in camera follow during navigation.
              // Tapping while following turns it off implicitly by the next
              // gesture; the button re-centers and re-enables when off.
              if (navigationActive)
                ListenableBuilder(
                  listenable: _follow,
                  builder: (context, _) => FloatingActionButton(
                    heroTag: 'followMe',
                    tooltip: _follow.following
                        ? 'Следить за мной: включено'
                        : 'Следить за мной',
                    backgroundColor: _follow.following
                        ? AppColors.primary
                        : null,
                    foregroundColor: _follow.following ? Colors.white : null,
                    mini: true,
                    child: Icon(
                      _follow.following
                          ? Icons.my_location
                          : Icons.location_searching,
                    ),
                    onPressed: () {
                      final point = widget.navigationUserPoint;
                      if (point == null) return;
                      _follow.recenter(point);
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaceTapListener implements ymk.MapObjectTapListener {
  final VoidCallback _callback;
  _PlaceTapListener(this._callback);
  @override
  bool onMapObjectTap(ymk.MapObject mapObject, ymk.Point point) {
    _callback();
    return true;
  }
}

/// Four 48 dp action slots plus the title spacing leave about 156 dp for the
/// title on a 360 dp phone, where the full brand name needs roughly 147 dp at
/// 15 dp and 167 dp at 17 dp. The title therefore steps down on narrow screens
/// so the name stays whole, and returns to the larger size when it fits.
double _brandTitleFontSize(BuildContext context) {
  const actionSlots = 4;
  const titleSpacing = 12.0;
  final available =
      MediaQuery.sizeOf(context).width - titleSpacing - 48 * actionSlots;
  return available >= 170 ? 17 : 15;
}
