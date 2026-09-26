# Contributing to mapbox_nav_core

Thank you for your interest in contributing to `mapbox_nav_core`! This guide explains how to set up your local development environment, run tests, adhere to coding standards, and submit pull requests.

---

## Prerequisites

- **Flutter SDK**: `>= 3.24.0` (Stable channel recommended)
- **Dart SDK**: `^3.7.0`
- **Git**: `>= 2.30`

---

## Monorepo Layout

This repository is organized as a Flutter monorepo:

- **`packages/mapbox_nav_core/`**: The primary reusable Flutter package containing the core navigation engine and Mapbox presentation layer.
- **`packages/mapbox_nav_core/example/`**: Standalone example Flutter application demonstrating integration with `mapbox_nav_core`.
- **`lib/`, `test/`, `android/`, `ios/`**: Development integration fixture and stress testing environment.

---

## Development Workflow

### 1. Fetching Dependencies
Always run `pub get` from the package directory:

```bash
cd packages/mapbox_nav_core
flutter pub get

cd example
flutter pub get
```

### 2. Code Formatting
All Dart files must adhere to standard Dart formatting:

```bash
cd packages/mapbox_nav_core
dart format --output=none --set-exit-if-changed .
```

### 3. Static Analysis
The package must pass static analysis with zero issues:

```bash
cd packages/mapbox_nav_core
flutter analyze

cd example
flutter analyze
```

### 4. Running Tests
The package includes comprehensive unit, geodesy, property/fuzz, lifecycle, and stress benchmark tests:

```bash
cd packages/mapbox_nav_core
flutter test test
```

### 5. Pre-Release Dry Run Validation
Verify the package archive can be packaged cleanly by pub:

```bash
cd packages/mapbox_nav_core
dart pub publish --dry-run
```

---

## Running the Example Application

To run the example app on an Android device or iOS simulator:

```bash
cd packages/mapbox_nav_core/example
flutter run --dart-define=MAPBOX_ACCESS_TOKEN=pk.your_mapbox_public_token
```

> [!CAUTION]
> **NEVER Commit Real Access Tokens or API Keys**  
> Tokens must strictly be passed via `--dart-define` at runtime. Pull requests containing hardcoded tokens or secrets will be rejected immediately.

---

## Architectural Guidelines

1. **Vendor-Neutral Core**: Core tracking, route matching, progress calculation, and state management in `lib/navigation.dart` and `lib/src/tracking/` must remain 100% decoupled from Mapbox native SDKs.
2. **Separation of Authoritative State vs Display Pose**: `NavigationState` exposes only measured GPS progress (`distanceAlongRouteMeters`, `remainingDistanceMeters`). High-frequency visual vehicle smoothing and extrapolation run downstream inside `NavigationVehicleAnimator` and must never mutate authoritative navigation state.
3. **Public API Surface Minimization**: Never expose internal coordinators, route matchers, metrics caches, render generations, or native layer IDs in public exports. Consumers must only need `package:mapbox_nav_core/navigation.dart` and `package:mapbox_nav_core/mapbox_nav_core.dart`.

---

## Pull Request Guidelines

- Ensure your branch is rebased on the latest `main`.
- Add unit or stress tests for any new behavior or bug fix.
- Verify that `flutter test test`, `flutter analyze`, and `dart format` all pass cleanly before opening your PR.
- Fill out the provided [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md).
