import 'package:flutter/material.dart';
import '../responsive.dart';
import '../theme.dart';

class McCard extends StatelessWidget {
  final String? title;
  final Widget child;
  final EdgeInsets? padding;
  final bool fill;

  const McCard({
    super.key,
    this.title,
    required this.child,
    this.padding,
    this.fill = false,
  });

  @override
  Widget build(BuildContext context) {
    final compact = context.isPhone;
    return Container(
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: padding ?? EdgeInsets.all(compact ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Container(width: 4, height: 12, color: MC.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 10.5 : 11,
                      letterSpacing: compact ? 1.2 : 2,
                      fontWeight: FontWeight.bold,
                      color: MC.text,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 10 : 14),
          ],
          if (fill) Expanded(child: child) else child,
        ],
      ),
    );
  }
}
