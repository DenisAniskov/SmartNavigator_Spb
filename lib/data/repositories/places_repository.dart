import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/historical_content_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';

class PlacesRepository {
  static const int placesPageSize = 200;
  static const int maxPlacesPages = 10;
  static const int maxLoadedPlaces = placesPageSize * maxPlacesPages;
  final ApiClient _apiClient;
  PlacesRepository({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  /// Host for the provider's lightweight connectivity probe (P2): a DNS
  /// resolution attempt, never a request to the backend itself.
  String get connectivityHost => Uri.parse(_apiClient.currentBaseUrl).host;

  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async {
    // Snapshot the filters once: later pages belong to the same user action.
    final categoryKeys = categories?.map((c) => c.key).toList(growable: false);
    final query = searchQuery?.trim();
    final filters = <String, dynamic>{
      if (categoryKeys != null && categoryKeys.isNotEmpty)
        'category': categoryKeys,
      if (isUnusual != null) 'is_unusual': isUnusual,
      if (query != null && query.isNotEmpty) 'q': query,
    };
    final places = <PlaceModel>[];
    final ids = <int>{};
    int? expectedTotal;
    for (var page = 0; page < maxPlacesPages; ++page) {
      final response = await _apiClient.dio.get(
        ApiConstants.placesEndpoint,
        queryParameters: {
          ...filters,
          'limit': placesPageSize,
          'offset': places.length,
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic> ||
          data['total'] is! int ||
          data['items'] is! List) {
        throw const FormatException('Invalid catalog page');
      }
      final total = data['total'] as int;
      final items = data['items'] as List;
      if (total < 0 ||
          total > maxLoadedPlaces ||
          (expectedTotal != null && total != expectedTotal) ||
          items.length > placesPageSize ||
          places.length + items.length > total ||
          (items.isEmpty && places.length < total)) {
        throw const FormatException(
          'Incomplete or inconsistent catalog pagination',
        );
      }
      expectedTotal = total;
      for (final item in items) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid catalog place');
        }
        late final PlaceModel place;
        try {
          place = PlaceModel.fromJson(item);
        } catch (_) {
          throw const FormatException('Invalid catalog place schema');
        }
        if (place.id <= 0 ||
            !ids.add(place.id) ||
            !place.latitude.isFinite ||
            !place.longitude.isFinite ||
            place.latitude < -90 ||
            place.latitude > 90 ||
            place.longitude < -180 ||
            place.longitude > 180) {
          throw const FormatException('Duplicate or invalid catalog place');
        }
        places.add(place);
      }
      if (places.length == total) return List.unmodifiable(places);
    }
    // A partial catalog must never be published as a successful complete load.
    throw const FormatException('Catalog pagination request limit reached');
  }

  Future<PlaceModel?> getPlaceDetail(int placeId) async {
    final response = await _apiClient.dio.get(
      '${ApiConstants.placesEndpoint}/$placeId',
    );
    return PlaceModel.fromJson(response.data as Map<String, dynamic>);
  }

  /// Phase C6: verified historical card, or null when the editorial dataset
  /// has no card for this place. Throws on transport/shape failures so the
  /// provider can distinguish «no history» from «history unavailable».
  Future<HistoricalContent?> getPlaceHistory(int placeId) async {
    final response = await _apiClient.dio.get(
      ApiConstants.placeHistoryEndpoint(placeId),
    );
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid history response');
    }
    final history = data['history'];
    if (history == null) return null;
    if (history is! Map<String, dynamic>) {
      throw const FormatException('Invalid historical card');
    }
    return HistoricalContent.fromJson(history);
  }

  Future<List<CategoryModel>> getCategories() async {
    final response = await _apiClient.dio.get(ApiConstants.categoriesEndpoint);
    return (response.data as List<dynamic>)
        .map((json) => CategoryModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<AutoWalkProposalResponseModel> proposeWalk({
    required double startLatitude,
    required double startLongitude,
    required int timeBudgetMinutes,
    List<PlaceCategoryEnum>? categories,
    bool preferUnusual = SmartWalkConfiguration.automaticPreferUnusual,
    int maxPlaces = 6,
  }) async {
    SmartWalkConfiguration.validateBudget(timeBudgetMinutes);
    final payload = {
      'start_point': {'latitude': startLatitude, 'longitude': startLongitude},
      'time_budget_minutes': timeBudgetMinutes,
      if (categories != null && categories.isNotEmpty)
        'categories': categories.map((c) => c.key).toList(),
      'prefer_unusual': preferUnusual,
      'max_places': maxPlaces,
    };

    final response = await _apiClient.dio.post(
      ApiConstants.routeProposeWalkEndpoint,
      data: payload,
    );
    return AutoWalkProposalResponseModel.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
