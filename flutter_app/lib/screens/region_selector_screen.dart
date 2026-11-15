import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../models/region.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_card.dart';
import '../widgets/mc_common.dart';

class RegionSelectorScreen extends ConsumerStatefulWidget {
  const RegionSelectorScreen({super.key});

  @override
  ConsumerState<RegionSelectorScreen> createState() =>
      _RegionSelectorScreenState();
}

class _RegionSelectorScreenState extends ConsumerState<RegionSelectorScreen> {
  final _n = TextEditingController();
  final _s = TextEditingController();
  final _w = TextEditingController();
  final _e = TextEditingController();

  @override
  void initState() {
    super.initState();
    final r = ref.read(regionControllerProvider).region;
    if (r != null) {
      _n.text = r.north.toString();
      _s.text = r.south.toString();
      _w.text = r.west.toString();
      _e.text = r.east.toString();
    }
  }

  @override
  void dispose() {
    _n.dispose();
    _s.dispose();
    _w.dispose();
    _e.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final landmarks = ref.watch(landmarksProvider);
    final status = ref.watch(statusProvider).asData?.value;
    final bounds =
        status != null ? status['bounds'] as Map<String, dynamic>? : null;

    final landmarkCard = McCard(
      title: 'LANDMARK PRESETS',
      child: landmarks.when(
        loading: () => const LinearProgressIndicator(color: MC.accent),
        error: (e, _) => Text('$e', style: const TextStyle(color: MC.bad)),
        data: (list) => Column(
          children: [for (final l in list) _buildLandmarkTile(l, bounds)],
        ),
      ),
    );

    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < kCompactContent;
      final manualCard = _manualCard(compact);

      return SingleChildScrollView(
        padding: EdgeInsets.all(pagePad(c.maxWidth)),
        child: compact
            ? Column(children: [
                manualCard,
                const SizedBox(height: 12),
                landmarkCard,
              ])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: landmarkCard),
                  const SizedBox(width: 16),
                  Expanded(child: manualCard),
                ],
              ),
      );
    });
  }

  Widget _manualCard(bool compact) => McCard(
        title: 'MANUAL BOUNDING BOX',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (compact) ...[
              Row(children: [
                Expanded(child: _field('North (° lat)', _n)),
                const SizedBox(width: 10),
                Expanded(child: _field('South (° lat)', _s)),
              ]),
              Row(children: [
                Expanded(child: _field('West (° E)', _w)),
                const SizedBox(width: 10),
                Expanded(child: _field('East (° E)', _e)),
              ]),
            ] else ...[
              _field('North (° lat)', _n),
              _field('South (° lat)', _s),
              _field('West (° E lon)', _w),
              _field('East (° E lon)', _e),
            ],
            const SizedBox(height: 12),
            McButton(
              label: 'APPLY REGION',
              icon: Icons.check,
              onPressed: _apply,
            ),
          ],
        ),
      );

  void _apply() {
    final n = double.tryParse(_n.text);
    final s = double.tryParse(_s.text);
    final w = double.tryParse(_w.text);
    final e = double.tryParse(_e.text);
    if ([n, s, w, e].contains(null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid coordinates entered')),
      );
      return;
    }
    ref.read(regionControllerProvider.notifier).setRegion(
          Region(south: s!, north: n!, west: w!, east: e!),
        );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Region applied. Open 2D Map or 3D Terrain.')),
    );
  }

  Widget _buildLandmarkTile(dynamic l, Map<String, dynamic>? bounds) {
    bool inTile = true;
    if (bounds != null) {
      final ts = (bounds['south'] as num).toDouble();
      final tn = (bounds['north'] as num).toDouble();
      final tw = (bounds['west'] as num).toDouble();
      final te = (bounds['east'] as num).toDouble();
      inTile = !(l.latMax < ts ||
          l.latMin > tn ||
          l.lonMax < tw ||
          l.lonMin > te);
    }

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading:
          Icon(Icons.place, color: inTile ? MC.good : MC.textDim, size: 16),
      title: Row(
        children: [
          Expanded(
            child: Text(l.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (inTile ? MC.good : MC.warn).withOpacity(0.15),
              border:
                  Border.all(color: inTile ? MC.good : MC.warn, width: 0.8),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              inTile ? 'IN TILE' : 'OUT',
              style: TextStyle(
                fontSize: 9,
                color: inTile ? MC.good : MC.warn,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        'lat ${l.latMin.toStringAsFixed(1)}° → ${l.latMax.toStringAsFixed(1)}°  '
        'lon ${l.lonMin.toStringAsFixed(1)}° → ${l.lonMax.toStringAsFixed(1)}°',
        style: const TextStyle(color: MC.textDim, fontSize: 10),
      ),
      onTap: () {
        ref.read(regionControllerProvider.notifier).setLandmark(l);
        _n.text = l.latMax.toString();
        _s.text = l.latMin.toString();
        _w.text = l.lonMin.toString();
        _e.text = l.lonMax.toString();
        setState(() {});
      },
    );
  }

  Widget _field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          style: const TextStyle(fontSize: 12, color: MC.text),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: MC.textDim, fontSize: 11),
            enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: MC.border)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: MC.accent)),
            isDense: true,
          ),
        ),
      );
}
