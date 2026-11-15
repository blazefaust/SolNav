import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/landmark.dart';
import '../models/region.dart';

class BackendService {
  final String baseUrl;

  // Default points to your permanent Tailscale Funnel HTTPS server.
  // Can still be overridden for local dev: BackendService(baseUrl: 'http://127.0.0.1:8443')
  BackendService({
    this.baseUrl = 'https://fedora.tail15b3a5.ts.net',
  });

  Uri _u(String p) => Uri.parse('$baseUrl$p');

  String _parseError(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body.containsKey('detail')) {
        return body['detail'].toString();
      }
    } catch (_) {}
    return res.body.isNotEmpty ? res.body : 'Server returned status ${res.statusCode}';
  }

  Future<T> _safeRequest<T>(Future<http.Response> Function() requestCall, Duration timeout) async {
    try {
      final res = await requestCall().timeout(timeout);
      if (res.statusCode >= 400) {
        throw Exception(_parseError(res));
      }
      return jsonDecode(res.body) as T;
    } on TimeoutException {
      throw Exception('Connection timed out while processing Mars terrain data. Please try again.');
    } on SocketException {
      throw Exception('Unable to reach Mars Mission Server. Check your internet connection.');
    } on FormatException {
      throw Exception('Invalid response format received from Mars server.');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Unexpected network error: $e');
    }
  }

  Future<Map<String, dynamic>> status() async {
    return _safeRequest<Map<String, dynamic>>(
      () => http.get(_u('/api/status')),
      const Duration(seconds: 15),
    );
  }

  Future<List<Landmark>> landmarks() async {
    final list = await _safeRequest<List<dynamic>>(
      () => http.get(_u('/api/landmarks')),
      const Duration(seconds: 15),
    );
    return list.map((e) => Landmark.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<dynamic>> layers() async {
    return _safeRequest<List<dynamic>>(
      () => http.get(_u('/api/layers')),
      const Duration(seconds: 15),
    );
  }

  Future<Map<String, dynamic>> selectRegion(Region r) async {
    return _safeRequest<Map<String, dynamic>>(
      () => http.post(
        _u('/api/select-region'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(r.toJson()),
      ),
      const Duration(seconds: 20),
    );
  }

  Future<Map<String, dynamic>> render2D({
    required Region region,
    Map<String, bool>? layers,
    double vertExag = 2.5,
    double azimuth = 315,
    double altitude = 45,
    String title = 'Mars Terrain',
  }) async {
    return _safeRequest<Map<String, dynamic>>(
      () => http.post(
        _u('/api/render/2d'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'region': region.toJson(),
          'layers': layers ?? {'mola': true},
          'vertical_exaggeration': vertExag,
          'azimuth': azimuth,
          'altitude': altitude,
          'title': title,
        }),
      ),
      const Duration(seconds: 60), // Render requests can take up to 60s
    );
  }

  Future<Map<String, dynamic>> render3D({
    required Region region,
    Map<String, bool>? layers,
    double vertExag = 2.5,
    String title = 'Mars Terrain',
  }) async {
    return _safeRequest<Map<String, dynamic>>(
      () => http.post(
        _u('/api/render/3d'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'region': region.toJson(),
          'layers': layers ?? {'mola': true},
          'vertical_exaggeration': vertExag,
          'title': title,
        }),
      ),
      const Duration(seconds: 60),
    );
  }

  Future<Map<String, dynamic>> planRoute({
    required double startLat,
    required double startLon,
    required double endLat,
    required double endLon,
    required Map<String, double> priorities,
    bool mapOnly = true,
  }) async {
    return _safeRequest<Map<String, dynamic>>(
      () => http.post(
        _u('/api/plan-route'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'start_lat': startLat,
          'start_lon': startLon,
          'end_lat': endLat,
          'end_lon': endLon,
          'priorities': priorities,
          'map_only': mapOnly,
        }),
      ),
      const Duration(seconds: 60),
    );
  }

  Future<Map<String, dynamic>> renderRoute3D({
    required List<Map<String, dynamic>> routes,
    List<double>? extent,
    double vertExag = 2.5,
    String title = 'Mars Route Plan',
  }) async {
    return _safeRequest<Map<String, dynamic>>(
      () => http.post(
        _u('/api/render/route-3d'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'routes': routes,
          if (extent != null && extent.length == 4)
            'region': {
              'west': extent[0],
              'east': extent[1],
              'south': extent[2],
              'north': extent[3],
            },
          'vertical_exaggeration': vertExag,
          'title': title,
        }),
      ),
      const Duration(seconds: 60),
    );
  }

  String fullUrl(String relative) => '$baseUrl$relative';
}