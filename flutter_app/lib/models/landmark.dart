class Landmark {
  final String name;
  final double latMin, latMax, lonMin, lonMax;
  Landmark({required this.name, required this.latMin, required this.latMax,
            required this.lonMin, required this.lonMax});
  factory Landmark.fromJson(Map<String, dynamic> j) => Landmark(
    name: j['name'],
    latMin: (j['lat_min'] as num).toDouble(),
    latMax: (j['lat_max'] as num).toDouble(),
    lonMin: (j['lon_min'] as num).toDouble(),
    lonMax: (j['lon_max'] as num).toDouble(),
  );
}