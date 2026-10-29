/// "Allow User Location", as the web's: when on, where you are goes with
/// each chat as {{USER_LOCATION}} and is saved to your account.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../core/api/openwebui_client.dart';

const userLocationKey = 'userLocation';

bool userLocationOn(Map? ui) => ui?[userLocationKey] == true;

/// As the web writes it: three decimals, then "(lat, long)".
String formatPosition(double lat, double lon) =>
    '${lat.toStringAsFixed(3)}, ${lon.toStringAsFixed(3)} (lat, long)';

/// Where the phone is, asking for permission the first time. Null when
/// it's not allowed or can't be found in time.
Future<String?> currentPosition({
  Duration wait = const Duration(seconds: 8),
}) async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  var allowed = await Geolocator.checkPermission();
  if (allowed == LocationPermission.denied) {
    allowed = await Geolocator.requestPermission();
  }
  if (allowed == LocationPermission.denied ||
      allowed == LocationPermission.deniedForever) {
    return null;
  }
  final last = await Geolocator.getLastKnownPosition();
  final p =
      last ??
      await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: wait,
        ),
      );
  return formatPosition(p.latitude, p.longitude);
}

/// Saves where you are to your account, as the web does, and returns it.
Future<String?> updateUserLocation(OpenWebUiClient client) async {
  final where = await currentPosition();
  if (where == null) return null;
  await client.send(
    'POST',
    '/api/v1/users/user/info/update',
    body: {'location': where},
  );
  return where;
}
