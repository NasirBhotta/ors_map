import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mapbox_navigation/src/errors/navigation_errors.dart';
import 'package:mapbox_navigation/src/models/geo_point.dart';
import 'package:mapbox_navigation/src/models/navigation_route.dart';
import 'package:mapbox_navigation/src/models/navigation_step.dart';
import 'package:mapbox_navigation/src/routing/route_provider.dart';

/// [RouteProvider] implementation powered by Mapbox Directions API V5.
final class MapboxRouteProvider implements RouteProvider {
  final String accessToken;
  final http.Client _client;
  final Duration timeout;
  final String profile;

  MapboxRouteProvider({
    required this.accessToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
    this.profile = 'mapbox/driving',
  }) : _client = httpClient ?? http.Client();

  @override
  Future<NavigationRoute> calculateRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    if (accessToken.trim().isEmpty) {
      throw const RouteException(
        'Mapbox access token is missing or empty.',
        reason: RouteErrorReason.missingOrInvalidCredentials,
      );
    }

    final fromLng = origin.longitude;
    final fromLat = origin.latitude;
    final toLng = destination.longitude;
    final toLat = destination.latitude;

    final url = Uri.parse(
      'https://api.mapbox.com/directions/v5/$profile/'
      '$fromLng,$fromLat;$toLng,$toLat'
      '?access_token=$accessToken'
      '&geometries=geojson'
      '&steps=true'
      '&overview=full'
      '&annotations=maxspeed',
    );

    http.Response response;
    try {
      response = await _client.get(url).timeout(timeout);
    } on TimeoutException catch (e) {
      throw RouteException(
        'Mapbox route request timed out after ${timeout.inSeconds}s: $e',
        reason: RouteErrorReason.timeout,
      );
    } on SocketException catch (e) {
      throw RouteException(
        'Network connection failure while requesting Mapbox route: $e',
        reason: RouteErrorReason.networkError,
      );
    } on http.ClientException catch (e) {
      throw RouteException(
        'HTTP client error while requesting Mapbox route: $e',
        reason: RouteErrorReason.networkError,
      );
    } catch (e) {
      throw RouteException(
        'Unexpected error during Mapbox route request: $e',
        reason: RouteErrorReason.networkError,
        cause: e,
      );
    }

    if (response.statusCode != 200) {
      final reason = _mapStatusCodeToReason(response.statusCode, response.body);
      throw RouteException(
        'Mapbox Directions API failed with status ${response.statusCode}: ${response.body}',
        reason: reason,
      );
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw RouteException(
        'Failed to parse Mapbox Directions JSON: $e',
        reason: RouteErrorReason.serverError,
        cause: e,
      );
    }

    return parseRouteResponse(data);
  }

  /// Parses a Mapbox Directions V5 API JSON dictionary into a [NavigationRoute].
  NavigationRoute parseRouteResponse(Map<String, dynamic> data) {
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) {
      throw const RouteException(
        'No route found between origin and destination.',
        reason: RouteErrorReason.noRouteFound,
      );
    }

    final primaryRoute = routes.first as Map<String, dynamic>;
    final geometry = primaryRoute['geometry'] as Map<String, dynamic>?;
    final rawCoords = geometry?['coordinates'] as List?;

    if (rawCoords == null || rawCoords.length < 2) {
      throw const RouteException(
        'Mapbox route geometry contains fewer than 2 coordinates.',
        reason: RouteErrorReason.noRouteFound,
      );
    }

    final points = <GeoPoint>[];
    for (final coord in rawCoords) {
      if (coord is List && coord.length >= 2) {
        final lng = (coord[0] as num).toDouble();
        final lat = (coord[1] as num).toDouble();
        points.add(GeoPoint(latitude: lat, longitude: lng));
      }
    }

    final steps = <NavigationStep>[];
    final legs = primaryRoute['legs'] as List?;
    if (legs != null) {
      for (final leg in legs) {
        if (leg is Map<String, dynamic>) {
          final legSteps = leg['steps'] as List?;
          if (legSteps != null) {
            for (final stepData in legSteps) {
              if (stepData is Map<String, dynamic>) {
                final maneuver = stepData['maneuver'] as Map<String, dynamic>?;
                final instruction = (maneuver?['instruction'] as String?) ?? '';
                final distance = (stepData['distance'] as num?)?.toDouble() ?? 0.0;
                final duration = (stepData['duration'] as num?)?.toDouble() ?? 0.0;

                int? speedLimitKmh;
                final maxSpeed = stepData['max_speed'] as Map<String, dynamic>?;
                if (maxSpeed != null) {
                  final speed = (maxSpeed['speed'] as num?)?.toInt();
                  final unit = maxSpeed['unit'] as String?;
                  if (speed != null) {
                    speedLimitKmh =
                        unit == 'mph' ? (speed * 1.60934).round() : speed;
                  }
                }

                GeoPoint? maneuverLoc;
                final locList = maneuver?['location'] as List?;
                if (locList != null && locList.length >= 2) {
                  maneuverLoc = GeoPoint(
                    latitude: (locList[1] as num).toDouble(),
                    longitude: (locList[0] as num).toDouble(),
                  );
                }

                steps.add(
                  NavigationStep(
                    instruction: instruction,
                    distanceMeters: distance,
                    durationSeconds: duration,
                    maneuverPoint: maneuverLoc,
                    speedLimitKmh: speedLimitKmh,
                  ),
                );
              }
            }
          }
        }
      }
    }

    final totalDistance = (primaryRoute['distance'] as num?)?.toDouble() ?? 0.0;
    final totalDuration = (primaryRoute['duration'] as num?)?.toDouble() ?? 0.0;

    return NavigationRoute(
      geometry: points,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
      steps: steps,
    );
  }

  RouteErrorReason _mapStatusCodeToReason(int statusCode, String body) {
    if (statusCode == 401 || statusCode == 403) {
      return RouteErrorReason.missingOrInvalidCredentials;
    }
    if (statusCode >= 500) return RouteErrorReason.serverError;
    if (body.contains('NoRoute') || body.contains('NoSegment')) {
      return RouteErrorReason.noRouteFound;
    }
    if (body.contains('InvalidInput')) {
      return RouteErrorReason.invalidCoordinates;
    }
    return RouteErrorReason.networkError;
  }
}
