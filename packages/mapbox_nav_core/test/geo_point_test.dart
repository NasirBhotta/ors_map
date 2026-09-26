import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_nav_core/navigation.dart';

void main() {
  group('GeoPoint', () {
    test('instantiates with valid coordinates', () {
      const point = GeoPoint(latitude: 33.7215, longitude: 73.0551);
      expect(point.latitude, 33.7215);
      expect(point.longitude, 73.0551);
    });

    test('supports value equality and hash code', () {
      const p1 = GeoPoint(latitude: 33.7215, longitude: 73.0551);
      const p2 = GeoPoint(latitude: 33.7215, longitude: 73.0551);
      const p3 = GeoPoint(latitude: 34.0000, longitude: 73.0551);

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
      expect(p1, isNot(equals(p3)));
    });

    test('validates latitude bounds [-90, 90]', () {
      expect(
        () => GeoPoint(latitude: -90.1, longitude: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => GeoPoint(latitude: 90.1, longitude: 0),
        throwsA(isA<AssertionError>()),
      );
      // Valid boundary values
      expect(const GeoPoint(latitude: -90.0, longitude: 0).latitude, -90.0);
      expect(const GeoPoint(latitude: 90.0, longitude: 0).latitude, 90.0);
    });

    test('validates longitude bounds [-180, 180]', () {
      expect(
        () => GeoPoint(latitude: 0, longitude: -180.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => GeoPoint(latitude: 0, longitude: 180.1),
        throwsA(isA<AssertionError>()),
      );
      // Valid boundary values
      expect(const GeoPoint(latitude: 0, longitude: -180.0).longitude, -180.0);
      expect(const GeoPoint(latitude: 0, longitude: 180.0).longitude, 180.0);
    });

    test('provides readable toString()', () {
      const p = GeoPoint(latitude: 12.34, longitude: 56.78);
      expect(p.toString(), contains('lat: 12.34'));
      expect(p.toString(), contains('lng: 56.78'));
    });
  });
}
