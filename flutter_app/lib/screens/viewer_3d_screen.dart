import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../providers/app_providers.dart';
import '../models/region.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_card.dart';
import '../widgets/mc_common.dart';
import '../widgets/stat_row.dart';

class Viewer3DScreen extends ConsumerStatefulWidget {
  const Viewer3DScreen({super.key});

  @override
  ConsumerState<Viewer3DScreen> createState() => _Viewer3DScreenState();
}

class _Viewer3DScreenState extends ConsumerState<Viewer3DScreen> {
  String? htmlUrl;
  bool loading = false;
  String? err;
  WebViewController? _mobileWv;

  bool get _isMobileOrWeb =>
      kIsWeb || Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  Future<void> _generate() async {
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

      final res = await backend.render3D(
        region: region,
        layers: activeLayers,
        vertExag: ref.read(vertExagProvider),
        title: ref.read(regionControllerProvider).landmarkName ?? 'Mars Terrain',
      );
      if (!mounted) return;

      if (res['region'] != null) {
        final r = res['region'] as Map<String, dynamic>;
        ref.read(regionControllerProvider.notifier).setRegion(
              Region(
                south: (r['south'] as num).toDouble(),
                north: (r['north'] as num).toDouble(),
                west: (r['west'] as num).toDouble(),
                east: (r['east'] as num).toDouble(),
              ),
              ref.read(regionControllerProvider).landmarkName ?? 'Mars',
            );
      }

      final url = backend.fullUrl(res['url'] as String);
      setState(() => htmlUrl = url);

      if (_isMobileOrWeb) {
        _mobileWv ??= WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted);
        await _mobileWv!.loadRequest(Uri.parse(url));
      } else {
        await launchUrl(Uri.parse(url));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => err = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _handleFitTile() {
    final st = ref.read(statusProvider).asData?.value;
    if (st != null && st['bounds'] != null) {
      ref
          .read(regionControllerProvider.notifier)
          .fitToTile(st['bounds'] as Map<String, dynamic>);
      setState(() => err = null);
      _generate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final regionState = ref.watch(regionControllerProvider);
    final region = regionState.region;
    final exag = ref.watch(vertExagProvider);

    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < kCompactContent;

      final controls = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow('Region', regionState.landmarkName ?? '—'),
          if (region != null) ...[
            StatRow('Lat',
                '${region.south.toStringAsFixed(2)}° → ${region.north.toStringAsFixed(2)}°'),
            StatRow('Lon',
                '${region.west.toStringAsFixed(2)}° → ${region.east.toStringAsFixed(2)}°'),
          ],
          const Divider(color: MC.border, height: 24),
          Text(
            'Vertical Exaggeration: ${exag.toStringAsFixed(1)}×',
            style: const TextStyle(
                color: MC.text, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          Slider(
            min: 1.0,
            max: 5.0,
            divisions: 40,
            value: exag,
            label: '${exag.toStringAsFixed(1)}×',
            onChanged: (v) => ref.read(vertExagProvider.notifier).state = v,
          ),
          const Text('1.0× = true physical scale',
              style: TextStyle(color: MC.textDim, fontSize: 10)),
          const SizedBox(height: 12),
          Text(
            compact
                ? 'Touch controls:\n'
                    '• Drag — orbit\n'
                    '• Pinch — zoom\n'
                    '• Two-finger drag — pan'
                : 'WebGL Interaction:\n'
                    '• Left Click Drag — Orbit 360°\n'
                    '• Mouse Wheel — Zoom in/out\n'
                    '• Right / Shift Drag — Pan\n'
                    '• Hover — Real-time altitude readout',
            style: const TextStyle(color: MC.textDim, fontSize: 10, height: 1.6),
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
                      ? 'BUILDING...'
                      : (compact ? 'GENERATE 3D' : 'GENERATE 3D MODEL'),
                  icon: Icons.threed_rotation,
                  onPressed: loading ? null : _generate,
                ),
                McButton(
                  label: compact ? 'FIT TILE' : 'FIT TO ACTIVE TILE',
                  icon: Icons.crop_free,
                  color: MC.warn,
                  outlined: true,
                  onPressed: _handleFitTile,
                ),
                if (htmlUrl != null)
                  McButton(
                    label: compact ? 'BROWSER' : 'OPEN 3D WEBGL VIEWER',
                    icon: Icons.open_in_new,
                    color: MC.good,
                    onPressed: () => launchUrl(Uri.parse(htmlUrl!)),
                  ),
                if (loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: MC.accent),
                  ),
              ],
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              McErrorBanner(
                err!,
                action: TextButton(
                  onPressed: _handleFitTile,
                  child: const Text('AUTO-FIX',
                      style: TextStyle(
                          color: MC.accent, fontWeight: FontWeight.bold)),
                ),
              ),
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
                            title: '3D CONTROLS',
                            maxBodyHeight: 300,
                            child: controls),
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
                            child:
                                McCard(title: '3D CONTROLS', child: controls),
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
        title: '3D PLOTLY WEBGL VIEWPORT',
        fill: true,
        child: Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: MC.border),
          ),
          child: htmlUrl == null
              ? const McEmpty(
                  icon: Icons.terrain_outlined,
                  title: 'No 3D model generated.',
                  subtitle: 'Tap GENERATE 3D to render interactive terrain.',
                )
              : (_isMobileOrWeb && _mobileWv != null
                  ? WebViewWidget(
                      controller: _mobileWv!,
                      gestureRecognizers: {
                        Factory<OneSequenceGestureRecognizer>(
                            () => EagerGestureRecognizer()),
                      },
                    )
                  : _desktopCardView()),
        ),
      );

  Widget _desktopCardView() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, color: MC.good, size: 48),
              const SizedBox(height: 16),
              Text(
                '3D WebGL Model Ready (${ref.watch(vertExagProvider).toStringAsFixed(1)}× Exaggeration)',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: MC.text, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Click below to launch in your browser for hardware-accelerated 360° orbit, pan & zoom.',
                textAlign: TextAlign.center,
                style: TextStyle(color: MC.textDim, fontSize: 12),
              ),
              const SizedBox(height: 20),
              McButton(
                label: 'LAUNCH 3D WEBGL VIEWER',
                icon: Icons.launch,
                onPressed: () => launchUrl(Uri.parse(htmlUrl!)),
              ),
            ],
          ),
        ),
      );
}
