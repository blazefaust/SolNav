import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_card.dart';
import '../widgets/mc_common.dart';
import '../widgets/stat_row.dart';

class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key});

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  Map<String, dynamic>? stats;
  String? err;
  bool loading = false;

  Future<void> _run() async {
    final r = ref.read(regionControllerProvider).region;
    if (r == null) {
      setState(() => err = 'Select a region first.');
      return;
    }
    setState(() {
      loading = true;
      err = null;
    });

    try {
      final res = await ref.read(backendProvider).selectRegion(r);
      if (!mounted) return;
      setState(() => stats = res['statistics'] as Map<String, dynamic>?);
    } catch (e) {
      if (!mounted) return;
      setState(() => err = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _f(String key, int digits, [String unit = '']) {
    final v = stats?[key];
    return v is num ? '${v.toStringAsFixed(digits)}$unit' : '—';
  }

  Widget _elevCard() => McCard(
        title: 'ELEVATION (MOLA RASTER)',
        child: Column(
          children: [
            StatRow('Min elevation', _f('min_elevation_m', 1, ' m')),
            StatRow('Max elevation', _f('max_elevation_m', 1, ' m')),
            StatRow('Mean elevation', _f('mean_elevation_m', 1, ' m')),
            StatRow('Std deviation', _f('std_elevation_m', 1, ' m')),
            StatRow('Elevation range', _f('elevation_range_m', 1, ' m')),
          ],
        ),
      );

  Widget _slopeCard() => McCard(
        title: 'TERRAIN SLOPE & SPATIAL',
        child: Column(
          children: [
            StatRow('Mean slope', _f('mean_slope_deg', 2, '°')),
            StatRow('Max slope', _f('max_slope_deg', 2, '°')),
            StatRow('Flat (<5°)', _f('pct_flat_terrain', 1, ' %')),
            StatRow('Steep (>20°)', _f('pct_steep_terrain', 1, ' %')),
            StatRow('Resolution', _f('resolution_m_per_pixel', 1, ' m/px')),
            StatRow('Area', _f('approx_area_km2', 1, ' km²')),
            StatRow('Dimensions',
                '${_f('width_km', 1)} × ${_f('height_km', 1)} km'),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = ref.watch(regionControllerProvider);
    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < kCompactContent;
      return SingleChildScrollView(
        padding: EdgeInsets.all(pagePad(c.maxWidth)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            McToolbar(
              children: [
                McButton(
                  label: compact ? 'COMPUTE STATS' : 'COMPUTE TERRAIN STATISTICS',
                  icon: Icons.calculate,
                  onPressed: loading ? null : _run,
                ),
                if (loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MC.accent),
                  ),
                Text('Region: ${r.landmarkName ?? "—"}',
                    style: const TextStyle(color: MC.textDim, fontSize: 11)),
              ],
            ),
            if (err != null) ...[
              const SizedBox(height: 10),
              McErrorBanner(err!),
            ],
            const SizedBox(height: 12),
            if (stats != null)
              compact
                  ? Column(children: [
                      _elevCard(),
                      const SizedBox(height: 12),
                      _slopeCard(),
                    ])
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _elevCard()),
                        const SizedBox(width: 16),
                        Expanded(child: _slopeCard()),
                      ],
                    )
            else
              const SizedBox(
                height: 220,
                child: McEmpty(
                  icon: Icons.analytics_outlined,
                  title: 'No statistics yet.',
                  subtitle: 'Tap COMPUTE to analyse the active region.',
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'All metrics computed dynamically from multi-tile MOLA MEGDR rasters.',
                style: TextStyle(
                    color: MC.textDim,
                    fontSize: 10,
                    fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      );
    });
  }
}
