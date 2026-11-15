import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_card.dart';
import '../widgets/stat_row.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(statusProvider);
    final landmarks = ref.watch(landmarksProvider);
    final layers = ref.watch(layersProvider);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final compact = w < kCompactContent;
      final wide = w > 1000;

      return SingleChildScrollView(
        padding: EdgeInsets.all(pagePad(w) + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                'SOLNAV',
                style: TextStyle(
                  fontSize: compact ? 26 : 32,
                  fontWeight: FontWeight.bold,
                  color: MC.text,
                  letterSpacing: compact ? 3 : 4,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              compact
                  ? 'Mars Mission Workspace'
                  : 'Interplanetary Survival Guide • Martian Map Workspace',
              style: TextStyle(
                  color: MC.accent,
                  fontSize: compact ? 11 : 13,
                  letterSpacing: compact ? 1.2 : 2),
            ),
            SizedBox(height: compact ? 18 : 28),
            wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: _datasetCard(status)),
                      const SizedBox(width: 16),
                      Expanded(child: _landmarksCard(landmarks, ref)),
                    ],
                  )
                : Column(
                    children: [
                      _datasetCard(status),
                      const SizedBox(height: 12),
                      _landmarksCard(landmarks, ref),
                    ],
                  ),
            const SizedBox(height: 12),
            _layersCard(layers),
          ],
        ),
      );
    });
  }

  Widget _datasetCard(AsyncValue st) => McCard(
        title: 'ACTIVE MOLA DATASET',
        child: st.when(
          loading: () => const _Loading(),
          error: (e, _) => Text('Backend unreachable:\n$e',
              style: const TextStyle(color: MC.bad, fontSize: 11)),
          data: (d) {
            if (d['status'] != 'ready') {
              return Text(d['message'] ?? 'No MOLA data loaded',
                  style: const TextStyle(color: MC.warn));
            }
            final b = d['bounds'] as Map;
            final sh = d['shape'] as List;
            return Column(
              children: [
                StatRow('Dataset', d['dataset'] ?? '—'),
                StatRow('Metadata', d['xml'] ?? 'reconciled'),
                StatRow('Resolution', '${d['resolution_ppd']} ppd'),
                StatRow('Grid Shape', '${sh[0]} × ${sh[1]} px'),
                const Divider(color: MC.border, height: 24),
                StatRow('Latitude Range',
                    '${b['south'].toStringAsFixed(1)}° → ${b['north'].toStringAsFixed(1)}°'),
                StatRow('Longitude Range',
                    '${b['west'].toStringAsFixed(1)}° → ${b['east'].toStringAsFixed(1)}°'),
                StatRow('Status', 'READY', valueColor: MC.good),
              ],
            );
          },
        ),
      );

  Widget _landmarksCard(AsyncValue lm, WidgetRef ref) => McCard(
        title: 'LANDMARK PRESETS',
        child: lm.when(
          loading: () => const _Loading(),
          error: (e, _) => Text('$e', style: const TextStyle(color: MC.bad)),
          data: (list) => Column(
            children: [
              for (final l in list)
                InkWell(
                  onTap: () {
                    ref.read(regionControllerProvider.notifier).setLandmark(l);
                    ref.read(navIndexProvider.notifier).state = 3;
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 6),
                    decoration: const BoxDecoration(
                        border:
                            Border(bottom: BorderSide(color: MC.border))),
                    child: Row(
                      children: [
                        const Icon(Icons.place_outlined,
                            size: 14, color: MC.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(l.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: MC.text)),
                        ),
                        const SizedBox(width: 8),
                        Text('${l.latMin.toInt()}° / ${l.lonMin.toInt()}°',
                            style: const TextStyle(
                                fontSize: 10, color: MC.textDim)),
                      ],
                    ),
                  ),
                )
            ],
          ),
        ),
      );

  Widget _layersCard(AsyncValue layers) => McCard(
        title: 'AVAILABLE NASA DATA LAYERS',
        child: layers.when(
          loading: () => const _Loading(),
          error: (e, _) => Text('$e', style: const TextStyle(color: MC.bad)),
          data: (list) => LayoutBuilder(builder: (context, c) {
            // 1 column on phones, 2-3 on larger screens.
            const gap = 10.0;
            final cols = c.maxWidth < 520 ? 1 : (c.maxWidth < 820 ? 2 : 3);
            final tileW = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final layer in list)
                  Container(
                    width: tileW,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: MC.border),
                      color: MC.panelAlt,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: layer['connected']
                                    ? MC.good
                                    : MC.textDim,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                layer['name'],
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(layer['source'] ?? '',
                            style: const TextStyle(
                                fontSize: 9, color: MC.textDim)),
                        const SizedBox(height: 4),
                        Text(
                          layer['connected']
                              ? 'CONNECTED (${layer['file_count'] ?? 0} files)'
                              : 'NO DATA',
                          style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 1,
                            color: layer['connected'] ? MC.good : MC.warn,
                          ),
                        ),
                      ],
                    ),
                  )
              ],
            );
          }),
        ),
      );
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(8),
        child: LinearProgressIndicator(
            color: MC.accent, backgroundColor: MC.border),
      );
}
