import Foundation
import AVFoundation

/// Adapter that makes CoreAudioMetronome conform to MetronomeInterface
/// Bridges between the new Core Audio implementation and the existing Flutter plugin interface
class CoreAudioMetronomeAdapter: MetronomeInterface {
    
    private var coreAudio: CoreAudioMetronome
    private var eventTickHandler: EventTickHandler?
    
    // Properties to maintain compatibility
    private var _bpm: Int = 120
    private var _timeSignature: Int = 4
    private var _volume: Float = 1.0
    private var _recordedClickVolume: Float = 0.75
    private var _isPlaying: Bool = false
    private var _recordingPath: String?
    
    // Timing data for Flutter
    private var recordingStartTime: TimeInterval = 0
    private var clickTimestamps: [Double] = []
    
    init(mainFileBytes: Data, accentedFileBytes: Data, bpm: Int, timeSignature: Int, volume: Float, sampleRate: Int) throws {
        self.coreAudio = try CoreAudioMetronome()
        self._bpm = bpm
        self._timeSignature = timeSignature
        self._volume = volume
        
        // Load main click sound
        try loadClickSoundFromData(mainFileBytes, isAccented: false)
        
        // Load accented click sound if provided
        if !accentedFileBytes.isEmpty {
            try loadClickSoundFromData(accentedFileBytes, isAccented: true)
        }
        
        // Set time signature
        coreAudio.setTimeSignature(timeSignature)
        coreAudio.setBPM(Double(bpm))
    }
    
    private func loadClickSoundFromData(_ data: Data, isAccented: Bool) throws {
        // Write to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = isAccented ? "click_accented_temp.wav" : "click_temp.wav"
        let tempFile = tempDir.appendingPathComponent(filename)
        try data.write(to: tempFile)
        
        // Load into Core Audio metronome
        if isAccented {
            try coreAudio.loadAccentedClickSound(from: tempFile)
        } else {
            try coreAudio.loadClickSound(from: tempFile)
        }
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: tempFile)
    }
    
    // MARK: - MetronomeInterface Implementation
    
    func play() throws {
        try coreAudio.play()
        _isPlaying = true
        
        // Start tracking clicks for Flutter callback
        clickTimestamps = []
    }
    
    func pause() throws {
        try coreAudio.pause()
        _isPlaying = false
    }
    
    func stop() {
        try? coreAudio.pause()
        _isPlaying = false
        clickTimestamps = []
    }
    
    func setBPM(bpm: Int) {
        _bpm = bpm
        coreAudio.setBPM(Double(bpm))
    }
    
    var audioBpm: Int {
        return _bpm
    }
    
    func setTimeSignature(timeSignature: Int) {
        _timeSignature = timeSignature
        coreAudio.setTimeSignature(timeSignature)
    }
    
    var audioTimeSignature: Int {
        return _timeSignature
    }
    
    func setVolume(volume: Float) {
        _volume = volume
        // TODO: Implement volume control in CoreAudioMetronome
    }
    
    var getVolume: Float {
        return _volume
    }
    
    var isPlaying: Bool {
        return _isPlaying
    }
    
    func enableMicrophone() throws {
        // Check current microphone permission status
        let permission = AVAudioSession.sharedInstance().recordPermission
        
        print("[CoreAudioAdapter] enableMicrophone() called, permission status: \(permission.rawValue)")
        
        switch permission {
        case .granted:
            print("[CoreAudioAdapter] ✓ Microphone permission granted")
            return  // Success - permission granted
        case .denied:
            print("[CoreAudioAdapter] ✗ Microphone permission DENIED by user")
            // Throw error so Flutter knows permission was denied
            throw NSError(domain: "MetronomeError", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "Microphone permission denied. Please enable in Settings."
            ])
        case .undetermined:
            print("[CoreAudioAdapter] ? Microphone permission undetermined (not yet requested)")
            // iOS permission dialog should have been shown during audio session setup
            // If we get here, it means the dialog was never shown or was bypassed
            throw NSError(domain: "MetronomeError", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Microphone permission not requested"
            ])
        @unknown default:
            print("[CoreAudioAdapter] ! Unknown permission status")
            throw NSError(domain: "MetronomeError", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Unknown permission status"
            ])
        }
    }
    
    func setRecordedClickVolume(_ volume: Float) {
        _recordedClickVolume = volume
        coreAudio.setRecordedClickVolume(volume)
    }
    
    func setDirectMonitoring(enabled: Bool) {
        coreAudio.setDirectMonitoring(enabled: enabled)
    }
    
    func startRecording(path: String) -> Bool {
        _recordingPath = path
        recordingStartTime = Date().timeIntervalSince1970
        clickTimestamps = []
        
        do {
            try coreAudio.startRecording(path: path)
            return true
        } catch {
            print("[CoreAudioAdapter] Failed to start recording: \(error)")
            return false
        }
    }
    
    func stopRecording() -> [String: Any]? {
        guard let recordingPath = _recordingPath else { return nil }
        
        do {
            let finalPath = try coreAudio.stopRecording()
            
            // Move file to requested path if different
            if finalPath != recordingPath {
                let fileManager = FileManager.default
                try? fileManager.removeItem(atPath: recordingPath)
                try fileManager.moveItem(atPath: finalPath, toPath: recordingPath)
            }
            
            // Return data structure expected by Flutter
            return [
                "path": recordingPath,
                "timestamps": clickTimestamps,
                "startTime": recordingStartTime
            ]
        } catch {
            print("[CoreAudioAdapter] Failed to stop recording: \(error)")
            return nil
        }
    }
    
    func destroy() {
        stop()
        // CoreAudioMetronome cleans itself up in deinit
    }
    
    func setAudioFile(mainFileBytes: Data, accentedFileBytes: Data) {
        do {
            try loadClickSoundFromData(mainFileBytes, isAccented: false)
            if !accentedFileBytes.isEmpty {
                try loadClickSoundFromData(accentedFileBytes, isAccented: true)
            }
        } catch {
            print("[CoreAudioAdapter] Failed to load audio file: \(error)")
        }
    }
    
    func enableTickCallback(_eventTickSink: EventTickHandler) {
        self.eventTickHandler = _eventTickSink
        
        // Set up beat callback to forward to Flutter
        coreAudio.setBeatCallback { [weak self] tick in
            guard let self = self, let handler = self.eventTickHandler else { return }
            handler.send(res: tick)
        }
    }
}
