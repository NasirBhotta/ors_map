# Mapbox Navigation Example

This example demonstrates how to integrate `mapbox_navigation` into a Flutter application.

## Prerequisites

1. A Mapbox account with a valid Public Access Token.
2. Location permissions enabled on the target device or emulator.

## Running the Example

Pass your Mapbox access token at build/run time via `--dart-define`:

```bash
flutter run --dart-define=MAPBOX_ACCESS_TOKEN=pk.your_actual_token_here
```

## Features Demonstrated

- Instantiating `NavigationController` with `MapboxRouteProvider` and `GeolocatorLocationSource`.
- Displaying active route lines and the 3D GLB vehicle using `NavigationMapView`.
- Handling route previews, starting navigation, and observing `NavigationState`.
- Handling discrete `NavigationEvent` alerts (e.g. rerouting, arrival).
