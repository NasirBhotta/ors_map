/// Mapbox-specific presentation and routing adapters for `mapbox_navigation`.
///
/// Consumers wishing to build UI with Mapbox should import this library:
/// ```dart
/// import 'package:mapbox_navigation/mapbox_navigation.dart';
/// ```
library;

// Re-export the pure core navigation contracts and models
export 'navigation.dart';

// Public Mapbox-specific presentation & routing components
export 'src/mapbox/camera/navigation_camera_controller.dart';
export 'src/mapbox/location/geolocator_location_source.dart';
export 'src/mapbox/models/mapbox_route_theme.dart';
export 'src/mapbox/models/vehicle_appearance.dart';
export 'src/mapbox/presentation/navigation_map_view.dart';
export 'src/mapbox/routing/mapbox_route_provider.dart';
