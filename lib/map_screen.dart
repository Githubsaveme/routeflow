import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;

import 'search_service.dart';

/// Main navigation and live-tracking map screen widget.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  // ===========================================================================
  // MAP & LOCATION STATE
  // ===========================================================================

  /// Controller for interacting with the FlutterMap instance
  final MapController mapController = MapController();

  /// Current live location of the driver/vehicle
  LatLng? currentLocation;

  /// Current destination location (if any)
  LatLng? destination;

  /// List of coordinates forming the navigation route path
  List<LatLng> routePoints = [];

  /// Current index along [routePoints] for progress tracking
  int routeIndex = 0;

  // ===========================================================================
  // SMOOTH INTERPOLATION STATE (60 FPS PHYSICS ENGINE)
  // ===========================================================================

  /// Target coordinates received from GPS update
  LatLng? targetLocation;

  /// Intermediate location continuously interpolated for smooth vehicle rendering
  LatLng? displayLocation;

  /// Target rotation bearing in radians
  double targetRotation = 0.0;

  /// Intermediate vehicle rotation in radians continuously interpolated
  double displayRotation = 0.0;

  /// Previous GPS coordinate before the latest update
  LatLng? previousLocation;

  /// Ticker providing high-precision per-frame callbacks for smooth movement
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// Smooth interpolation speed coefficients per millisecond
  static const double _rotationSpeedPerMs = 0.015;
  static const double _movementSpeedPerMs = 0.08;

  /// Last camera center coordinate to prevent unnecessary camera repositioning
  LatLng? lastCameraCenter;

  // ===========================================================================
  // UI & SETTINGS STATE
  // ===========================================================================

  /// Loading state indicator for route calculation network requests
  bool isLoading = false;

  /// Active stream subscription for live location updates
  StreamSubscription<loc.LocationData>? positionStream;

  /// Location service instance
  final loc.Location _locationService = loc.Location();

  /// Currently selected map style ('standard' for OpenStreetMap, 'satellite' for ArcGIS)
  String _mapType = 'standard';

  /// Toggle for route polyline visibility on the map
  bool _showPolyline = true;

  /// Currently selected vehicle marker asset image path
  String _selectedVehicle = 'assets/car.png';

  /// List of selectable vehicle options
  final List<Map<String, String>> _vehicles = const [
    {'name': 'Car', 'asset': 'assets/car.png'},
    {'name': 'Bike', 'asset': 'assets/bike_im.png'},
  ];

  // ===========================================================================
  // LIFECYCLE METHODS
  // ===========================================================================

  @override
  void initState() {
    super.initState();

    // Start ticker for continuous per-millisecond smooth vehicle interpolation
    _ticker = createTicker(_onTick);
    _ticker.start();

    // Ensure map renders first on screen before prompting location permissions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLocation();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    positionStream?.cancel();
    super.dispose();
  }

  // ===========================================================================
  // ROUTING & DESTINATION METHODS
  // ===========================================================================

  /// Sets destination coordinates and triggers route calculation and camera positioning.
  void goToDestination(double latitude, double longitude) {
    final dest = LatLng(latitude, longitude);

    setState(() {
      destination = dest;
    });

    if (currentLocation != null) {
      _calculateRoute(currentLocation!, dest);

      // Adjust camera bounds to fit both current location and destination
      final bounds = LatLngBounds.fromPoints([currentLocation!, dest]);
      mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
      );
    }
  }

  /// Calculates driving route between [start] and [end] using OSRM API.
  Future<void> _calculateRoute(LatLng start, LatLng end) async {
    try {
      routePoints = [];
      routeIndex = 0;

      setState(() {
        isLoading = true;
      });

      final String url =
          'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson';

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final coordinates = route['geometry']['coordinates'] as List;

          for (final coord in coordinates) {
            routePoints.add(LatLng(coord[1].toDouble(), coord[0].toDouble()));
          }
        }
      }

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Route calculation error: $e');
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }

      // Fallback: create linear route if routing request fails
      routePoints = [];
      routeIndex = 0;
      const int numPoints = 50;
      for (int i = 0; i <= numPoints; i++) {
        final t = i / numPoints;
        final lat = start.latitude + (end.latitude - start.latitude) * t;
        final lon = start.longitude + (end.longitude - start.longitude) * t;
        routePoints.add(LatLng(lat, lon));
      }
      if (mounted) {
        setState(() {});
      }
    }
  }

  // ===========================================================================
  // SMOOTH INTERPOLATION TICKER (PER FRAME / MILLISECOND PHYSICS)
  // ===========================================================================

  /// Per-frame callback providing ultra-smooth vehicle movement and camera tracking
  void _onTick(Duration elapsed) {
    if (!mounted) return;

    final deltaMs = (elapsed - _lastElapsed).inMilliseconds.toDouble();
    _lastElapsed = elapsed;

    // Skip frame if delta is invalid or app was paused/resumed
    if (deltaMs <= 0 || deltaMs > 100) return;

    bool needsUpdate = false;

    // 1. Smooth rotation interpolation
    if ((targetRotation - displayRotation).abs() > 0.005) {
      double diff = targetRotation - displayRotation;

      // Wrap angle for shortest rotation path
      while (diff > math.pi) {
        diff -= 2 * math.pi;
      }
      while (diff < -math.pi) {
        diff += 2 * math.pi;
      }

      final rotationStep = diff * _rotationSpeedPerMs * deltaMs;
      displayRotation += rotationStep;

      // Normalize rotation angle
      while (displayRotation > math.pi) {
        displayRotation -= 2 * math.pi;
      }
      while (displayRotation < -math.pi) {
        displayRotation += 2 * math.pi;
      }

      needsUpdate = true;
    }

    // 2. Smooth position interpolation
    if (targetLocation != null && displayLocation != null) {
      final distance = const Distance().as(
        LengthUnit.Meter,
        displayLocation!,
        targetLocation!,
      );

      if (distance > 0.01) {
        final movementFactor = _movementSpeedPerMs * deltaMs;

        displayLocation = LatLng(
          _lerp(
            displayLocation!.latitude,
            targetLocation!.latitude,
            movementFactor,
          ),
          _lerp(
            displayLocation!.longitude,
            targetLocation!.longitude,
            movementFactor,
          ),
        );

        needsUpdate = true;
      } else if (distance <= 0.01) {
        displayLocation = targetLocation;
      }
    }

    // 3. Smooth camera follow updates
    if (displayLocation != null && mapController.camera.zoom >= 14) {
      if (lastCameraCenter == null ||
          const Distance().as(
                LengthUnit.Meter,
                lastCameraCenter!,
                displayLocation!,
              ) >
              0.5) {
        mapController.move(displayLocation!, mapController.camera.zoom);
        lastCameraCenter = displayLocation;
      }
    }

    if (needsUpdate && mounted) {
      setState(() {});
    }
  }

  /// Linear interpolation helper with clamped coefficient
  double _lerp(double a, double b, double t) {
    final clampedT = t.clamp(0.0, 1.0);
    return a + (b - a) * clampedT;
  }

  // ===========================================================================
  // LOCATION SERVICES & STREAM MANAGEMENT
  // ===========================================================================

  /// Initializes location service checks, permissions, and streams updates.
  Future<void> _initLocation() async {
    try {
      // Check location service status
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) return;
      }

      // Check location permission status
      loc.PermissionStatus permissionGranted =
          await _locationService.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await _locationService.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) return;
      }

      // Configure location update frequency
      await _locationService.changeSettings(
        accuracy: loc.LocationAccuracy.high,
        interval: 1000,
        distanceFilter: 1,
      );

      // Fetch initial location
      final pos = await _locationService.getLocation();
      final initialLatLng = LatLng(pos.latitude, pos.longitude);
      if (mounted) {
        setState(() {
          currentLocation = initialLatLng;
          targetLocation = initialLatLng;
          displayLocation = initialLatLng;
          previousLocation = initialLatLng;
        });
        mapController.move(initialLatLng, 16);
      }

      // Listen for continuous GPS updates
      positionStream = _locationService.onLocationChanged.listen((pos) {
        if (mounted) {
          updateVehiclePosition(LatLng(pos.latitude, pos.longitude));
        }
      });
    } catch (e) {
      debugPrint('Location initialization error: $e');
    }
  }

  /// Processes incoming vehicle position updates and triggers bearing/route progress tracking.
  void updateVehiclePosition(LatLng newPos) {
    if (currentLocation == null) {
      currentLocation = newPos;
      targetLocation = newPos;
      displayLocation = newPos;
      previousLocation = newPos;
      return;
    }

    final movementDistance = const Distance().as(
      LengthUnit.Meter,
      currentLocation!,
      newPos,
    );

    if (movementDistance > 0.05) {
      final newBearing = _bearingBetween(currentLocation!, newPos);

      targetRotation = newBearing;
      previousLocation = currentLocation;
      currentLocation = newPos;
      targetLocation = newPos;
    }

    // Track progress along current route
    if (routePoints.length > 1 && routeIndex < routePoints.length - 1) {
      final nextPoint = routePoints[routeIndex + 1];
      final distanceToNext = const Distance().as(
        LengthUnit.Meter,
        newPos,
        nextPoint,
      );

      if (distanceToNext < 8) {
        routeIndex++;
        if (routeIndex < routePoints.length - 1) {
          targetRotation = _bearingBetween(
            routePoints[routeIndex],
            routePoints[routeIndex + 1],
          );
        }
      }
    }

    // Check if reached destination
    if (destination != null) {
      final distanceToDestination = const Distance().as(
        LengthUnit.Meter,
        newPos,
        destination!,
      );

      if (distanceToDestination < 10) {
        _onReachedDestination();
      }
    }
  }

  /// Callback executed when the vehicle arrives at destination.
  void _onReachedDestination() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🎉 You have reached your destination!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ),
    );

    setState(() {
      destination = null;
      routePoints.clear();
      routeIndex = 0;
    });
  }

  /// Calculates bearing angle in radians between [start] and [end] coordinates.
  double _bearingBetween(LatLng start, LatLng end) {
    final lat1 = start.latitude * math.pi / 180;
    final lon1 = start.longitude * math.pi / 180;
    final lat2 = end.latitude * math.pi / 180;
    final lon2 = end.longitude * math.pi / 180;

    final dLon = lon2 - lon1;

    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return math.atan2(y, x);
  }

  // ===========================================================================
  // MAP CONTROLS & UI EVENT HANDLERS
  // ===========================================================================

  /// Sets map destination when user taps on map screen
  void _onMapTap(LatLng latLng) {
    if (currentLocation == null) return;
    goToDestination(latLng.latitude, latLng.longitude);
  }

  /// Zooms in map camera
  void _zoomIn() {
    final currentZoom = mapController.camera.zoom;
    mapController.move(
      mapController.camera.center,
      (currentZoom + 1).clamp(1.0, 18.0),
    );
  }

  /// Zooms out map camera
  void _zoomOut() {
    final currentZoom = mapController.camera.zoom;
    mapController.move(
      mapController.camera.center,
      (currentZoom - 1).clamp(1.0, 18.0),
    );
  }

  /// Centers map camera over user's current live location
  void _centerOnUser() {
    if (currentLocation != null) {
      mapController.move(currentLocation!, 16);
    }
  }

  /// Shows map layer selection dialog (Standard vs Satellite)
  void _changeMapType() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Map Type'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('OpenStreetMap'),
              leading: Icon(
                Icons.map,
                color: _mapType == 'standard' ? Colors.blue : Colors.grey,
              ),
              selected: _mapType == 'standard',
              onTap: () {
                setState(() => _mapType = 'standard');
                Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('Satellite'),
              leading: Icon(
                Icons.satellite_alt,
                color: _mapType == 'satellite' ? Colors.blue : Colors.grey,
              ),
              selected: _mapType == 'satellite',
              onTap: () {
                setState(() => _mapType = 'satellite');
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Toggles visibility of route polyline
  void _togglePolyline() {
    setState(() {
      _showPolyline = !_showPolyline;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_showPolyline ? 'Route shown' : 'Route hidden'),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  /// Returns current map tile server URL based on [_mapType]
  String _getTileUrl() {
    switch (_mapType) {
      case 'satellite':
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case 'standard':
      default:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }
  }

  /// Opens location search delegate dialog
  void _showSearchDialog() {
    showSearch(
      context: context,
      delegate: _LocationSearchDelegate(
        onLocationSelected: (LocationResult result) {
          goToDestination(result.latitude, result.longitude);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Navigating to ${result.displayName}'),
              backgroundColor: Colors.blue,
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // BUILD METHOD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. FlutterMap Tile & Marker Layers
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: currentLocation ?? const LatLng(0, 0),
              initialZoom: 16,
              onTap: (_, latLng) => _onMapTap(latLng),
              maxZoom: 18,
              minZoom: 5,
            ),
            children: [
              TileLayer(
                retinaMode: true,
                urlTemplate: _getTileUrl(),
                subdomains: const [],
                userAgentPackageName: 'com.example.routeflow',
              ),

              // Route Polyline Layer
              if (_showPolyline && routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5,
                      color: const Color(0xB32196F3),
                    ),
                  ],
                ),

              // Markers Layer (Vehicle + Destination)
              MarkerLayer(
                markers: [
                  if (displayLocation != null)
                    Marker(
                      point: displayLocation!,
                      width: 50,
                      height: 50,
                      child: Transform.rotate(
                        angle: displayRotation + (math.pi / 2),
                        child: Image.asset(
                          _selectedVehicle,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  if (destination != null)
                    Marker(
                      point: destination!,
                      width: 50,
                      height: 50,
                      child: const Icon(
                        Icons.location_on,
                        size: 50,
                        color: Colors.red,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // 2. Navigation / Search Header Card
          if (destination != null && currentLocation != null)
            Positioned(
              top: 50,
              left: 16,
              right: 16,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.navigation,
                        color: Colors.blue,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Navigating to destination',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              '${(const Distance().as(LengthUnit.Meter, currentLocation!, destination!) / 1000).toStringAsFixed(2)} km away',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          setState(() {
                            destination = null;
                            routePoints.clear();
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Positioned(
              top: 50,
              left: 16,
              right: 16,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _showSearchDialog,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.search, color: Colors.grey),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Where to go?',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                        ),
                        Icon(Icons.location_on, color: Colors.red),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 3. Right Floating Map Action Controls
          Positioned(
            right: 16,
            bottom: 100,
            child: Column(
              children: [
                _buildControlButton(icon: Icons.add, onPressed: _zoomIn),
                const SizedBox(height: 8),
                _buildControlButton(icon: Icons.remove, onPressed: _zoomOut),
                const SizedBox(height: 8),
                _buildControlButton(
                  icon: Icons.my_location,
                  onPressed: _centerOnUser,
                  color: Colors.blue,
                ),
                const SizedBox(height: 8),
                _buildControlButton(
                  icon: Icons.layers,
                  onPressed: _changeMapType,
                  color: Colors.purple,
                ),
                const SizedBox(height: 8),
                _buildControlButton(
                  icon: _showPolyline ? Icons.route : Icons.route_outlined,
                  onPressed: _togglePolyline,
                  color: _showPolyline ? Colors.green : Colors.grey,
                ),
              ],
            ),
          ),

          // 4. Bottom Vehicle Selector Card
          Positioned(
            left: 16,
            bottom: 24,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(16),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _vehicles.map((vehicle) {
                    final isSelected = _selectedVehicle == vehicle['asset'];
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedVehicle = vehicle['asset']!;
                        });
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Vehicle changed to ${vehicle['name']}',
                            ),
                            duration: const Duration(milliseconds: 800),
                          ),
                        );
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.blue.shade50
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? Colors.blue
                                : Colors.grey.shade300,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Image.asset(
                              vehicle['asset']!,
                              width: 28,
                              height: 28,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              vehicle['name']!,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSelected
                                    ? Colors.blue
                                    : Colors.black87,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),

          // 5. Route Calculation Loading Overlay
          if (isLoading)
            Container(
              color: const Color(0x66000000),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Helper widget for rendering rounded control buttons
  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    Color color = Colors.black,
  }) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }
}

// =============================================================================
// LOCATION SEARCH DELEGATE
// =============================================================================

/// Custom [SearchDelegate] for searching destination locations via Nominatim API.
class _LocationSearchDelegate extends SearchDelegate<LocationResult> {
  final Function(LocationResult) onLocationSelected;

  _LocationSearchDelegate({required this.onLocationSelected});

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(
          context,
          const LocationResult(
            name: '',
            latitude: 0,
            longitude: 0,
            displayName: '',
          ),
        );
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(child: Text('Enter a destination to search'));
    }

    return FutureBuilder<List<LocationResult>>(
      future: SearchService.searchLocations(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final results = snapshot.data ?? [];

        if (results.isEmpty) {
          return const Center(child: Text('No locations found'));
        }

        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return ListTile(
              leading: const Icon(Icons.location_on, color: Colors.red),
              title: Text(result.name),
              subtitle: Text(
                result.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                onLocationSelected(result);
                close(context, result);
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_on, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('Search for a destination'),
          ],
        ),
      );
    }

    return FutureBuilder<List<LocationResult>>(
      future: SearchService.searchLocations(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final results = snapshot.data ?? [];

        if (results.isEmpty) {
          return const Center(child: Text('No suggestions'));
        }

        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return ListTile(
              leading: const Icon(Icons.location_on, color: Colors.red),
              title: Text(result.name),
              subtitle: Text(
                result.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                query = result.name;
                onLocationSelected(result);
                close(context, result);
              },
            );
          },
        );
      },
    );
  }
}
