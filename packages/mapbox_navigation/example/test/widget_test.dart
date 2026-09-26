import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_navigation_example/main.dart';

void main() {
  testWidgets('NavigationExampleApp smoke test without token',
      (WidgetTester tester) async {
    await tester.pumpWidget(const NavigationExampleApp());
    expect(find.textContaining('Mapbox access token is required'), findsOneWidget);
  });
}
