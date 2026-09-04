class StreamMarker {
  const StreamMarker({
    required this.streamId,
    required this.source,
    required this.value,
    required this.code,
    required this.receivedAt,
    this.lslTimestamp,
  });

  final String streamId;
  final String source;
  final String value;
  final int code;
  final DateTime receivedAt;
  final double? lslTimestamp;

  static int codeForValue(String value) {
    final numeric = int.tryParse(value.trim());
    if (numeric != null) return numeric.clamp(-32768, 32767);
    var hash = 2166136261;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return 1 + (hash % 32766);
  }
}
