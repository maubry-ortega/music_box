// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:music_box/main.dart';
import 'package:music_box/models/library_manifest.dart';
import 'package:music_box/services/music_api.dart';

void main() {
  testWidgets('shows tracks from the configured Music Box server', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MusicBoxApp(api: _FakeMusicApi()));
    await tester.pumpAndSettle();

    expect(find.text('Tu música,\ntu espacio.'), findsOneWidget);
    expect(find.text('Midnight Drive'), findsOneWidget);
    expect(
      find.text('Test Artist  ·  Test Album  ·  3:42  ·  OPUS 160 kbps'),
      findsOneWidget,
    );
    expect(find.text('Servidor conectado'), findsOneWidget);
  });
}

class _FakeMusicApi implements MusicApi {
  @override
  Future<LibraryManifest> fetchManifest(Uri server) async =>
      const LibraryManifest(
        version: 1,
        count: 1,
        tracks: [
          MusicTrack(
            id: 'track-1',
            title: 'Midnight Drive',
            artist: 'Test Artist',
            album: 'Test Album',
            durationMs: 222000,
            codec: 'flac',
            audioUrl: '/api/tracks/track-1/audio',
          ),
        ],
      );

  @override
  Future<UploadCatalog> fetchUploadCatalog(Uri server) async =>
      const UploadCatalog(artists: [], albums: []);

  @override
  Uri audioUri(Uri server, MusicTrack track) => server.resolve(track.audioUrl);

  @override
  Future<File> downloadAudio(
    Uri server,
    MusicTrack track,
    Directory directory,
  ) async {
    final file = File('${directory.path}/${track.id}.opus');
    await file.parent.create(recursive: true);
    return file;
  }

  @override
  Future<void> uploadAudio(
    Uri server,
    File file,
    Map<String, String> metadata,
  ) async {}
}
