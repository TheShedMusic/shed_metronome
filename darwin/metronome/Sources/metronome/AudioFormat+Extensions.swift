import AVFoundation
import AudioToolbox

/// Extensions for working with Core Audio formats and stream descriptions
extension AudioStreamBasicDescription {
    /// Creates a non-interleaved Float32 PCM format at the specified sample rate
    static func floatFormat(sampleRate: Double, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
    
    /// Returns a human-readable description of the format
    var debugDescription: String {
        return """
        AudioStreamBasicDescription:
          Sample Rate: \(mSampleRate) Hz
          Format: \(formatIDString)
          Channels: \(mChannelsPerFrame)
          Bits per Channel: \(mBitsPerChannel)
          Bytes per Frame: \(mBytesPerFrame)
          Frames per Packet: \(mFramesPerPacket)
          Flags: \(formatFlagsString)
        """
    }
    
    private var formatIDString: String {
        let id = mFormatID.bigEndian
        let bytes = withUnsafeBytes(of: id) { Array($0) }
        return String(bytes: bytes, encoding: .ascii) ?? "Unknown"
    }
    
    private var formatFlagsString: String {
        var flags: [String] = []
        if mFormatFlags & kAudioFormatFlagIsFloat != 0 { flags.append("Float") }
        if mFormatFlags & kAudioFormatFlagIsBigEndian != 0 { flags.append("BigEndian") }
        if mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 { flags.append("SignedInt") }
        if mFormatFlags & kAudioFormatFlagIsPacked != 0 { flags.append("Packed") }
        if mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 { flags.append("NonInterleaved") }
        return flags.joined(separator: ", ")
    }
}

/// Extensions for working with AudioBufferList
extension AudioBufferList {
    /// Creates a mutable pointer to an AudioBufferList
    static func allocate(numberOfBuffers: Int) -> UnsafeMutableAudioBufferListPointer {
        return AudioBufferList.allocate(maximumBuffers: numberOfBuffers)
    }
    
    /// Helper to access buffers safely
    static func withBuffers<T>(
        _ bufferList: UnsafePointer<AudioBufferList>,
        numberOfBuffers: Int,
        _ body: (UnsafeBufferPointer<AudioBuffer>) -> T
    ) -> T {
        let buffers = UnsafeBufferPointer(
            start: &bufferList.pointee.mBuffers,
            count: numberOfBuffers
        )
        return body(buffers)
    }
}

/// Helper for converting between time representations
struct AudioTimestamp {
    let sampleTime: Float64
    let hostTime: UInt64
    let sampleRate: Double
    
    /// Converts sample time to seconds
    var seconds: TimeInterval {
        return sampleTime / sampleRate
    }
    
    /// Creates a timestamp from Core Audio's AudioTimeStamp
    init(from timestamp: AudioTimeStamp, sampleRate: Double) {
        self.sampleTime = timestamp.mSampleTime
        self.hostTime = timestamp.mHostTime
        self.sampleRate = sampleRate
    }
    
    /// Calculates the time difference between two timestamps in seconds
    func timeSince(_ other: AudioTimestamp) -> TimeInterval {
        return (sampleTime - other.sampleTime) / sampleRate
    }
}

/// Error types for Core Audio operations
enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case invalidState(String)
    case configurationFailed(String)
    
    var description: String {
        switch self {
        case .osStatus(let status, let context):
            return "Core Audio error (\(status)): \(context) - \(statusString(status))"
        case .invalidState(let message):
            return "Invalid state: \(message)"
        case .configurationFailed(let message):
            return "Configuration failed: \(message)"
        }
    }
    
    private func statusString(_ status: OSStatus) -> String {
        switch status {
        case kAudioSessionNotInitialized: return "Audio session not initialized"
        case kAudioSessionAlreadyInitialized: return "Audio session already initialized"
        case kAudioSessionInitializationError: return "Audio session initialization error"
        case kAudioSessionUnsupportedPropertyError: return "Unsupported property"
        case kAudioSessionBadPropertySizeError: return "Bad property size"
        case kAudioSessionNotActiveError: return "Audio session not active"
        case kAudioUnitErr_InvalidProperty: return "Invalid audio unit property"
        case kAudioUnitErr_InvalidParameter: return "Invalid audio unit parameter"
        case kAudioUnitErr_NoConnection: return "No audio unit connection"
        case kAudioUnitErr_FailedInitialization: return "Audio unit initialization failed"
        case kAudioUnitErr_FormatNotSupported: return "Audio format not supported"
        default:
            let fourCC = statusToFourCC(status)
            return fourCC.isEmpty ? "Unknown error" : fourCC
        }
    }
    
    private func statusToFourCC(_ status: OSStatus) -> String {
        let bytes = [
            UInt8((status >> 24) & 0xFF),
            UInt8((status >> 16) & 0xFF),
            UInt8((status >> 8) & 0xFF),
            UInt8(status & 0xFF)
        ]
        
        // Only return if all bytes are printable ASCII
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }
        return ""
    }
}

/// Helper function to check OSStatus and throw on error
@inline(__always)
func checkStatus(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else {
        throw CoreAudioError.osStatus(status, context)
    }
}

/// Helper to get the hardware sample rate
func getHardwareSampleRate() -> Double {
    let session = AVAudioSession.sharedInstance()
    return session.sampleRate
}

/// Helper to get the optimal buffer size for low latency
func getOptimalBufferSize() -> Int {
    let session = AVAudioSession.sharedInstance()
    // AVAudioSession uses seconds, convert to frames
    let bufferDuration = session.ioBufferDuration
    let sampleRate = session.sampleRate
    return Int(bufferDuration * sampleRate)
}
