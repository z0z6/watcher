import 'dart:math';

class LatLon {
  final double lat, lon;
  const LatLon(this.lat, this.lon);
}

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  double rad(double d) => d * pi / 180;
  final dp = rad(lat2 - lat1), dl = rad(lon2 - lon1);
  final a = pow(sin(dp / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dl / 2), 2);
  return 2 * r * asin(sqrt(a));
}
