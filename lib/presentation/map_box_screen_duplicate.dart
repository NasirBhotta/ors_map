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
  static const double _carModelBearingOffset = 180.0;
  static const double _carModelScale = 2.0;
  static const Color _accentBlue = Color(0xFF2563EB);
  static const Color _successGreen = Color(0xFF16A34A);
  static const Color _warningAmber = Color(0xFFFACC15);
  static const Color _ink = Color(0xFF0F172A);
  static const Color _mutedInk = Color(0xFF64748B);
  static const Color _panelBorder = Color(0xFFE2E8F0);
  static const double _panelRadius = 8.0;

  mapbox.MapboxMap? _mapboxMap;
  mapbox.Position? _currentPosition;

  MapboxRouteResult? _activeRoute;
  mapbox.Position? _activeDestination;

  MapboxNavigationService? _navService;
  bool _isNavigating = false;
  bool _isFollowingCamera = true;
  String _currentInstruction = '';
  double _currentSpeedKmh = 0.0;
  int? _currentSpeedLimit;
  List<MapboxStep> _upcomingSteps = [];
  bool _isNavCardExpanded = false;
  DateTime? _estimatedArrival;
  String _remainingDistanceText = '--';
  bool _ttsEnabled = true;
  bool _showingRouteOverview = false;
  mapbox.PointAnnotationManager? _annotationManager;
  mapbox.PointAnnotation? _destinationMarker;
  static const double _carLngOffset = 0.000000;
  static const double _carLatOffset = 0.000009;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  List<_SearchPlace> _searchResults = [];
  bool _isSearching = false;
  String? _searchError;
  int _searchRequestId = 0;
  Timer? _recenterTimer;
  Timer? _carAnimationTimer;
  mapbox.Position? _displayCarPosition;
  double? _displayCarBearing;
  mapbox.Position? _carTargetPosition;
  double _carTargetBearing = 0.0;
  double _carTargetSpeedMps = 0.0;
  double? _displayCarRouteDistance;
  double? _carTargetRouteDistance;
  DateTime? _carTargetAt;
  DateTime? _lastCarFrameAt;
  DateTime? _lastRouteProgressPaintAt;
  bool _routeProgressPaintInFlight = false;
  final List<double> _displayRouteDistanceAtIndex = [];

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
    _recenterTimer?.cancel();
    _carAnimationTimer?.cancel();
    _resetCarAnimationState();
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
      body: SafeArea(
        child: Stack(
          children: [
            mapbox.MapWidget(
              key: const ValueKey('mapWidget'),
              styleUri: mapbox.MapboxStyles.STANDARD,
              onScrollListener: _handleNavigationMapGesture,
              onZoomListener: _handleNavigationMapGesture,
              mapOptions: mapbox.MapOptions(
                pixelRatio: MediaQuery.of(context).devicePixelRatio,
              ),
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

                _mapboxMap!.compass.updateSettings(
                  mapbox.CompassSettings(enabled: false),
                );

                _mapboxMap!.scaleBar.updateSettings(
                  mapbox.ScaleBarSettings(enabled: false),
                );

                _mapboxMap!.logo.updateSettings(
                  mapbox.LogoSettings(enabled: false),
                );

                _mapboxMap!.attribution.updateSettings(
                  mapbox.AttributionSettings(enabled: false),
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
                top: 10,
                left: 16,
                right: 16,
                child: _buildSearchPanel(),
              ),

            Positioned(
              top:
                  MediaQuery.of(context).padding.top +
                  (_isNavigating ? 96 : 98),
              right: 16,
              child: _buildCompassButton(),
            ),

            if (_isNavigating)
              Positioned(
                top: MediaQuery.of(context).padding.top + 162,
                right: 16,
                child: _buildTtsButton(),
              ),

            if (_isNavigating)
              Positioned(
                top: MediaQuery.of(context).padding.top + 228,
                right: 16,
                child: _buildRouteOverviewButton(),
              ),

            if (_isNavigating && !_isFollowingCamera)
              Positioned(
                top: MediaQuery.of(context).padding.top + 294,
                right: 16,
                child: _buildRecenterButton(),
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

            if (_isNavigating)
              Positioned(bottom: 130, left: 16, child: _buildSpeedLimitSign()),

            if (_activeRoute != null && !_isNavigating)
              Positioned(
                bottom: 40,
                left: 16,
                right: 16,
                child: _buildStartButton(),
              ),
          ],
        ),
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

    final layers = await style.getStyleLayers();
    for (final layer in layers) {
      print("layers are ${layer!.type} and id is ${layer.id}");
      debugPrint(layer.id);
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

  void _safeSpeak(String text) {
    if (_ttsEnabled) _tts.speak(text);
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

    await map.flyTo(
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

  void _handleNavigationMapGesture(mapbox.MapContentGestureContext context) {
    if (!_isNavigating) return;
    if (_showingRouteOverview) return;

    _navService?.setFollowModeEnabled(false);
    _recenterTimer?.cancel();
    _recenterTimer = Timer(const Duration(seconds: 4), _recenterNavigation);

    if (_isFollowingCamera && mounted) {
      setState(() => _isFollowingCamera = false);
    }
  }

  Future<void> _recenterNavigation() async {
    _recenterTimer?.cancel();
    _recenterTimer = null;

    final current = _currentPosition;
    final map = _mapboxMap;
    if (!_isNavigating || current == null || map == null) return;

    _navService?.setFollowModeEnabled(true);
    await map.flyTo(
      _navigationCamera(
        lat: current.lat.toDouble(),
        lng: current.lng.toDouble(),
        bearing: _mapBearing,
      ),
      mapbox.MapAnimationOptions(duration: 550),
    );

    if (mounted) {
      setState(() {
        _isFollowingCamera = true;
        _showingRouteOverview = false;
      });
    }
  }

  Future<void> _toggleRouteOverview() async {
    final route = _activeRoute;
    final current = _currentPosition;
    final dest = _activeDestination;
    final map = _mapboxMap;
    if (route == null || current == null || dest == null || map == null) return;

    _recenterTimer?.cancel();
    _recenterTimer = null;

    if (!_showingRouteOverview) {
      _navService?.setFollowModeEnabled(false);
      final drawing = MapboxDrawingService(mapboxMap: map);
      await drawing.fitRouteBounds(
        fromLng: current.lng.toDouble(),
        fromLat: current.lat.toDouble(),
        toLng: dest.lng.toDouble(),
        toLat: dest.lat.toDouble(),
      );
      if (!mounted) return;
      setState(() {
        _showingRouteOverview = true;
        _isFollowingCamera = false;
      });
    } else {
      _navService?.setFollowModeEnabled(true);
      await map.flyTo(
        _navigationCamera(
          lat: current.lat.toDouble(),
          lng: current.lng.toDouble(),
          bearing: _mapBearing,
        ),
        mapbox.MapAnimationOptions(duration: 800),
      );
      if (!mounted) return;
      setState(() {
        _showingRouteOverview = false;
        _isFollowingCamera = true;
      });
    }
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
    _buildDisplayRouteMetrics(result);

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
    _carAnimationTimer?.cancel();
    _resetCarAnimationState();
    _displayRouteDistanceAtIndex.clear();

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
      _currentSpeedLimit = null;
      _upcomingSteps = [];
      _isNavCardExpanded = false;
      _remainingDistanceText = '--';
      _showingRouteOverview = false;
    });
  }

  void _startNavigation() async {
    final route = _activeRoute;
    final destination = _activeDestination;
    final map = _mapboxMap;
    if (route == null || destination == null || map == null) return;

    _recenterTimer?.cancel();
    _recenterTimer = null;

    if (route.steps.isNotEmpty) {
      _safeSpeak(route.steps.first.instruction);
    }

    final initialBearing = _initialRouteBearing(route);
    if (_currentPosition != null) {
      await _setupNavigationCarModel(
        position: _currentPosition!,
        bearing: initialBearing,
      );
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
      onLocationUpdate: (
        position,
        speedKmh,
        bearing,
        visualPosition,
        routeDistance,
      ) {
        final current = mapbox.Position(position.longitude, position.latitude);
        unawaited(
          _animateNavigationCarModel(
            targetPosition: visualPosition,
            targetBearing: bearing,
            speedMps: speedKmh / 3.6,
            targetRouteDistance: routeDistance,
          ),
        );
        setState(() {
          _currentPosition = current;
          _currentSpeedKmh = speedKmh;
          _mapBearing = bearing;
        });
      },
      onStepChanged: (index, step) {
        setState(() {
          _currentInstruction = step.instruction;
          _currentSpeedLimit = step.speedLimitKmh;
          final route = _activeRoute;
          if (route != null) {
            final remaining = route.steps.length - index;
            final count = remaining.clamp(0, 3).toInt();
            _upcomingSteps = route.steps.sublist(index, index + count);
          }
        });
        _safeSpeak(step.instruction);
      },
      onReroute: (msg) {
        setState(() => _currentInstruction = msg);
        _safeSpeak('Rerouting, please wait');
      },
      onRouteChanged: (newRoute) async {
        final drawing = MapboxDrawingService(mapboxMap: map);
        await drawing.drawRoute(newRoute);
        _buildDisplayRouteMetrics(newRoute);
        _resetCarAnimationState();
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
        if (!mounted) return;
        setState(() {
          _remainingDistanceText = _formatDistance(remainingDistanceMeters);
          _estimatedArrival = DateTime.now().add(
            Duration(seconds: remainingDurationSeconds.toInt()),
          );
        });
      },
      onDestinationReached: () async {
        _safeSpeak('You have reached your destination!');
        _recenterTimer?.cancel();
        _recenterTimer = null;
        await _clearAll();
        await _setupLocationPuck();
        _resetCameraToCurrentLocation();
        if (mounted) {
          setState(() {
            _isNavigating = false;
            _isFollowingCamera = true;
            _currentSpeedLimit = null;
            _upcomingSteps = [];
            _isNavCardExpanded = false;
            _showingRouteOverview = false;
            _ttsEnabled = true;
          });
        }
      },
    );

    _navService!.setFollowModeEnabled(true);
    if (_activeRoute != null && _activeRoute!.steps.isNotEmpty) {
      _upcomingSteps = _activeRoute!.steps.take(3).toList();
    }
    _buildDisplayRouteMetrics(route);
    _navService!.startNavigation(route: route, destination: destination);

    setState(() {
      _isNavigating = true;
      _isFollowingCamera = true;
      _showingRouteOverview = false;
      _currentSpeedLimit =
          route.steps.isNotEmpty ? route.steps.first.speedLimitKmh : null;
      _upcomingSteps = route.steps.take(3).toList();
      _currentInstruction =
          route.steps.isNotEmpty ? route.steps.first.instruction : 'Continue';
      _remainingDistanceText = route.distanceText;
    });
  }

  void _stopNavigation() {
    _recenterTimer?.cancel();
    _recenterTimer = null;
    _carAnimationTimer?.cancel();
    _resetCarAnimationState();
    _navService?.setFollowModeEnabled(true);
    _navService?.stopNavigation();
    _tts.stop();
    _setupLocationPuck();
    _resetCameraToCurrentLocation();
    _clearAll();
    setState(() {
      _isNavigating = false;
      _isFollowingCamera = true;
      _currentSpeedLimit = null;
      _upcomingSteps = [];
      _isNavCardExpanded = false;
      _showingRouteOverview = false;
      _ttsEnabled = true;
    });
  }

  mapbox.CameraOptions _navigationCamera({
    required double lat,
    required double lng,
    required double bearing,
  }) {
    return mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: 20,
      pitch: 75.0,
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

  Future<void> _setupNavigationCarModel({
    required mapbox.Position position,
    required double bearing,
  }) async {
    final map = _mapboxMap;
    if (map == null) return;

    await map.location.updateSettings(
      mapbox.LocationComponentSettings(enabled: false),
    );

    await _removeCarModelLayer();

    await map.style.addSource(
      mapbox.GeoJsonSource(
        id: _carModelSourceId,
        data: _carPointGeoJson(position),
      ),
    );

    final layer = mapbox.ModelLayer(
      id: _carModelLayerId,
      sourceId: _carModelSourceId,
      modelId: _carModelUri,
      modelScale: const [_carModelScale, _carModelScale, _carModelScale],
      modelRotation: [0.0, 0.0, _carModelRotation(bearing)],
      modelType: mapbox.ModelType.COMMON_3D,
      modelCastShadows: true,
      modelReceiveShadows: true,
      modelEmissiveStrength: 0.7,
      modelOpacity: 1.0,
    );
    await map.style.addLayer(layer);
    _displayCarPosition = position;
    _displayCarBearing = bearing;
    _carTargetPosition = position;
    _carTargetBearing = bearing;
    _carTargetSpeedMps = 0;
    _carTargetAt = DateTime.now();
    _lastCarFrameAt = null;
  }

  Future<void> _animateNavigationCarModel({
    required mapbox.Position targetPosition,
    required double targetBearing,
    required double speedMps,
    required double? targetRouteDistance,
  }) async {
    if (!_isNavigating) return;

    final now = DateTime.now();
    final currentPosition = _displayCarPosition;
    final distance =
        currentPosition == null
            ? 0.0
            : _distanceBetweenPositions(currentPosition, targetPosition);

    if (currentPosition == null || distance > 80) {
      _displayCarPosition = targetPosition;
      _displayCarBearing = targetBearing;
      await _setNavigationCarModelPose(
        position: targetPosition,
        bearing: targetBearing,
      );
    }

    _carTargetPosition = targetPosition;
    _carTargetBearing = targetBearing;
    final previousRouteTarget = _carTargetRouteDistance;
    final previousTargetAt = _carTargetAt;
    var effectiveSpeedMps = speedMps;
    if (targetRouteDistance != null &&
        previousRouteTarget != null &&
        previousTargetAt != null) {
      final elapsedSeconds =
          now.difference(previousTargetAt).inMilliseconds / 1000.0;
      final routeDelta = targetRouteDistance - previousRouteTarget;
      if (elapsedSeconds > 0 && routeDelta > 0) {
        effectiveSpeedMps = max(effectiveSpeedMps, routeDelta / elapsedSeconds);
      }
    }
    _carTargetSpeedMps = effectiveSpeedMps.clamp(0.0, 55.0).toDouble();
    _carTargetRouteDistance = targetRouteDistance;
    if (_displayCarRouteDistance == null && targetRouteDistance != null) {
      _displayCarRouteDistance = targetRouteDistance;
    }
    _carTargetAt = now;
    _lastCarFrameAt ??= now;
    _ensureCarAnimationLoop();
  }

  void _ensureCarAnimationLoop() {
    if (_carAnimationTimer?.isActive ?? false) return;

    _carAnimationTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _tickNavigationCarModel();
    });
  }

  void _tickNavigationCarModel() {
    if (!_isNavigating) {
      _carAnimationTimer?.cancel();
      _carAnimationTimer = null;
      return;
    }

    final target = _carTargetPosition;
    if (target == null) return;

    final now = DateTime.now();
    final previousFrameAt = _lastCarFrameAt ?? now;
    final dtSeconds =
        now.difference(previousFrameAt).inMilliseconds.clamp(1, 80) / 1000.0;
    _lastCarFrameAt = now;

    final targetAgeSeconds =
        _carTargetAt == null
            ? 0.0
            : now.difference(_carTargetAt!).inMilliseconds / 1000.0;
    final predictionMeters =
        _carTargetSpeedMps < 0.7
            ? 0.0
            : (_carTargetSpeedMps * targetAgeSeconds).clamp(0.0, 24.0);
    final desiredRouteDistance =
        _carTargetRouteDistance == null
            ? null
            : (_carTargetRouteDistance! + predictionMeters).clamp(
              0.0,
              _displayRouteLength,
            );
    final desiredRoutePosition =
        desiredRouteDistance == null
            ? null
            : _positionAtRouteDistance(desiredRouteDistance);
    final desiredPosition =
        desiredRoutePosition ??
        _offsetPosition(target, _carTargetBearing, predictionMeters);

    final currentPosition = _displayCarPosition ?? desiredPosition;
    final currentBearing = _displayCarBearing ?? _carTargetBearing;
    final distance = _distanceBetweenPositions(
      currentPosition,
      desiredPosition,
    );
    final minStep = _carTargetSpeedMps > 0.7 ? 0.18 : 0.08;
    final maxStep = max(
      minStep,
      max(_carTargetSpeedMps * dtSeconds * 1.35, distance * 0.12),
    );
    final moveT = distance <= maxStep ? 1.0 : maxStep / max(distance, 0.001);
    final currentRouteDistance = _displayCarRouteDistance;
    final nextRouteDistance =
        desiredRouteDistance != null && currentRouteDistance != null
            ? currentRouteDistance +
                (desiredRouteDistance - currentRouteDistance) * moveT
            : null;
    final nextRoutePosition =
        nextRouteDistance == null
            ? null
            : _positionAtRouteDistance(nextRouteDistance);
    final nextPosition =
        nextRoutePosition ??
        _lerpPosition(currentPosition, desiredPosition, moveT);
    final bearingT = min(1.0, dtSeconds * 4.5);
    final nextBearing = _lerpBearing(
      currentBearing,
      _carTargetBearing,
      Curves.easeOut.transform(bearingT),
    );

    _displayCarPosition = nextPosition;
    _displayCarBearing = nextBearing;
    _displayCarRouteDistance = nextRouteDistance;
    unawaited(
      _setNavigationCarModelPose(position: nextPosition, bearing: nextBearing),
    );
    unawaited(_paintDisplayedRouteProgress());
  }

  void _resetCarAnimationState() {
    _carAnimationTimer = null;
    _displayCarPosition = null;
    _displayCarBearing = null;
    _carTargetPosition = null;
    _carTargetBearing = 0.0;
    _carTargetSpeedMps = 0.0;
    _displayCarRouteDistance = null;
    _carTargetRouteDistance = null;
    _carTargetAt = null;
    _lastCarFrameAt = null;
    _lastRouteProgressPaintAt = null;
    _routeProgressPaintInFlight = false;
  }

  Future<void> _setNavigationCarModelPose({
    required mapbox.Position position,
    required double bearing,
  }) async {
    final map = _mapboxMap;
    if (map == null || !_isNavigating) return;

    try {
      final source =
          await map.style.getSource(_carModelSourceId) as mapbox.GeoJsonSource;
      await source.updateGeoJSON(_carPointGeoJson(position));
      await map.style.setStyleLayerProperty(
        _carModelLayerId,
        'model-rotation',
        [0.0, 0.0, _carModelRotation(bearing)],
      );
    } catch (_) {
      await _setupNavigationCarModel(position: position, bearing: bearing);
    }
  }

  mapbox.Position _lerpPosition(
    mapbox.Position from,
    mapbox.Position to,
    double t,
  ) {
    return mapbox.Position(
      from.lng.toDouble() + (to.lng.toDouble() - from.lng.toDouble()) * t,
      from.lat.toDouble() + (to.lat.toDouble() - from.lat.toDouble()) * t,
    );
  }

  double _lerpBearing(double from, double to, double t) {
    final delta = ((to - from + 540) % 360) - 180;
    return (from + delta * t + 360) % 360;
  }

  double _distanceBetweenPositions(mapbox.Position a, mapbox.Position b) {
    return _haversine(
      a.lat.toDouble(),
      a.lng.toDouble(),
      b.lat.toDouble(),
      b.lng.toDouble(),
    );
  }

  double get _displayRouteLength =>
      _displayRouteDistanceAtIndex.isEmpty
          ? 0.0
          : _displayRouteDistanceAtIndex.last;

  void _buildDisplayRouteMetrics(MapboxRouteResult route) {
    _displayRouteDistanceAtIndex
      ..clear()
      ..add(0);

    for (var i = 1; i < route.coordinates.length; i++) {
      final previous = route.coordinates[i - 1];
      final current = route.coordinates[i];
      _displayRouteDistanceAtIndex.add(
        _displayRouteDistanceAtIndex.last +
            _haversine(previous[1], previous[0], current[1], current[0]),
      );
    }
  }

  mapbox.Position? _positionAtRouteDistance(double distanceMeters) {
    final route = _activeRoute;
    if (route == null ||
        route.coordinates.isEmpty ||
        _displayRouteDistanceAtIndex.length != route.coordinates.length) {
      return null;
    }

    final targetDistance = distanceMeters.clamp(0.0, _displayRouteLength);
    for (var i = 0; i < _displayRouteDistanceAtIndex.length - 1; i++) {
      final startDistance = _displayRouteDistanceAtIndex[i];
      final endDistance = _displayRouteDistanceAtIndex[i + 1];
      if (targetDistance > endDistance) continue;

      final segmentLength = max(endDistance - startDistance, 0.0);
      final fraction =
          segmentLength == 0
              ? 0.0
              : (targetDistance - startDistance) / segmentLength;
      final a = route.coordinates[i];
      final b = route.coordinates[i + 1];
      return mapbox.Position(
        a[0] + (b[0] - a[0]) * fraction,
        a[1] + (b[1] - a[1]) * fraction,
      );
    }

    final last = route.coordinates.last;
    return mapbox.Position(last[0], last[1]);
  }

  Future<void> _paintDisplayedRouteProgress() async {
    final route = _activeRoute;
    final map = _mapboxMap;
    final distance = _displayCarRouteDistance;
    if (route == null || map == null || distance == null) return;
    if (_routeProgressPaintInFlight) return;

    final now = DateTime.now();
    final lastPaintAt = _lastRouteProgressPaintAt;
    if (lastPaintAt != null &&
        now.difference(lastPaintAt).inMilliseconds < 80) {
      return;
    }

    _lastRouteProgressPaintAt = now;
    _routeProgressPaintInFlight = true;
    try {
      final drawing = MapboxDrawingService(mapboxMap: map);
      await drawing.updateRouteProgressByDistance(route, distance);
    } finally {
      _routeProgressPaintInFlight = false;
    }
  }

  mapbox.Position _offsetPosition(
    mapbox.Position position,
    double bearing,
    double meters,
  ) {
    if (meters <= 0) return position;

    const earthRadius = 6371000.0;
    final bearingRad = bearing * pi / 180;
    final latRad = position.lat.toDouble() * pi / 180;
    final lngRad = position.lng.toDouble() * pi / 180;
    final angularDistance = meters / earthRadius;

    final nextLat = asin(
      sin(latRad) * cos(angularDistance) +
          cos(latRad) * sin(angularDistance) * cos(bearingRad),
    );
    final nextLng =
        lngRad +
        atan2(
          sin(bearingRad) * sin(angularDistance) * cos(latRad),
          cos(angularDistance) - sin(latRad) * sin(nextLat),
        );

    return mapbox.Position(nextLng * 180 / pi, nextLat * 180 / pi);
  }

  double _carModelRotation(double bearing) {
    return (bearing + _carModelBearingOffset + 360.0) % 360.0;
  }

  String _carPointGeoJson(mapbox.Position position) {
    return jsonEncode({
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [
          position.lng + _carLngOffset,
          position.lat + _carLatOffset,
        ],
      },
      'properties': {},
    });
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

  BoxDecoration _panelDecoration({
    Color color = Colors.white,
    Color borderColor = _panelBorder,
    double shadowAlpha = 0.14,
  }) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(_panelRadius),
      border: Border.all(color: borderColor),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: shadowAlpha),
          blurRadius: 22,
          offset: const Offset(0, 10),
        ),
      ],
    );
  }

  Widget _frostedPanel({
    required Widget child,
    Color color = Colors.white,
    Color borderColor = _panelBorder,
    double shadowAlpha = 0.14,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(_panelRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: _panelDecoration(
            color: color,
            borderColor: borderColor,
            shadowAlpha: shadowAlpha,
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSearchPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _frostedPanel(
          color: Colors.white.withValues(alpha: 0.94),
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
              hintStyle: const TextStyle(
                color: _mutedInk,
                fontWeight: FontWeight.w500,
              ),
              prefixIcon: const Icon(Icons.search_rounded, color: _ink),
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
                        color: _mutedInk,
                      )
                      : IconButton(
                        onPressed: _moveCameraToCurrentLocation,
                        icon: const Icon(Icons.my_location_rounded),
                        color: _accentBlue,
                      ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
            ),
            style: const TextStyle(
              color: _ink,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (_searchResults.isNotEmpty || _searchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _frostedPanel(
              color: Colors.white.withValues(alpha: 0.96),
              shadowAlpha: 0.12,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child:
                    _searchResults.isNotEmpty
                        ? ListView.separated(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: _searchResults.length,
                          separatorBuilder:
                              (_, __) => Divider(
                                height: 1,
                                color: _panelBorder.withValues(alpha: 0.8),
                              ),
                          itemBuilder: (context, index) {
                            final place = _searchResults[index];
                            return ListTile(
                              minVerticalPadding: 12,
                              leading: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: _accentBlue.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.place_rounded,
                                  color: _accentBlue,
                                  size: 20,
                                ),
                              ),
                              title: Text(
                                place.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _ink,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                place.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: _mutedInk),
                              ),
                              onTap: () => _selectSearchPlace(place),
                            );
                          },
                        )
                        : Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.info_outline_rounded,
                                size: 20,
                                color: _mutedInk,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _searchError!,
                                  style: const TextStyle(
                                    color: _ink,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCompassButton() {
    final headingText =
        _compassHeading == null ? '--' : '${_compassHeading!.round()}';

    return _roundMapButton(
      onTap: _resetNorth,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.rotate(
            angle: -_mapBearing * pi / 180,
            child: const Icon(
              Icons.navigation_rounded,
              color: Color(0xFFEF4444),
              size: 28,
            ),
          ),
          Positioned(
            bottom: 6,
            child: Text(
              headingText,
              style: const TextStyle(
                color: _mutedInk,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundMapButton({
    required VoidCallback onTap,
    required Widget child,
    String? tooltip,
  }) {
    final button = Material(
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.16),
      color: Colors.white.withValues(alpha: 0.96),
      shape: const CircleBorder(side: BorderSide(color: _panelBorder)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 54, height: 54, child: child),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _buildRecenterButton() {
    return _roundMapButton(
      onTap: _recenterNavigation,
      tooltip: 'Recenter',
      child: const Icon(
        Icons.my_location_rounded,
        color: _accentBlue,
        size: 26,
      ),
    );
  }

  Widget _buildTtsButton() {
    return _roundMapButton(
      onTap: () => setState(() => _ttsEnabled = !_ttsEnabled),
      tooltip: _ttsEnabled ? 'Mute voice guidance' : 'Enable voice guidance',
      child: Icon(
        _ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        color: _ttsEnabled ? _accentBlue : _mutedInk,
        size: 26,
      ),
    );
  }

  Widget _buildRouteOverviewButton() {
    return _roundMapButton(
      onTap: _toggleRouteOverview,
      tooltip: _showingRouteOverview ? 'Follow route' : 'Route overview',
      child: Icon(
        _showingRouteOverview ? Icons.navigation_rounded : Icons.route_rounded,
        color: _accentBlue,
        size: 26,
      ),
    );
  }

  Widget _buildSpeedLimitSign() {
    if (_currentSpeedLimit == null || !_isNavigating) {
      return const SizedBox.shrink();
    }

    final isOverLimit = _currentSpeedKmh > _currentSpeedLimit!;
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(
          color: isOverLimit ? Colors.orange : Colors.red,
          width: 4,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$_currentSpeedLimit',
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  Widget _buildNavCard() {
    final canExpand = _upcomingSteps.length > 1;

    return _frostedPanel(
      color: const Color(0xFF0F172A).withValues(alpha: 0.92),
      borderColor: Colors.white.withValues(alpha: 0.1),
      shadowAlpha: 0.22,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap:
                canExpand
                    ? () =>
                        setState(() => _isNavCardExpanded = !_isNavCardExpanded)
                    : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _warningAmber.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.navigation_rounded,
                      color: _warningAmber,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _currentInstruction,
                      maxLines: _isNavCardExpanded ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (canExpand) ...[
                    const SizedBox(width: 6),
                    Icon(
                      _isNavCardExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: Colors.white.withValues(alpha: 0.64),
                      size: 24,
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _stopNavigation,
                    icon: const Icon(Icons.close_rounded),
                    color: Colors.white70,
                    tooltip: 'Stop',
                  ),
                ],
              ),
            ),
          ),
          if (_isNavCardExpanded && canExpand) ...[
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
            ..._upcomingSteps
                .skip(1)
                .take(2)
                .map(
                  (step) => Padding(
                    padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
                    child: Row(
                      children: [
                        Icon(
                          Icons.turn_slight_right_rounded,
                          color: Colors.white.withValues(alpha: 0.5),
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            step.instruction,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Text(
                          step.distance >= 1000
                              ? '${(step.distance / 1000).toStringAsFixed(1)} km'
                              : '${step.distance.round()} m',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
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

    return _frostedPanel(
      color: const Color(0xFF0B1220).withValues(alpha: 0.94),
      borderColor: Colors.white.withValues(alpha: 0.08),
      shadowAlpha: 0.22,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: _barItem(
                '${_currentSpeedKmh.toInt()}',
                'km/h',
                Colors.white,
                Icons.speed_rounded,
              ),
            ),
            _barDivider(),
            Expanded(
              child: _barItem(
                arrivalText,
                'Arrival',
                _warningAmber,
                Icons.schedule_rounded,
              ),
            ),
            _barDivider(),
            Expanded(
              child: _barItem(
                _remainingDistanceText,
                'Left',
                Colors.white,
                Icons.route_rounded,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barDivider() {
    return Container(
      width: 1,
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.white.withValues(alpha: 0.12),
    );
  }

  Widget _barItem(String value, String label, Color valueColor, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.56), size: 17),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: valueColor,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.58),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildStartButton() {
    return _frostedPanel(
      color: Colors.white.withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: _successGreen,
          borderRadius: BorderRadius.circular(_panelRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(_panelRadius),
            onTap: () async => _startNavigation(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.navigation_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Start navigation',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if ((_activeRoute?.durationText ?? '').isNotEmpty)
                          Text(
                            _activeRoute!.durationText,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.76),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ],
              ),
            ),
          ),
        ),
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

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a =
        pow(sin(dLat / 2), 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * pow(sin(dLng / 2), 2);
    return 2 * r * asin(sqrt(a.toDouble()));
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
