import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme.dart';
import '../providers/app_providers.dart';
import '../screens/dashboard_screen.dart';
import '../screens/map_2d_screen.dart';
import '../screens/viewer_3d_screen.dart';
import '../screens/region_selector_screen.dart';
import '../screens/layers_screen.dart';
import '../screens/analysis_screen.dart';
import '../screens/mission_planning_screen.dart';
import '../screens/solnav_screen.dart';
import 'status_badge.dart';

// (full label, short label for phone tabs, icon)
const _navItems = [
  ('DASHBOARD', 'HOME', Icons.dashboard_outlined),
  ('2D MAP', '2D MAP', Icons.map_outlined),
  ('3D TERRAIN', '3D', Icons.terrain_outlined),
  ('REGION SELECT', 'REGION', Icons.crop_square_outlined),
  ('DATA LAYERS', 'LAYERS', Icons.layers_outlined),
  ('ANALYSIS', 'ANALYSIS', Icons.analytics_outlined),
  ('MISSION PLAN', 'MISSION', Icons.route_outlined),
  ('MARS GLOBE', 'GLOBE', Icons.public),
];

class McShell extends ConsumerWidget {
  const McShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = ref.watch(navIndexProvider);

    ref.listen(statusProvider, (_, state) {
      state.whenData((data) {
        ref.read(regionControllerProvider.notifier).alignWithDataset(data);
      });
    });

    return Scaffold(
      backgroundColor: MC.bg,
      body: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;

        // PHONE: slim header + horizontally scrollable pill tabs.
        if (w < 700) {
          return SafeArea(
            child: Column(
              children: [
                const _PhoneHeader(),
                _PhoneTabs(idx: idx),
                const Divider(height: 1, color: MC.border),
                Expanded(child: _body(idx)),
              ],
            ),
          );
        }

        // TABLET: icon rail.  DESKTOP: full side nav.
        final wide = w >= 1100;
        // Landscape phones are short: drop the top bar to give content the height.
        final short = c.maxHeight < 500;
        return SafeArea(
          child: Row(
            children: [
              wide ? _SideNav(idx: idx) : _Rail(idx: idx, short: short),
              Expanded(
                child: Column(
                  children: [
                    if (!short) _TopBar(compact: !wide),
                    Expanded(child: _body(idx)),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _body(int i) => switch (i) {
        0 => const DashboardScreen(),
        1 => const Map2DScreen(),
        2 => const Viewer3DScreen(),
        3 => const RegionSelectorScreen(),
        4 => const LayersScreen(),
        5 => const AnalysisScreen(),
        6 => const MissionPlanningScreen(),
        7 => const SolNavScreen(),
        _ => const SizedBox.shrink(),
      };
}

// ───────────────────────────── PHONE ─────────────────────────────

class _PhoneHeader extends ConsumerWidget {
  const _PhoneHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final region = ref.watch(regionControllerProvider);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: MC.panel,
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                const BoxDecoration(color: MC.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          const Text('SOLNAV',
              style: TextStyle(
                  color: MC.accent,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2)),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.place_outlined, size: 12, color: MC.textDim),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    region.landmarkName ?? 'GLOBAL',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: MC.text,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const StatusBadge(dotOnly: true),
        ],
      ),
    );
  }
}

class _PhoneTabs extends ConsumerStatefulWidget {
  final int idx;
  const _PhoneTabs({required this.idx});

  @override
  ConsumerState<_PhoneTabs> createState() => _PhoneTabsState();
}

class _PhoneTabsState extends ConsumerState<_PhoneTabs> {
  final _keys = List.generate(_navItems.length, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void didUpdateWidget(covariant _PhoneTabs old) {
    super.didUpdateWidget(old);
    if (old.idx != widget.idx) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void _reveal() {
    final ctx = _keys[widget.idx].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.5,
          curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      color: MC.panel,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            for (int i = 0; i < _navItems.length; i++) ...[
              GestureDetector(
                key: _keys[i],
                behavior: HitTestBehavior.opaque,
                onTap: () => ref.read(navIndexProvider.notifier).state = i,
                child: _chip(i, i == widget.idx),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(int i, bool sel) {
    final item = _navItems[i];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: sel ? MC.accent.withOpacity(0.16) : Colors.transparent,
        border: Border.all(color: sel ? MC.accent : MC.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(item.$3, size: 14, color: sel ? MC.accent : MC.textDim),
          const SizedBox(width: 6),
          Text(
            item.$2,
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.8,
              color: sel ? MC.text : MC.textDim,
              fontWeight: sel ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── TABLET ─────────────────────────────

class _Rail extends ConsumerWidget {
  final int idx;
  final bool short;
  const _Rail({required this.idx, this.short = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 64,
      decoration: const BoxDecoration(
        color: MC.panel,
        border: Border(right: BorderSide(color: MC.border)),
      ),
      child: Column(
        children: [
          SizedBox(height: short ? 8 : 18),
          Container(
            width: 10,
            height: 10,
            decoration:
                const BoxDecoration(color: MC.accent, shape: BoxShape.circle),
          ),
          SizedBox(height: short ? 8 : 18),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (int i = 0; i < _navItems.length; i++)
                    Tooltip(
                      message: _navItems[i].$1,
                      child: InkWell(
                        onTap: () =>
                            ref.read(navIndexProvider.notifier).state = i,
                        child: Container(
                          height: short ? 40 : 48,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            border: Border(
                                left: BorderSide(
                                    color: i == idx
                                        ? MC.accent
                                        : Colors.transparent,
                                    width: 3)),
                            color:
                                i == idx ? MC.panelAlt : Colors.transparent,
                          ),
                          child: Icon(_navItems[i].$3,
                              size: 20,
                              color: i == idx ? MC.accent : MC.textDim),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(vertical: short ? 8 : 16),
            child: const StatusBadge(dotOnly: true),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── DESKTOP ─────────────────────────────

class _SideNav extends ConsumerWidget {
  final int idx;
  const _SideNav({required this.idx});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: MC.panel,
        border: Border(right: BorderSide(color: MC.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                      color: MC.accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                const Text(
                  'SOLNAV',
                  style: TextStyle(
                    color: MC.accent,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Text('v2.0.0 • NASA SA26',
                style: TextStyle(color: MC.textDim, fontSize: 10)),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (int i = 0; i < _navItems.length; i++)
                    _navTile(ref, i, _navItems[i].$1, _navItems[i].$3,
                        selected: i == idx),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(14),
            child: StatusBadge(),
          ),
        ],
      ),
    );
  }

  Widget _navTile(WidgetRef ref, int i, String label, IconData icon,
      {required bool selected}) {
    return InkWell(
      onTap: () => ref.read(navIndexProvider.notifier).state = i,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          border: Border(
              left: BorderSide(
                  color: selected ? MC.accent : Colors.transparent, width: 3)),
          color: selected ? MC.panelAlt : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: selected ? MC.accent : MC.textDim),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                color: selected ? MC.text : MC.textDim,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  final bool compact;
  const _TopBar({required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = ref.watch(navIndexProvider);
    final region = ref.watch(regionControllerProvider);
    final active = ref.watch(activeLayersProvider);
    final activeCount = active.values.where((v) => v).length;

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Container(width: 1, height: 20, color: MC.border),
        );

    return Container(
      height: 52,
      padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 24),
      decoration: const BoxDecoration(
        color: MC.panel,
        border: Border(bottom: BorderSide(color: MC.border)),
      ),
      child: Row(
        children: [
          Text(
            _navItems[idx].$1,
            style: const TextStyle(
                fontSize: 13,
                letterSpacing: 2,
                color: MC.text,
                fontWeight: FontWeight.bold),
          ),
          divider(),
          if (!compact)
            const Text('ACTIVE REGION:',
                style: TextStyle(
                    color: MC.textDim, fontSize: 10, letterSpacing: 1.5)),
          if (!compact) const SizedBox(width: 8),
          Flexible(
            child: Text(
              region.landmarkName ?? 'GLOBAL',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: MC.accent, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          divider(),
          Text(
            compact ? '$activeCount LAYERS' : 'LAYERS:',
            style: const TextStyle(
                color: MC.textDim, fontSize: 10, letterSpacing: 1.5),
          ),
          if (!compact) ...[
            const SizedBox(width: 8),
            Text(
              '$activeCount ACTIVE',
              style: const TextStyle(
                  color: MC.good, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            const Text('SOLNAV',
                style: TextStyle(
                    color: MC.textDim, fontSize: 11, letterSpacing: 2)),
          ],
        ],
      ),
    );
  }
}
