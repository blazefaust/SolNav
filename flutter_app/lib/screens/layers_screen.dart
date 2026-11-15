import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_card.dart';

class LayersScreen extends ConsumerWidget {
  const LayersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layersAsync = ref.watch(layersProvider);
    final activeMap = ref.watch(activeLayersProvider);

    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < kCompactContent;
      return SingleChildScrollView(
        padding: EdgeInsets.all(pagePad(c.maxWidth)),
        child: McCard(
          title: compact
              ? 'NASA DATA LAYERS'
              : 'NASA DATA LAYERS CONTROLLER (ZERO-DOWNLOAD STREAMING)',
          child: layersAsync.when(
            loading: () => const LinearProgressIndicator(color: MC.accent),
            error: (e, _) =>
                Text('$e', style: const TextStyle(color: MC.bad)),
            data: (list) => Column(
              children: [
                for (final l in list)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: EdgeInsets.symmetric(
                        horizontal: compact ? 8 : 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: MC.panelAlt,
                      border: Border.all(
                        color: activeMap[l['id']] == true
                            ? MC.accent
                            : MC.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Switch(
                          value: activeMap[l['id']] ?? false,
                          activeColor: MC.accent,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (val) {
                            ref.read(activeLayersProvider.notifier).update(
                                  (state) => {...state, l['id']: val},
                                );
                          },
                        ),
                        SizedBox(width: compact ? 8 : 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l['name'],
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: MC.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l['source'] ?? '',
                                style: const TextStyle(
                                    color: MC.textDim, fontSize: 10),
                              ),
                              if (compact) ...[
                                const SizedBox(height: 6),
                                _badge(),
                              ],
                            ],
                          ),
                        ),
                        if (!compact) _badge(),
                      ],
                    ),
                  )
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _badge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: MC.good.withOpacity(0.15),
          border: Border.all(color: MC.good),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const Text(
          'ONLINE / STREAMING',
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 1,
            color: MC.good,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
}
