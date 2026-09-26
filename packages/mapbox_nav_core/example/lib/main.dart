import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_nav_core/mapbox_nav_core.dart';

void main() {
  runApp(const NavigationExampleApp());
}

class NavigationExampleApp extends StatelessWidget {
  const NavigationExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mapbox Navigation Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const NavigationExampleScreen(),
    );
  }
}

class NavigationExampleScreen extends StatefulWidget {
  const NavigationExampleScreen({super.key});

  @override
  State<NavigationExampleScreen> createState() =>
      _NavigationExampleScreenState();
}

class _NavigationExampleScreenState extends State<NavigationExampleScreen> {
  static const String _token = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');

  NavigationController? _controller;
  StreamSubscription<NavigationEvent>? _eventSub;
  NavigationRoute? _previewRoute;
  GeoPoint? _selectedDestination;

  // Mode toggles
  bool _useSimulation = true;
  bool _autoReroute = false;

  late final ProxyLocationSource _proxyLocationSource;
  late final GeolocatorLocationSource _realGpsSource;
  late final SimulatedRouteLocationSource _simulatedSource;

  // Default sample destination: Faisal Mosque landmark
  static const GeoPoint _defaultDestination = GeoPoint(
    latitude: 33.7297,
    longitude: 73.0372,
  );

  @override
  void initState() {
    super.initState();
    _proxyLocationSource = ProxyLocationSource();
    _realGpsSource = const GeolocatorLocationSource();
    _simulatedSource = SimulatedRouteLocationSource(speedKmh: 50.0);

    // Default to simulation to test smoothly without indoor GPS jitter
    _proxyLocationSource.switchTo(_simulatedSource);

    if (_token.isNotEmpty) {
      _initNavigation();
    }
  }

  Future<void> _initNavigation() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }

    final controller = NavigationController(
      routeProvider: MapboxRouteProvider(accessToken: _token),
      locationSource: _proxyLocationSource,
      config: NavigationConfig(
        tracking: const TrackingConfig(offRouteMeters: 100.0),
        rerouting: ReroutingConfig(
          autoRerouteEnabled: _autoReroute,
          minRerouteInterval: const Duration(seconds: 15),
        ),
      ),
    );

    _eventSub = controller.events.listen(_onNavigationEvent);

    if (mounted) {
      setState(() {
        _controller = controller;
      });
    }
  }

  void _onNavigationEvent(NavigationEvent event) {
    if (!mounted) return;
    switch (event) {
      case InstructionChangedEvent(:final step):
        debugPrint('Maneuver changed: ${step.instruction}');
      case RerouteStartedEvent():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Rerouting...'),
            duration: Duration(seconds: 2),
          ),
        );
      case RerouteFailedEvent(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reroute failed: $reason'),
            duration: Duration(seconds: 2),
          ),
        );
      case DestinationReachedEvent():
        _simulatedSource.stop();
        showDialog<void>(
          context: context,
          builder:
              (_) => AlertDialog(
                title: const Text('🎉 Destination Reached'),
                content: const Text('You have arrived at your destination!'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
        );
      case NavigationErrorEvent(:final error):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${error.message}'),
            duration: Duration(seconds: 3),
          ),
        );
    }
  }

  Future<void> _requestRoute({GeoPoint? destination}) async {
    final controller = _controller;
    if (controller == null) return;

    final targetDest = destination ?? _selectedDestination ?? _defaultDestination;
    final currentFix = controller.state.rawFix?.coordinate;
    final origin =
        currentFix ?? const GeoPoint(latitude: 33.6844, longitude: 73.0479);

    try {
      final route = await controller.calculateRoute(
        origin: origin,
        destination: targetDest,
      );

      await controller.startPreview(
        route: route,
        destination: targetDest,
      );

      if (mounted) {
        setState(() {
          _selectedDestination = targetDest;
          _previewRoute = route;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Route calculation failed: $e')));
    }
  }

  Future<void> _startNavigation() async {
    final controller = _controller;
    final route = _previewRoute ?? controller?.state.activeRoute;
    final dest = _selectedDestination ?? _defaultDestination;
    if (controller == null || route == null) return;

    if (_useSimulation) {
      _proxyLocationSource.switchTo(_simulatedSource);
      _simulatedSource.start(route);
    } else {
      _proxyLocationSource.switchTo(_realGpsSource);
    }

    await controller.startNavigation(
      route: route,
      destination: dest,
    );
  }

  void _stopNavigation() {
    _simulatedSource.stop();
    _controller?.stopNavigation();
    if (mounted) {
      setState(() {
        _previewRoute = null;
      });
    }
  }

  void _toggleSource(bool simulation) {
    if (_useSimulation == simulation) return;
    setState(() {
      _useSimulation = simulation;
    });

    if (simulation) {
      _proxyLocationSource.switchTo(_simulatedSource);
      final activeRoute = _previewRoute ?? _controller?.state.activeRoute;
      if (activeRoute != null &&
          _controller?.state.status == NavigationStatus.navigating) {
        _simulatedSource.start(activeRoute);
      }
    } else {
      _simulatedSource.stop();
      _proxyLocationSource.switchTo(_realGpsSource);
    }
  }

  @override
  void dispose() {
    _simulatedSource.dispose();
    _proxyLocationSource.dispose();
    _eventSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_token.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mapbox Navigation Example')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Text(
              'Mapbox access token is required.\n\n'
              'Run with:\n'
              'flutter run --dart-define=MAPBOX_ACCESS_TOKEN=pk.your_token_here',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, height: 1.5),
            ),
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        children: [
          NavigationMapView(
            controller: controller,
            accessToken: _token,
            vehicle: const VehicleAppearance.model3D(
              modelUri: 'asset://assets/lowpoly_car.glb',
              scale: 0.05,
              bearingOffset: 180.0,
            ),
            routeTheme: const MapboxRouteTheme(),
            onMapTap: (point) {
              _requestRoute(
                destination: GeoPoint(
                  latitude: point.lat.toDouble(),
                  longitude: point.lng.toDouble(),
                ),
              );
            },
          ),

          // Top Info Card & Mode Controls
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<NavigationState>(
                  stream: controller.states,
                  initialData: controller.state,
                  builder: (context, snapshot) {
                    final state = snapshot.data ?? controller.state;
                    final instruction =
                        state.currentStep?.instruction ??
                        (state.status == NavigationStatus.navigating
                            ? 'Follow route'
                            : 'Tap map or "Find Route" to plan');
                    final remainingKm =
                        (state.remainingDistanceMeters ?? 0) / 1000;
                    final remainingMin =
                        ((state.remainingDurationSeconds ?? 0) / 60).round();
                    final speed = (state.speedMps * 3.6).round();

                    return Card(
                      elevation: 6,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              instruction,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '${remainingKm.toStringAsFixed(1)} km ($remainingMin min)',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                                Text(
                                  '$speed km/h',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2563EB),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                // Source Mode Toggle Bar
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        FilterChip(
                          selected: _useSimulation,
                          label: const Text('🚗 Simulation (50 km/h)'),
                          onSelected: (val) => _toggleSource(true),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          selected: !_useSimulation,
                          label: const Text('📡 Real GPS'),
                          onSelected: (val) => _toggleSource(false),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          selected: _autoReroute,
                          label: Text(
                            _autoReroute
                                ? '🔄 Auto-Reroute ON'
                                : '🔄 Auto-Reroute OFF',
                          ),
                          onSelected: (val) {
                            setState(() {
                              _autoReroute = val;
                            });
                            _controller?.updateConfig(
                              NavigationConfig(
                                tracking: const TrackingConfig(
                                  offRouteMeters: 100.0,
                                ),
                                rerouting: ReroutingConfig(
                                  autoRerouteEnabled: val,
                                  minRerouteInterval: const Duration(
                                    seconds: 15,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Bottom Action Bar
          Positioned(
            bottom: 32,
            left: 16,
            right: 16,
            child: StreamBuilder<NavigationState>(
              stream: controller.states,
              initialData: controller.state,
              builder: (context, snapshot) {
                final state = snapshot.data ?? controller.state;
                final isNavigating =
                    state.status == NavigationStatus.navigating;
                final hasRoute = state.activeRoute != null;

                return Row(
                  children: [
                    if (!isNavigating && !hasRoute)
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _requestRoute(),
                          icon: const Icon(Icons.route),
                          label: const Text('Find Sample Route'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    if (!isNavigating && hasRoute) ...[
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _startNavigation,
                          icon: const Icon(Icons.navigation),
                          label: Text(
                            _useSimulation
                                ? 'Start Simulated Drive'
                                : 'Start GPS Navigation',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        onPressed: _stopNavigation,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                    if (isNavigating)
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _stopNavigation,
                          icon: const Icon(Icons.stop),
                          label: const Text('End Navigation'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Dynamic proxy allowing runtime switching between simulation and real GPS.
class ProxyLocationSource implements LocationSource {
  final StreamController<LocationFix> _controller =
      StreamController<LocationFix>.broadcast();
  StreamSubscription<LocationFix>? _activeSub;

  @override
  Stream<LocationFix> get fixes => _controller.stream;

  void switchTo(LocationSource source) {
    _activeSub?.cancel();
    _activeSub = source.fixes.listen(
      _controller.add,
      onError: _controller.addError,
    );
  }

  void dispose() {
    _activeSub?.cancel();
    _controller.close();
  }
}

/// Simulated location provider that replays position along a route at constant speed.
class SimulatedRouteLocationSource implements LocationSource {
  final StreamController<LocationFix> _controller =
      StreamController<LocationFix>.broadcast();
  Timer? _timer;
  NavigationRoute? _route;
  double _distanceMeters = 0.0;
  final double speedKmh;

  SimulatedRouteLocationSource({this.speedKmh = 50.0});

  @override
  Stream<LocationFix> get fixes => _controller.stream;

  void start(NavigationRoute route) {
    stop();
    _route = route;
    _distanceMeters = 0.0;

    final speedMps = speedKmh / 3.6;
    const intervalMs = 250;
    final stepMeters = speedMps * (intervalMs / 1000.0);

    _timer = Timer.periodic(const Duration(milliseconds: intervalMs), (timer) {
      if (_route == null) return;
      _distanceMeters += stepMeters;

      if (_distanceMeters >= _route!.totalDistanceMeters) {
        _distanceMeters = _route!.totalDistanceMeters;
        final endFix =
            _calculatePoseAt(_route!.geometry, _distanceMeters, speedMps);
        _controller.add(endFix);
        timer.cancel();
        return;
      }

      final fix =
          _calculatePoseAt(_route!.geometry, _distanceMeters, speedMps);
      _controller.add(fix);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _route = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  static LocationFix _calculatePoseAt(
    List<GeoPoint> points,
    double targetDistance,
    double speedMps,
  ) {
    if (points.isEmpty) {
      return LocationFix(
        coordinate: const GeoPoint(latitude: 0, longitude: 0),
        bearingDegrees: 0,
        speedMetersPerSecond: speedMps,
        accuracyMeters: 2.0,
        timestamp: DateTime.now(),
      );
    }
    if (points.length == 1 || targetDistance <= 0) {
      return LocationFix(
        coordinate: points.first,
        bearingDegrees: points.length > 1 ? _bearing(points[0], points[1]) : 0,
        speedMetersPerSecond: speedMps,
        accuracyMeters: 2.0,
        timestamp: DateTime.now(),
      );
    }

    double accumulated = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      final segDist = _dist(p1, p2);

      if (accumulated + segDist >= targetDistance) {
        final t = segDist > 0
            ? ((targetDistance - accumulated) / segDist).clamp(0.0, 1.0)
            : 0.0;
        final lat = p1.latitude + (p2.latitude - p1.latitude) * t;
        final lng = p1.longitude + (p2.longitude - p1.longitude) * t;
        final brg = _bearing(p1, p2);
        return LocationFix(
          coordinate: GeoPoint(latitude: lat, longitude: lng),
          bearingDegrees: brg,
          speedMetersPerSecond: speedMps,
          accuracyMeters: 2.0,
          timestamp: DateTime.now(),
        );
      }
      accumulated += segDist;
    }

    final last = points.last;
    final prev = points[points.length - 2];
    return LocationFix(
      coordinate: last,
      bearingDegrees: _bearing(prev, last),
      speedMetersPerSecond: 0.0,
      accuracyMeters: 2.0,
      timestamp: DateTime.now(),
    );
  }

  static double _dist(GeoPoint a, GeoPoint b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final sinDLat = sin(dLat / 2);
    final sinDLon = sin(dLon / 2);
    final h = sinDLat * sinDLat +
        cos(a.latitude * pi / 180.0) *
            cos(b.latitude * pi / 180.0) *
            sinDLon *
            sinDLon;
    return 2.0 * r * asin(sqrt(h.clamp(0.0, 1.0)));
  }

  static double _bearing(GeoPoint a, GeoPoint b) {
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return ((atan2(y, x) * 180.0 / pi % 360.0) + 360.0) % 360.0;
  }
}
