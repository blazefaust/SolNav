import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_providers.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Safe parsing helpers + tiny data models for the /api/plan-route response
// ─────────────────────────────────────────────────────────────────────────────

double? _toD(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

List<double> _dList(dynamic v) =>
    v is List ? v.map(_toD).whereType<double>().toList() : <double>[];

class _LL {
  final double lat, lon;
  const _LL(this.lat, this.lon);
}

class _Step {
  final String instruction;
  final double distanceKm;
  const _Step(this.instruction, this.distanceKm);

  factory _Step.fromJson(Map<String, dynamic> j) =>
      _Step('${j['instruction'] ?? ''}', _toD(j['distance_km']) ?? 0);
}

class _Route {
  final String id, label;
  final List<String> tags;
  final List<_LL> path;
  final List<_Step> steps;
  final Map<String, dynamic> stats;
  final List<double> pDist, pElev, pSlope;

  _Route({
    required this.id,
    required this.label,
    required this.tags,
    required this.path,
    required this.steps,
    required this.stats,
    required this.pDist,
    required this.pElev,
    required this.pSlope,
  });

  factory _Route.fromJson(Map<String, dynamic> j) {
    final path = <_LL>[];
    if (j['path'] is List) {
      for (final p in j['path'] as List) {
        if (p is List && p.length >= 2) {
          final a = _toD(p[0]), b = _toD(p[1]);
          if (a != null && b != null) path.add(_LL(a, b));
        }
      }
    }
    final steps = (j['steps'] is List ? j['steps'] as List : const [])
        .whereType<Map>()
        .map((m) => _Step.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    final prof = j['profile'] is Map
        ? Map<String, dynamic>.from(j['profile'] as Map)
        : <String, dynamic>{};
    return _Route(
      id: '${j['id'] ?? 'route'}',
      label: '${j['label'] ?? 'Route'}',
      tags: j['tags'] is List
          ? (j['tags'] as List).map((e) => '$e').toList()
          : <String>[],
      path: path,
      steps: steps,
      stats: j['stats'] is Map
          ? Map<String, dynamic>.from(j['stats'] as Map)
          : <String, dynamic>{},
      pDist: _dList(prof['dist_km']),
      pElev: _dList(prof['elev_m']),
      pSlope: _dList(prof['slope_deg']),
    );
  }

  String n(String k, {int d = 1, String u = ''}) {
    final v = _toD(stats[k]);
    return v == null ? '—' : '${v.toStringAsFixed(d)}$u';
  }

  String s(String k) => stats[k] == null ? '—' : '${stats[k]}';

  /// Cumulative planar length along the path (used to place points by fraction).
  late final List<double> cum = () {
    final out = <double>[0];
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1], b = path[i];
      final dLat = b.lat - a.lat;
      final dLon = (b.lon - a.lon) * math.cos(((a.lat + b.lat) / 2) * math.pi / 180);
      out.add(out.last + math.sqrt(dLat * dLat + dLon * dLon));
    }
    return out;
  }();

  /// Start fraction of each step along the route (+ final 1.0).
  late final List<double> stepStarts = () {
    final total = steps.fold<double>(0, (a, s) => a + s.distanceKm);
    final out = <double>[];
    var acc = 0.0;
    for (final st in steps) {
      out.add(total == 0 ? 0 : acc / total);
      acc += st.distanceKm;
    }
    out.add(1.0);
    return out;
  }();

  _LL pointAt(double f) {
    if (path.isEmpty) return const _LL(0, 0);
    if (path.length < 2 || cum.last == 0) return path.first;
    final t = f.clamp(0.0, 1.0) * cum.last;
    for (var i = 1; i < path.length; i++) {
      if (cum[i] >= t) {
        final seg = cum[i] - cum[i - 1];
        final u = seg == 0 ? 0.0 : (t - cum[i - 1]) / seg;
        return _LL(
          path[i - 1].lat + (path[i].lat - path[i - 1].lat) * u,
          path[i - 1].lon + (path[i].lon - path[i - 1].lon) * u,
        );
      }
    }
    return path.last;
  }

  List<_LL> slice(double f0, double f1) {
    if (path.length < 2) return path;
    final a = f0 * cum.last, b = f1 * cum.last;
    final out = <_LL>[pointAt(f0)];
    for (var i = 0; i < path.length; i++) {
      if (cum[i] > a && cum[i] < b) out.add(path[i]);
    }
    out.add(pointAt(f1));
    return out;
  }

  /// Elevation (m) at fraction [f] (0..1) along the route, from the profile.
  double elevAt(double f) {
    final n = math.min(pDist.length, pElev.length);
    if (n == 0) return 0;
    if (n == 1) return pElev[0];
    final d = f.clamp(0.0, 1.0) * pDist[n - 1];
    for (var i = 1; i < n; i++) {
      if (pDist[i] >= d) {
        final seg = pDist[i] - pDist[i - 1];
        final u = seg == 0 ? 0.0 : (d - pDist[i - 1]) / seg;
        return pElev[i - 1] + (pElev[i] - pElev[i - 1]) * u;
      }
    }
    return pElev[n - 1];
  }

  /// Slope (deg) at fraction [f] along the route, from the profile.
  double slopeAt(double f) {
    final n = math.min(pDist.length, pSlope.length);
    if (n == 0) return 0;
    final d = f.clamp(0.0, 1.0) * pDist[n - 1];
    for (var i = 0; i < n; i++) {
      if (pDist[i] >= d) return pSlope[i];
    }
    return pSlope[n - 1];
  }

  /// Elevation for every path point.
  late final List<double> pathElev = () {
    final total = cum.isEmpty ? 0.0 : cum.last;
    return [
      for (var i = 0; i < path.length; i++) elevAt(total == 0 ? 0.0 : cum[i] / total),
    ];
  }();

  String readout(double f) {
    final n = math.min(pDist.length, math.min(pElev.length, pSlope.length));
    if (n == 0) return '';
    final d = f * pDist[n - 1];
    var idx = n - 1;
    for (var i = 0; i < n; i++) {
      if (pDist[i] >= d) {
        idx = i;
        break;
      }
    }
    return '${pDist[idx].toStringAsFixed(0)} km  ·  ${pElev[idx].toStringAsFixed(0)} m  ·  ${pSlope[idx].toStringAsFixed(1)}° slope';
  }
}

Color _routeColor(String id) {
  switch (id) {
    case 'recommended':
      return const Color(0xFF3B9BFF);
    case 'shortest':
      return const Color(0xFFFFB020);
    case 'safest':
      return const Color(0xFF3DDC84);
    case 'energy':
      return const Color(0xFFB07CFF);
    default:
      return const Color(0xFF9AA4B2);
  }
}

IconData _stepIcon(String s) {
  final t = s.toLowerCase();
  if (t.contains('arrive')) return Icons.flag;
  if (t.contains('turn left')) return Icons.turn_left;
  if (t.contains('turn right')) return Icons.turn_right;
  if (t.startsWith('head')) return Icons.navigation;
  return Icons.arrow_upward;
}

const _prioKeys = {
  'Safety': 'safety',
  'Science': 'science',
  'Distance': 'distance',
  'Energy': 'energy',
  'Terrain Difficulty': 'difficulty',
};

/// What each priority slider means (shown when you hover over it).
const _prioInfo = <String, String>{
  'Safety':
      'Penalises steep slopes AND sets hard limits: at 1.0 the rover may not enter slopes above '
          '~18 deg (25 deg at 0), and ground with too many steep sub-pixels is blocked. Usually the '
          'strongest lever: low values let the route climb mountains like Olympus Mons.',
  'Science':
      'Makes cells with a high mineral-diversity score cheaper to drive through (up to 60% '
          'cheaper), so the route detours toward them. Needs a science layer: with none loaded it '
          'does nothing (the planner warns you).',
  'Distance':
      'How much each kilometre driven costs. High = a straight, short route even over rougher '
          'ground. Low = long detours are fine to avoid slopes and climbs. 0.5 is neutral.',
  'Energy':
      'Penalty for climbing: each metre of ascent counts like about 10 x weight metres of flat '
          'driving. High = flatter paths that avoid big elevation gain.',
  'Terrain Difficulty':
      'Penalises rough ground: cells where many sub-pixels are moderately steep (over ~25% of the '
          'slope limit). High = prefers smooth plains over crater rims, ridges and flanks. Only '
          'matters if the terrain between your points actually has rough patches.',
};

const _prioHowItWorks =
    'Each weight is an absolute value from 0 to 1 (not a ratio). They shape the Recommended '
    'route only; Shortest, Safest and Energy saver use fixed profiles. A weight only changes the '
    'path when the terrain between your points offers a real trade-off: on flat ground most '
    'sliders do nothing. Safety and Energy usually matter most near big mountains.';

String _wrapText(String t, int w) {
  final lines = <String>[];
  var cur = '';
  for (final word in t.split(' ')) {
    if (cur.isNotEmpty && (cur.length + 1 + word.length) > w) {
      lines.add(cur);
      cur = word;
    } else {
      cur = cur.isEmpty ? word : '$cur $word';
    }
  }
  if (cur.isNotEmpty) lines.add(cur);
  return lines.join('\n');
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

const _briefCss = r"""
*{box-sizing:border-box}
body{font-family:'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#111827;margin:0;background:#f3f4f6}
.page{max-width:980px;margin:0 auto;background:#fff;padding:32px 40px}
header{border-bottom:3px solid #ff6b35;padding-bottom:12px;margin-bottom:18px}
h1{margin:0;font-size:26px;letter-spacing:.5px}
h2{font-size:13px;letter-spacing:1.6px;text-transform:uppercase;color:#6b7280;margin:26px 0 8px;border-bottom:1px solid #e5e7eb;padding-bottom:4px}
.sub{color:#6b7280;font-size:12px;margin-top:4px}
.summary{font-size:14px;line-height:1.55;background:#fff7f3;border-left:4px solid #ff6b35;padding:10px 14px}
.map{position:relative;width:100%;border:1px solid #d1d5db;background:#0b0f14;overflow:hidden}
.map img{display:block;width:100%}
.map svg{position:absolute;left:0;top:0;width:100%;height:100%}
.pin{position:absolute;transform:translate(-50%,-50%);width:22px;height:22px;border-radius:50%;border:2px solid #fff;color:#000;font-weight:700;font-size:12px;text-align:center;line-height:18px}
.pin.a{background:#3ddc84}.pin.b{background:#ff4d4d}
.legend{margin-top:6px}.legend span{display:inline-block;margin-right:14px;font-size:12px}
.legend i{display:inline-block;width:18px;height:4px;vertical-align:middle;margin-right:5px}
.grid{display:grid;grid-template-columns:repeat(5,1fr);gap:8px}
.tile{border:1px solid #e5e7eb;padding:8px 10px}.tile b{display:block;font-size:16px}
.tile small{color:#6b7280;font-size:10px;letter-spacing:1px;text-transform:uppercase}
table{border-collapse:collapse;width:100%;font-size:12px}
th,td{border:1px solid #e5e7eb;padding:5px 8px;text-align:left}th{background:#f9fafb}
tr.sel td{background:#fff7f3;font-weight:600}
ol{font-size:12px;line-height:1.7;columns:2;column-gap:28px}
.warn{background:#fffbeb;border:1px solid #f59e0b;padding:8px 12px;font-size:12px;margin:6px 0}
.prof{width:100%;height:auto;border:1px solid #e5e7eb}
ul{font-size:12px;line-height:1.6}
button.print{position:fixed;right:18px;top:14px;background:#ff6b35;color:#fff;border:0;padding:10px 16px;font-weight:700;cursor:pointer}
footer{margin-top:28px;font-size:11px;color:#9ca3af;text-align:center}
@media print{body{background:#fff}.page{padding:0;max-width:none}.no-print{display:none}h2{break-after:avoid}.map,table,.grid{break-inside:avoid}}
""";

/// Little top-down rover glyph (body, 6 wheels, heading arrow).
void _drawRover(Canvas c, Offset o, double ang, double k) {
  c.save();
  c.translate(o.dx, o.dy);
  c.rotate(ang);
  c.drawCircle(Offset.zero, 14 * k, Paint()..color = const Color(0x55FFFFFF));
  final wheel = Paint()..color = Colors.black;
  for (final dx in [-6.0, 0.0, 6.0]) {
    for (final dy in [-7.0, 7.0]) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(dx * k, dy * k), width: 5 * k, height: 3 * k),
          Radius.circular(1 * k),
        ),
        wheel,
      );
    }
  }
  final body = RRect.fromRectAndRadius(
    Rect.fromCenter(center: Offset.zero, width: 16 * k, height: 10 * k),
    Radius.circular(2 * k),
  );
  c.drawRRect(body, Paint()..color = MC.accent);
  c.drawRRect(
    body,
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * k,
  );
  final tri = Path()
    ..moveTo(14 * k, 0)
    ..lineTo(9 * k, -4 * k)
    ..lineTo(9 * k, 4 * k)
    ..close();
  c.drawPath(tri, Paint()..color = Colors.white);
  c.restore();
}

enum _Pick { none, start, end }

class MissionPlanningScreen extends ConsumerStatefulWidget {
  const MissionPlanningScreen({super.key});

  @override
  ConsumerState<MissionPlanningScreen> createState() => _MissionPlanningScreenState();
}

class _MissionPlanningScreenState extends ConsumerState<MissionPlanningScreen>
    with SingleTickerProviderStateMixin {
  final _startLat = TextEditingController(text: "18.0");
  final _startLon = TextEditingController(text: "226.0");
  final _endLat = TextEditingController(text: "21.5");
  final _endLon = TextEditingController(text: "230.5");

  final Map<String, double> prio = {
    'Safety': 0.9,
    'Science': 0.7,
    'Distance': 0.5,
    'Energy': 0.4,
    'Terrain Difficulty': 0.6,
  };

  bool loading = false;
  bool _building3d = false;
  String? err;
  _Pick _pick = _Pick.none;

  // Responsive layout state (phone/tablet = tabbed, desktop = 3 columns)
  bool _compact = false;
  int _tab = 0; // 0 = plan, 1 = map, 2 = routes

  // Parsed result
  List<_Route> _routes = [];
  int _sel = 0;
  int? _step;
  List<String> _warnings = [];
  String? _mapUrl;
  List<double> _extent = [0, 1, 0, 1]; // west, east, south, north
  bool _mapOnly = false;
  bool _overlay = true;
  Size? _imgSize;
  _LL? _start, _end;

  final ValueNotifier<double?> _hover = ValueNotifier(null);

  // Rover playback (null = hidden, otherwise 0..1 progress along the route)
  final ValueNotifier<double?> _rover = ValueNotifier(null);
  Ticker? _ticker;
  Duration _last = Duration.zero;
  bool _playing = false;
  double _speed = 1.0;

  // Priorities: live re-plan + "did the path change?" note
  bool _live = true;
  bool _livePending = false;
  Timer? _liveTimer;
  String? _prioNote;

  // Mission brief export
  bool _exporting = false;
  String? _exportMsg;
  Map<String, dynamic> _assumptions = {};
  Map<String, double> _plannedPrio = {};

  _Route? get _route => _routes.isEmpty ? null : _routes[_sel.clamp(0, _routes.length - 1)];

  @override
  void initState() {
    super.initState();
    _useRegionCorners();
  }

  void _useRegionCorners() {
    final r = ref.read(regionControllerProvider).region;
    if (r != null) {
      _startLat.text = r.south.toStringAsFixed(2);
      _startLon.text = r.west.toStringAsFixed(2);
      _endLat.text = r.north.toStringAsFixed(2);
      _endLon.text = r.east.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _startLat.dispose();
    _startLon.dispose();
    _endLat.dispose();
    _endLon.dispose();
    _hover.dispose();
    _liveTimer?.cancel();
    _ticker?.stop();
    _ticker?.dispose();
    _rover.dispose();
    super.dispose();
  }

  Future<void> _calculateRoute({bool jump = true}) async {
    final sLat = double.tryParse(_startLat.text);
    final sLon = double.tryParse(_startLon.text);
    final eLat = double.tryParse(_endLat.text);
    final eLon = double.tryParse(_endLon.text);

    if (sLat == null || sLon == null || eLat == null || eLon == null) {
      setState(() => err = 'Please enter valid numerical coordinates.');
      return;
    }

    setState(() {
      loading = true;
      err = null;
    });

    try {
      final backend = ref.read(backendProvider);
      final res = await backend.planRoute(
        startLat: sLat,
        startLon: sLon,
        endLat: eLat,
        endLon: eLon,
        priorities: {for (final e in prio.entries) _prioKeys[e.key]!: e.value},
        mapOnly: true,
      );

      if (!mounted) return;
      if (res['ok'] == false) {
        throw Exception('${res['error'] ?? res['detail'] ?? 'Route planning failed.'}');
      }

      final routes = (res['routes'] is List ? res['routes'] as List : const [])
          .whereType<Map>()
          .map((m) => _Route.fromJson(Map<String, dynamic>.from(m)))
          .where((r) => r.path.length >= 2)
          .toList();
      if (routes.isEmpty) throw Exception('Backend returned no routes.');

      // Extent: [west, east, south, north]
      List<double> extent = _dList(res['extent']);
      if (extent.length != 4 && res['region'] is Map) {
        final g = res['region'] as Map;
        extent = [
          _toD(g['west']) ?? 0,
          _toD(g['east']) ?? 1,
          _toD(g['south']) ?? 0,
          _toD(g['north']) ?? 1,
        ];
      }

      _LL? ll(dynamic m, _LL? fallback) {
        if (m is Map) {
          final a = _toD(m['lat']), b = _toD(m['lon']);
          if (a != null && b != null) return _LL(a, b);
        }
        return fallback;
      }

      // Did the new weights actually change the Recommended path?
      String? note;
      if (_routes.isNotEmpty && _plannedPrio.isNotEmpty) {
        final sameWeights = _plannedPrio.entries.every((e) => prio[e.key] == e.value);
        if (!sameWeights) {
          final prevRec = _routes.firstWhere((r) => r.id == 'recommended', orElse: () => _routes.first);
          final nowRec = routes.firstWhere((r) => r.id == 'recommended', orElse: () => routes.first);
          final samePts = prevRec.path.first.lat == nowRec.path.first.lat &&
              prevRec.path.first.lon == nowRec.path.first.lon &&
              prevRec.path.last.lat == nowRec.path.last.lat &&
              prevRec.path.last.lon == nowRec.path.last.lon;
          if (samePts) {
            String key(_LL p) => '${p.lat.toStringAsFixed(3)},${p.lon.toStringAsFixed(3)}';
            final prevSet = prevRec.path.map(key).toSet();
            final diff = nowRec.path.where((p) => !prevSet.contains(key(p))).length;
            final pct = diff / nowRec.path.length * 100;
            final dKm = (_toD(nowRec.stats['distance_km']) ?? 0) -
                (_toD(prevRec.stats['distance_km']) ?? 0);
            note = diff == 0
                ? 'Recommended path is IDENTICAL to the previous plan: these weights did not change '
                    'the cheapest path. This terrain may offer no real trade-off for them. Try Safety 0, '
                    'or push Energy / Distance to an extreme.'
                : 'Recommended path changed: ${pct.toStringAsFixed(0)}% of waypoints differ '
                    '(${dKm >= 0 ? '+' : ''}${dKm.toStringAsFixed(0)} km vs previous).';
          }
        }
      }

      final mapUrl = res['map_url'];
      final fullUrl = mapUrl is String && mapUrl.isNotEmpty ? backend.fullUrl(mapUrl) : null;

      setState(() {
        _routes = routes;
        if (jump && _compact) _tab = 1;
        _sel = 0;
        _step = null;
        _warnings = res['warnings'] is List
            ? (res['warnings'] as List).map((e) => '$e').toList()
            : <String>[];
        _extent = extent.length == 4 ? extent : [0, 1, 0, 1];
        _stopRover();
        _exportMsg = null;
        _prioNote = note;
        _plannedPrio = Map<String, double>.from(prio);
        _assumptions = res['assumptions'] is Map
            ? Map<String, dynamic>.from(res['assumptions'] as Map)
            : <String, dynamic>{};
        _mapOnly = res['map_only'] == true;
        _overlay = _mapOnly; // if backend already drew routes, don't double-draw
        _start = ll(res['start'], routes.first.path.first);
        _end = ll(res['end'], routes.first.path.last);
        if (fullUrl != _mapUrl) {
          _mapUrl = fullUrl;
          _imgSize = null;
        }
      });
      if (fullUrl != null && _imgSize == null) _loadImageSize(fullUrl);
    } catch (e) {
      if (!mounted) return;
      setState(() => err = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
      if (mounted && _livePending) {
        _livePending = false;
        _calculateRoute(jump: false);
      }
    }
  }

  /// Sends the planned routes to the backend and opens the 3D terrain with the routes draped on it.
  Future<void> _viewRoutesIn3D() async {
    if (_routes.isEmpty) return;
    setState(() {
      _building3d = true;
      err = null;
    });
    try {
      final backend = ref.read(backendProvider);
      final res = await backend.renderRoute3D(
        routes: [
          for (var i = 0; i < _routes.length; i++)
            {
              'label': _routes[i].label,
              'primary': i == _sel, // selected route is drawn thickest
              'path': [for (final p in _routes[i].path) [p.lat, p.lon]],
            },
        ],
        extent: _extent,
        vertExag: ref.read(vertExagProvider),
        title: 'Mars Route Plan',
      );
      await launchUrl(Uri.parse(backend.fullUrl(res['url'] as String)));
    } catch (e) {
      if (mounted) setState(() => err = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _building3d = false);
    }
  }

  void _loadImageSize(String url) {
    final stream = NetworkImage(url).resolve(const ImageConfiguration());
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (mounted) {
        setState(() => _imgSize =
            Size(info.image.width.toDouble(), info.image.height.toDouble()));
      }
      stream.removeListener(l);
    }, onError: (e, s) {
      stream.removeListener(l);
    });
    stream.addListener(l);
  }

  // ───────────────────────────── UI building blocks ─────────────────────────

  Widget _panel({
    required String title,
    required Widget child,
    Widget? trailing,
    EdgeInsets padding = const EdgeInsets.all(12),
  }) {
    final titleText = Text(
      title,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: MC.textDim,
        fontSize: 10,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.4,
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: MC.border)),
            ),
            child: (_compact && trailing != null)
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      titleText,
                      const SizedBox(height: 6),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: trailing,
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: titleText),
                      if (trailing != null) trailing,
                    ],
                  ),
          ),
          Expanded(child: Padding(padding: padding, child: child)),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(t,
            style: const TextStyle(
                color: MC.textDim, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
      );

  Widget _field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          style: const TextStyle(color: MC.text, fontSize: 12),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: MC.textDim, fontSize: 11),
            isDense: true,
            enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: MC.border)),
            focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: MC.accent)),
          ),
        ),
      );

  Widget _leftPanel() {
    return _panel(
      title: 'ROUTE DEFINITION',
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pickLabel('START', _Pick.start),
            Row(children: [
              Expanded(child: _field('Lat °N', _startLat)),
              const SizedBox(width: 8),
              Expanded(child: _field('Lon °E', _startLon)),
            ]),
            _pickLabel('DESTINATION', _Pick.end),
            Row(children: [
              Expanded(child: _field('Lat °N', _endLat)),
              const SizedBox(width: 8),
              Expanded(child: _field('Lon °E', _endLon)),
            ]),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() {
                    final a = _startLat.text, b = _startLon.text;
                    _startLat.text = _endLat.text;
                    _startLon.text = _endLon.text;
                    _endLat.text = a;
                    _endLon.text = b;
                  }),
                  icon: const Icon(Icons.swap_vert, size: 14, color: MC.textDim),
                  label: const Text('SWAP', style: TextStyle(color: MC.textDim, fontSize: 10)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(_useRegionCorners),
                  child: const Text('USE REGION CORNERS',
                      style: TextStyle(color: MC.textDim, fontSize: 10)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _tip(
              'How priorities work',
              _prioHowItWorks,
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Row(
                  children: const [
                    Text('PRIORITIES',
                        style: TextStyle(
                            color: MC.textDim,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2)),
                    SizedBox(width: 4),
                    Icon(Icons.info_outline, size: 11, color: MC.textDim),
                    Spacer(),
                    Text('hover for info', style: TextStyle(color: MC.textDim, fontSize: 8)),
                  ],
                ),
              ),
            ),
            for (final k in prio.keys)
              _tip(
                k,
                _prioInfo[k] ?? '',
                Row(
                  children: [
                    SizedBox(
                      width: 108,
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(k,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: MC.text, fontSize: 10)),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.info_outline, size: 11, color: MC.textDim),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: prio[k]!,
                        min: 0,
                        max: 1,
                        divisions: 10,
                        activeColor: MC.accent,
                        inactiveColor: MC.border,
                        label: prio[k]!.toStringAsFixed(1),
                        onChanged: (v) => setState(() => prio[k] = v),
                        onChangeEnd: (_) => _scheduleLive(),
                      ),
                    ),
                    SizedBox(
                      width: 22,
                      child: Text(prio[k]!.toStringAsFixed(1),
                          style: const TextStyle(color: MC.accent, fontSize: 10)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: loading ? null : _calculateRoute,
              icon: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Icon(Icons.route, size: 16),
              label: Text(
                loading ? 'CALCULATING...' : 'PLAN ROUTES',
                style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: MC.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: const RoundedRectangleBorder(),
              ),
            ),
            const SizedBox(height: 4),
            _tip(
              'Auto re-plan',
              'When on, the routes are re-planned automatically (after a short pause) every time '
                  'you release a priority slider. Turn off to plan only when you press PLAN ROUTES.',
              Row(
                children: [
                  Transform.scale(
                    scale: 0.7,
                    child: Switch(
                      value: _live,
                      activeColor: MC.accent,
                      onChanged: (v) => setState(() => _live = v),
                    ),
                  ),
                  const Flexible(
                    child: Text('AUTO RE-PLAN WHEN WEIGHTS CHANGE',
                        style: TextStyle(color: MC.textDim, fontSize: 9)),
                  ),
                ],
              ),
            ),
            if (!_live && _prioDirty)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Weights changed since the last plan. Press PLAN ROUTES to apply them.',
                    style: TextStyle(color: MC.warn, fontSize: 10)),
              ),
            if (_prioNote != null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: MC.accent.withOpacity(0.10),
                  border: Border.all(color: MC.accent),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_prioNote!, style: const TextStyle(color: MC.text, fontSize: 10)),
              ),
            if (_routes.isNotEmpty) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: (loading || _building3d) ? null : _viewRoutesIn3D,
                icon: _building3d
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: MC.accent))
                    : const Icon(Icons.threed_rotation, size: 16, color: MC.accent),
                label: Text(
                  _building3d ? 'BUILDING 3D...' : 'VIEW ROUTES IN 3D',
                  style: const TextStyle(
                      color: MC.accent, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: MC.accent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const RoundedRectangleBorder(),
                ),
              ),
            ],
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err!, style: const TextStyle(color: MC.bad, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }

  // ───────────────────────────── Map picking ────────────────────────────────

  List<double> _regionExtent() {
    final g = ref.watch(regionControllerProvider).region;
    if (g == null || g.east <= g.west || g.north <= g.south) {
      return [216.5, 237.5, 10.25, 26.75];
    }
    return [g.west, g.east, g.south, g.north];
  }

  bool get _hasMap => _mapUrl != null && _imgSize != null;

  _LL? _parseLL(TextEditingController a, TextEditingController b) {
    final la = double.tryParse(a.text), lo = double.tryParse(b.text);
    return (la == null || lo == null) ? null : _LL(la, lo);
  }

  void _pickAt(Offset p, Size size, List<double> e) {
    if (_pick == _Pick.none || size.width <= 0 || size.height <= 0) return;
    final fx = (p.dx / size.width).clamp(0.0, 1.0);
    final fy = (p.dy / size.height).clamp(0.0, 1.0);
    final lon = e[0] + fx * (e[1] - e[0]);
    final lat = e[3] - fy * (e[3] - e[2]);
    setState(() {
      if (_pick == _Pick.start) {
        _startLat.text = lat.toStringAsFixed(3);
        _startLon.text = lon.toStringAsFixed(3);
        _pick = _Pick.end; // auto-advance to destination
      } else {
        _endLat.text = lat.toStringAsFixed(3);
        _endLon.text = lon.toStringAsFixed(3);
        _pick = _Pick.none;
      }
    });
  }

  // ───────────────────────────── Rover playback ─────────────────────────────

  void _stopRover() {
    _ticker?.stop();
    _playing = false;
    _rover.value = null;
  }

  void _onTick(Duration d) {
    final dt = (d - _last).inMicroseconds / 1e6;
    _last = d;
    final cur = _rover.value ?? 0.0;
    final next = cur + dt * _speed / 20.0; // 1× = whole route in 20 seconds
    if (next >= 1.0) {
      _rover.value = 1.0;
      _ticker?.stop();
      if (mounted) setState(() => _playing = false);
    } else {
      _rover.value = next;
    }
  }

  void _togglePlay() {
    if (_route == null) return;
    if (_playing) {
      _ticker?.stop();
      setState(() => _playing = false);
      return;
    }
    if ((_rover.value ?? 0.0) >= 1.0) _rover.value = 0.0;
    _rover.value ??= 0.0;
    _last = Duration.zero;
    _ticker ??= createTicker(_onTick);
    if (!_ticker!.isActive) _ticker!.start();
    setState(() => _playing = true);
  }

  void _restartRover() {
    _rover.value = 0.0;
    if (!_playing) _togglePlay();
  }

  Widget _playbackBar() {
    final r = _route;
    if (r == null) return const SizedBox.shrink();
    final totalKm = _toD(r.stats['distance_km']) ?? 0.0;
    final totalSols = _toD(r.stats['eta_sols']) ?? 0.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ValueListenableBuilder<double?>(
        valueListenable: _rover,
        builder: (_, v, __) {
          final f = v ?? 0.0;
          return Row(
            children: [
              IconButton(
                tooltip: _playing ? 'Pause' : 'Play rover',
                visualDensity: VisualDensity.compact,
                icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                    color: MC.accent, size: 28),
                onPressed: _togglePlay,
              ),
              IconButton(
                tooltip: 'Restart',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.replay, color: MC.textDim, size: 18),
                onPressed: _restartRover,
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 26,
                      child: Slider(
                        value: f.clamp(0.0, 1.0),
                        min: 0,
                        max: 1,
                        activeColor: MC.accent,
                        inactiveColor: MC.border,
                        onChanged: (x) => _rover.value = x,
                      ),
                    ),
                    Text(
                      v == null
                          ? 'ROVER PLAYBACK  ·  press play to drive the ${r.label} route'
                          : 'SOL ${(f * totalSols).round()} / ${totalSols.round()}   ·   '
                              '${(f * totalKm).toStringAsFixed(0)} / ${totalKm.toStringAsFixed(0)} km   ·   '
                              '${r.elevAt(f).round()} m   ·   ${r.slopeAt(f).toStringAsFixed(1)}° slope',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: MC.textDim, fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<double>(
                value: _speed,
                dropdownColor: MC.panel,
                underline: const SizedBox.shrink(),
                isDense: true,
                style: const TextStyle(color: MC.text, fontSize: 11),
                items: [
                  for (final sp in const [0.5, 1.0, 2.0, 4.0, 10.0])
                    DropdownMenuItem(
                      value: sp,
                      child: Text(sp == sp.roundToDouble() ? '${sp.toInt()}×' : '$sp×'),
                    ),
                ],
                onChanged: (x) => setState(() => _speed = x ?? 1.0),
              ),
            ],
          );
        },
      ),
    );
  }

  // ───────────────────────────── Mission brief export ───────────────────────

  Widget _exportMenu() => PopupMenuButton<String>(
        tooltip: 'Export mission brief',
        color: MC.panel,
        enabled: !_exporting && _route != null,
        onSelected: _export,
        itemBuilder: (_) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'html',
            child: Text('Mission brief (HTML → Save as PDF)',
                style: TextStyle(color: MC.text, fontSize: 11)),
          ),
          PopupMenuItem<String>(
            value: 'geojson',
            child: Text('GeoJSON (all routes)', style: TextStyle(color: MC.text, fontSize: 11)),
          ),
          PopupMenuItem<String>(
            value: 'csv',
            child: Text('CSV (selected route waypoints)',
                style: TextStyle(color: MC.text, fontSize: 11)),
          ),
          PopupMenuItem<String>(
            value: 'all',
            child: Text('Export all three', style: TextStyle(color: MC.text, fontSize: 11)),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: MC.accent),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _exporting
                  ? const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 2, color: MC.accent))
                  : const Icon(Icons.download, size: 12, color: MC.accent),
              const SizedBox(width: 5),
              const Text('EXPORT',
                  style: TextStyle(
                      color: MC.accent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
            ],
          ),
        ),
      );

  Future<Directory> _exportDir() async {
    Directory? d;
    try {
      d = await getDownloadsDirectory();
    } catch (_) {}
    d ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${d.path}${Platform.pathSeparator}MarsMissionPlanner');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _export(String kind) async {
    final r = _route;
    if (r == null) return;
    setState(() {
      _exporting = true;
      _exportMsg = null;
      err = null;
    });
    try {
      final dir = await _exportDir();
      final stamp = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '-')
          .replaceAll('T', '_');
      final base = '${dir.path}${Platform.pathSeparator}mission_${r.id}_$stamp';
      final saved = <File>[];
      if (kind == 'html' || kind == 'all') {
        final f = File('$base.html');
        await f.writeAsString(await _buildBriefHtml());
        saved.add(f);
      }
      if (kind == 'geojson' || kind == 'all') {
        final f = File('$base.geojson');
        await f.writeAsString(_buildGeoJson());
        saved.add(f);
      }
      if (kind == 'csv' || kind == 'all') {
        final f = File('$base.csv');
        await f.writeAsString(_buildCsv());
        saved.add(f);
      }
      try {
        final html = saved.where((f) => f.path.endsWith('.html'));
        await launchUrl(Uri.file(html.isNotEmpty ? html.first.path : dir.path));
      } catch (_) {}
      if (!mounted) return;
      setState(() => _exportMsg =
          'Saved ${saved.length} file(s) to ${dir.path}'
          '${kind == 'html' || kind == 'all' ? '  ·  open the HTML and press "Save as PDF"' : ''}');
    } catch (e) {
      if (!mounted) return;
      setState(() => err = 'Export failed: ${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String _hex(Color c) => '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  String _summary(_Route r) {
    final d = _toD(r.stats['distance_km']) ?? 0.0;
    final straight = _toD(r.stats['straight_line_km']) ?? 0.0;
    final sb = StringBuffer();
    sb.write('The ${r.label} route links point A (${_startLat.text}°N, ${_startLon.text}°E) '
        'to point B (${_endLat.text}°N, ${_endLon.text}°E) over ${d.toStringAsFixed(0)} km');
    if (straight > 0) {
      sb.write(' (${(d / straight).toStringAsFixed(2)}× the straight-line distance)');
    }
    sb.write(', with an estimated drive time of ${r.s('eta_label')}. ');
    sb.write('The steepest slope is ${r.n('max_slope_deg', u: '°')} '
        '(mean ${r.n('mean_slope_deg', u: '°')}), with ${r.n('ascent_m', d: 0, u: ' m')} of total '
        'ascent and ${r.n('descent_m', d: 0, u: ' m')} of descent. ');
    sb.write('It is rated ${r.s('difficulty')} with a risk score of ${r.n('risk_score')}. ');
    final notes = <String>[];
    for (final o in _routes) {
      if (o.id == r.id) continue;
      final dd = (_toD(o.stats['distance_km']) ?? 0.0) - d;
      final ds = (_toD(o.stats['max_slope_deg']) ?? 0.0) - (_toD(r.stats['max_slope_deg']) ?? 0.0);
      notes.add('${o.label} is ${dd.abs().toStringAsFixed(0)} km ${dd <= 0 ? 'shorter' : 'longer'} '
          'but its steepest slope is ${ds.abs().toStringAsFixed(1)}° ${ds >= 0 ? 'steeper' : 'gentler'}');
    }
    if (notes.isNotEmpty) sb.write('Alternatives: ${notes.join('; ')}.');
    return sb.toString();
  }

  String _profileSvg(_Route r) {
    final n = math.min(r.pDist.length, r.pElev.length);
    if (n < 2) return '';
    const W = 800.0, H = 200.0, pl = 52.0, pr = 8.0, pt = 8.0, pb = 22.0;
    final lo = r.pElev.take(n).reduce(math.min), hi = r.pElev.take(n).reduce(math.max);
    final range = (hi - lo) == 0 ? 1.0 : hi - lo;
    final maxD = r.pDist[n - 1] == 0 ? 1.0 : r.pDist[n - 1];
    final pts = <String>[];
    for (var i = 0; i < n; i++) {
      final x = pl + r.pDist[i] / maxD * (W - pl - pr);
      final y = pt + (1 - (r.pElev[i] - lo) / range) * (H - pt - pb);
      pts.add('${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}');
    }
    final col = _hex(_routeColor(r.id));
    final area = '$pl,${H - pb} ${pts.join(' ')} ${W - pr},${H - pb}';
    return '<svg class="prof" viewBox="0 0 800 200" xmlns="http://www.w3.org/2000/svg">'
        '<polygon points="$area" fill="$col" fill-opacity="0.18"/>'
        '<polyline points="${pts.join(' ')}" fill="none" stroke="$col" stroke-width="2"/>'
        '<text x="4" y="${pt + 8}" font-size="10" fill="#6b7280">${hi.round()} m</text>'
        '<text x="4" y="${H - pb}" font-size="10" fill="#6b7280">${lo.round()} m</text>'
        '<text x="$pl" y="${H - 6}" font-size="10" fill="#6b7280">0 km</text>'
        '<text x="${W - 60}" y="${H - 6}" font-size="10" fill="#6b7280">${maxD.toStringAsFixed(0)} km</text>'
        '</svg>';
  }

  Future<String> _buildBriefHtml() async {
    final r = _route!;
    final ext = _extent;
    final w = ext[0], e = ext[1], s = ext[2], n = ext[3];
    final okExt = ext.length == 4 && e > w && n > s;

    String? b64;
    if (_mapUrl != null) {
      try {
        final resp = await http.get(Uri.parse(_mapUrl!)).timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) b64 = base64Encode(resp.bodyBytes);
      } catch (_) {}
    }

    double px(double lon) => (lon - w) / (e - w) * 100;
    double py(double lat) => (n - lat) / (n - s) * 100;
    final drawOverlay = okExt && (_mapOnly || b64 == null);

    final b = StringBuffer();
    b.writeln('<!doctype html><html lang="en"><head><meta charset="utf-8">');
    b.writeln('<meta name="viewport" content="width=device-width, initial-scale=1">');
    b.writeln('<title>${_esc('Mission Brief – ${r.label}')}</title>');
    b.writeln('<style>$_briefCss</style></head><body>');
    b.writeln('<button class="print no-print" onclick="window.print()">Save as PDF</button>');
    b.writeln('<div class="page">');
    b.writeln('<header><h1>MARS MISSION BRIEF</h1>'
        '<div class="sub">Generated ${DateTime.now().toString().substring(0, 16)} · '
        'Mars Mission Planner · NASA Space Apps 2026</div></header>');

    b.writeln('<h2>Summary</h2><div class="summary">${_esc(_summary(r))}</div>');

    b.writeln('<h2>Route map</h2>');
    final aspect = okExt ? ((e - w) / (n - s)).toStringAsFixed(3) : '1.2';
    b.writeln('<div class="map"${b64 == null ? ' style="aspect-ratio:$aspect"' : ''}>');
    if (b64 != null) b.writeln('<img alt="Terrain map" src="data:image/png;base64,$b64">');
    if (drawOverlay) {
      b.writeln('<svg viewBox="0 0 1000 1000" preserveAspectRatio="none">');
      for (final o in _routes) {
        if (o.id == r.id) continue;
        final pts = o.path
            .map((q) => '${(px(q.lon) * 10).toStringAsFixed(1)},${(py(q.lat) * 10).toStringAsFixed(1)}')
            .join(' ');
        b.writeln('<polyline points="$pts" fill="none" stroke="${_hex(_routeColor(o.id))}" '
            'stroke-width="2.5" stroke-opacity="0.8" vector-effect="non-scaling-stroke"/>');
      }
      final sp = r.path
          .map((q) => '${(px(q.lon) * 10).toStringAsFixed(1)},${(py(q.lat) * 10).toStringAsFixed(1)}')
          .join(' ');
      b.writeln('<polyline points="$sp" fill="none" stroke="#fff" stroke-width="7" '
          'vector-effect="non-scaling-stroke"/>');
      b.writeln('<polyline points="$sp" fill="none" stroke="${_hex(_routeColor(r.id))}" '
          'stroke-width="4" vector-effect="non-scaling-stroke"/>');
      b.writeln('</svg>');
      b.writeln('<div class="pin a" style="left:${px(r.path.first.lon).toStringAsFixed(2)}%;'
          'top:${py(r.path.first.lat).toStringAsFixed(2)}%">A</div>');
      b.writeln('<div class="pin b" style="left:${px(r.path.last.lon).toStringAsFixed(2)}%;'
          'top:${py(r.path.last.lat).toStringAsFixed(2)}%">B</div>');
    }
    b.writeln('</div>');
    b.writeln('<div class="legend">${_routes.map((o) => '<span><i style="background:${_hex(_routeColor(o.id))}"></i>'
        '${_esc(o.label)}${o.id == r.id ? ' (selected)' : ''}</span>').join()}</div>');

    String tile(String k, String v) =>
        '<div class="tile"><small>${_esc(k)}</small><b>${_esc(v)}</b></div>';
    final wh = _toD(r.stats['energy_wh']);
    b.writeln('<h2>Key figures · ${_esc(r.label)}</h2><div class="grid">'
        '${tile('Distance', r.n('distance_km', u: ' km'))}'
        '${tile('Straight line', r.n('straight_line_km', u: ' km'))}'
        '${tile('ETA', r.s('eta_label'))}'
        '${tile('Energy', wh == null ? '—' : '${(wh / 1000).toStringAsFixed(0)} kWh')}'
        '${tile('Difficulty', r.s('difficulty'))}'
        '${tile('Ascent', r.n('ascent_m', d: 0, u: ' m'))}'
        '${tile('Descent', r.n('descent_m', d: 0, u: ' m'))}'
        '${tile('Mean slope', r.n('mean_slope_deg', u: '°'))}'
        '${tile('Max slope', r.n('max_slope_deg', u: '°'))}'
        '${tile('Risk score', r.n('risk_score'))}'
        '</div>');

    b.writeln('<h2>Elevation profile</h2>${_profileSvg(r)}');

    b.writeln('<h2>Route comparison</h2><table><tr><th>Route</th><th>Distance</th><th>ETA</th>'
        '<th>Ascent</th><th>Max slope</th><th>Risk</th><th>Difficulty</th></tr>');
    for (final o in _routes) {
      b.writeln('<tr${o.id == r.id ? ' class="sel"' : ''}><td>${_esc(o.label)}'
          '${o.tags.isEmpty ? '' : ' (${_esc(o.tags.join(', '))})'}</td>'
          '<td>${o.n('distance_km', d: 0, u: ' km')}</td><td>${_esc(o.s('eta_label'))}</td>'
          '<td>${o.n('ascent_m', d: 0, u: ' m')}</td><td>${o.n('max_slope_deg', u: '°')}</td>'
          '<td>${o.n('risk_score')}</td><td>${_esc(o.s('difficulty'))}</td></tr>');
    }
    b.writeln('</table>');

    if (_warnings.isNotEmpty) {
      b.writeln('<h2>Warnings</h2>');
      for (final x in _warnings) {
        b.writeln('<div class="warn">${_esc(x)}</div>');
      }
    }

    b.writeln('<h2>Turn-by-turn · ${_esc(r.label)}</h2><ol>');
    for (final st in r.steps) {
      b.writeln('<li>${_esc(st.instruction)}</li>');
    }
    b.writeln('</ol>');

    b.writeln('<h2>Mission priorities &amp; assumptions</h2><ul>');
    if (_plannedPrio.isNotEmpty) {
      b.writeln('<li><b>Priorities:</b> ${_plannedPrio.entries.map((x) => '${_esc(x.key)} ${x.value.toStringAsFixed(1)}').join(' · ')}</li>');
    }
    _assumptions.forEach((k, v) {
      final val = v is Map ? v.entries.map((x) => '${x.key} = ${x.value}').join(', ') : '$v';
      b.writeln('<li><b>${_esc(k)}:</b> ${_esc(val)}</li>');
    });
    b.writeln('</ul>');

    b.writeln('<footer>Mars Mission Planner · NASA Space Apps 2026 · '
        'Energy and ETA are rough estimates from slope and distance only.</footer>');
    b.writeln('</div></body></html>');
    return b.toString();
  }

  String _buildGeoJson() {
    double l180(double lon) => lon > 180 ? lon - 360 : lon;
    final feats = <Map<String, dynamic>>[];
    final sel = _route!;
    for (final r in _routes) {
      feats.add({
        'type': 'Feature',
        'properties': {
          'id': r.id,
          'label': r.label,
          'tags': r.tags,
          'selected': r.id == sel.id,
          ...r.stats,
        },
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (var i = 0; i < r.path.length; i++)
              [
                double.parse(l180(r.path[i].lon).toStringAsFixed(5)),
                double.parse(r.path[i].lat.toStringAsFixed(5)),
                double.parse(r.pathElev[i].toStringAsFixed(1)),
              ],
          ],
        },
      });
    }
    Map<String, dynamic> pt(String name, _LL p, double elev) => {
          'type': 'Feature',
          'properties': {'name': name},
          'geometry': {
            'type': 'Point',
            'coordinates': [l180(p.lon), p.lat, double.parse(elev.toStringAsFixed(1))],
          },
        };
    feats.add(pt('Start (A)', sel.path.first, sel.pathElev.first));
    feats.add(pt('Destination (B)', sel.path.last, sel.pathElev.last));
    return const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'name': 'Mars Mission Planner routes',
      'description': 'Longitudes converted from 0..360 °E to -180..180. Elevation in metres (MOLA).',
      'features': feats,
    });
  }

  String _buildCsv() {
    final r = _route!;
    final total = r.cum.isEmpty ? 0.0 : r.cum.last;
    final km = _toD(r.stats['distance_km']) ?? 0.0;
    final sb = StringBuffer('index,lat_deg_n,lon_deg_e,elevation_m,distance_km,fraction\n');
    for (var i = 0; i < r.path.length; i++) {
      final f = total == 0 ? 0.0 : r.cum[i] / total;
      sb.writeln('$i,${r.path[i].lat.toStringAsFixed(5)},${r.path[i].lon.toStringAsFixed(5)},'
          '${r.pathElev[i].toStringAsFixed(1)},${(f * km).toStringAsFixed(2)},${f.toStringAsFixed(4)}');
    }
    return sb.toString();
  }

  // ───────────────────────────── Priorities helpers ─────────────────────────

  bool get _prioDirty =>
      _plannedPrio.isNotEmpty && _plannedPrio.entries.any((e) => prio[e.key] != e.value);

  void _scheduleLive() {
    if (!_live || _routes.isEmpty) return;
    _liveTimer?.cancel();
    _liveTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (loading) {
        _livePending = true; // re-plan as soon as the current plan finishes
      } else {
        _calculateRoute(jump: false);
      }
    });
  }

  Widget _tip(String title, String body, Widget child) => Tooltip(
        message: '$title\n${_wrapText(body, 46)}',
        waitDuration: const Duration(milliseconds: 250),
        showDuration: const Duration(seconds: 10),
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(color: MC.text, fontSize: 11, height: 1.35),
        decoration: BoxDecoration(
          color: const Color(0xF2121A24),
          border: Border.all(color: MC.accent),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );

  Widget _pickLabel(String t, _Pick m) {
    final on = _pick == m;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Row(
        children: [
          Text(t,
              style: const TextStyle(
                  color: MC.textDim, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          const Spacer(),
          InkWell(
            onTap: () => setState(() {
              _pick = on ? _Pick.none : m;
              if (_compact && !on) _tab = 1;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: on ? MC.accent : Colors.transparent,
                border: Border.all(color: MC.accent),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.place, size: 11, color: on ? Colors.black : MC.accent),
                  const SizedBox(width: 4),
                  Text('PICK ON MAP',
                      style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                          color: on ? Colors.black : MC.accent)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickBtn(String t, _Pick m, Color c) {
    final on = _pick == m;
    return OutlinedButton(
      onPressed: () => setState(() => _pick = on ? _Pick.none : m),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: c),
        backgroundColor: on ? c : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 24),
        shape: const RoundedRectangleBorder(),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(t,
          style: TextStyle(
              color: on ? Colors.black : c, fontSize: 9, fontWeight: FontWeight.bold)),
    );
  }

  Widget _mapPanel() {
    final r = _route;
    final ext = _hasMap ? _extent : _regionExtent();
    final aspect = _hasMap
        ? _imgSize!.width / _imgSize!.height
        : (ext[1] - ext[0]) / (ext[3] - ext[2]);
    final waiting = _mapUrl != null && _imgSize == null;
    final slice = (r != null && _step != null && _step! < r.steps.length)
        ? r.slice(r.stepStarts[_step!], r.stepStarts[_step! + 1])
        : null;

    final Widget body = waiting
        ? const Center(child: CircularProgressIndicator(color: MC.accent))
        : ClipRect(
            child: InteractiveViewer(
              maxScale: 10,
              child: Center(
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final size = Size(c.maxWidth, c.maxHeight);
                      return MouseRegion(
                        cursor: _pick == _Pick.none
                            ? MouseCursor.defer
                            : SystemMouseCursors.precise,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) => _pickAt(d.localPosition, size, ext),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (_hasMap)
                                Image.network(
                                  _mapUrl!,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, __, ___) => const Center(
                                    child: Text('Failed to load map image from backend',
                                        style: TextStyle(color: MC.bad)),
                                  ),
                                )
                              else
                                CustomPaint(painter: _GridPainter(ext)),
                              if (_hasMap && _overlay && _routes.isNotEmpty)
                                CustomPaint(
                                  painter: _RoutePainter(
                                    routes: _routes,
                                    selected: _sel,
                                    extent: _extent,
                                    stepSlice: slice,
                                    start: _start,
                                    end: _end,
                                    hover: _hover,
                                    rover: _rover,
                                  ),
                                ),
                              AnimatedBuilder(
                                animation: Listenable.merge(
                                    [_startLat, _startLon, _endLat, _endLon]),
                                builder: (_, __) => CustomPaint(
                                  painter: _PickPainter(
                                    extent: ext,
                                    start: _parseLL(_startLat, _startLon),
                                    end: _parseLL(_endLat, _endLon),
                                  ),
                                ),
                              ),
                              if (!_hasMap)
                                Positioned(
                                  left: 8,
                                  bottom: 8,
                                  right: 8,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    color: Colors.black.withOpacity(0.6),
                                    child: const Text(
                                      'Press SET START / SET DEST, then click the map. '
                                      'Terrain appears after your first PLAN ROUTES.',
                                      style: TextStyle(color: MC.textDim, fontSize: 10),
                                    ),
                                  ),
                                ),
                              if (loading)
                                const Center(
                                    child: CircularProgressIndicator(color: MC.accent)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );

    return _panel(
      title: 'ROUTE MAP',
      padding: EdgeInsets.zero,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pickBtn('SET START', _Pick.start, const Color(0xFF3DDC84)),
          const SizedBox(width: 6),
          _pickBtn('SET DEST', _Pick.end, const Color(0xFFFF4D4D)),
          if (r != null) ...[
            const SizedBox(width: 10),
            const Text('OVERLAY', style: TextStyle(color: MC.textDim, fontSize: 9)),
            Transform.scale(
              scale: 0.7,
              child: Switch(
                value: _overlay,
                activeColor: MC.accent,
                onChanged: (v) => setState(() => _overlay = v),
              ),
            ),
          ],
        ],
      ),
      child: Container(color: Colors.black, child: body),
    );
  }

  Widget _profilePanel() {
    final r = _route;
    if (r == null) return const SizedBox.shrink();
    final c = _routeColor(r.id);
    return _panel(
      title: 'ELEVATION PROFILE · ${r.label.toUpperCase()}',
      trailing: ValueListenableBuilder<double?>(
        valueListenable: _hover,
        builder: (_, f, __) => Text(
          f == null
              ? '▲ ${r.n('ascent_m', d: 0, u: ' m')}   ▼ ${r.n('descent_m', d: 0, u: ' m')}'
              : r.readout(f),
          style: const TextStyle(color: MC.text, fontSize: 10),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: LayoutBuilder(
        builder: (context, cons) => MouseRegion(
          onHover: (e) {
            final w = cons.maxWidth - _kPadL - _kPadR;
            if (w <= 0) return;
            _hover.value = ((e.localPosition.dx - _kPadL) / w).clamp(0.0, 1.0);
          },
          onExit: (_) => _hover.value = null,
          child: GestureDetector(
            onHorizontalDragUpdate: (d) {
              final w = cons.maxWidth - _kPadL - _kPadR;
              if (w <= 0) return;
              _hover.value = ((d.localPosition.dx - _kPadL) / w).clamp(0.0, 1.0);
            },
            onHorizontalDragEnd: (_) => _hover.value = null,
            child: CustomPaint(
              size: Size(cons.maxWidth, cons.maxHeight),
              painter: _ProfilePainter(
                dist: r.pDist,
                elev: r.pElev,
                color: c,
                hover: _hover,
                rover: _rover,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _routeCard(int i) {
    final r = _routes[i];
    final sel = i == _sel;
    final c = _routeColor(r.id);
    return InkWell(
      onTap: () => setState(() {
        _sel = i;
        _step = null;
        _stopRover();
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: sel ? c.withOpacity(0.12) : Colors.transparent,
          border: Border.all(color: sel ? c : MC.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Container(width: 4, height: 36, color: c),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(r.label,
                          style: const TextStyle(
                              color: MC.text, fontSize: 12, fontWeight: FontWeight.bold)),
                      for (final t in r.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(color: c),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(t, style: TextStyle(color: c, fontSize: 8)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${r.n('distance_km', d: 0, u: ' km')}  ·  ${r.s('eta_label')}  ·  ${r.s('difficulty')}',
                    style: const TextStyle(color: MC.textDim, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statTile(String k, String v) => SizedBox(
        width: 140,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(k.toUpperCase(),
                  style: const TextStyle(color: MC.textDim, fontSize: 8, letterSpacing: 1)),
              const SizedBox(height: 1),
              Text(v,
                  style: const TextStyle(
                      color: MC.text, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );

  Widget _routesPanel() {
    final r = _route!;
    final wh = _toD(r.stats['energy_wh']);

    final cards = Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Column(children: [for (var i = 0; i < _routes.length; i++) _routeCard(i)]),
    );
    final stats = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(
        children: [
          _statTile('Distance', r.n('distance_km', u: ' km')),
          _statTile('Straight line', r.n('straight_line_km', u: ' km')),
          _statTile('ETA', r.s('eta_label')),
          _statTile('Energy', wh == null ? '—' : '${(wh / 1000).toStringAsFixed(0)} kWh'),
          _statTile('Ascent', r.n('ascent_m', d: 0, u: ' m')),
          _statTile('Descent', r.n('descent_m', d: 0, u: ' m')),
          _statTile('Mean slope', r.n('mean_slope_deg', u: '°')),
          _statTile('Max slope', r.n('max_slope_deg', u: '°')),
          _statTile('Risk score', r.n('risk_score')),
          _statTile('Difficulty', r.s('difficulty')),
        ],
      ),
    );

    Widget stepTile(int i) {
      final st = r.steps[i];
      final on = _step == i;
      return InkWell(
        onTap: () => setState(() {
          _step = on ? null : i;
          if (_compact && !on) _tab = 1; // show the highlighted leg on the map
        }),
        child: Container(
          color: on ? const Color(0x33FFE066) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(_stepIcon(st.instruction), size: 16, color: MC.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(st.instruction,
                    style: const TextStyle(color: MC.text, fontSize: 11)),
              ),
              if (st.distanceKm > 0)
                Text('${st.distanceKm.toStringAsFixed(0)} km',
                    style: const TextStyle(color: MC.textDim, fontSize: 10)),
            ],
          ),
        ),
      );
    }

    const div = Divider(color: MC.border, height: 1);

    return _panel(
      title: 'ROUTES',
      trailing: _exportMenu(),
      padding: EdgeInsets.zero,
      child: _compact
          ? ListView(
              padding: EdgeInsets.zero,
              children: [
                cards,
                div,
                stats,
                div,
                for (var i = 0; i < r.steps.length; i++) stepTile(i),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cards,
                div,
                stats,
                div,
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: r.steps.length,
                    itemBuilder: (_, i) => stepTile(i),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _banner(String text, Color c, IconData icon) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          border: Border.all(color: c),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: c, fontSize: 10))),
          ],
        ),
      );

  List<Widget> _bannerList(bool has) => [
        if (_pick != _Pick.none)
          _banner(
            _pick == _Pick.start
                ? 'Tap the map to place the START point.'
                : 'Tap the map to place the DESTINATION point.',
            MC.accent,
            Icons.touch_app,
          ),
        if (_exportMsg != null) _banner(_exportMsg!, MC.good, Icons.check_circle_outline),
        for (final w in _warnings) _banner(w, MC.warn, Icons.warning_amber),
        if (has && !_mapOnly)
          _banner(
            'Backend did not return a bare map (map_only=false), so the overlay is off by default. '
            'Turn OVERLAY on to try drawing routes over it.',
            MC.textDim,
            Icons.info_outline,
          ),
      ];

  Widget _tabBar(bool has) {
    Widget seg(int i, String label, IconData icon, {bool enabled = true}) {
      final on = _tab == i;
      final col = !enabled ? MC.border : (on ? MC.accent : MC.textDim);
      return Expanded(
        child: InkWell(
          onTap: enabled ? () => setState(() => _tab = i) : null,
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? MC.accent.withOpacity(0.14) : Colors.transparent,
              border: Border(
                bottom: BorderSide(color: on ? MC.accent : MC.border, width: on ? 2 : 1),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: col),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: col,
                        fontSize: 10.5,
                        letterSpacing: 1,
                        fontWeight: on ? FontWeight.bold : FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(children: [
        seg(0, 'PLAN', Icons.tune),
        seg(1, 'MAP', Icons.map_outlined),
        seg(2, 'ROUTES', Icons.alt_route, enabled: has),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final has = _route != null;
    return LayoutBuilder(builder: (context, cons) {
      _compact = cons.maxWidth < 1150;
      final pad = cons.maxWidth < 600 ? 10.0 : 16.0;
      final banners = _bannerList(has);

      // ── Desktop: original three-column layout ──
      if (!_compact) {
        return Padding(
          padding: EdgeInsets.all(pad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 300, child: _leftPanel()),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...banners,
                    Expanded(child: _mapPanel()),
                    if (has) ...[
                      const SizedBox(height: 12),
                      _playbackBar(),
                      const SizedBox(height: 12),
                      SizedBox(height: 170, child: _profilePanel()),
                    ],
                  ],
                ),
              ),
              if (has) ...[
                const SizedBox(width: 12),
                SizedBox(width: 340, child: _routesPanel()),
              ],
            ],
          ),
        );
      }

      // ── Phone / tablet: three tabs (PLAN · MAP · ROUTES) ──
      final tab = (_tab == 2 && !has) ? 0 : _tab;
      final tall = cons.maxHeight >= 560;
      final medium = cons.maxHeight >= 420;

      Widget bannerBox() => banners.isEmpty
          ? const SizedBox.shrink()
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(child: Column(children: banners)),
            );

      Widget content;
      if (tab == 0) {
        content = _leftPanel();
      } else if (tab == 1) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            bannerBox(),
            Expanded(child: _mapPanel()),
            if (has && medium) ...[
              const SizedBox(height: 8),
              _playbackBar(),
            ],
            if (has && tall) ...[
              const SizedBox(height: 8),
              SizedBox(height: 150, child: _profilePanel()),
            ],
          ],
        );
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            bannerBox(),
            Expanded(child: _routesPanel()),
          ],
        );
      }

      return Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _tabBar(has),
            const SizedBox(height: 8),
            Expanded(child: content),
          ],
        ),
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painters
// ─────────────────────────────────────────────────────────────────────────────

class _RoutePainter extends CustomPainter {
  final List<_Route> routes;
  final int selected;
  final List<double> extent; // west, east, south, north
  final List<_LL>? stepSlice;
  final _LL? start, end;
  final ValueNotifier<double?> hover;
  final ValueNotifier<double?> rover;

  _RoutePainter({
    required this.routes,
    required this.selected,
    required this.extent,
    required this.stepSlice,
    required this.start,
    required this.end,
    required this.hover,
    required this.rover,
  }) : super(repaint: Listenable.merge([hover, rover]));

  Offset _px(_LL p, Size s) => Offset(
        (p.lon - extent[0]) / (extent[1] - extent[0]) * s.width,
        (extent[3] - p.lat) / (extent[3] - extent[2]) * s.height,
      );

  Path _path(List<_LL> pts, Size s) {
    final p = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = _px(pts[i], s);
      if (i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    return p;
  }

  Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  void _dot(Canvas canvas, Offset o, double r, Color fill) {
    canvas.drawCircle(o, r + 2, Paint()..color = Colors.white);
    canvas.drawCircle(o, r, Paint()..color = fill);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (extent.length != 4 || routes.isEmpty) return;
    final k = (size.width / 700).clamp(0.6, 3.0);

    // Alternatives first (thin), selected last (bold, on top).
    for (var i = 0; i < routes.length; i++) {
      if (i == selected) continue;
      final c = _routeColor(routes[i].id);
      canvas.drawPath(_path(routes[i].path, size), _stroke(Colors.black.withOpacity(0.45), 4.5 * k));
      canvas.drawPath(_path(routes[i].path, size), _stroke(c.withOpacity(0.75), 3 * k));
    }
    final sel = routes[selected.clamp(0, routes.length - 1)];
    final sp = _path(sel.path, size);
    canvas.drawPath(sp, _stroke(Colors.white, 8 * k));
    canvas.drawPath(sp, _stroke(_routeColor(sel.id), 5 * k));

    if (stepSlice != null && stepSlice!.length >= 2) {
      final hp = _path(stepSlice!, size);
      canvas.drawPath(hp, _stroke(Colors.black, 10 * k));
      canvas.drawPath(hp, _stroke(const Color(0xFFFFE066), 6.5 * k));
    }

    if (start != null) _dot(canvas, _px(start!, size), 6 * k, const Color(0xFF3DDC84));
    if (end != null) _dot(canvas, _px(end!, size), 6 * k, const Color(0xFFFF4D4D));

    final h = hover.value;
    if (h != null) {
      final o = _px(sel.pointAt(h), size);
      canvas.drawCircle(o, 8 * k, Paint()..color = Colors.black.withOpacity(0.5));
      _dot(canvas, o, 5.5 * k, Colors.white);
      canvas.drawCircle(o, 3 * k, Paint()..color = _routeColor(sel.id));
    }

    // Rover + travelled trail
    final rv = rover.value;
    if (rv != null) {
      if (rv > 0) {
        final trail = _path(sel.slice(0, rv), size);
        canvas.drawPath(trail, _stroke(Colors.black, 7.5 * k));
        canvas.drawPath(trail, _stroke(Colors.white, 4.5 * k));
      }
      final a = _px(sel.pointAt(rv), size);
      final b = _px(sel.pointAt((rv + 0.004).clamp(0.0, 1.0)), size);
      var ang = (b - a).direction;
      if ((b - a).distance < 0.01) {
        final a0 = _px(sel.pointAt((rv - 0.004).clamp(0.0, 1.0)), size);
        ang = (a - a0).direction;
      }
      _drawRover(canvas, a, ang, k);
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) => true;
}

const double _kPadL = 46;
const double _kPadR = 10;

class _ProfilePainter extends CustomPainter {
  final List<double> dist, elev;
  final Color color;
  final ValueNotifier<double?> hover;
  final ValueNotifier<double?> rover;

  _ProfilePainter({
    required this.dist,
    required this.elev,
    required this.color,
    required this.hover,
    required this.rover,
  }) : super(repaint: Listenable.merge([hover, rover]));

  void _text(Canvas c, String t, Offset o, {bool right = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: const TextStyle(color: MC.textDim, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = o.dx;
    if (right) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    tp.paint(c, Offset(dx, o.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = math.min(dist.length, elev.length);
    if (n < 2) return;
    const padT = 6.0, padB = 18.0;
    final w = size.width - _kPadL - _kPadR;
    final h = size.height - padT - padB;
    if (w <= 0 || h <= 0) return;

    final minE = elev.take(n).reduce(math.min);
    final maxE = elev.take(n).reduce(math.max);
    final range = (maxE - minE) == 0 ? 1.0 : (maxE - minE);
    final maxD = dist[n - 1] == 0 ? 1.0 : dist[n - 1];

    Offset pt(int i) => Offset(
          _kPadL + dist[i] / maxD * w,
          padT + (1 - (elev[i] - minE) / range) * h,
        );

    // Grid + y labels
    final grid = Paint()
      ..color = MC.border
      ..strokeWidth = 1;
    for (var g = 0; g <= 2; g++) {
      final y = padT + h * g / 2;
      canvas.drawLine(Offset(_kPadL, y), Offset(_kPadL + w, y), grid);
      final v = maxE - range * g / 2;
      _text(canvas, '${v.toStringAsFixed(0)} m', Offset(_kPadL - 4, y), right: true);
    }
    _text(canvas, '0 km', Offset(_kPadL, padT + h + 10), center: true);
    _text(canvas, '${maxD.toStringAsFixed(0)} km', Offset(_kPadL + w, padT + h + 10), center: true);

    // Area + line
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < n; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(_kPadL + w, padT + h)
      ..lineTo(_kPadL, padT + h)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.45), color.withOpacity(0.03)],
        ).createShader(Rect.fromLTWH(_kPadL, padT, w, h)),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    // Hover cursor
    final f = hover.value;
    if (f != null) {
      final x = _kPadL + f * w;
      canvas.drawLine(
        Offset(x, padT),
        Offset(x, padT + h),
        Paint()
          ..color = Colors.white.withOpacity(0.7)
          ..strokeWidth = 1,
      );
      final d = f * maxD;
      var idx = n - 1;
      for (var i = 0; i < n; i++) {
        if (dist[i] >= d) {
          idx = i;
          break;
        }
      }
      canvas.drawCircle(Offset(x, pt(idx).dy), 4, Paint()..color = Colors.white);
    }

    // Rover cursor
    final rv = rover.value;
    if (rv != null) {
      final x = _kPadL + rv * w;
      canvas.drawLine(
        Offset(x, padT),
        Offset(x, padT + h),
        Paint()
          ..color = MC.accent
          ..strokeWidth = 1.5,
      );
      final d = rv * maxD;
      var idx = n - 1;
      for (var i = 0; i < n; i++) {
        if (dist[i] >= d) {
          idx = i;
          break;
        }
      }
      canvas.drawCircle(Offset(x, pt(idx).dy), 5, Paint()..color = MC.accent);
      canvas.drawCircle(
        Offset(x, pt(idx).dy),
        5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ProfilePainter old) =>
      old.dist != dist || old.elev != elev || old.color != color;
}

// Markers A (start) / B (destination) drawn from the coordinate fields.
class _PickPainter extends CustomPainter {
  final List<double> extent; // west, east, south, north
  final _LL? start, end;
  _PickPainter({required this.extent, required this.start, required this.end});

  Offset _px(_LL p, Size s) => Offset(
        (p.lon - extent[0]) / (extent[1] - extent[0]) * s.width,
        (extent[3] - p.lat) / (extent[3] - extent[2]) * s.height,
      );

  void _pin(Canvas c, Offset o, Color col, String letter, double k) {
    c.drawCircle(o, 12 * k, Paint()..color = Colors.white);
    c.drawCircle(o, 10 * k, Paint()..color = col);
    final tp = TextPainter(
      text: TextSpan(
        text: letter,
        style: TextStyle(color: Colors.black, fontSize: 12 * k, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (extent.length != 4) return;
    final k = (size.width / 700).clamp(0.6, 2.5);
    if (start != null && end != null) {
      canvas.drawLine(
        _px(start!, size),
        _px(end!, size),
        Paint()
          ..color = Colors.white.withOpacity(0.35)
          ..strokeWidth = 1.5 * k,
      );
    }
    if (start != null) _pin(canvas, _px(start!, size), const Color(0xFF3DDC84), 'A', k);
    if (end != null) _pin(canvas, _px(end!, size), const Color(0xFFFF4D4D), 'B', k);
  }

  @override
  bool shouldRepaint(covariant _PickPainter old) =>
      old.start != start || old.end != end || old.extent != extent;
}

// Lat/lon grid shown before any terrain image exists, so you can still pick points.
class _GridPainter extends CustomPainter {
  final List<double> extent; // west, east, south, north
  _GridPainter(this.extent);

  double _step(double span) {
    final t = span / 6;
    for (final s in [0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0]) {
      if (s >= t) return s;
    }
    return 20.0;
  }

  void _text(Canvas c, String t, Offset o) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: const TextStyle(color: MC.textDim, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B0F14));
    final w = extent[0], e = extent[1], s = extent[2], n = extent[3];
    if (e <= w || n <= s) return;
    final line = Paint()
      ..color = MC.border
      ..strokeWidth = 1;

    final ls = _step(e - w);
    for (var lon = (w / ls).ceil() * ls; lon <= e; lon += ls) {
      final x = (lon - w) / (e - w) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      _text(canvas, '${lon.toStringAsFixed(ls < 1 ? 2 : 0)}°E', Offset(x + 3, size.height - 13));
    }
    final bs = _step(n - s);
    for (var lat = (s / bs).ceil() * bs; lat <= n; lat += bs) {
      final y = (n - lat) / (n - s) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      _text(canvas, '${lat.toStringAsFixed(bs < 1 ? 2 : 0)}°N', Offset(4, y + 2));
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = MC.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.extent != extent;
}