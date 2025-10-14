import AVFoundation
import AudioToolbox
import os.log

/// Core Audio-based metronome with sample-accurate timing and real-time mixing
/// Uses Remote I/O Audio Unit with unified render callback for perfect sync between mic and clicks
class CoreAudioMetronome {
    
    // MARK: - Properties
    
    /// The Remote I/O Audio Unit (handles both input and output)
    private var ioUnit: AudioUnit?
    
    /// Current sample rate (matches hardware)
    private var sampleRate: Double = 44100.0
    
    /// Audio format for processing (32-bit float, non-interleaved)
    private var audioFormat: AudioStreamBasicDescription!
    
    /// Current BPM (beats per minute)
    private var bpm: Double = 120.0
    
    /// Whether metronome is currently playing
    private var isPlaying: Bool = false
    
    /// Whether currently recording
    private var isRecording: Bool = false
    
    /// Sample time when recording started
    private var recordingStartSample: Float64 = 0
    
    /// Circular buffer for passing audio from render callback to file writer
    private var audioBuffer: CircularBuffer<Float>?
    
    /// File writer background queue
    private let fileWriterQueue = DispatchQueue(
        label: "com.grooveshed.filewriter",
        qos: .userInitiated
    )
    
    /// Logger for debugging
    private let logger = OSLog(subsystem: "com.grooveshed.metronome", category: "CoreAudio")
    
    /// Click sound buffer (pre-loaded in memory)
    private var clickBuffer: [Float] = []
    private var clickBufferLength: Int = 0
    
    /// Current playback position in the metronome pattern (in samples)
    private var currentSamplePosition: Float64 = 0
    
    /// Number of samples between clicks
    private var samplesPerBeat: Float64 = 0
    
    // MARK: - Initialization
    
    init() throws {
        // Get hardware sample rate
        self.sampleRate = getHardwareSampleRate()
        
        // Create audio format
        self.audioFormat = AudioStreamBasicDescription.floatFormat(
            sampleRate: sampleRate,
            channels: 2  // Stereo
        )
        
        os_log("CoreAudioMetronome initialized at %f Hz", log: logger, type: .info, sampleRate)
        
        // Calculate samples per beat
        updateSamplesPerBeat()
    }
    
    deinit {
        try? shutdown()
    }
    
    // MARK: - Public API
    
    /// Starts the metronome (clicks only, no recording)
    func play() throws {
        guard !isPlaying else { return }
        
        try setupAudioSession()
        try createAudioUnit()
        try startAudioUnit()
        
        isPlaying = true
        currentSamplePosition = 0
        
        os_log("Metronome started", log: logger, type: .info)
    }
    
    /// Stops the metronome
    func pause() throws {
        guard isPlaying else { return }
        
        try stopAudioUnit()
        isPlaying = false
        
        os_log("Metronome paused", log: logger, type: .info)
    }
    
    /// Updates the tempo
    func setBPM(_ newBPM: Double) {
        self.bpm = newBPM
        updateSamplesPerBeat()
        os_log("BPM set to %f", log: logger, type: .info, newBPM)
    }
    
    /// Starts recording (starts metronome if not already playing)
    func startRecording() throws {
        guard !isRecording else { return }
        
        // Ensure metronome is playing
        if !isPlaying {
            try play()
        }
        
        // Allocate circular buffer (5 seconds of stereo audio)
        let bufferSize = Int(sampleRate * 5.0) * 2  // 5 seconds, 2 channels
        audioBuffer = CircularBuffer<Float>(capacity: bufferSize)
        
        isRecording = true
        recordingStartSample = currentSamplePosition
        
        os_log("Recording started at sample %f", log: logger, type: .info, recordingStartSample)
    }
    
    /// Stops recording and returns the file path
    func stopRecording() throws -> String {
        guard isRecording else { throw CoreAudioError.invalidState("Not recording") }
        
        isRecording = false
        
        // TODO: Flush remaining audio from circular buffer
        // TODO: Finalize audio file
        // TODO: Return file path
        
        os_log("Recording stopped", log: logger, type: .info)
        
        return "TODO_FILE_PATH"
    }
    
    /// Loads the click sound into memory
    func loadClickSound(from url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw CoreAudioError.configurationFailed("Failed to create audio buffer")
        }
        
        try audioFile.read(into: buffer)
        
        // Convert to our internal format (Float array)
        guard let floatChannelData = buffer.floatChannelData else {
            throw CoreAudioError.configurationFailed("Failed to get float channel data")
        }
        
        clickBufferLength = Int(buffer.frameLength)
        clickBuffer = Array(UnsafeBufferPointer(
            start: floatChannelData[0],
            count: clickBufferLength
        ))
        
        os_log("Click sound loaded: %d samples", log: logger, type: .info, clickBufferLength)
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,  // Low latency mode
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        
        // Request low latency (iOS will get as close as possible)
        try session.setPreferredIOBufferDuration(0.005)  // 5ms = ~256 samples at 48kHz
        
        try session.setActive(true)
        
        // Update sample rate to match hardware
        self.sampleRate = session.sampleRate
        self.audioFormat = AudioStreamBasicDescription.floatFormat(
            sampleRate: sampleRate,
            channels: 2
        )
        updateSamplesPerBeat()
        
        os_log("Audio session configured: %f Hz, buffer: %f s",
               log: logger, type: .info,
               session.sampleRate,
               session.ioBufferDuration)
    }
    
    // MARK: - Audio Unit Setup
    
    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CoreAudioError.configurationFailed("Failed to find Remote I/O component")
        }
        
        var unit: AudioUnit?
        try checkStatus(
            AudioComponentInstanceNew(component, &unit),
            "Failed to create Audio Unit instance"
        )
        
        guard let audioUnit = unit else {
            throw CoreAudioError.configurationFailed("Audio Unit is nil")
        }
        
        self.ioUnit = audioUnit
        
        // Enable input (mic)
        var enableInput: UInt32 = 1
        try checkStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,  // Input bus
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to enable input"
        )
        
        // Enable output (speaker)
        var enableOutput: UInt32 = 1
        try checkStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,  // Output bus
                &enableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to enable output"
        )
        
        // Set format for output bus input scope (what we provide to output)
        var format = audioFormat!
        try checkStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,  // Output bus
                &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "Failed to set output format"
        )
        
        // Set format for input bus output scope (what we receive from mic)
        try checkStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,  // Input bus
                &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "Failed to set input format"
        )
        
        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: coreAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        try checkStatus(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,  // Output bus
                &callbackStruct,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "Failed to set render callback"
        )
        
        // Initialize the audio unit
        try checkStatus(
            AudioUnitInitialize(audioUnit),
            "Failed to initialize Audio Unit"
        )
        
        os_log("Audio Unit created and configured", log: logger, type: .info)
    }
    
    // MARK: - Audio Unit Control
    
    private func startAudioUnit() throws {
        guard let audioUnit = ioUnit else {
            throw CoreAudioError.invalidState("Audio Unit not created")
        }
        
        try checkStatus(
            AudioOutputUnitStart(audioUnit),
            "Failed to start Audio Unit"
        )
    }
    
    private func stopAudioUnit() throws {
        guard let audioUnit = ioUnit else { return }
        
        try checkStatus(
            AudioOutputUnitStop(audioUnit),
            "Failed to stop Audio Unit"
        )
    }
    
    private func shutdown() throws {
        if isPlaying {
            try stopAudioUnit()
        }
        
        if let audioUnit = ioUnit {
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.ioUnit = nil
        }
        
        try? AVAudioSession.sharedInstance().setActive(false)
        
        os_log("CoreAudioMetronome shut down", log: logger, type: .info)
    }
    
    // MARK: - Timing Helpers
    
    private func updateSamplesPerBeat() {
        samplesPerBeat = (sampleRate * 60.0) / bpm
    }
    
    // MARK: - Render Callback (The Heart of Everything)
    
    /// This callback runs on the real-time audio thread
    /// CRITICAL: Must be fast, deterministic, and lock-free
    /// All mic input processing, click generation, and mixing happens here
    private func renderCallback(
        ioData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32,
        timeStamp: UnsafePointer<AudioTimeStamp>
    ) {
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
        
        // Get output buffers (assuming stereo)
        guard bufferList.count >= 2 else { return }
        
        let leftChannel = bufferList[0].mData?.assumingMemoryBound(to: Float.self)
        let rightChannel = bufferList[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard let left = leftChannel, let right = rightChannel else { return }
        
        // Generate clicks if playing
        if isPlaying && !clickBuffer.isEmpty {
            generateClicks(
                leftBuffer: left,
                rightBuffer: right,
                frameCount: Int(frameCount)
            )
        } else {
            // Silence if not playing
            memset(left, 0, Int(frameCount) * MemoryLayout<Float>.size)
            memset(right, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
        
        // Update position
        currentSamplePosition += Float64(frameCount)
    }
    
    /// Generates click sounds in the output buffers
    /// Called from render callback - must be real-time safe!
    private func generateClicks(
        leftBuffer: UnsafeMutablePointer<Float>,
        rightBuffer: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        // Clear buffers first
        memset(leftBuffer, 0, frameCount * MemoryLayout<Float>.size)
        memset(rightBuffer, 0, frameCount * MemoryLayout<Float>.size)
        
        var samplePos = currentSamplePosition
        
        for frameIndex in 0..<frameCount {
            // Calculate position within the beat cycle
            let beatPosition = samplePos.truncatingRemainder(dividingBy: samplesPerBeat)
            
            // If we're at the start of a beat (within click buffer length)
            if beatPosition < Float64(clickBufferLength) {
                let clickIndex = Int(beatPosition)
                if clickIndex < clickBuffer.count {
                    let sample = clickBuffer[clickIndex]
                    leftBuffer[frameIndex] = sample
                    rightBuffer[frameIndex] = sample
                }
            }
            
            samplePos += 1
        }
    }
}

    // MARK: - Internal Render Method (Accessed by C callback)
    
    /// Internal render method called from C callback
    /// Must be accessible to the C callback function
    fileprivate func internalRenderCallback(
        ioData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32,
        timeStamp: UnsafePointer<AudioTimeStamp>
    ) {
        renderCallback(ioData: ioData, frameCount: frameCount, timeStamp: timeStamp)
    }
}

// MARK: - C Callback Bridge (Must be at file scope)

/// C callback function that bridges to Swift method
/// This must be a file-scope function (not inside the class) to work with Core Audio
private func coreAudioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    
    guard let ioData = ioData else { return kAudioUnitErr_InvalidParameter }
    
    // Get reference to our metronome instance
    let metronome = Unmanaged<CoreAudioMetronome>.fromOpaque(inRefCon).takeUnretainedValue()
    
    // Call the Swift render method
    metronome.internalRenderCallback(
        ioData: ioData,
        frameCount: inNumberFrames,
        timeStamp: inTimeStamp
    )
    
    return noErr
}
