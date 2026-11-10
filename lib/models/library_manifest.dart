class LibraryManifest {
  const LibraryManifest({
    required this.version,
    required this.count,
    required this.tracks,
  });

  final int version;
  final int count;
  final List<MusicTrack> tracks;

  Map<String, dynamic> toJson() => {
    'version': version,
    'count': count,
    'tracks': tracks.map((track) => track.toJson()).toList(growable: false),
  };

  factory LibraryManifest.fromJson(Map<String, dynamic> json) {
    final tracksJson = json['tracks'];
    if (tracksJson is! List) {
      throw const FormatException(
        'El manifiesto no contiene una lista de pistas.',
      );
    }
    return LibraryManifest(
      version: json['version'] as int? ?? 1,
      count: json['count'] as int? ?? tracksJson.length,
      tracks: tracksJson
          .map((item) => MusicTrack.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.codec,
    this.deliveryCodec = 'opus',
    this.deliveryBitrateKbps = 160,
    required this.audioUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String codec;
  final String deliveryCodec;
  final int deliveryBitrateKbps;
  final String audioUrl;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'duration_ms': durationMs,
    'codec': codec,
    'delivery_codec': deliveryCodec,
    'delivery_bitrate_kbps': deliveryBitrateKbps,
    'audio_url': audioUrl,
  };

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
    id: json['id'] as String,
    title: json['title'] as String? ?? 'Sin título',
    artist: json['artist'] as String? ?? 'Artista desconocido',
    album: json['album'] as String? ?? 'Álbum desconocido',
    durationMs: json['duration_ms'] as int? ?? 0,
    codec: json['codec'] as String? ?? 'unknown',
    deliveryCodec: json['delivery_codec'] as String? ?? 'opus',
    deliveryBitrateKbps: json['delivery_bitrate_kbps'] as int? ?? 160,
    audioUrl: json['audio_url'] as String,
  );
}
