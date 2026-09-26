import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Pure core library contains no Mapbox imports or SDK references', () {
    final packageLib = Directory('packages/mapbox_navigation/lib');
    final libDir = packageLib.existsSync() ? packageLib : Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib directory must exist');

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.contains('mapbox') || f.path.endsWith('navigation.dart'))
        .where((f) => !f.path.contains('src${Platform.pathSeparator}mapbox') && !f.path.endsWith('mapbox_navigation.dart'))
        .toList();

    expect(dartFiles, isNotEmpty, reason: 'lib core must contain dart files');

    final forbiddenPatterns = [
      'mapbox_maps_flutter',
      'package:geolocator',
      'package:flutter_tts',
      'package:flutter_background_service',
      'package:flutter_local_notifications',
      'package:google_maps_flutter',
      'mapbox.Position',
      'CameraOptions',
      'MapboxMap',
    ];

    final violations = <String>[];

    for (final file in dartFiles) {
      final content = file.readAsStringSync();
      for (final pattern in forbiddenPatterns) {
        if (content.contains(pattern)) {
          violations.add('${file.path} contains forbidden pattern "$pattern"');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Core package must be strictly vendor-neutral and free of external SDK dependencies:\n'
          '${violations.join('\n')}',
    );
  });
}
