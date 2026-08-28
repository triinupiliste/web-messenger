import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'api_service.dart';

class AudioService {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _recordedPath;

  // Exposed so a voice-message bubble can show a live seek bar/duration.
  Stream<Duration> get onDurationChanged => _audioPlayer.onDurationChanged;
  Stream<Duration> get onPositionChanged => _audioPlayer.onPositionChanged;
  Stream<void> get onPlayerComplete => _audioPlayer.onPlayerComplete;

  // Browsers' MediaRecorder API can't produce AAC/M4A (mobile's format) — only
  // Opus-in-WebM is broadly supported, so web must use a different encoder.
  // Exposed so the caller can pick a matching filename extension.
  String get recordingFileExtension => kIsWeb ? '.weba' : '.m4a';

  Future<void> startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final config = RecordConfig(encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc);
      if (kIsWeb) {
        // No real filesystem on web — record only ever hands back a blob: URL
        // from stop(), regardless of the path passed in here.
        await _audioRecorder.start(config, path: '');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        _recordedPath = '${dir.path}/voice_note_${DateTime.now().millisecondsSinceEpoch}$recordingFileExtension';
        await _audioRecorder.start(config, path: _recordedPath!);
      }
    }
  }

  Future<String?> stopRecording() async {
    final path = await _audioRecorder.stop();
    return path ?? _recordedPath;
  }

  // Cross-platform: on mobile/desktop `record` writes a real file readable via
  // dart:io; on web it only ever exposes a blob: URL (not a real file), so we
  // fetch that instead — dart:io's File can't read blob: URLs.
  Future<Uint8List?> stopRecordingBytes() async {
    final path = await stopRecording();
    if (path == null || path.isEmpty) return null;
    if (kIsWeb) {
      final response = await http.get(Uri.parse(path));
      return response.bodyBytes;
    }
    return File(path).readAsBytes();
  }

  // "Remote" means an absolute http(s) URL (legacy rows) or a server-relative
  // upload path like '/uploads/xyz.m4a' (what's stored today); anything else is
  // a local, not-yet-uploaded file path.
  bool _isRemote(String urlOrPath) =>
      urlOrPath.startsWith('http://') ||
      urlOrPath.startsWith('https://') ||
      urlOrPath.startsWith('/uploads/');

  // Loads a voice message's audio without starting playback, so its total
  // duration can be shown (via onDurationChanged) before the user taps play.
  Future<void> preload(String urlOrPath) async {
    if (_isRemote(urlOrPath)) {
      await _audioPlayer.setSourceUrl(ApiService.mediaUrl(urlOrPath));
    } else {
      await _audioPlayer.setSourceDeviceFile(urlOrPath);
    }
  }

  // Voice messages store a server-relative path like '/uploads/xyz.m4a', not a full URL.
  Future<void> playAudio(String urlOrPath) async {
    if (_isRemote(urlOrPath)) {
      await _audioPlayer.play(UrlSource(ApiService.mediaUrl(urlOrPath)));
    } else {
      await _audioPlayer.play(DeviceFileSource(urlOrPath));
    }
  }

  Future<void> pauseAudio() async {
    await _audioPlayer.pause();
  }

  Future<void> seek(Duration position) async {
    await _audioPlayer.seek(position);
  }

  Future<void> stopAudio() async {
    await _audioPlayer.stop();
  }

  // Must be called by the owning widget's dispose(), otherwise the native
  // recorder/player session leaks for the app's lifetime.
  Future<void> dispose() async {
    await _audioRecorder.dispose();
    await _audioPlayer.dispose();
  }
}