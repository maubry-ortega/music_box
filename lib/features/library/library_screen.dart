import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/library_manifest.dart';
import '../../services/music_api.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.api, super.key});

  final MusicApi api;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _serverPreferenceKey = 'music_box_server_url';
  static const _manifestPreferenceKey = 'music_box_library_manifest';
  static const _catalogPreferenceKey = 'music_box_upload_catalog';
  static const _defaultServerUrl = 'http://192.168.18.96:32516';

  final _serverController = TextEditingController();
  final _player = AudioPlayer();
  Timer? _libraryRefreshTimer;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  LibraryManifest? _manifest;
  UploadCatalog _uploadCatalog = const UploadCatalog(artists: [], albums: []);
  MusicTrack? _currentTrack;
  Uri? _server;
  Directory? _audioDirectory;
  String? _error;
  bool _loading = true;
  bool _savingServer = false;
  bool _uploading = false;
  bool _serverAvailable = false;

  @override
  void initState() {
    super.initState();
    _currentIndexSubscription = _player.currentIndexStream.listen((index) {
      final tracks = _manifest?.tracks ?? const <MusicTrack>[];
      if (!mounted || index == null || index >= tracks.length) return;
      if (_currentTrack?.id != tracks[index].id) {
        setState(() => _currentTrack = tracks[index]);
      }
    });
    _libraryRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_savingServer) unawaited(_connect(saveAddress: false));
    });
    _initialize();
  }

  Future<void> _initialize() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
        _interruptionSubscription = session.interruptionEventStream.listen((
          event,
        ) {
          if (event.begin) unawaited(_player.pause());
        });
      } catch (_) {
        // Audio focus is optional on platforms without a native audio session.
      }
    }
    final preferences = await SharedPreferences.getInstance();
    final savedServer = preferences.getString(_serverPreferenceKey);
    if (!mounted) return;
    _serverController.text = savedServer ?? _defaultServerUrl;
    _audioDirectory = await getApplicationSupportDirectory();
    await _loadCachedLibrary(preferences);
    await _connect(saveAddress: false);
  }

  Future<void> _loadCachedLibrary(SharedPreferences preferences) async {
    final cachedManifest = preferences.getString(_manifestPreferenceKey);
    final cachedCatalog = preferences.getString(_catalogPreferenceKey);
    LibraryManifest? manifest;
    var catalog = const UploadCatalog(artists: [], albums: []);
    try {
      if (cachedManifest != null) {
        final json = jsonDecode(cachedManifest);
        if (json is Map<String, dynamic>) {
          manifest = LibraryManifest.fromJson(json);
        }
      }
      if (cachedCatalog != null) {
        final json = jsonDecode(cachedCatalog);
        if (json is Map<String, dynamic>) {
          catalog = UploadCatalog.fromJson(json);
        }
      }
    } catch (_) {
      // Ignore a damaged cache; the online synchronization can rebuild it.
    }
    if (!mounted || manifest == null) return;
    setState(() {
      _manifest = manifest;
      _uploadCatalog = catalog;
      _loading = false;
    });
  }

  Future<void> _saveCachedLibrary(
    SharedPreferences preferences,
    LibraryManifest manifest,
    UploadCatalog catalog,
  ) async {
    await preferences.setString(
      _manifestPreferenceKey,
      jsonEncode(manifest.toJson()),
    );
    await preferences.setString(
      _catalogPreferenceKey,
      jsonEncode(catalog.toJson()),
    );
  }

  Uri? _parseServerAddress() {
    final uri = Uri.tryParse(_serverController.text.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.replace(path: '', query: null, fragment: null);
  }

  Future<void> _connect({bool saveAddress = true}) async {
    final server = _parseServerAddress();
    if (server == null) {
      setState(() {
        _error =
            'Escribe una dirección válida, por ejemplo http://192.168.1.20:32516';
        _loading = false;
        _serverAvailable = false;
      });
      return;
    }

    setState(() {
      _server = server;
      _loading = true;
      _savingServer = true;
      _serverAvailable = false;
      _error = null;
    });
    try {
      if (saveAddress) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(_serverPreferenceKey, server.toString());
      }
      final manifest = await widget.api.fetchManifest(server);
      final catalog = await widget.api.fetchUploadCatalog(server);
      final preferences = await SharedPreferences.getInstance();
      await _saveCachedLibrary(preferences, manifest, catalog);
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _uploadCatalog = catalog;
        _loading = false;
        _serverAvailable = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _connectionMessage(error);
        _loading = false;
        _serverAvailable = false;
      });
    } finally {
      if (mounted) setState(() => _savingServer = false);
    }
  }

  String _connectionMessage(Object error) {
    if (error is TimeoutException) {
      return 'El servidor tardó demasiado en responder.';
    }
    if (error is FormatException) {
      return 'El servidor devolvió un manifiesto no válido.';
    }
    return 'No se pudo conectar. Verifica la IP, el puerto 32516 y que ambos estén en la misma red.';
  }

  Future<void> _togglePlayback(MusicTrack track) async {
    try {
      if (_currentTrack?.id == track.id && _player.playing) {
        await _player.pause();
        return;
      }
      if (_currentTrack?.id != track.id) {
        final previousTrack = _currentTrack;
        setState(() => _currentTrack = track);
        try {
          final directory =
              _audioDirectory ?? await getApplicationSupportDirectory();
          _audioDirectory = directory;
          final libraryTracks = _manifest?.tracks ?? [track];
          final tracks = <MusicTrack>[];
          final files = <File>[];
          for (final libraryTrack in libraryTracks) {
            final cachedFile = File(
              '${directory.path}/${libraryTrack.id}.opus',
            );
            if (await cachedFile.exists() && await cachedFile.length() > 0) {
              tracks.add(libraryTrack);
              files.add(cachedFile);
              continue;
            }
            final server = _server;
            if (!_serverAvailable || server == null) {
              if (libraryTrack.id != track.id) continue;
              throw StateError(
                'Esta pista todavía no está descargada para usarla sin conexión.',
              );
            }
            tracks.add(libraryTrack);
            files.add(
              await widget.api.downloadAudio(server, libraryTrack, directory),
            );
          }
          if (tracks.isEmpty) {
            throw StateError(
              'Esta pista todavía no está descargada para usarla sin conexión.',
            );
          }
          final sources = <AudioSource>[
            for (var index = 0; index < tracks.length; index++)
              AudioSource.file(
                files[index].path,
                tag: MediaItem(
                  id: tracks[index].id,
                  album: tracks[index].album,
                  artist: tracks[index].artist,
                  title: tracks[index].title,
                  duration: Duration(milliseconds: tracks[index].durationMs),
                ),
              ),
          ];
          final initialIndex = tracks.indexWhere((item) => item.id == track.id);
          await _player.setAudioSources(
            sources,
            initialIndex: initialIndex < 0 ? 0 : initialIndex,
          );
        } catch (_) {
          if (mounted) setState(() => _currentTrack = previousTrack);
          rethrow;
        }
      }
      await _player.play();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo reproducir la pista: $error')),
      );
    }
  }

  Future<void> _uploadSong() async {
    if (!_serverAvailable || _server == null || _uploading) return;
    final server = _server!;
    final selection = await Navigator.of(context).push<UploadSelection>(
      MaterialPageRoute(
        builder: (_) => UploadSongPage(catalog: _uploadCatalog),
      ),
    );
    if (!mounted || selection == null) return;
    setState(() => _uploading = true);
    try {
      await widget.api.uploadAudio(server, selection.file, selection.metadata);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Canción subida. Preparando tu versión Opus…'),
        ),
      );
      await _connect(saveAddress: false);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo subir la canción: $error')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _libraryRefreshTimer?.cancel();
    unawaited(_currentIndexSubscription?.cancel());
    unawaited(_interruptionSubscription?.cancel());
    _serverController.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tracks = _manifest?.tracks ?? const <MusicTrack>[];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 22,
        title: const Row(
          children: [
            Icon(Icons.graphic_eq_rounded, size: 23),
            SizedBox(width: 10),
            Text(
              'MUSIC BOX',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizar biblioteca',
            onPressed: _loading ? null : () => _connect(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BIBLIOTECA PERSONAL',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.secondary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tu música,\ntu espacio.',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.05,
                            ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _serverController,
                              enabled: !_savingServer,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.go,
                              autocorrect: false,
                              onSubmitted: (_) => _connect(),
                              decoration: const InputDecoration(
                                labelText: 'Servidor local',
                                hintText: 'http://192.168.1.20:32516',
                                prefixIcon: Icon(Icons.lan_outlined),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton.filled(
                            onPressed: _savingServer ? null : () => _connect(),
                            tooltip: 'Conectar al servidor',
                            icon: _savingServer
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_forward_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            _error == null && !_loading
                                ? Icons.circle
                                : Icons.circle_outlined,
                            size: 9,
                            color: _error == null && !_loading
                                ? colorScheme.primary
                                : colorScheme.secondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error ??
                                  (_loading
                                      ? 'Conectando con tu servidor'
                                      : 'Servidor conectado'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: _error == null
                                        ? const Color(0xFFADB9B1)
                                        : colorScheme.secondary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
                  child: Row(
                    children: [
                      Text(
                        'PISTAS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_manifest?.count ?? 0}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildTrackList(tracks)),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNavigation(colorScheme),
    );
  }

  Widget _buildBottomNavigation(ColorScheme colorScheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_currentTrack != null) _buildPlayerBar(colorScheme),
        NavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (index) {
            if (index == 1 && _serverAvailable) unawaited(_uploadSong());
          },
          backgroundColor: const Color(0xFF151F1B),
          indicatorColor: const Color(0xFF2A4537),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music_rounded),
              label: 'Biblioteca',
            ),
            NavigationDestination(
              icon: _uploading
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_circle_outline_rounded),
              selectedIcon: const Icon(Icons.file_upload_rounded),
              label: _uploading ? 'Subiendo…' : 'Subir música',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTrackList(List<MusicTrack> tracks) {
    if (_loading && _manifest == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 32),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _connect(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }
    if (tracks.isEmpty) {
      return RefreshIndicator(
        onRefresh: _connect,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 68),
            Icon(Icons.library_music_outlined, size: 34),
            SizedBox(height: 12),
            Center(child: Text('Todavía no hay pistas listas')),
            SizedBox(height: 6),
            Center(child: Text('Añade música a la biblioteca del servidor')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _connect,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
        itemCount: tracks.length,
        separatorBuilder: (context, index) =>
            const Divider(height: 1, indent: 64),
        itemBuilder: (context, index) => _buildTrackTile(tracks[index]),
      ),
    );
  }

  Widget _buildTrackTile(MusicTrack track) {
    return StreamBuilder<PlayerState>(
      stream: _player.playerStateStream,
      builder: (context, snapshot) {
        final isCurrent = _currentTrack?.id == track.id;
        final isPlaying = isCurrent && (snapshot.data?.playing ?? false);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 3,
          ),
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF23332A),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              isCurrent ? Icons.graphic_eq_rounded : Icons.album_outlined,
              color: Theme.of(context).colorScheme.primary,
              size: 22,
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${track.artist}  ·  ${track.album}  ·  ${_formatDuration(track.durationMs)}  ·  ${track.deliveryCodec.toUpperCase()} ${track.deliveryBitrateKbps} kbps',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFFADB9B1)),
          ),
          trailing: IconButton(
            tooltip: isPlaying ? 'Pausar' : 'Reproducir',
            onPressed: () => _togglePlayback(track),
            icon: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          onTap: () => _togglePlayback(track),
        );
      },
    );
  }

  Widget _buildPlayerBar(ColorScheme colorScheme) {
    return SafeArea(
      top: false,
      child: Material(
        color: const Color(0xFF1A2420),
        child: InkWell(
          onTap: _showNowPlaying,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFF33413A))),
            ),
            padding: const EdgeInsets.fromLTRB(18, 8, 12, 8),
            child: Row(
              children: [
                _buildCoverArt(size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _currentTrack!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _currentTrack!.artist,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFADB9B1),
                        ),
                      ),
                    ],
                  ),
                ),
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;
                    return IconButton(
                      tooltip: playing ? 'Pausar' : 'Reproducir',
                      onPressed: () => _togglePlayback(_currentTrack!),
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverArt({double size = 280}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size > 100 ? 24 : 8),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFC6F36B), Color(0xFF527A35), Color(0xFF18241B)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.graphic_eq_rounded,
          size: size * .42,
          color: const Color(0xFF101714),
        ),
      ),
    );
  }

  Future<void> _showNowPlaying() async {
    final track = _currentTrack;
    if (track == null || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101714),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF506157),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 24),
              _buildCoverArt(),
              const SizedBox(height: 22),
              Text(
                track.title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${track.artist} · ${track.album}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFADB9B1)),
              ),
              const SizedBox(height: 6),
              Text(
                'MUSIC BOX  ·  ${track.deliveryCodec.toUpperCase()} ${track.deliveryBitrateKbps} kbps',
                style: const TextStyle(
                  color: Color(0xFFC6F36B),
                  fontSize: 11,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 18),
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (context, positionSnapshot) =>
                    StreamBuilder<Duration?>(
                      stream: _player.durationStream,
                      builder: (context, durationSnapshot) {
                        final duration = durationSnapshot.data ?? Duration.zero;
                        final position = positionSnapshot.data ?? Duration.zero;
                        final max = duration.inMilliseconds.toDouble();
                        return Slider(
                          value: max == 0
                              ? 0
                              : position.inMilliseconds
                                    .clamp(0, duration.inMilliseconds)
                                    .toDouble(),
                          max: max == 0 ? 1 : max,
                          onChanged: max == 0
                              ? null
                              : (value) => _player.seek(
                                  Duration(milliseconds: value.round()),
                                ),
                        );
                      },
                    ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 34,
                    onPressed: _player.hasPrevious
                        ? _player.seekToPrevious
                        : null,
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  const SizedBox(width: 12),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      return IconButton.filled(
                        iconSize: 34,
                        onPressed: () => _togglePlayback(_currentTrack!),
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    iconSize: 34,
                    onPressed: _player.hasNext ? _player.seekToNext : null,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class UploadSelection {
  const UploadSelection({required this.file, required this.metadata});

  final File file;
  final Map<String, String> metadata;
}

class UploadSongPage extends StatefulWidget {
  const UploadSongPage({required this.catalog, super.key});

  final UploadCatalog catalog;

  @override
  State<UploadSongPage> createState() => _UploadSongPageState();
}

class _UploadSongPageState extends State<UploadSongPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();
  final _yearController = TextEditingController();
  final _genreController = TextEditingController();
  String? _selectedArtist;
  String? _selectedAlbum;
  String? _filePath;
  String? _fileName;
  bool _choosingFile = false;

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _yearController.dispose();
    _genreController.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    if (_choosingFile) return;
    setState(() => _choosingFile = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'mp3',
          'flac',
          'wav',
          'm4a',
          'ogg',
          'opus',
          'aac',
          'aiff',
          'wma',
        ],
      );
      if (result.isEmpty || result.single.path == null) return;
      final path = result.single.path!;
      setState(() {
        _filePath = path;
        _fileName = path.split(Platform.pathSeparator).last;
        if (_titleController.text.trim().isEmpty) {
          _titleController.text = _fileName!.replaceFirst(
            RegExp(r'\.[^.]+$'),
            '',
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir el selector de archivos.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _choosingFile = false);
    }
  }

  void _submit() {
    if (_filePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero selecciona una canción.')),
      );
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final artist = _artistController.text.trim().isNotEmpty
        ? _artistController.text.trim()
        : (_selectedArtist ?? '');
    final album = _albumController.text.trim().isNotEmpty
        ? _albumController.text.trim()
        : (_selectedAlbum ?? '');
    Navigator.of(context).pop(
      UploadSelection(
        file: File(_filePath!),
        metadata: {
          'title': _titleController.text.trim(),
          'artist': artist,
          'album': album,
          'year': _yearController.text.trim(),
          'genre': _genreController.text.trim(),
        },
      ),
    );
  }

  String? _required(String? value, String label) {
    if (value == null || value.trim().isEmpty) return 'Escribe $label.';
    return null;
  }

  String? _year(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final year = int.tryParse(value.trim());
    if (year == null || year < 1 || year > 9999) {
      return 'Usa un año entre 1 y 9999.';
    }
    return null;
  }

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    helperMaxLines: 2,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectedFile = _fileName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Subir música'),
        leading: IconButton(
          tooltip: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                children: [
                  Text(
                    'Añade una canción',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Selecciona el archivo y completa sus datos para organizar tu biblioteca.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFADB9B1),
                    ),
                  ),
                  const SizedBox(height: 24),
                  InkWell(
                    onTap: _chooseFile,
                    borderRadius: BorderRadius.circular(16),
                    child: Ink(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A2420),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selectedFile == null
                              ? const Color(0xFF506157)
                              : colors.primary,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 58,
                            height: 58,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A4537),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              selectedFile == null
                                  ? Icons.audio_file_rounded
                                  : Icons.check_circle_rounded,
                              color: colors.primary,
                              size: 30,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  selectedFile ??
                                      'Selecciona un archivo de audio',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  selectedFile == null
                                      ? 'MP3, FLAC, WAV, M4A, OGG, OPUS y más'
                                      : 'Toca para cambiar el archivo',
                                  style: const TextStyle(
                                    color: Color(0xFFADB9B1),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_choosingFile)
                            const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Información de la canción',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _titleController,
                    textInputAction: TextInputAction.next,
                    decoration: _decoration(
                      'Título *',
                      Icons.music_note_rounded,
                    ),
                    validator: (value) => _required(value, 'el título'),
                  ),
                  const SizedBox(height: 14),
                  if (widget.catalog.artists.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: _selectedArtist,
                      isExpanded: true,
                      decoration: _decoration(
                        'Usar artista existente',
                        Icons.person_outline_rounded,
                      ),
                      items: widget.catalog.artists
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _selectedArtist = value),
                    ),
                  if (widget.catalog.artists.isNotEmpty)
                    const SizedBox(height: 14),
                  TextFormField(
                    controller: _artistController,
                    textInputAction: TextInputAction.next,
                    decoration:
                        _decoration(
                          'Artista nuevo${_selectedArtist == null ? ' *' : ''}',
                          Icons.person_add_alt_rounded,
                        ).copyWith(
                          helperText:
                              'Selecciona uno existente o escribe uno nuevo.',
                        ),
                    validator: (value) {
                      if (_selectedArtist != null) return null;
                      return _required(value, 'el artista');
                    },
                  ),
                  const SizedBox(height: 14),
                  if (widget.catalog.albums.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: _selectedAlbum,
                      isExpanded: true,
                      decoration: _decoration(
                        'Usar álbum existente',
                        Icons.album_outlined,
                      ),
                      items: widget.catalog.albums
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _selectedAlbum = value),
                    ),
                  if (widget.catalog.albums.isNotEmpty)
                    const SizedBox(height: 14),
                  TextFormField(
                    controller: _albumController,
                    textInputAction: TextInputAction.next,
                    decoration:
                        _decoration(
                          'Álbum nuevo${_selectedAlbum == null ? ' *' : ''}',
                          Icons.library_music_outlined,
                        ).copyWith(
                          helperText:
                              'Selecciona uno existente o escribe uno nuevo.',
                        ),
                    validator: (value) {
                      if (_selectedAlbum != null) return null;
                      return _required(value, 'el álbum');
                    },
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _yearController,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          decoration: _decoration(
                            'Año',
                            Icons.calendar_today_outlined,
                          ),
                          validator: _year,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextFormField(
                          controller: _genreController,
                          textInputAction: TextInputAction.done,
                          decoration: _decoration(
                            'Género',
                            Icons.local_offer_outlined,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.cloud_upload_rounded),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('Subir canción'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Cancelar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
