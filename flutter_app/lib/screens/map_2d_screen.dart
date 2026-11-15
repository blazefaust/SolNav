import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../models/region.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_card.dart';
import '../widgets/mc_common.dart';
import '../widgets/stat_row.dart';

class Map2DScreen extends ConsumerStatefulWidget {
  const Map2DScreen({super.key});

  @override
  ConsumerState<Map2DScreen> createState() => _Map2DScreenState();
}

class _Map2DScreenState extends ConsumerState<Map2DScreen> {
  String? imageUrl;
  Map<String, dynamic>? stats;
  bool loading = false;
  String? err;

  double? _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  String _stat(String key, {int digits = 0, String unit = ''}) {
    final v = _num(stats?[key]);
    return v == null ? '—' : '${v.toStringAsFixed(digits)}$unit';
  }

  Future<void> _render() async {
    final region = ref.read(regionControllerProvider).region;
    if (region == null) {
      setState(() => err = 'Select a region first.');
      return;
    }

    setState(() {
      loading = true;
      err = null;
    });

    try {
      final backend = ref.read(backendProvider);
      final activeLayers = ref.read(activeLayersProvider);

      final res = await backend.render2D(
        region: region,
        layers: activeLayers,
        title: ref.read(regionControllerProvider).landmarkName ?? 'Mars Terrain',
      );
      debugPrint('render2d response: $res');

      if (!mounted) return;

      final r = res['region'];
      if (r is Map) {
        final s = _num(r['south']);
        final n = _num(r['north']);
        final w = _num(r['west']);
        final e = _num(r['east']);
        if (s != null && n != null && w != null && e != null) {
          ref.read(regionControllerProvider.notifier).setRegion(
                Region(south: s, north: n, west: w, east: e),
                ref.read(regionControllerProvider).landmarkName ?? 'Mars',
              );
        }
      }

      final url = res['url'];
      if (url is! String || url.isEmpty) {
        throw Exception('Backend did not return an image url.');
      }

      final sel = await backend.selectRegion(
        ref.read(regionControllerProvider).region ?? region,
      );
      debugPrint('select-region response: $sel');

      if (!mounted) return;
      final st = sel['statistics'];
      setState(() {
        imageUrl = backend.fullUrl(url);
        stats = st is Map ? Map<String, dynamic>.from(st) : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => err = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _handleFitTile() {
    final st = ref.read(statusProvider).asData?.value;
    final b = st?['bounds'];
    if (b is Map) {
      ref
          .read(regionControllerProvider.notifier)
          .fitToTile(Map<String, dynamic>.from(b));
      setState(() => err = null);
      _render();
    } else {
      setState(() => err = 'No dataset bounds available yet.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final regionState = ref.watch(regionControllerProvider);
    final region = regionState.region;
    final activeLayers = ref.watch(activeLayersProvider);

    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < kCompactContent;

      final metrics = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow('Target', regionState.landmarkName ?? '—'),
          if (region != null) ...[
            StatRow('North', '${region.north.toStringAsFixed(2)}° N'),
            StatRow('South', '${region.south.toStringAsFixed(2)}° N'),
            StatRow('West', '${region.west.toStringAsFixed(2)}° E'),
            StatRow('East', '${region.east.toStringAsFixed(2)}° E'),
          ],
          const Divider(color: MC.border, height: 24),
          if (stats != null) ...[
            StatRow('Min elev', _stat('min_elevation_m', unit: ' m')),
            StatRow('Max elev', _stat('max_elevation_m', unit: ' m')),
            StatRow('Mean elev', _stat('mean_elevation_m', unit: ' m')),
            StatRow('Range', _stat('elevation_range_m', unit: ' m')),
            StatRow('Resolution', _stat('resolution_m_per_pixel', unit: ' m/px')),
            StatRow('Area', _stat('approx_area_km2', unit: ' km²')),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                'Elevation metrics will calculate automatically after rendering.',
                style: TextStyle(color: MC.textDim, fontSize: 11),
              ),
            ),
        ],
      );

      return Padding(
        padding: EdgeInsets.all(pagePad(c.maxWidth)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            McToolbar(
              children: [
                McButton(
                  label: loading
                      ? 'COMPOSITING...'
                      : (compact ? 'GENERATE MAP' : 'GENERATE MULTI-LAYER MAP'),
                  icon: Icons.auto_awesome,
                  onPressed: loading ? null : _render,
                ),
                McButton(
                  label: compact ? 'FIT TILE' : 'FIT TO ACTIVE TILE',
                  icon: Icons.crop_free,
                  color: MC.warn,
                  outlined: true,
                  onPressed: loading ? null : _handleFitTile,
                ),
                if (loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MC.accent),
                  ),
              ],
              footer: Text(
                'ACTIVE: ${activeLayers.entries.where((e) => e.value).map((e) => e.key.toUpperCase()).join(", ")}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: MC.good, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              McErrorBanner(err!),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _viewport()),
                        const SizedBox(height: 8),
                        McCollapsible(
                            title: 'TERRAIN METRICS', child: metrics),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: _viewport()),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: c.maxWidth < 1000 ? 260 : 320,
                          child: SingleChildScrollView(
                            child: McCard(
                                title: 'TERRAIN METRICS', child: metrics),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    });
  }

  Widget _viewport() => McCard(
        title: '2D MULTI-LAYER VIEWPORT',
        fill: true,
        child: Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: MC.border),
          ),
          child: imageUrl == null
              ? const McEmpty(
                  icon: Icons.map_outlined,
                  title: 'No render yet.',
                  subtitle: 'Tap GENERATE to render this region.',
                )
              : InteractiveViewer(
                  minScale: 1,
                  maxScale: 8,
                  child: Center(
                    child: Image.network(
                      imageUrl!,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(color: MC.accent),
                        );
                      },
                      errorBuilder: (_, __, ___) => const Center(
                        child: Text(
                          'Failed to load image from backend',
                          style: TextStyle(color: MC.bad),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      );
}
