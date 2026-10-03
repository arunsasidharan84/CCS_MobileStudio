import 'dart:io';

/// Individual stimulus audio cue in the ACLS playlist.
class StimulusCueItem {
  StimulusCueItem({
    required this.id,
    required this.name,
    required this.filePath,
    required this.markerCode,
    this.playCount = 0,
  });

  final String id;
  String name;
  String filePath;
  int markerCode;
  int playCount;

  bool get exists => File(filePath).existsSync();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filePath': filePath,
    'markerCode': markerCode,
    'playCount': playCount,
  };

  factory StimulusCueItem.fromJson(Map<String, dynamic> json) => StimulusCueItem(
    id: json['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: json['name']?.toString() ?? 'Cue',
    filePath: json['filePath']?.toString() ?? '',
    markerCode: (json['markerCode'] as num?)?.round() ?? 40,
    playCount: (json['playCount'] as num?)?.round() ?? 0,
  );

  StimulusCueItem copyWith({
    String? id,
    String? name,
    String? filePath,
    int? markerCode,
    int? playCount,
  }) {
    return StimulusCueItem(
      id: id ?? this.id,
      name: name ?? this.name,
      filePath: filePath ?? this.filePath,
      markerCode: markerCode ?? this.markerCode,
      playCount: playCount ?? this.playCount,
    );
  }
}
