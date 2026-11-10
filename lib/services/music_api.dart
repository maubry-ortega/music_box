import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/library_manifest.dart';

abstract interface class MusicApi {
  Future<LibraryManifest> fetchManifest(Uri server);

  Future<UploadCatalog> fetchUploadCatalog(Uri server);

  Uri audioUri(Uri server, MusicTrack track);

  Future<File> downloadAudio(Uri server, MusicTrack track, Directory directory);

  Future<void> uploadAudio(Uri server, File file, Map<String, String> metadata);
}

class UploadCatalog {
  const UploadCatalog({required this.artists, required this.albums});
  final List<String> artists;
  final List<String> albums;

  Map<String, dynamic> toJson() => {'artists': artists, 'albums': albums};

  factory UploadCatalog.fromJson(Map<String, dynamic> json) => UploadCatalog(
    artists: (json['artists'] as List<dynamic>? ?? const []).cast<String>(),
    albums: (json['albums'] as List<dynamic>? ?? const []).cast<String>(),
  );
}

class HttpMusicApi implements MusicApi {
  HttpMusicApi({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<LibraryManifest> fetchManifest(Uri server) async {
    final request = await _client.getUrl(server.resolve('/api/manifest'));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 12));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'El servidor respondió ${response.statusCode}.',
        uri: server,
      );
    }
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Respuesta inválida del servidor.');
    }
    return LibraryManifest.fromJson(json);
  }

  @override
  Uri audioUri(Uri server, MusicTrack track) => server.resolve(track.audioUrl);

  @override
  Future<UploadCatalog> fetchUploadCatalog(Uri server) async {
    final response = await _client
        .getUrl(server.resolve('/api/catalog'))
        .then((request) => request.close());
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('No se pudo leer el catálogo.', uri: server);
    }
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Catálogo inválido.');
    }
    return UploadCatalog.fromJson(json);
  }

  @override
  Future<File> downloadAudio(
    Uri server,
    MusicTrack track,
    Directory directory,
  ) async {
    await directory.create(recursive: true);
    final target = File('${directory.path}/${track.id}.opus');
    if (await target.exists() && await target.length() > 0) return target;

    final temporary = File('${target.path}.part');
    if (await temporary.exists()) await temporary.delete();
    final request = await _client.getUrl(audioUri(server, track));
    request.headers.set(HttpHeaders.acceptHeader, 'audio/ogg');
    final response = await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'No se pudo descargar el audio (${response.statusCode}).',
        uri: audioUri(server, track),
      );
    }
    final sink = temporary.openWrite();
    try {
      await response.pipe(sink);
    } catch (_) {
      await sink.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    await temporary.rename(target.path);
    return target;
  }

  @override
  Future<void> uploadAudio(
    Uri server,
    File file,
    Map<String, String> metadata,
  ) async {
    final boundary = 'musicbox-${DateTime.now().microsecondsSinceEpoch}';
    final request = await _client.postUrl(server.resolve('/api/upload'));
    request.headers.contentType = ContentType(
      'multipart',
      'form-data',
      parameters: {'boundary': boundary},
    );
    final filename = file.uri.pathSegments.last;
    request.write('--$boundary\r\n');
    request.write(
      'Content-Disposition: form-data; name="file"; filename="$filename"\r\n',
    );
    request.write('Content-Type: application/octet-stream\r\n\r\n');
    await request.addStream(file.openRead());
    request.write('\r\n--$boundary\r\n');
    for (final entry in metadata.entries) {
      request.write(
        'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n${entry.value}\r\n--$boundary\r\n',
      );
    }
    request.write('--\r\n');
    final response = await request.close().timeout(const Duration(minutes: 5));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.created) {
      throw HttpException(
        'El servidor rechazó la subida (${response.statusCode}): $body',
        uri: server,
      );
    }
  }
}
