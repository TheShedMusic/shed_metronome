import Foundation

/// Protocol defining the metronome interface
/// Both old (AVAudioEngine-based) and new (Core Audio-based) implementations conform to this
protocol MetronomeInterface {
    /// Start playing the metronome
    func play() throws
    
    /// Pause the metronome
    func pause() throws
    
    /// Stop the metronome
    func stop()
    
    /// Set beats per minute
    func setBPM(bpm: Int)
    
    /// Get current BPM
    var audioBpm: Int { get }
    
    /// Set time signature
    func setTimeSignature(timeSignature: Int)
    
    /// Get time signature
    var audioTimeSignature: Int { get }
    
    /// Set volume
    func setVolume(volume: Float)
    
    /// Get volume
    var getVolume: Float { get }
    
    /// Check if playing
    var isPlaying: Bool { get }
    
    /// Enable microphone input
    func enableMicrophone() throws
    
    /// Set microphone volume
    func setMicVolume(_ volume: Float)
    
    /// Start recording
    /// - Parameter path: File path for recording
    /// - Returns: Success status
    func startRecording(path: String) -> Bool
    
    /// Stop recording
    /// - Returns: Dictionary with recording info (path, timestamps, etc)
    func stopRecording() -> [String: Any]?
    
    /// Cleanup
    func destroy()
    
    /// Set audio files for click sounds
    func setAudioFile(mainFileBytes: Data, accentedFileBytes: Data)
    
    /// Enable tick callback for beat synchronization
    func enableTickCallback(_eventTickSink: EventTickHandler)
}
