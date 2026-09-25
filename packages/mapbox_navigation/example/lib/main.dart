import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_navigation/mapbox_navigation.dart';

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

  // Sample destination: Islamabad Landmark
  static const GeoPoint _sampleDestination = GeoPoint(
    latitude: 33.7297,
    longitude: 73.0372,
  );

  @override
  void initState() {
    super.initState();
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
      locationSource: const GeolocatorLocationSource(),
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
          const SnackBar(content: Text('Rerouting...')),
        );
      case RerouteFailedEvent(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reroute failed: $reason')),
        );
      case DestinationReachedEvent():
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
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
          SnackBar(content: Text('Error: ${error.message}')),
        );
    }
  }

  Future<void> _requestRoute() async {
    final controller = _controller;
    if (controller == null) return;

    final currentFix = controller.state.rawFix?.coordinate;
    final origin = currentFix ??
        const GeoPoint(latitude: 33.6844, longitude: 73.0479);

    try {
      final route = await controller.calculateRoute(
        origin: origin,
        destination: _sampleDestination,
      );

      await controller.startPreview(
        route: route,
        destination: _sampleDestination,
      );

      if (mounted) {
        setState(() {
          _previewRoute = route;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Route calculation failed: $e')),
      );
    }
  }

  Future<void> _startNavigation() async {
    final controller = _controller;
    final route = _previewRoute ?? controller?.state.activeRoute;
    if (controller == null || route == null) return;

    await controller.startNavigation(
      route: route,
      destination: _sampleDestination,
    );
  }

  void _stopNavigation() {
    _controller?.stopNavigation();
    if (mounted) {
      setState(() {
        _previewRoute = null;
      });
    }
  }

  @override
  void dispose() {
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          NavigationMapView(
            controller: controller,
            accessToken: _token,
            vehicle: const VehicleAppearance.model3D(),
            routeTheme: const MapboxRouteTheme(),
          ),

          // Top Info Card
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: StreamBuilder<NavigationState>(
              stream: controller.states,
              initialData: controller.state,
              builder: (context, snapshot) {
                final state = snapshot.data ?? controller.state;
                final instruction = state.currentStep?.instruction ??
                    (state.status == NavigationStatus.navigating
                        ? 'Follow route'
                        : 'Tap "Find Route" to begin');
                final remainingKm = (state.remainingDistanceMeters ?? 0) / 1000;
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
                          onPressed: _requestRoute,
                          icon: const Icon(Icons.route),
                          label: const Text('Find Route'),
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
                          label: const Text('Start Navigation'),
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
