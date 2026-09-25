// navigation_freshness_test.dart
//
// Tests A-M for location freshness, stale-GPS handling, prediction bounding,
// GPS recovery, and timer lifecycle safety.
//
// No real GPS, HTTP, or Mapbox objects are needed.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ors_map_test/models/navigation_state.dart';
import 'package:ors_map_test/services/map_box_navigation_service.dart';
import 'package:ors_map_test/services/mapbox_route_service.dart';
import 'package:ors_map_test/services/navigation_location_source.dart';

class ControlledSource implements NavigationLocationSource {
  final _ctrl = StreamController<NavigationFix>.broadcast(sync: true);
  @override
  Stream<NavigationFix> get fixes => _ctrl.stream;
  void send(NavigationFix fix) => _ctrl.add(fix);
  Future<void> close() => _ctrl.close();
}

class FakeClock {
  DateTime _time;
  FakeClock(this._time);
  DateTime call() => _time;
  void advanceBy(Duration d) => _time = _time.add(d);
}

NavigationFix freshFix({
  required FakeClock clock,
  double lng = 0.03,
  double lat = 0,
  double speed = 5,
  double accuracy = 5,
  double heading = 90,
  Duration ageOffset = Duration.zero,
}) => NavigationFix(
  longitude: lng,
  latitude: lat,
  accuracy: accuracy,
  altitude: 0,
  heading: heading,
  speedMetersPerSecond: speed,
  timestamp: clock().subtract(ageOffset),
);

MapboxRouteResult straightRoute() {
  final coords = <List<double>>[];
  for (var i = 0; i <= 9; i++) {
    coords.add([i * 0.01, 0.0]);
  }
  const segLen = 1112.0;
  final totalDist = 9 * segLen;
  return MapboxRouteResult(
    coordinates: coords,
    distanceMeters: totalDist,
    durationSeconds: 200,
    steps: [
      MapboxStep(instruction: 'Go', distance: totalDist, duration: 200),
    ],
  );
}

const _farDest = NavigationCoordinate(1, 1);
const _timeout = Duration(seconds: 3);

void main() {
  late ControlledSource src;
  late FakeClock clock;
  late MapboxNavigationService svc;

  setUp(() {
    src = ControlledSource();
    clock = FakeClock(DateTime.utc(2026, 1, 1, 12, 0, 0));
    svc = MapboxNavigationService(
      locationSource: src,
      staleLocationTimeout: _timeout,
      now: clock.call,
    );
  });

  tearDown(() async {
    svc.dispose();
    await src.close();
  });

  // A. Fresh fix
  test('A: fresh fix results in LocationFreshness.fresh', () {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock));
    final state = svc.state;
    expect(state.locationQuality.freshness, LocationFreshness.fresh);
    expect(state.locationQuality.timestamp, isNotNull);
  });

  // B. Stale transition without new GPS event
  test('B: stale transition occurs without a new GPS event', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock));
    expect(svc.state.locationQuality.freshness, LocationFreshness.fresh);

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));

    expect(
      svc.state.locationQuality.freshness,
      LocationFreshness.stale,
      reason: 'State must be stale when no GPS for > staleLocationTimeout',
    );
  });

  // C. Stale state does not advance progress
  test('C: stale state does not advance distanceAlongRoute or step', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));
    final freshState = svc.state;
    expect(freshState.locationQuality.freshness, LocationFreshness.fresh);
    final distBefore = freshState.distanceAlongRouteMeters!;
    final stepBefore = freshState.currentStepIndex;

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));

    final staleState = svc.state;
    expect(staleState.locationQuality.freshness, LocationFreshness.stale);
    expect(staleState.distanceAlongRouteMeters, equals(distBefore),
        reason: 'Stale state must not advance distanceAlongRoute');
    expect(staleState.currentStepIndex, equals(stepBefore),
        reason: 'Stale state must not advance step');
    expect(staleState.trackingStatus, isNot(TrackingStatus.offRoute),
        reason: 'Stale GPS is not the same as being off-route');
  });

  // D. predictionHorizon equals staleLocationTimeout
  test('D: service exposes predictionHorizon equal to staleLocationTimeout', () {
    expect(svc.predictionHorizon, equals(_timeout));
  });

  // E. GPS recovery
  test('E: GPS recovery restores fresh state and allows progress to resume', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));
    expect(svc.state.locationQuality.freshness, LocationFreshness.fresh);

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));
    expect(svc.state.locationQuality.freshness, LocationFreshness.stale);

    src.send(freshFix(clock: clock, lng: 0.05, lat: 0));
    expect(svc.state.locationQuality.freshness, LocationFreshness.fresh,
        reason: 'Fresh GPS must restore freshness');
    expect(svc.state.distanceAlongRouteMeters, greaterThan(2000),
        reason: 'Progress can resume from the new accepted position');
  });

  // F. Large correction after stale recovery
  test('F: fresh fix after stale recovery reseeds distanceAlongRoute from actual position', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));
    final beforeDist = svc.state.distanceAlongRouteMeters!;

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));

    src.send(freshFix(clock: clock, lng: 0.07, lat: 0));
    final afterDist = svc.state.distanceAlongRouteMeters!;
    expect(afterDist, greaterThan(beforeDist));
    expect(afterDist, greaterThan(5000));
  });

  // G. Zero-speed correction
  test('G: zero-speed fix corrects authoritative position and matchedLocation', () {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0, speed: 5));
    final firstDist = svc.state.distanceAlongRouteMeters!;

    clock.advanceBy(const Duration(seconds: 1));
    src.send(freshFix(clock: clock, lng: 0.04, lat: 0, speed: 0));

    final afterState = svc.state;
    expect(afterState.locationQuality.freshness, LocationFreshness.fresh,
        reason: 'Zero-speed fix must be accepted as fresh');
    expect(afterState.distanceAlongRouteMeters!, greaterThan(firstDist),
        reason: 'Zero-speed fix must still advance distanceAlongRoute');
    expect(afterState.matchedLocation, isNotNull);
  });

  // H. Delayed callback containing old fix
  test('H: delayed callback with timestamp already stale on delivery is rejected', () {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));
    final beforeState = svc.state;

    clock.advanceBy(const Duration(seconds: 10));

    // Fix with timestamp 10 seconds ago (already older than 3s stale timeout).
    src.send(freshFix(
      clock: clock,
      lng: 0.05,
      lat: 0,
      ageOffset: const Duration(seconds: 10),
    ));

    final afterState = svc.state;
    expect(afterState.distanceAlongRouteMeters,
        equals(beforeState.distanceAlongRouteMeters),
        reason: 'Stale-on-delivery fix must not advance progress');
    expect(afterState.locationQuality.timestamp,
        equals(beforeState.locationQuality.timestamp),
        reason: '_lastUsableFixTimestamp must not update from stale-on-delivery fix');
  });

  // I. Stale location cannot trigger arrival
  test('I: stale state does not newly commit arrival', () async {
    final nearDest = NavigationCoordinate(0.09, 0.0);
    svc.dispose();
    svc = MapboxNavigationService(
      locationSource: src,
      staleLocationTimeout: _timeout,
      now: clock.call,
    );
    svc.startNavigation(route: straightRoute(), destination: nearDest);

    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));
    expect(svc.state.arrived, isFalse);

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));

    expect(svc.state.locationQuality.freshness, LocationFreshness.stale);
    expect(svc.state.arrived, isFalse,
        reason: 'Arrival must not be committed while state is stale');
    expect(svc.state.status, isNot(NavigationStatus.arrived));
  });

  // J. Stale location cannot accumulate off-route evidence
  test('J: stale GPS does not trigger rerouting or change trackingStatus to offRoute', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));

    expect(svc.state.locationQuality.freshness, LocationFreshness.stale);
    expect(svc.state.routeRequestStatus, isNot(RouteRequestStatus.rerouting),
        reason: 'Stale absence must not trigger rerouting');
    expect(svc.state.trackingStatus, isNot(TrackingStatus.offRoute));
  });

  // K. Foreground pause simulation
  test('K: large clock jump is reflected in freshness on next timer tick', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock));
    expect(svc.state.locationQuality.freshness, LocationFreshness.fresh);

    // Simulate app suspension: advance clock 60 seconds without timer ticks.
    clock.advanceBy(const Duration(seconds: 60));

    // One timer period later: freshness must be stale because actual elapsed
    // time (60s) >> staleLocationTimeout (3s).
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));

    expect(svc.state.locationQuality.freshness, LocationFreshness.stale,
        reason: 'After large clock advance, first timer tick must report stale');
  });

  // L. Dispose cancels freshness timer
  test('L: freshness timer is cancelled on dispose', () {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock));
    svc.dispose();
    final stateAfterDispose = svc.state;
    expect(stateAfterDispose.status, NavigationStatus.disposed);

    clock.advanceBy(const Duration(seconds: 30));
    // State must not change after disposal.
    expect(svc.state, same(stateAfterDispose));
  });

  // M. New session clears old freshness state
  test('M: new navigation session clears freshness state from prior session', () async {
    svc.startNavigation(route: straightRoute(), destination: _farDest);
    src.send(freshFix(clock: clock, lng: 0.02, lat: 0));
    expect(svc.state.locationQuality.freshness, LocationFreshness.fresh);

    clock.advanceBy(_timeout + const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));
    expect(svc.state.locationQuality.freshness, LocationFreshness.stale);

    svc.startNavigation(route: straightRoute(), destination: _farDest);
    expect(svc.state.locationQuality.freshness, LocationFreshness.unknown,
        reason: 'New session must reset freshness to unknown');
    expect(svc.state.locationQuality.timestamp, isNull);

    src.send(freshFix(clock: clock));
    expect(svc.state.locationQuality.freshness, LocationFreshness.fresh);
  });
}
