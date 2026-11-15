import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../theme.dart';

class StatusBadge extends ConsumerWidget {
  /// Smaller padding/text.
  final bool compact;

  /// Only a coloured dot (label shown as a tooltip). Used in tight headers.
  final bool dotOnly;

  const StatusBadge({super.key, this.compact = false, this.dotOnly = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(statusProvider);
    return s.when(
      loading: () => _Pill(
          color: MC.warn, label: 'CONNECTING...', compact: compact, dotOnly: dotOnly),
      error: (_, __) => _Pill(
          color: MC.bad, label: 'BACKEND OFFLINE', compact: compact, dotOnly: dotOnly),
      data: (d) {
        final ok = d['status'] == 'ready';
        return _Pill(
          color: ok ? MC.good : MC.warn,
          label: ok ? 'MOLA LOADED' : 'NO DATA',
          compact: compact,
          dotOnly: dotOnly,
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  final Color color;
  final String label;
  final bool compact;
  final bool dotOnly;
  const _Pill({
    required this.color,
    required this.label,
    required this.compact,
    required this.dotOnly,
  });

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (dotOnly) return Tooltip(message: label, child: dot);

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.6)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: compact ? 9 : 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
