/// ADS1299 conversion used by xAMP-L10 and Orbit.
class Ads1299Scaling {
  const Ads1299Scaling._();

  /// Orbit exposes direct ADS1299 counts.
  static const double orbitMicrovoltsPerCount = -0.0224;

  /// xAMP-L10 has an additional calibrated 100× front-end gain.
  ///
  /// This agrees with the established xAMP desktop viewer configuration,
  /// which specifies `Scaling_factor: 100`.
  static const double xampMicrovoltsPerCount = -0.000224;
  static const int positiveRail = 0x7FFFFF;

  static int signed24(int mostSignificant, int middle, int leastSignificant) {
    var raw =
        ((mostSignificant & 0xFF) << 16) |
        ((middle & 0xFF) << 8) |
        (leastSignificant & 0xFF);
    if ((raw & 0x800000) != 0) raw -= 0x1000000;
    return raw;
  }

  static double xampMicrovolts(int counts) => counts * xampMicrovoltsPerCount;

  static double orbitMicrovolts(num counts) => counts * orbitMicrovoltsPerCount;

  static bool isAtRail(int counts, {double threshold = 0.98}) =>
      counts.abs() >= (positiveRail * threshold).round();
}
