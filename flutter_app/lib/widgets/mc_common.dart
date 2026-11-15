import 'package:flutter/material.dart';
import '../responsive.dart';
import '../theme.dart';

/// Primary (filled) or outlined action button that shrinks on phones.
class McButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final bool outlined;

  const McButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.color = MC.accent,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final compact = context.isPhone;
    final padding = EdgeInsets.symmetric(
        horizontal: compact ? 12 : 18, vertical: compact ? 10 : 14);
    final text = Text(
      label,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: compact ? 10.5 : 12,
        letterSpacing: compact ? 0.6 : 1.2,
      ),
    );
    final ic = Icon(icon, size: compact ? 14 : 16);

    if (outlined) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: ic,
        label: text,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color),
          padding: padding,
          minimumSize: const Size(0, 40),
          shape: const RoundedRectangleBorder(),
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: ic,
      label: text,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.black,
        padding: padding,
        minimumSize: const Size(0, 40),
        shape: const RoundedRectangleBorder(),
      ),
    );
  }
}

/// Wrapping toolbar: buttons flow onto a second line instead of overflowing.
class McToolbar extends StatelessWidget {
  final List<Widget> children;
  final Widget? footer;
  const McToolbar({super.key, required this.children, this.footer});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.isPhone ? 8 : 12),
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
          if (footer != null) ...[const SizedBox(height: 8), footer!],
        ],
      ),
    );
  }
}

class McErrorBanner extends StatelessWidget {
  final String message;
  final Widget? action;
  const McErrorBanner(this.message, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MC.bad.withOpacity(0.15),
        border: Border.all(color: MC.bad),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: MC.bad, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: MC.bad, fontSize: 11)),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class McEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const McEmpty(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: MC.textDim, size: 44),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: MC.text, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: MC.textDim, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// Collapsible card used on phones in place of a side panel.
class McCollapsible extends StatelessWidget {
  final String title;
  final Widget child;
  final bool initiallyExpanded;
  final double maxBodyHeight;
  const McCollapsible({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
    this.maxBodyHeight = 260,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          iconColor: MC.textDim,
          collapsedIconColor: MC.textDim,
          title: Row(
            children: [
              Container(width: 4, height: 12, color: MC.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold,
                        color: MC.text)),
              ),
            ],
          ),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxBodyHeight),
              child: SingleChildScrollView(child: child),
            ),
          ],
        ),
      ),
    );
  }
}
