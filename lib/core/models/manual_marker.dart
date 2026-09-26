import 'package:flutter/material.dart';

@immutable
class ManualMarkerDefinition {
  const ManualMarkerDefinition({
    required this.name,
    required this.code,
    this.colorValue = 0xFFFFB74D,
  });

  final String name;
  final int code;
  final int colorValue;

  Color get color => Color(colorValue);

  ManualMarkerDefinition copyWith({String? name, int? code, int? colorValue}) {
    return ManualMarkerDefinition(
      name: name ?? this.name,
      code: code ?? this.code,
      colorValue: colorValue ?? this.colorValue,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'code': code,
    'color': colorValue,
  };

  factory ManualMarkerDefinition.fromJson(Map<String, dynamic> json) {
    final code = ((json['code'] as num?)?.round() ?? 1).clamp(1, 32767);
    return ManualMarkerDefinition(
      name: (json['name']?.toString().trim().isNotEmpty ?? false)
          ? json['name'].toString().trim()
          : 'Marker $code',
      code: code,
      colorValue:
          (json['color'] as num?)?.toInt() ??
          const Color(0xFFFFB74D).toARGB32(),
    );
  }
}

const List<ManualMarkerDefinition> kDefaultManualMarkers = [
  ManualMarkerDefinition(name: 'Event 1', code: 1, colorValue: 0xFFFFB74D),
  ManualMarkerDefinition(name: 'Event 2', code: 2, colorValue: 0xFF4DD0E1),
  ManualMarkerDefinition(name: 'Event 3', code: 3, colorValue: 0xFFCE93D8),
  ManualMarkerDefinition(name: 'Event 5', code: 5, colorValue: 0xFF81C784),
  ManualMarkerDefinition(name: 'Event 10', code: 10, colorValue: 0xFFEF9A9A),
];
