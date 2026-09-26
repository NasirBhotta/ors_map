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

## Platform Setup (Android & iOS)

> [!IMPORTANT]
> **Foreground Navigation Only**  
> `mapbox_navigation` V1 provides turn-by-turn navigation strictly while the app is in the foreground. Background navigation (such as background GPS tracking, background route recalculation, or persistent background notifications) is **not supported** by the package core.
>
> **Host-Owned Permissions**  
> The host application is strictly responsible for requesting location permissions from the user and directing users to system settings if permissions are denied or GPS is disabled. `NavigationMapView` and `NavigationController` will never trigger unexpected system permission dialogs.

### Android Setup

1. **Permissions (`android/app/src/main/AndroidManifest.xml`)**:
   Add only the permissions required for foreground GPS and Directions API network access:
   ```xml
   <manifest xmlns:android="http://schemas.android.com/apk/res/android">
       <!-- Required for foreground turn-by-turn navigation -->
       <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
       <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
       <uses-permission android:name="android.permission.INTERNET"/>
       ...
   </manifest>
   ```
   *(Do NOT include `ACCESS_BACKGROUND_LOCATION` or `FOREGROUND_SERVICE_LOCATION` unless your host application provides a separate, custom background service).*

2. **Min SDK & Java Target (`android/app/build.gradle.kts`)**:
   Mapbox Maps SDK requires a minimum Android SDK of 24:
   ```kotlin
   android {
       ...
       defaultConfig {
           minSdk = 24
           ...
       }
   }
   ```

3. **Mapbox Maven Downloads Repository (`android/build.gradle.kts`)**:
   Configure the Mapbox Maven repository with your secret download token:
   ```kotlin
   allprojects {
       repositories {
           google()
           mavenCentral()
           maven {
               url = uri("https://api.mapbox.com/downloads/v2/releases/maven")
               authentication {
                   create<BasicAuthentication>("basic")
               }
               credentials {
                   username = "mapbox"
                   password = System.getenv("MAPBOX_DOWNLOADS_TOKEN") ?: ""
               }
           }
       }
   }
   ```

---

### iOS Setup

1. **Location Description & Token (`ios/Runner/Info.plist`)**:
   Add the mandatory foreground location usage description and access token reference:
   ```xml
   <dict>
       ...
       <!-- Required for foreground location access -->
       <key>NSLocationWhenInUseUsageDescription</key>
       <string>This application requires location access to provide turn-by-turn navigation guidance.</string>

       <!-- Mapbox public access token -->
       <key>MBXAccessToken</key>
       <string>$(MAPBOX_ACCESS_TOKEN)</string>
   </dict>
   ```
   *(Do NOT add `NSLocationAlwaysUsageDescription` or `UIBackgroundModes: location` unless your host application has independent background location capabilities).*

2. **CocoaPods & Deployment Target (`ios/Podfile`)**:
   Ensure the minimum deployment target is iOS 14.0 or higher:
   ```ruby
   platform :ios, '14.0'
   ```

---

## Controller Ownership & Lifecycle Behavior

### Caller Owns the Controller
`NavigationController` lifecycle is strictly owned by the caller (or your screen state / dependency injection container):
* **Screen transitions**: Popping a screen containing `NavigationMapView` detaches the Mapbox rendering delegates, cancels the 60fps display timer, and unhooks listeners without disposing the controller.
* **Re-mounting**: When navigating back or opening a new screen with the same controller, a new `NavigationMapView` attaches cleanly to the active session.
* **Disposal**: You must call `controller.dispose()` when the trip is completely terminated.

### Application Lifecycle (`AppLifecycleState`)
`NavigationMapView` automatically observes application lifecycle transitions:
* **Background (`paused` / `inactive` / `hidden`)**: Cancels the 60fps vehicle animation timer immediately to prevent battery and CPU drain.
* **Foreground (`resumed`)**: Calls `controller.evaluateFreshness()` to instantly recompute GPS fix age against current wall-clock time. If the GPS fix aged past `staleTimeout`, the state is marked stale, extrapolation is frozen, and vehicle pose reseeds cleanly from authoritative state without replaying missed animation frames or causing artificial visual jumps.

---

## Known V1 Limitations

- **Foreground Navigation Only**: True background location daemons, audio ducking, and persistent notification tray integration are host-owned and must be orchestrated outside this package.
- **Online Route Calculation**: `MapboxRouteProvider` relies on the Mapbox Directions v5 API; full offline routing graph engines are not included.
- **Geometric Polyline Matching**: Route snapping uses flat-earth orthogonal projection with heading penalties and search window clamping rather than a native road-network topology graph or Hidden Markov Model.
- **Single Primary Route**: Multi-route alternative selection and intermediate waypoint re-ordering are not included in V1.
- **Host-Owned Audio / TTS**: Turn instructions are emitted via `InstructionChangedEvent`; audio synthesis (e.g. `flutter_tts`) is kept separate for developer flexibility.
- **Map View Concurrency**: Running multiple concurrent `NavigationMapView` widgets simultaneously on screen is not recommended due to native Mapbox style and model layer constraints. Sequential navigation sessions are fully supported.
