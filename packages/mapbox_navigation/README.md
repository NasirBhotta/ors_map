# mapbox_navigation

A modular, extensible Flutter package providing a decoupled navigation engine and Mapbox presentation layer.

[![pub package](https://img.shields.io/badge/version-0.1.0--dev.1-blue.svg)](https://pub.dev)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Overview

### What It Is
- **Pure Core Navigation Engine**: Vendor-neutral tracking, flat-earth projection route matching, monotonic progress calculation, multi-maneuver advancement, automatic off-route detection, reroute coordination, and GPS freshness monitoring.
- **Mapbox Presentation Layer**: Mapbox line layers (casing, traveled, and remaining route), 60fps display pose smoothing (`NavigationVehicleAnimator`), 3D GLB vehicle model rendering (`MapboxVehicleRenderer`), and camera tracking (`NavigationCameraController`).
- **Composite Widget**: `NavigationMapView`, connecting `NavigationController` directly to Mapbox rendering while leaving UI and search fully host-owned.

### What It Is Not
- Does **not** force proprietary UI components, search SDKs, or TTS engines.
- Does **not** run background location daemons by default (keeps lifecycle and permissions host-controlled).
- Does **not** couple navigation state to UI rendering.

---

## Architectural Principle

A core guarantee of this package is the separation between authoritative navigation progress and visual display interpolation:

```text
LocationSource (GPS)
       ↓
NavigationController (Atomic fix pipeline, route matching, progress)
       ↓
NavigationState (Authoritative, immutable, measured)
       ├─→ Host Application UI (Instructions, ETA, Speed limit, TTS)
       └─→ NavigationMapView
              ├─→ MapboxRouteRenderer (Traveled/remaining route lines)
              ├─→ NavigationVehicleAnimator (Smooth 60fps display pose)
              │      └─→ MapboxVehicleRenderer (3D GLB model)
              └─→ NavigationCameraController (Camera follow, recenter, overview)
```

> [!IMPORTANT]
> **Measured Navigation State $\neq$ Predicted Visual Vehicle Pose**  
> `NavigationState` exposes only measured, verified GPS progress (`distanceAlongRouteMeters`, `remainingDistanceMeters`, `currentStepIndex`). Display animation and speed extrapolation run strictly downstream inside `NavigationVehicleAnimator` and never mutate authoritative navigation state.

---

## Getting Started

### 1. Installation

Add `mapbox_navigation` to your `pubspec.yaml`:

```yaml
dependencies:
  mapbox_navigation:
    path: packages/mapbox_navigation # or hosted version
  geolocator: ^14.0.2
```

### 2. Mapbox Access Token

Provide your Mapbox public access token securely via `--dart-define` at run/build time:

```bash
flutter run --dart-define=MAPBOX_ACCESS_TOKEN=pk.your_token_here
```

---

## Quickstart

```dart
import 'package:flutter/material.dart';
import 'package:mapbox_navigation/mapbox_navigation.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const token = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  late final NavigationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = NavigationController(
      routeProvider: MapboxRouteProvider(accessToken: token),
      locationSource: const GeolocatorLocationSource(),
    );
  }

  Future<void> _startTrip() async {
    final route = await _controller.calculateRoute(
      origin: const GeoPoint(latitude: 33.6844, longitude: 73.0479),
      destination: const GeoPoint(latitude: 33.7297, longitude: 73.0372),
    );

    await _controller.startNavigation(
      route: route,
      destination: const GeoPoint(latitude: 33.7297, longitude: 73.0372),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            NavigationMapView(
              controller: _controller,
              accessToken: token,
              vehicle: const VehicleAppearance.model3D(
                modelUri: 'asset://assets/lowpoly_car.glb',
                scale: 0.05,
                bearingOffset: 180.0,
              ),
              routeTheme: const MapboxRouteTheme(),
            ),
            Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: ElevatedButton(
                onPressed: _startTrip,
                child: const Text('Start Navigation'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
```

---

## Observing State & Events

### Authoritative State
Listen to continuous state updates for instructions, speed, and remaining distance:

```dart
StreamBuilder<NavigationState>(
  stream: controller.states,
  builder: (context, snapshot) {
    final state = snapshot.data;
    final instruction = state?.currentStep?.instruction ?? 'Drive safe';
    final remainingKm = (state?.remainingDistanceMeters ?? 0) / 1000;
    return Text('$instruction • ${remainingKm.toStringAsFixed(1)} km left');
  },
);
```

### Discrete Events
Listen to one-time edge triggers (rerouting alerts, arrival dialogs, errors):

```dart
controller.events.listen((event) {
  switch (event) {
    case InstructionChangedEvent(:final step):
      debugPrint('Next maneuver: ${step.instruction}');
    case RerouteStartedEvent():
      debugPrint('Off-route detected, recalculating...');
    case RerouteFailedEvent(:final reason):
      debugPrint('Reroute failed: $reason');
    case DestinationReachedEvent():
      debugPrint('Arrived at destination!');
    case NavigationErrorEvent(:final error):
      debugPrint('Navigation error: ${error.message}');
  }
});
```

---

## Configuration Reference

Tune engine thresholds cleanly via `NavigationConfig`:

```dart
final config = NavigationConfig(
  tracking: const TrackingConfig(
    offRouteMeters: 60.0,
  ),
  arrival: const ArrivalConfig(
    destinationRadiusMeters: 30.0,
  ),
  freshness: const FreshnessConfig(
    staleTimeout: Duration(seconds: 5),
  ),
  rerouting: const ReroutingConfig(
    autoRerouteEnabled: true,
    minRerouteInterval: Duration(seconds: 8),
    routeRequestTimeout: Duration(seconds: 15),
  ),
);

final controller = NavigationController(
  routeProvider: provider,
  locationSource: source,
  config: config,
);
```

---

## Lifecycle & Disposal

Always call `controller.dispose()` when the navigation session ends:
- Unsubscribes from the active `LocationSource`.
- Cancels internal 1-second freshness timers and animation loops.
- Closes broadcast streams cleanly.

---

## Known V1 Limitations

- **Background Execution**: Background services (e.g. notifications, wakelocks) are host-owned and must be managed outside this package.
- **Route Options**: Multi-alternative route selection and toll/avoid options can be configured on the `RouteProvider` level.
