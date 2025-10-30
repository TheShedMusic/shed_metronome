import 'dart:async';
import 'dart:typed_data';

import 'metronome_platform_interface.dart';

class Metronome {
  static final Metronome _instance = Metronome._internal();
  factory Metronome() {
    return _instance;
  }
  Metronome._internal();
  final MetronomePlatform _platform = MetronomePlatform.instance;
  bool get isInitialized => _initialized;
  bool _initialized = false;

  /// ```
  /// metronome.tickStream.listen(
  ///   (int tick) {
  ///     print("tick: $tick");
  ///   },
  /// );
  /// ```
  Stream<int> get tickStream => _platform.tickController.stream;

  ///initialize the metronome
  /// ```
  /// @param mainPath: the path of the main audio file
  /// @param accentedPath: the path of the accented audio file, default ''
  /// @param bpm: the beats per minute, default `120`
  /// @param volume: the volume of the metronome, default `50`%
  /// @param timeSignature: the timeSignature of the metronome, default `4`
  /// @param sampleRate: the sampleRate of the metronome, default `44100`
  /// ```
  Future<void> init(
    String mainPath, {
    String accentedPath = '',
    int bpm = 120,
    int volume = 50,
    bool enableTickCallback = false,
    int timeSignature = 4,
    int sampleRate = 44100,
  }) async {
    try {
      MetronomePlatform.instance.init(
        mainPath,
        accentedPath: accentedPath,
        bpm: bpm,
        volume: volume,
        enableTickCallback: enableTickCallback,
        timeSignature: timeSignature,
        sampleRate: sampleRate,
      );
      _initialized = true;
      return;
    } catch (err) {
      _initialized = false;
      rethrow;
    }
  }

  ///play the metronome
  Future<void> play() async {
    return MetronomePlatform.instance.play();
  }

  ///pause the metronome
  Future<void> pause() async {
    return MetronomePlatform.instance.pause();
  }

  ///stop the metronome
  Future<void> stop() async {
    return MetronomePlatform.instance.stop();
  }

  ///get the volume of the metronome
  Future<int> getVolume() async {
    int? volume = await MetronomePlatform.instance.getVolume();
    return volume ?? 50;
  }

  ///set the volume of the metronome (0-100)
  Future<void> setVolume(int volume) async {
    return MetronomePlatform.instance.setVolume(volume);
  }

  ///check if the metronome is playing
  Future<bool?> isPlaying() async {
    return MetronomePlatform.instance.isPlaying();
  }

  ///set the audio file of the metronome
  Future<void> setAudioFile(
      {String mainPath = '', String accentedPath = ''}) async {
    return MetronomePlatform.instance
        .setAudioFile(mainPath: mainPath, accentedPath: accentedPath);
  }

  ///set the bpm of the metronome
  Future<void> setBPM(int bpm) async {
    return MetronomePlatform.instance.setBPM(bpm);
  }

  ///get the bpm of the metronome
  Future<int> getBPM() async {
    int? bpm = await MetronomePlatform.instance.getBPM();
    return bpm ?? 120;
  }

  ///set the time signature of the metronome
  Future<void> setTimeSignature(int timeSignature) async {
    return MetronomePlatform.instance.setTimeSignature(timeSignature);
  }

  ///get the signature of the metronome
  Future<int> getTimeSignature() async {
    int? timeSignature = await MetronomePlatform.instance.getTimeSignature();
    return timeSignature ?? 0;
  }

  ///enable microphone input for recording
  ///must be called before startRecording()
  Future<bool> enableMicrophone() async {
    try {
      final result = await MetronomePlatform.instance.enableMicrophone();
      return result;
    } catch (e) {
      print('[Metronome] Error enabling microphone: $e');
      return false;
    }
  }

  /// Request microphone permission from the user
  /// Returns true if permission is granted, false otherwise
  Future<bool> requestMicrophonePermission() async {
    try {
      final result = await MetronomePlatform.instance.requestMicrophonePermission();
      return result;
    } catch (e) {
      print('[Metronome] Error requesting microphone permission: $e');
      return false;
    }
  }

  /// Check current microphone permission status
  /// Returns true if permission is granted, false if denied or undetermined
  Future<bool> checkMicrophonePermission() async {
    try {
      final result = await MetronomePlatform.instance.checkMicrophonePermission();
      return result;
    } catch (e) {
      print('[Metronome] Error checking microphone permission: $e');
      return false;
    }
  }

  /// set recorded click volume (1.0 for drum mode, 0.75 for normal mode)
  Future<void> setRecordedClickVolume(double volume) async {
    try {
      await MetronomePlatform.instance.setRecordedClickVolume(volume);
    } catch (e) {
      print('[Metronome] Error setting recorded click volume: $e');
    }
  }

  ///start recording audio (captures both clicks and microphone)
  /// [path] - Full file path where recording will be saved (must end in .wav for now)
  Future<bool> startRecording(String path) async {
    try {
      final result = await MetronomePlatform.instance.startRecording(path);
      return result ?? false;
    } catch (e) {
      print('[Metronome] Error starting recording: $e');
      return false;
    }
  }

  ///stop recording and finalize audio file
  Future<Map<String, dynamic>?> stopRecording() async {
    try {
      final result = await MetronomePlatform.instance.stopRecording();
      return result;
    } catch (e) {
      print('[Metronome] Error stopping recording: $e');
      return null;
    }
  }

  Future<String?> generateClickTrack({
  required List<double> timestamps,
  required int bpm,
  required int timeSignature,
  required Uint8List mainClickBytes,
  required Uint8List accentedClickBytes,
  required String outputPath,
}) async {
  return MetronomePlatform.instance.generateClickTrack(
    timestamps: timestamps,
    bpm: bpm,
    timeSignature: timeSignature,
    mainClickBytes: mainClickBytes,
    accentedClickBytes: accentedClickBytes,
    outputPath: outputPath,
  );
}

/// Mix microphone audio with click track
Future<String?> mixAudioFiles({
  required String micAudioPath,
  required String clickTrackPath,
  required String outputPath,
}) async {
  return MetronomePlatform.instance.mixAudioFiles(
    micAudioPath: micAudioPath,
    clickTrackPath: clickTrackPath,
    outputPath: outputPath,
  );
}

  /// Enable or disable direct monitoring (hearing yourself through headphones)
  Future<void> setDirectMonitoring(bool enabled) async {
    return MetronomePlatform.instance.setDirectMonitoring(enabled);
  }

  ///destroy the metronome
  Future<void> destroy() async {
    _initialized = false;
    return MetronomePlatform.instance.destroy();
  }

  @Deprecated('use tickStream instead')
  void onListenTick(onEvent) {}
}
