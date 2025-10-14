import AVFoundation

class ClickTrackGenerator {
    
    /// Generate a click track audio file from timing data
    /// - Parameters:
    ///   - clickTimestamps: Array of Double values representing click times in seconds
    ///   - bpm: Tempo in beats per minute
    ///   - timeSignature: Beats per measure
    ///   - mainClickData: Audio data for off-beat clicks
    ///   - accentedClickData: Audio data for downbeat clicks
    ///   - outputPath: File path where the click track should be saved
    /// - Returns: The output path if successful, nil otherwise
    static func generateClickTrack(
        clickTimestamps: [Double],
        bpm: Int,
        timeSignature: Int,
        mainClickData: Data,
        accentedClickData: Data,
        outputPath: String
    ) -> String? {
        guard !clickTimestamps.isEmpty else {
            print("[ClickTrackGenerator] No timestamps provided")
            return nil
        }
        
        do {
            // Load click audio files
            let mainClickFile = try AVAudioFile(fromData: mainClickData)
            let accentedClickFile = try AVAudioFile(fromData: accentedClickData)
            
            // Calculate total duration needed (last click + 2 seconds buffer)
            let totalDuration = clickTimestamps.last! + 2.0
            let sampleRate = mainClickFile.processingFormat.sampleRate
            let channelCount = mainClickFile.processingFormat.channelCount
            let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)
            
            // Create output format and file
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                print("[ClickTrackGenerator] Failed to create output format")
                return nil
            }
            
            let outputURL = URL(fileURLWithPath: outputPath)
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            
            // Create a buffer for the entire output
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: totalFrames
            ) else {
                print("[ClickTrackGenerator] Failed to create output buffer")
                return nil
            }
            outputBuffer.frameLength = totalFrames
            
            // Clear the output buffer
            let channelData = outputBuffer.floatChannelData!
            for channel in 0..<Int(channelCount) {
                memset(channelData[channel], 0, Int(totalFrames) * MemoryLayout<Float>.size)
            }
            
            // Read click samples into buffers
            let mainClickBuffer = AVAudioPCMBuffer(
                pcmFormat: mainClickFile.processingFormat,
                frameCapacity: AVAudioFrameCount(mainClickFile.length)
            )!
            try mainClickFile.read(into: mainClickBuffer)
            mainClickBuffer.frameLength = AVAudioFrameCount(mainClickFile.length)
            
            let accentedClickBuffer = AVAudioPCMBuffer(
                pcmFormat: accentedClickFile.processingFormat,
                frameCapacity: AVAudioFrameCount(accentedClickFile.length)
            )!
            try accentedClickFile.read(into: accentedClickBuffer)
            accentedClickBuffer.frameLength = AVAudioFrameCount(accentedClickFile.length)
            
            // Mix clicks into the output buffer
            for (index, timestamp) in clickTimestamps.enumerated() {
                let isDownbeat = (timeSignature > 1) && (index % timeSignature == 0)
                let clickBuffer = isDownbeat ? accentedClickBuffer : mainClickBuffer
                let clickLength = Int(clickBuffer.frameLength)
                let startFrame = Int(timestamp * sampleRate)
                
                // Ensure we don't write past the end of the buffer
                guard startFrame + clickLength <= Int(totalFrames) else {
                    print("[ClickTrackGenerator] Click at \(timestamp)s would exceed buffer, skipping")
                    continue
                }
                
                // Mix the click into the output buffer
                let clickData = clickBuffer.floatChannelData!
                for channel in 0..<Int(channelCount) {
                    let outputChannel = channelData[channel]
                    let clickChannel = clickData[channel]
                    
                    for frame in 0..<clickLength {
                        outputChannel[startFrame + frame] += clickChannel[frame]
                    }
                }
            }
            
            // Write the output buffer to file
            try outputFile.write(from: outputBuffer)
            
            print("[ClickTrackGenerator] ✅ Generated click track: \(clickTimestamps.count) clicks, duration: \(totalDuration)s")
            return outputPath
            
        } catch {
            print("[ClickTrackGenerator] ❌ Error generating click track: \(error)")
            return nil
        }
    }
}
