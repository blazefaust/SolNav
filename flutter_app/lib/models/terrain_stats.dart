class TerrainStats {
  final Map<String, dynamic> raw;
  TerrainStats(this.raw);
  double? d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : null;
}