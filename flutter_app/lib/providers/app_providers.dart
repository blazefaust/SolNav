import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/backend_service.dart';
import '../models/landmark.dart';
import '../models/region.dart';

final backendProvider = Provider((_) => BackendService());

final statusProvider = FutureProvider.autoDispose((ref) async {
  return ref.read(backendProvider).status();
});

final landmarksProvider = FutureProvider.autoDispose((ref) async {
  return ref.read(backendProvider).landmarks();
});

final layersProvider = FutureProvider.autoDispose((ref) async {
  return ref.read(backendProvider).layers();
});

final activeLayersProvider = StateProvider<Map<String, bool>>((ref) => {
  'mola': true,
  'ctx': false,
  'hirise': false,
  'mcs': false,
  'sharad': false,
  'crism': false,
});

class RegionState {
  final Region? region;
  final String? landmarkName;
  const RegionState({this.region, this.landmarkName});
  RegionState copyWith({Region? region, String? landmarkName}) =>
      RegionState(
        region: region ?? this.region,
        landmarkName: landmarkName ?? this.landmarkName,
      );
}

class RegionController extends StateNotifier<RegionState> {
  RegionController()
      : super(const RegionState(
          region: Region(south: 13.0, north: 24.0, west: 220.0, east: 234.0),
          landmarkName: 'Olympus Mons',
        ));

  void setLandmark(Landmark l) => state = RegionState(
        region: Region(south: l.latMin, north: l.latMax, west: l.lonMin, east: l.lonMax),
        landmarkName: l.name,
      );

  void setRegion(Region r, [String name = 'Custom Region']) =>
      state = RegionState(region: r, landmarkName: name);

  void fitToTile(Map<String, dynamic> bounds) {
    final s = (bounds['south'] as num).toDouble();
    final n = (bounds['north'] as num).toDouble();
    final w = (bounds['west'] as num).toDouble();
    final e = (bounds['east'] as num).toDouble();

    state = RegionState(
      region: Region(south: s, north: n, west: w, east: e),
      landmarkName: 'Full Loaded Dataset Bounds',
    );
  }

  void alignWithDataset(Map<String, dynamic> status) {
    if (status['status'] == 'ready' && status['bounds'] != null) {
      final b = status['bounds'] as Map<String, dynamic>;
      final s = (b['south'] as num).toDouble();
      final n = (b['north'] as num).toDouble();
      final w = (b['west'] as num).toDouble();
      final e = (b['east'] as num).toDouble();

      final cur = state.region;
      if (cur == null ||
          cur.north <= s || cur.south >= n ||
          cur.east <= w || cur.west >= e) {
        fitToTile(b);
      }
    }
  }
}

final regionControllerProvider =
    StateNotifierProvider<RegionController, RegionState>((_) => RegionController());

final navIndexProvider = StateProvider<int>((_) => 0);
final vertExagProvider = StateProvider<double>((_) => 2.5);