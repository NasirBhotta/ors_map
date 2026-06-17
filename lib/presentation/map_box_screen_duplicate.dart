import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:ors_map_test/services/map_box_drawing_service.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/api_key_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';
import 'package:ors_map_test/services/tts_service.dart';

class MapboxTestScreen extends StatefulWidget {
  const MapboxTestScreen({super.key});

  @override
  State<MapboxTestScreen> createState() => _MapboxTestScreenState();
}

class _MapboxTestScreenState extends State<MapboxTestScreen> {
  static const String _carModelSourceId = 'navigation-car-model-source';
  static const String _carModelLayerId = 'navigation-car-model-layer';
  static const String _carModelUri = 'asset://assets/lowpoly_car.glb';
  static const double _carModelBearingOffset = 90.0;
  static const double _carModelScale = 5.0;

  mapbox.MapboxMap? _mapboxMap;
  mapbox.Position? _currentPosition;

  MapboxRouteResult? _activeRoute;
  mapbox.Position? _activeDestination;

  MapboxNavigationService? _navService;
  bool _isNavigating = false;
  String _currentInstruction = '';
  double _currentSpeedKmh = 0.0;
  DateTime? _estimatedArrival;
  String _remainingDistanceText = '--';

  mapbox.PointAnnotationManager? _annotationManager;
  mapbox.PointAnnotation? _destinationMarker;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  List<_SearchPlace> _searchResults = [];
  bool _isSearching = false;
  String? _searchError;
  int _searchRequestId = 0;

  StreamSubscription<CompassEvent>? _compassSub;
  double? _compassHeading;
  double _mapBearing = 0.0;

  final TtsService _tts = TtsService();

  @override
  void initState() {
    super.initState();
    _tts.init();
    _startCompass();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _compassSub?.cancel();
    _tts.stop();
    _navService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          mapbox.MapWidget(
            key: const ValueKey('mapWidget'),
            styleUri: mapbox.MapboxStyles.STANDARD,
            onStyleLoadedListener: (_) async {
              await _configureMapStyle();
              await _setupLocationPuck();
              _startLocationUpdates();
            },
            onMapCreated: (controller) async {
              _mapboxMap = controller;
              _annotationManager =
                  await controller.annotations.createPointAnnotationManager();

              await _mapboxMap!.setCamera(
                mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates: mapbox.Position(73.0551, 33.7215),
                  ),
                  zoom: 17.0,
                  pitch: 60.0,
                  bearing: 45.0,
                ),
              );
              if (mounted) setState(() => _mapBearing = 45.0);

              _mapboxMap!.addInteraction(
                mapbox.TapInteraction.onMap((context) async {
                  if (_currentPosition == null) return;
                  if (_isNavigating) _stopNavigation();

                  final tapped = context.point.coordinates;
                  await _buildRouteToDestination(tapped);
                }),
              );
            },
          ),

          if (!_isNavigating)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: _buildSearchPanel(),
            ),

          Positioned(
            top: MediaQuery.of(context).padding.top + (_isNavigating ? 96 : 98),
            right: 16,
            child: _buildCompassButton(),
          ),

          if (_isNavigating && _currentInstruction.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: _buildNavCard(),
            ),

          if (_isNavigating)
            Positioned(
              bottom: 40,
              left: 16,
              right: 16,
              child: _buildBottomBar(),
            ),

          if (_activeRoute != null && !_isNavigating)
            Positioned(
              bottom: 40,
              left: 16,
              right: 16,
              child: _buildStartButton(),
            ),
        ],
      ),
    );
  }

  Future<void> _configureMapStyle() async {
    final style = _mapboxMap?.style;
    if (style == null) return;

    final configs = <String, Object>{
      'lightPreset': 'dusk',
      'show3dObjects': true,
      'showRoadLabels': true,
      'showTransitLabels': false,
      'showPointOfInterestLabels': false,
    };

    for (final entry in configs.entries) {
      try {
        await style.setStyleImportConfigProperty(
          'basemap',
          entry.key,
          entry.value,
        );
      } catch (_) {}
    }
  }

  void _startCompass() {
    _compassSub = FlutterCompass.events?.listen((event) {
      final heading = event.heading;
      if (heading == null || heading.isNaN) return;
      if (!mounted) return;
      setState(() => _compassHeading = (heading + 360) % 360);
    });
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    final trimmed = query.trim();

    if (trimmed.length < 2) {
      setState(() {
        _searchResults = [];
        _searchError = null;
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _searchPlaces(trimmed),
    );
  }

  Future<void> _searchPlaces(String query) async {
    final requestId = ++_searchRequestId;
    final current = _currentPosition;
    final mapboxToken = ApiKeyService.mapboxAccessToken;

    if (mapboxToken.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _searchError = 'Mapbox token missing';
      });
      return;
    }

    final params = <String, String>{
      'access_token': mapboxToken,
      'autocomplete': 'true',
      'limit': '6',
      'types': 'poi,address,place,locality,neighborhood',
      'language': 'en',
    };

    if (current != null) {
      params['proximity'] =
          '${current.lng.toDouble()},${current.lat.toDouble()}';
    }

    final uri = Uri.https(
      'api.mapbox.com',
      '/geocoding/v5/mapbox.places/$query.json',
      params,
    );

    try {
      final response = await http.get(uri);
      if (!mounted || requestId != _searchRequestId) return;

      if (response.statusCode != 200) {
        setState(() {
          _isSearching = false;
          _searchError = 'Search unavailable';
        });
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List? ?? [];
      setState(() {
        _searchResults =
            features
                .whereType<Map<String, dynamic>>()
                .map(_SearchPlace.fromJson)
                .where((place) => place != null)
                .cast<_SearchPlace>()
                .toList();
        _isSearching = false;
        _searchError = _searchResults.isEmpty ? 'No places found' : null;
      });
    } catch (_) {
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _isSearching = false;
        _searchError = 'Search unavailable';
      });
    }
  }

  Future<void> _selectSearchPlace(_SearchPlace place) async {
    _searchController.text = place.title;
    _searchFocusNode.unfocus();
    setState(() {
      _searchResults = [];
      _searchError = null;
      _isSearching = false;
    });
    await _buildRouteToDestination(mapbox.Position(place.lng, place.lat));
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchResults = [];
      _searchError = null;
      _isSearching = false;
    });
  }

  Future<void> _resetNorth() async {
    final map = _mapboxMap;
    if (map == null) return;

    await map.easeTo(
      mapbox.CameraOptions(bearing: 0.0),
      mapbox.MapAnimationOptions(duration: 500),
    );
    if (mounted) setState(() => _mapBearing = 0.0);
  }

  Future<void> _moveCameraToCurrentLocation() async {
    final current = _currentPosition;
    final map = _mapboxMap;
    if (current == null || map == null) return;

    await map.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: current),
        zoom: 17.0,
        pitch: 60.0,
        bearing: _mapBearing,
      ),
      mapbox.MapAnimationOptions(duration: 900),
    );
  }

  Future<void> _buildRouteToDestination(mapbox.Position destination) async {
    final current = _currentPosition;
    final map = _mapboxMap;
    if (current == null || map == null) return;

    final result = await MapboxRouteService.getRoute(
      fromLng: current.lng.toDouble(),
      fromLat: current.lat.toDouble(),
      toLng: destination.lng.toDouble(),
      toLat: destination.lat.toDouble(),
    );
    if (result == null) return;

    await _addDestinationMarker(destination);

    final drawing = MapboxDrawingService(mapboxMap: map);
    await drawing.drawRoute(result);
    await drawing.fitRouteBounds(
      fromLng: current.lng.toDouble(),
      fromLat: current.lat.toDouble(),
      toLng: destination.lng.toDouble(),
      toLat: destination.lat.toDouble(),
    );

    setState(() {
      _activeRoute = result;
      _activeDestination = destination;
      _currentInstruction = '';
      _remainingDistanceText = result.distanceText;
      _estimatedArrival = DateTime.now().add(
        Duration(seconds: result.durationSeconds.toInt()),
      );
    });
  }

  Future<void> _clearAll() async {
    final map = _mapboxMap;
    if (map != null) {
      final drawing = MapboxDrawingService(mapboxMap: map);
      await drawing.clearRoute();
    }

    if (_destinationMarker != null && _annotationManager != null) {
      await _annotationManager!.delete(_destinationMarker!);
      _destinationMarker = null;
    }

    await _removeCarModelLayer();

    setState(() {
      _activeRoute = null;
      _activeDestination = null;
      _currentInstruction = '';
      _currentSpeedKmh = 0.0;
      _remainingDistanceText = '--';
    });
  }

  void _startNavigation() async {
    final route = _activeRoute;
    final destination = _activeDestination;
    final map = _mapboxMap;
    if (route == null || destination == null || map == null) return;

    if (route.steps.isNotEmpty) {
      _tts.speak(route.steps.first.instruction);
    }

    await _setupNavigationCarPuck();

    if (_currentPosition != null) {
      final initialBearing = _initialRouteBearing(route);
      await map.flyTo(
        _navigationCamera(
          lat: _currentPosition!.lat.toDouble(),
          lng: _currentPosition!.lng.toDouble(),
          bearing: initialBearing,
        ),
        mapbox.MapAnimationOptions(duration: 1000),
      );
      if (mounted) setState(() => _mapBearing = initialBearing);
    }

    _navService?.dispose();
    _navService = MapboxNavigationService(
      mapboxMap: map,
      compassHeadingProvider: () => _compassHeading,
      onLocationUpdate: (position, speedKmh, bearing) {
        setState(() {
          _currentSpeedKmh = speedKmh;
          _mapBearing = bearing;
        });
      },
      onStepChanged: (index, step) {
        setState(() => _currentInstruction = step.instruction);
        _tts.speak(step.instruction);
      },
      onReroute: (msg) {
        setState(() => _currentInstruction = msg);
        _tts.speak('Rerouting, please wait');
      },
      onRouteChanged: (newRoute) async {
        final drawing = MapboxDrawingService(mapboxMap: map);
        await drawing.drawRoute(newRoute);
        if (!mounted) return;
        setState(() {
          _activeRoute = newRoute;
          _remainingDistanceText = newRoute.distanceText;
          _estimatedArrival = DateTime.now().add(
            Duration(seconds: newRoute.durationSeconds.toInt()),
          );
        });
      },
      onRouteProgress: (
        progressRoute,
        closestRouteIndex,
        remainingDistanceMeters,
        remainingDurationSeconds,
      ) async {
        final drawing = MapboxDrawingService(mapboxMap: map);
        await drawing.updateRouteProgress(progressRoute, closestRouteIndex);
        if (!mounted) return;
        setState(() {
          _remainingDistanceText = _formatDistance(remainingDistanceMeters);
          _estimatedArrival = DateTime.now().add(
            Duration(seconds: remainingDurationSeconds.toInt()),
          );
        });
      },
      onDestinationReached: () async {
        _tts.speak('You have reached your destination!');
        await _clearAll();
        await _setupLocationPuck();
        _resetCameraToCurrentLocation();
        if (mounted) setState(() => _isNavigating = false);
      },
    );

    _navService!.startNavigation(route: route, destination: destination);

    setState(() {
      _isNavigating = true;
      _currentInstruction =
          route.steps.isNotEmpty ? route.steps.first.instruction : 'Continue';
      _remainingDistanceText = route.distanceText;
    });
  }

  void _stopNavigation() {
    _navService?.stopNavigation();
    _tts.stop();
    _setupLocationPuck();
    _resetCameraToCurrentLocation();
    _clearAll();
    setState(() => _isNavigating = false);
  }

  mapbox.CameraOptions _navigationCamera({
    required double lat,
    required double lng,
    required double bearing,
  }) {
    return mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: 18.7,
      pitch: 72.0,
      bearing: bearing,
      padding: mapbox.MbxEdgeInsets(top: 80, left: 0, bottom: 300, right: 0),
    );
  }

  void _resetCameraToCurrentLocation() {
    final current = _currentPosition;
    final map = _mapboxMap;
    if (current == null || map == null) return;

    map.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: current),
        zoom: 16.0,
        pitch: 0.0,
        bearing: 0.0,
        padding: mapbox.MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
      ),
      mapbox.MapAnimationOptions(duration: 1200),
    );
    if (mounted) setState(() => _mapBearing = 0.0);
  }

  Future<void> _setupLocationPuck() async {
    await _mapboxMap?.location.updateSettings(
      mapbox.LocationComponentSettings(
        enabled: true,
        pulsingEnabled: true,
        pulsingColor: Colors.blue.toARGB32(),
        pulsingMaxRadius: 50.0,
      ),
    );
  }

  Future<void> _setupNavigationCarPuck() async {
    await _mapboxMap?.location.updateSettings(
      mapbox.LocationComponentSettings(
        enabled: true,
        puckBearingEnabled: true,
        puckBearing: mapbox.PuckBearing.COURSE,
        locationPuck: mapbox.LocationPuck(
          locationPuck3D: mapbox.LocationPuck3D(
            modelUri: _carModelUri,
            modelScale: const [_carModelScale, _carModelScale, _carModelScale],
            modelRotation: const [0.0, 0.0, _carModelBearingOffset],
            modelScaleMode: mapbox.ModelScaleMode.MAP,
            modelCastShadows: true,
            modelReceiveShadows: true,
            modelEmissiveStrength: 0.7,
            modelOpacity: 1.0,
          ),
        ),
      ),
    );
  }

  void _startLocationUpdates() async {
    final serviceEnabled =
        await geolocator.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    var permission = await geolocator.Geolocator.checkPermission();
    if (permission == geolocator.LocationPermission.denied) {
      permission = await geolocator.Geolocator.requestPermission();
    }
    if (permission == geolocator.LocationPermission.denied ||
        permission == geolocator.LocationPermission.deniedForever) {
      return;
    }

    final last = await geolocator.Geolocator.getLastKnownPosition();
    if (last != null) {
      _currentPosition = mapbox.Position(last.longitude, last.latitude);
      await _mapboxMap?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(last.longitude, last.latitude),
          ),
          zoom: 17.0,
          pitch: 60.0,
        ),
        mapbox.MapAnimationOptions(duration: 1500),
      );
    }

    geolocator.Geolocator.getPositionStream(
      locationSettings: const geolocator.LocationSettings(
        accuracy: geolocator.LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      ),
    ).listen((position) {
      _currentPosition = mapbox.Position(position.longitude, position.latitude);
    });
  }

  Future<void> _addDestinationMarker(mapbox.Position position) async {
    if (_annotationManager == null) return;

    if (_destinationMarker != null) {
      await _annotationManager!.delete(_destinationMarker!);
    }

    final markerImage = await _createMarkerImage();
    _destinationMarker = await _annotationManager!.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: position),
        image: markerImage,
        iconSize: 1.0,
        iconAnchor: mapbox.IconAnchor.CENTER,
      ),
    );
  }

  Future<void> _removeCarModelLayer() async {
    final map = _mapboxMap;
    if (map == null) return;

    try {
      await map.style.removeStyleLayer(_carModelLayerId);
    } catch (_) {}
    try {
      await map.style.removeStyleSource(_carModelSourceId);
    } catch (_) {}
  }

  Future<Uint8List> _createMarkerImage() async {
    const size = 80.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      24,
      Paint()..color = Colors.red,
    );
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      24,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );

    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Widget _buildSearchPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(14),
          color: Colors.white,
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              if (_searchResults.isNotEmpty) {
                _selectSearchPlace(_searchResults.first);
              } else {
                _onSearchChanged(value);
              }
            },
            decoration: InputDecoration(
              hintText: 'Search destination',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon:
                  _isSearching
                      ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                      : _searchController.text.isNotEmpty
                      ? IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close_rounded),
                      )
                      : IconButton(
                        onPressed: _moveCameraToCurrentLocation,
                        icon: const Icon(Icons.my_location_rounded),
                      ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 15,
              ),
            ),
          ),
        ),
        if (_searchResults.isNotEmpty || _searchError != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child:
                _searchResults.isNotEmpty
                    ? ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final place = _searchResults[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.place_rounded,
                            color: Color(0xFF2563EB),
                          ),
                          title: Text(
                            place.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            place.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectSearchPlace(place),
                        );
                      },
                    )
                    : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _searchError!,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
          ),
      ],
    );
  }

  Widget _buildCompassButton() {
    final headingText =
        _compassHeading == null ? '--' : '${_compassHeading!.round()}';

    return Material(
      elevation: 7,
      color: Colors.white,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _resetNorth,
        child: SizedBox(
          width: 54,
          height: 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: -_mapBearing * pi / 180,
                child: const Icon(
                  Icons.navigation_rounded,
                  color: Colors.red,
                  size: 28,
                ),
              ),
              Positioned(
                bottom: 6,
                child: Text(
                  headingText,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.navigation, color: Colors.yellow, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _currentInstruction,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GestureDetector(
            onTap: _stopNavigation,
            child: const Icon(Icons.close, color: Colors.red),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    String arrivalText = '--';
    if (_estimatedArrival != null) {
      final h = _estimatedArrival!.hour;
      final m = _estimatedArrival!.minute.toString().padLeft(2, '0');
      final amPm = h >= 12 ? 'PM' : 'AM';
      final hour12 = h > 12 ? h - 12 : (h == 0 ? 12 : h);
      arrivalText = '$hour12:$m $amPm';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _barItem('${_currentSpeedKmh.toInt()}', 'km/h', Colors.white),
          Container(height: 40, width: 1, color: Colors.grey),
          _barItem(arrivalText, 'Arrival', Colors.yellow),
          Container(height: 40, width: 1, color: Colors.grey),
          _barItem(_remainingDistanceText, 'Left', Colors.white),
        ],
      ),
    );
  }

  Widget _barItem(String value, String label, Color valueColor) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    );
  }

  Widget _buildStartButton() {
    return ElevatedButton.icon(
      onPressed: () async => _startNavigation(),
      icon: const Icon(Icons.navigation),
      label: Text(
        'Start - ${_activeRoute?.durationText ?? ''}',
        style: const TextStyle(fontSize: 16),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  double _initialRouteBearing(MapboxRouteResult route) {
    if (route.coordinates.length < 2) return 0;
    final first = route.coordinates.first;
    final next = route.coordinates[1];
    return _bearingBetween(first[1], first[0], next[1], next[0]);
  }

  double _bearingBetween(double lat1, double lng1, double lat2, double lng2) {
    final lat1Rad = lat1 * pi / 180;
    final lat2Rad = lat2 * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final y = sin(dLng) * cos(lat2Rad);
    final x =
        cos(lat1Rad) * sin(lat2Rad) - sin(lat1Rad) * cos(lat2Rad) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }
}

class _SearchPlace {
  final String title;
  final String subtitle;
  final double lat;
  final double lng;

  const _SearchPlace({
    required this.title,
    required this.subtitle,
    required this.lat,
    required this.lng,
  });

  static _SearchPlace? fromJson(Map<String, dynamic> json) {
    final center = json['center'];
    if (center is! List || center.length < 2) return null;

    final lng = (center[0] as num?)?.toDouble();
    final lat = (center[1] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final title =
        (json['text'] ?? json['place_name'] ?? 'Destination').toString();
    final placeName = (json['place_name'] ?? title).toString();
    final subtitle =
        placeName == title
            ? (json['place_type'] as List? ?? const [])
                .map((type) => type.toString())
                .join(', ')
            : placeName;

    return _SearchPlace(title: title, subtitle: subtitle, lat: lat, lng: lng);
  }
}
