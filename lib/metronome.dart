import 'dart:async';

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
      return result ?? false;
    } catch (e) {
      print('[Metronome] Error enabling microphone: $e');
      return false;
    }
  }

  /// set microphone volume (0.0 to 1.0)
  Future<void> setMicVolume(double volume) async {
    try {
      await MetronomePlatform.instance.setMicVolume(volume);
    } catch (e) {
      print('[Metronome] Error setting mic volume: $e');
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
  Future<String?> stopRecording() async {
    try {
      final result = await MetronomePlatform.instance.stopRecording();
      return result;
    } catch (e) {
      print('[Metronome] Error stopping recording: $e');
      return null;
    }
  }

  ///destroy the metronome
  Future<void> destroy() async {
    _initialized = false;
    return MetronomePlatform.instance.destroy();
  }

  @Deprecated('use tickStream instead')
  void onListenTick(onEvent) {}
}
