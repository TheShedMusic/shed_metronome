// ============================================================================
// DEPRECATED: This file is no longer used with Core Audio implementation.
// 
// Core Audio mixes audio in real-time during recording (sample-accurate).
// This post-recording mixing approach is only kept for:
// - Backwards compatibility with AVAudioEngine (useCoreAudio = false)
// - Legacy recordings that need remixing
//
// TODO: Remove after Phase 6 validation when Core Audio is proven stable.
// ============================================================================

import AVFoundation

class AudioMixer {
    
    /// Mix two audio files into one
    /// - Parameters:
    ///   - micAudioPath: Path to the microphone recording
    ///   - clickTrackPath: Path to the generated click track
    ///   - outputPath: Path where the mixed audio should be saved
    /// - Returns: The output path if successful, nil otherwise
    static func mixAudioFiles(
        micAudioPath: String,
        clickTrackPath: String,
        outputPath: String
    ) -> String? {
        do {
            let micURL = URL(fileURLWithPath: micAudioPath)
            let clickURL = URL(fileURLWithPath: clickTrackPath)
            let outputURL = URL(fileURLWithPath: outputPath)
            
            // Load audio files
            let micFile = try AVAudioFile(forReading: micURL)
            let clickFile = try AVAudioFile(forReading: clickURL)
            
            // Use the longer duration
            let micDuration = Double(micFile.length) / micFile.processingFormat.sampleRate
            let clickDuration = Double(clickFile.length) / clickFile.processingFormat.sampleRate
            let maxDuration = max(micDuration, clickDuration)
            
            let sampleRate = micFile.processingFormat.sampleRate
            let channelCount = micFile.processingFormat.channelCount
            let totalFrames = AVAudioFrameCount(maxDuration * sampleRate)
            
            // Create output format
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                print("[AudioMixer] Failed to create output format")
                return nil
            }
            
            // Create output file (using .m4a for compatibility)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: 128000
            ]
            
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings
            )
            
            // Create buffers
            let bufferSize: AVAudioFrameCount = 4096
            guard let micBuffer = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: bufferSize),
                  let clickBuffer = AVAudioPCMBuffer(pcmFormat: clickFile.processingFormat, frameCapacity: bufferSize),
                  let mixBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else {
                print("[AudioMixer] Failed to create buffers")
                return nil
            }
            
            var framesProcessed: AVAudioFrameCount = 0
            
            while framesProcessed < totalFrames {
                let framesToRead = min(bufferSize, totalFrames - framesProcessed)
                
                // Read from both files (or silence if past end)
                micBuffer.frameLength = 0
                clickBuffer.frameLength = 0
                
                if framesProcessed < AVAudioFrameCount(micFile.length) {
                    try micFile.read(into: micBuffer, frameCount: framesToRead)
                }
                
                if framesProcessed < AVAudioFrameCount(clickFile.length) {
                    try clickFile.read(into: clickBuffer, frameCount: framesToRead)
                }
                
                // Mix the audio
                mixBuffer.frameLength = framesToRead
                let mixData = mixBuffer.floatChannelData!
                let micData = micBuffer.floatChannelData!
                let clickData = clickBuffer.floatChannelData!
                
                for channel in 0..<Int(channelCount) {
                    let mixChannel = mixData[channel]
                    let micChannel = micData[channel]
                    let clickChannel = clickData[channel]
                    
                    for frame in 0..<Int(framesToRead) {
                        var sample: Float = 0.0
                        
                        // Add mic audio if available
                        if frame < Int(micBuffer.frameLength) {
                            sample += micChannel[frame]
                        }
                        
                        // Add click audio if available (with volume adjustment)
                        if frame < Int(clickBuffer.frameLength) {
                            sample += clickChannel[frame] * 0.7 // Reduce click volume slightly
                        }
                        
                        // Simple limiting to prevent clipping
                        mixChannel[frame] = max(-1.0, min(1.0, sample))
                    }
                }
                
                // Write mixed buffer
                try outputFile.write(from: mixBuffer)
                framesProcessed += framesToRead
            }
            
            print("[AudioMixer] ✅ Mixed audio: mic + clicks → \(outputPath)")
            return outputPath
            
        } catch {
            print("[AudioMixer] ❌ Error mixing audio: \(error)")
            return nil
        }
    }
}
