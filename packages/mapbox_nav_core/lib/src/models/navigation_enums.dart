/// Represents the lifecycle status of a navigation session.
enum NavigationStatus {
  /// Navigation session is not active.
  idle,

  /// Navigation session is initializing or awaiting route calculation.
  starting,

  /// A route preview is currently displayed prior to active turn-by-turn guidance.
  preview,

  /// Active turn-by-turn navigation is currently underway.
  navigating,

  /// The destination has been reached.
  arrived,

  /// Navigation was stopped explicitly by the user or host app.
  stopped,

  /// The navigation session or controller has been disposed.
  disposed,
}

/// Status of an asynchronous route calculation or reroute request.
enum RouteRequestStatus {
  /// No route calculation is currently in flight.
  idle,

  /// An initial or preview route calculation is in flight.
  loading,

  /// An automatic off-route reroute calculation is in flight.
  rerouting,

  /// The last route calculation or reroute attempt failed.
  failed,
}

/// The tracking relationship between current location and the active route.
enum TrackingStatus {
  /// No confident match has been established (e.g. before initial lock or during reacquisition).
  unmatched,

  /// Current location is securely matched within the route corridor.
  onRoute,

  /// Current location has deviated outside the route corridor.
  offRoute,
}

/// Quality classification of GPS updates relative to freshness timeout.
enum LocationFreshness {
  /// No fix has been received yet in this session.
  unknown,

  /// The most recent fix is within the freshness timeout; authoritative progress is active.
  fresh,

  /// No fix received within the freshness timeout; authoritative progress is frozen.
  stale,

  /// Fix contained invalid or impossible metrics; rejected without mutating state.
  unusable,
}
