import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'features/library/library_screen.dart';
import 'services/music_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.maubry.musicbox.preview.audio',
    androidNotificationChannelName: 'Music Box · Tu espacio',
    androidNotificationChannelDescription: 'Controles de tu biblioteca local',
    notificationColor: const Color(0xFFC6F36B),
    androidNotificationIcon: 'drawable/ic_music_box_notification',
    androidShowNotificationBadge: false,
    androidStopForegroundOnPause: false,
    androidNotificationOngoing: false,
  );
  runApp(const MusicBoxApp());
}

class MusicBoxApp extends StatelessWidget {
  const MusicBoxApp({super.key, this.api});

  final MusicApi? api;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF101714);
    return MaterialApp(
      title: 'Music Box',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFC6F36B),
          secondary: Color(0xFFE7B56A),
          surface: Color(0xFF1A2420),
          onSurface: Color(0xFFE8EFEA),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: Color(0xFFE8EFEA),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1A2420),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF33413A)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF33413A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFFC6F36B)),
          ),
        ),
        dividerColor: const Color(0xFF33413A),
      ),
      home: LibraryScreen(api: api ?? HttpMusicApi()),
    );
  }
}
