/// Reusable, vendor-neutral navigation engine core.
///
/// Provides immutable navigation models, location and route provider contracts,
/// configuration schemas, and typed event/error contracts.
library;

// Core Models
export 'src/models/geo_point.dart';
export 'src/models/location_fix.dart';
export 'src/models/location_quality.dart';
export 'src/models/navigation_enums.dart';
export 'src/models/navigation_route.dart';
export 'src/models/navigation_state.dart';
export 'src/models/navigation_step.dart';

// Configuration
export 'src/config/navigation_config.dart';

// Events & Errors
export 'src/errors/navigation_errors.dart';
export 'src/events/navigation_events.dart';

// Abstractions
export 'src/api/navigation_controller.dart';
export 'src/location/location_source.dart';
export 'src/routing/route_provider.dart';
