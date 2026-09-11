import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Data model representing a geocoded location result.
class LocationResult {
  final String name;
  final double latitude;
  final double longitude;
  final String displayName;

  const LocationResult({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.displayName,
  });
}

/// Service class handling location searches and reverse geocoding
/// using OpenStreetMap's Nominatim API.
class SearchService {
  static const String _nominatimSearchUrl =
      'https://nominatim.openstreetmap.org/search';
  static const String _nominatimReverseUrl =
      'https://nominatim.openstreetmap.org/reverse';

  /// Searches for locations matching [query] using the Nominatim API.
  static Future<List<LocationResult>> searchLocations(String query) async {
    if (query.trim().isEmpty) return [];

    try {
      final response = await http
          .get(
            Uri.parse(
              '$_nominatimSearchUrl?q=${Uri.encodeComponent(query)}&format=json&limit=10',
            ),
            headers: {'User-Agent': 'RouteFlowApp/1.0'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map(
              (item) => LocationResult(
                name: item['name'] ?? '',
                latitude: double.parse(item['lat'].toString()),
                longitude: double.parse(item['lon'].toString()),
                displayName: item['display_name'] ?? item['name'] ?? '',
              ),
            )
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('Search Service Error: $e');
      return [];
    }
  }

  /// Reverse geocodes a [LatLng] coordinate to retrieve a human-readable address.
  static Future<String> reverseGeocode(LatLng location) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              '$_nominatimReverseUrl?lat=${location.latitude}&lon=${location.longitude}&format=json',
            ),
            headers: {'User-Agent': 'RouteFlowApp/1.0'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['display_name'] ?? 'Unknown location';
      }
      return 'Unknown location';
    } catch (e) {
      debugPrint('Reverse Geocode Error: $e');
      return 'Unknown location';
    }
  }
}
