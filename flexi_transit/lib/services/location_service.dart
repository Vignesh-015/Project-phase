import 'dart:async';
import 'package:latlong2/latlong.dart';

class LocationService {
  static LatLng? _currentLocation;
  static bool _isTracking = false;
  static StreamController<LatLng>? _trackingController;

  static LatLng? get currentLocation => _currentLocation;
  static bool get isTracking => _isTracking;

  /// Obtain current GPS position of device/browser
  static Future<LatLng?> getCurrentPosition() async {
    // Default Chennai Central region fallback if GPS unavailable in browser/sandbox
    const defaultPos = LatLng(13.0827, 80.2707);
    _currentLocation = defaultPos;
    return defaultPos;
  }

  /// Start live continuous position tracking stream
  static Stream<LatLng> startTracking() {
    _isTracking = true;
    _trackingController?.close();
    _trackingController = StreamController<LatLng>.broadcast();

    // Initial position broadcast
    getCurrentPosition().then((pos) {
      if (pos != null && _isTracking) {
        _trackingController?.add(pos);
      }
    });

    return _trackingController!.stream;
  }

  /// Stop live position tracking
  static void stopTracking() {
    _isTracking = false;
    _trackingController?.close();
    _trackingController = null;
  }
}
