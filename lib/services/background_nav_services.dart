import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  // Notification channel (Android)
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'nav_channel',
    'Navigation',
    description: 'Turn-by-turn navigation',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()!
      .createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false,
      isForegroundMode: true, // OS kill nahi karega
      notificationChannelId: 'nav_channel',
      initialNotificationTitle: 'Navigation',
      initialNotificationContent: 'Starting...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onServiceStart,
      onBackground: onIosBackground,
    ),
  );
}

// Yeh background isolate mein chalta hai
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  // Notification update karo jab instruction aaye
  service.on('updateInstruction').listen((data) {
    service.invoke('update', {
      'instruction': data?['instruction'] ?? '',
      'distance': data?['distance'] ?? '',
    });

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: '🚗 Navigation',
        content: data?['instruction'] ?? 'On route...',
      );
    }
  });

  service.on('stopService').listen((_) {
    service.stopSelf();
  });
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}
