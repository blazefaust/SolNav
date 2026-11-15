class Region {
  final double south, north, west, east;
  const Region({
    required this.south,
    required this.north,
    required this.west,
    required this.east,
  });
  Map<String, dynamic> toJson() =>
      {'south': south, 'north': north, 'west': west, 'east': east};
}