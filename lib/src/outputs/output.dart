/// A server output from `GET /api/outputs` (R-09).
///
/// Unit 001 consumes this read-only (criterion 5: post-reconnect state must
/// be correct); the interactive speakers screen is unit 004.
class Output {
  const Output({
    required this.id,
    required this.name,
    required this.type,
    required this.selected,
    required this.hasPassword,
    required this.needsAuthKey,
    this.volume,
  });

  final String id;
  final String name;

  /// `Chromecast`, `AirPlay 1`, `ALSA`, … — a display-only string (parse
  /// defensively per docs/API.md).
  final String type;
  final bool selected;
  final bool hasPassword;
  final bool needsAuthKey;
  final int? volume;

  Output copyWith({bool? selected, int? volume}) => Output(
    id: id,
    name: name,
    type: type,
    selected: selected ?? this.selected,
    hasPassword: hasPassword,
    needsAuthKey: needsAuthKey,
    volume: volume ?? this.volume,
  );

  factory Output.fromJson(Map<String, dynamic> json) => Output(
    id: (json['id'] ?? '').toString(),
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? '',
    selected: json['selected'] as bool? ?? false,
    hasPassword: json['has_password'] as bool? ?? false,
    needsAuthKey: json['needs_auth_key'] as bool? ?? false,
    volume: (json['volume'] as num?)?.toInt(),
  );
}
