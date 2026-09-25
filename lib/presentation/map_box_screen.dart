import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:mapbox_navigation/mapbox_navigation.dart';
import 'package:ors_map_test/services/api_key_service.dart';
import 'package:ors_map_test/services/background_nav_services.dart';
import 'package:ors_map_test/services/tts_service.dart';

class MapboxTestScreen extends StatefulWidget {
  const MapboxTestScreen({super.key});

  @override
  State<MapboxTestScreen> createState() => _MapboxTestScreenState();
}

class _MapboxTestScreenState extends State<MapboxTestScreen> {
  static const Color _accentBlue = Color(0xFF2563EB);
  static const Color _successGreen = Color(0xFF16A34A);
  static const Color _warningAmber = Color(0xFFFACC15);
  static const Color _ink = Color(0xFF0F172A);
  static const Color _mutedInk = Color(0xFF64748B);
  static const Color _panelBorder = Color(0xFFE2E8F0);
  static const double _panelRadius = 8.0;

  mapbox.MapboxMap? _mapboxMap;
  mapbox.PointAnnotationManager? _annotationManager;
  mapbox.PointAnnotation? _destinationMarker;

  late final NavigationController _navigationController;
  final NavigationCameraController _cameraController =
      NavigationCameraController();
  StreamSubscription<NavigationState>? _navigationStateSub;
  StreamSubscription<NavigationEvent>? _navigationEventSub;
  StreamSubscription<CompassEvent>? _compassSub;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final TtsService _tts = TtsService();

  double _compassHeading = 0.0;
  bool _ttsEnabled = true;
  bool _isNavCardExpanded = false;
  bool _isSearching = false;
  String? _searchError;
  List<_SearchPlace> _searchResults = [];
  Timer? _searchDebounce;
  int _searchRequestId = 0;

  NavigationRoute? get _activeRoute => _navigationController.state.activeRoute;
  bool get _isNavigating =>
      _navigationController.state.status == NavigationStatus.navigating;

  String get _currentInstruction {
    final state = _navigationController.state;
    if (state.routeRequestStatus == RouteRequestStatus.rerouting) {
      return 'Rerouting, please wait...';
    }
    if (state.routeRequestStatus == RouteRequestStatus.loading &&
        state.status == NavigationStatus.starting) {
      return 'Finding route from current location...';
    }
    if (state.currentStep != null) {
      return state.currentStep!.instruction;
    }
    if (state.activeRoute?.steps.isNotEmpty == true) {
      return state.activeRoute!.steps.first.instruction;
    }
    return '';
  }

  int? get _currentSpeedLimit =>
      _navigationController.state.currentStep?.speedLimitKmh;

  List<NavigationStep> get _upcomingSteps {
    final state = _navigationController.state;
    final route = state.activeRoute;
    if (route == null || route.steps.isEmpty) return const [];
    final idx = state.currentStepIndex ?? 0;
    return route.steps.skip(idx).take(3).toList();
  }

  DateTime? get _estimatedArrival {
    final state = _navigationController.state;
    final duration = state.remainingDurationSeconds;
    if (duration != null) {
      return DateTime.now().add(Duration(seconds: duration.toInt()));
    }
    return null;
  }

  String get _remainingDistanceText {
    final meters =
        _navigationController.state.remainingDistanceMeters ??
        _activeRoute?.totalDistanceMeters ??
        0.0;
    return _formatDistance(meters);
  }

  @override
  void initState() {
    super.initState();
    _startCompass();
    _initNavigation();
  }

  void _initNavigation() {
    _navigationController = NavigationController(
      routeProvider: MapboxRouteProvider(
        accessToken: ApiKeyService.mapboxAccessToken,
      ),
      locationSource: const GeolocatorLocationSource(),
    );

    _navigationStateSub = _navigationController.states.listen((state) {
      if (mounted) setState(() {});
    });

    _navigationEventSub =
        _navigationController.events.listen(_onNavigationEvent);
  }

  void _onNavigationEvent(NavigationEvent event) {
    if (!mounted) return;
    switch (event) {
      case InstructionChangedEvent(:final step):
        _safeSpeak(step.instruction);
        FlutterBackgroundService().invoke('updateInstruction', {
          'instruction': step.instruction,
          'distance': _remainingDistanceText,
        });
      case RerouteStartedEvent():
        _safeSpeak('Rerouting, please wait');
      case RerouteFailedEvent(:final reason):
        debugPrint('Reroute failed: $reason');
      case DestinationReachedEvent():
        _safeSpeak('You have reached your destination!');
        _clearAll();
        _showArrivalDialog();
      case NavigationErrorEvent(:final error):
        debugPrint('Navigation error: ${error.message}');
    }
  }

  void _showArrivalDialog() {
    showDialog<void>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('🎉 Destination Reached!'),
            content: const Text('You have arrived at your destination.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
    );
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

  Future<void> _buildRouteToDestination(GeoPoint destination) async {
    final current =
        _navigationController.state.rawFix?.coordinate ??
        const GeoPoint(latitude: 33.6844, longitude: 73.0479);

    try {
      final route = await _navigationController.calculateRoute(
        origin: current,
        destination: destination,
      );
      await _navigationController.startPreview(
        route: route,
        destination: destination,
      );
      await _addDestinationMarker(
        mapbox.Position(destination.longitude, destination.latitude),
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Route error: $e');
    }
  }

  void _startNavigation() async {
    unawaited(
      initBackgroundService().then(
        (_) => FlutterBackgroundService().startService(),
      ),
    );

    final route = _navigationController.state.activeRoute;
    final dest = _navigationController.state.destination;
    if (route == null || dest == null) return;

    if (route.steps.isNotEmpty) {
      _safeSpeak(route.steps.first.instruction);
    }

    await _navigationController.startNavigation(
      route: route,
      destination: dest,
    );

    if (mounted) setState(() {});
  }

  void _stopNavigation() {
    _navigationController.stopNavigation();
    _tts.stop();
    _clearAll();
    if (mounted) setState(() {});
  }

  Future<void> _clearAll() async {
    if (_destinationMarker != null && _annotationManager != null) {
      await _annotationManager!.delete(_destinationMarker!);
      _destinationMarker = null;
    }
    if (mounted) {
      setState(() {
        _isNavCardExpanded = false;
      });
    }
  }

  Future<void> _recenterNavigation() async {
    final current = _navigationController.state.rawFix?.coordinate;
    final bearing = _navigationController.state.bearingDegrees;
    await _cameraController.recenter(
      currentPosition: current,
      currentBearing: bearing,
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleRouteOverview() async {
    final current = _navigationController.state.rawFix?.coordinate;
    final dest = _navigationController.state.destination;
    final map = _mapboxMap;
    if (current == null || dest == null || map == null) return;

    if (!_cameraController.isOverview) {
      await _cameraController.showRouteOverview(
        from: current,
        to: dest,
      );
      if (mounted) setState(() {});
    } else {
      final bearing = _navigationController.state.bearingDegrees;
      await _cameraController.exitOverview(
        currentPosition: current,
        currentBearing: bearing,
      );
      if (mounted) setState(() {});
    }
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
    final token = ApiKeyService.mapboxAccessToken;
    if (token.isEmpty) {
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _isSearching = false;
        _searchError = 'Mapbox token is missing';
      });
      return;
    }

    final rawLoc = _navigationController.state.rawFix?.coordinate;
    final proximity =
        rawLoc != null ? '&proximity=${rawLoc.longitude},${rawLoc.latitude}' : '';
    final uri = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/${Uri.encodeComponent(query)}.json'
      '?access_token=$token&autocomplete=true&limit=5$proximity',
    );

    try {
      final response = await http.get(uri);
      if (!mounted || requestId != _searchRequestId) return;

      if (response.statusCode != 200) {
        setState(() {
          _isSearching = false;
          _searchError = 'Search failed (${response.statusCode})';
        });
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List? ?? const [];
      final places =
          features
              .map(
                (f) => _SearchPlace.fromJson(
                  (f as Map).cast<String, dynamic>(),
                ),
              )
              .whereType<_SearchPlace>()
              .toList();

      setState(() {
        _isSearching = false;
        _searchResults = places;
        _searchError = places.isEmpty ? 'No places found' : null;
      });
    } catch (_) {
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _isSearching = false;
        _searchError = 'Search error';
      });
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchResults = [];
      _searchError = null;
      _isSearching = false;
    });
  }

  Future<void> _selectSearchPlace(_SearchPlace place) async {
    _searchFocusNode.unfocus();
    _searchController.text = place.title;
    setState(() {
      _searchResults = [];
      _searchError = null;
      _isSearching = false;
    });

    final destination = GeoPoint(latitude: place.lat, longitude: place.lng);
    await _buildRouteToDestination(destination);
  }

  @override
  void dispose() {
    _navigationStateSub?.cancel();
    _navigationEventSub?.cancel();
    _compassSub?.cancel();
    _navigationController.dispose();
    _cameraController.dispose();
    _tts.stop();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          children: [
            // Pure package NavigationMapView
            NavigationMapView(
              controller: _navigationController,
              accessToken: ApiKeyService.mapboxAccessToken,
              vehicle: const VehicleAppearance.model3D(
                modelUri: 'asset://assets/lowpoly_car.glb',
                scale: 0.05,
                bearingOffset: 180.0,
              ),
              routeTheme: const MapboxRouteTheme(),
              cameraController: _cameraController,
              onMapCreated: (controller) async {
                _mapboxMap = controller;
                _annotationManager =
                    await controller.annotations.createPointAnnotationManager();
                await _configureMapStyle();
              },
              onMapTap: (point) async {
                if (_isNavigating) _stopNavigation();
                await _buildRouteToDestination(
                  GeoPoint(
                    latitude: point.lat.toDouble(),
                    longitude: point.lng.toDouble(),
                  ),
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

            if (_isNavigating && !_cameraController.isFollowing)
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
                      : null,
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
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                place.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _mutedInk,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
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
                                color: _mutedInk,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _searchError ?? '',
                                  style: const TextStyle(
                                    color: _mutedInk,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
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
    return _frostedPanel(
      color: Colors.white.withValues(alpha: 0.94),
      child: IconButton(
        onPressed: _recenterNavigation,
        icon: Transform.rotate(
          angle: -_compassHeading * pi / 180,
          child: const Icon(Icons.navigation, color: Colors.red),
        ),
      ),
    );
  }

  Widget _buildTtsButton() {
    return _frostedPanel(
      color: Colors.white.withValues(alpha: 0.94),
      child: IconButton(
        onPressed: () {
          setState(() => _ttsEnabled = !_ttsEnabled);
          if (!_ttsEnabled) _tts.stop();
        },
        icon: Icon(
          _ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          color: _ttsEnabled ? _accentBlue : _mutedInk,
        ),
      ),
    );
  }

  Widget _buildRouteOverviewButton() {
    return _frostedPanel(
      color: Colors.white.withValues(alpha: 0.94),
      child: IconButton(
        onPressed: _toggleRouteOverview,
        icon: Icon(
          _cameraController.isOverview ? Icons.navigation_rounded : Icons.alt_route_rounded,
          color: _cameraController.isOverview ? _warningAmber : _accentBlue,
        ),
      ),
    );
  }

  Widget _buildRecenterButton() {
    return _frostedPanel(
      color: Colors.white.withValues(alpha: 0.94),
      child: IconButton(
        onPressed: _recenterNavigation,
        icon: const Icon(Icons.my_location_rounded, color: _accentBlue),
      ),
    );
  }

  Widget _buildNavCard() {
    final nextStep =
        _upcomingSteps.length > 1 ? _upcomingSteps[1] : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _frostedPanel(
          color: const Color(0xFF0F172A).withValues(alpha: 0.92),
          borderColor: Colors.white.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _accentBlue,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.turn_right_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _remainingDistanceText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _currentInstruction,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_upcomingSteps.length > 1)
                      IconButton(
                        onPressed: () {
                          setState(() {
                            _isNavCardExpanded = !_isNavCardExpanded;
                          });
                        },
                        icon: Icon(
                          _isNavCardExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          color: Colors.white70,
                        ),
                      ),
                  ],
                ),
                if (nextStep != null && !_isNavCardExpanded) ...[
                  const SizedBox(height: 8),
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Then: ${nextStep.instruction}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSpeedLimitSign() {
    final limit = _currentSpeedLimit;
    if (limit == null) return const SizedBox.shrink();

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.red, width: 4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$limit',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 16,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final arrival = _estimatedArrival;
    final timeStr =
        arrival != null
            ? '${arrival.hour % 12 == 0 ? 12 : arrival.hour % 12}:${arrival.minute.toString().padLeft(2, '0')} ${arrival.hour >= 12 ? 'PM' : 'AM'}'
            : '--:--';
    final remainingDuration =
        _navigationController.state.remainingDurationSeconds;
    final minStr =
        remainingDuration != null ? '${(remainingDuration / 60).round()} min' : '';

    return _frostedPanel(
      color: const Color(0xFF0F172A).withValues(alpha: 0.94),
      borderColor: Colors.white.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '$minStr • $_remainingDistanceText',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            ElevatedButton(
              onPressed: _stopNavigation,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('End'),
            ),
          ],
        ),
      ),
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
            onTap: _startNavigation,
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
