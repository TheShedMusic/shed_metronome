import AVFoundation

/// Singleton to share the metronome's AVAudioEngine with external recorders
/// This allows apps to tap into the metronome's audio output for synchronized recording
public class SharedMetronomeEngine {
    public static let shared = SharedMetronomeEngine()
    
    private(set) public var audioEngine: AVAudioEngine?
    private(set) public var mixerNode: AVAudioMixerNode?
    
    private init() {}
    
    public func register(_ engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        self.audioEngine = engine
        self.mixerNode = mixer
        print("[SharedMetronomeEngine] ✅ Engine registered")
    }
    
    public func unregister() {
        self.audioEngine = nil
        self.mixerNode = nil
        print("[SharedMetronomeEngine] Engine unregistered")
    }
}
