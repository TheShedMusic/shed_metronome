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
    
    /// Path where recording should be saved
    private var recordingPath: String?
    
    /// Time signature (beats per bar) - 0 or 1 means no accent
    private var timeSignature: Int = 4
    
    /// Accented click buffer
    private var accentedClickBuffer: [Float] = []
    private var accentedClickBufferLength: Int = 0
    
    /// Current beat number (for accent pattern)
    private var currentBeat: Int = 0
    
    /// Last beat number for which we fired a callback (to avoid duplicates)
    private var lastBeatFired: Int = -1
    
    /// Beat callback handler
    private var beatCallback: ((Int) -> Void)?
    
    /// Microphone input volume (0.0 to 1.0)
    private var micVolume: Float = 1.0
    
    /// Buffer for delaying clicks to align with mic latency in recordings
    private var clickDelayBuffer: [Float] = []
    
    /// The measured latency compensation in samples (based on AVAudioSession.inputLatency)
    private var latencyCompensationInSamples: Int = 0
    
    /// Whether direct monitoring is enabled (hearing yourself through headphones)
    private var directMonitoringEnabled: Bool = true
    
    /// Circular buffer for passing audio from render callback to file writer
    private var audioBuffer: CircularBuffer<Float>?
    
    /// File writer instance
    private var fileWriter: AudioFileWriter?
    
    /// File writer background queue
    private let fileWriterQueue = DispatchQueue(
        label: "com.grooveshed.filewriter",
        qos: .userInitiated
    )
    
    /// Input buffer for pulling mic samples (allocated once, reused)
    private var inputBufferList: UnsafeMutableAudioBufferListPointer?
    private var inputBufferListStorage: UnsafeMutablePointer<AudioBufferList>?
    
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
    
    /// Sets the microphone input volume
    func setMicVolume(_ volume: Float) {
        self.micVolume = max(0.0, min(1.0, volume))  // Clamp to 0.0-1.0
        os_log("Mic volume set to %f", log: logger, type: .info, micVolume)
    }
    
    /// Enable or disable direct monitoring (hearing yourself through headphones)
    func setDirectMonitoring(enabled: Bool) {
        self.directMonitoringEnabled = enabled
        os_log("Direct monitoring %@", log: logger, type: .info, enabled ? "enabled" : "disabled")
    }
    
    /// Starts recording (starts metronome if not already playing)
    func startRecording(path: String) throws {
        guard !isRecording else { return }
        
        os_log("startRecording() called with path: %@", log: logger, type: .info, path)
        
        self.recordingPath = path
        
        // Ensure metronome is playing
        if !isPlaying {
            os_log("Metronome not playing, starting it...", log: logger, type: .info)
            try play()
        }
        
        // Set recording flag FIRST so mic input works
        isRecording = true
        recordingStartSample = currentSamplePosition
        
        // Clear the delay buffer to start fresh
        let bufferSize = latencyCompensationInSamples * 2  // Stereo
        clickDelayBuffer = [Float](repeating: 0.0, count: bufferSize)
        
        // Allocate circular buffer (5 seconds of stereo audio)
        let bufferSize = Int(sampleRate * 5.0) * 2  // 5 seconds, 2 channels
        os_log("Allocating circular buffer: %d samples", log: logger, type: .info, bufferSize)
        let buffer = CircularBuffer<Float>(capacity: bufferSize)
        audioBuffer = buffer
        
        // Create file writer
        os_log("Creating AudioFileWriter...", log: logger, type: .info)
        do {
            let writer = try AudioFileWriter(
                circularBuffer: buffer,
                filePath: path,
                format: audioFormat,
                writerQueue: fileWriterQueue
            )
            fileWriter = writer
            
            // Start the file writer thread
            os_log("Starting file writer thread...", log: logger, type: .info)
            writer.start()
            
            os_log("Recording started successfully at sample %f, path: %@", log: logger, type: .info, recordingStartSample, path)
        } catch {
            // If file writer creation fails, revert recording state
            isRecording = false
            audioBuffer = nil
            os_log("Failed to create file writer: %@", log: logger, type: .error, error.localizedDescription)
            throw error
        }
    }
    
    /// Stops recording and returns the file path
    func stopRecording() throws -> String {
        guard isRecording else { throw CoreAudioError.invalidState("Not recording") }
        guard let path = recordingPath else {
            throw CoreAudioError.invalidState("No recording path set")
        }
        
        // Stop recording flag first (stops writing to circular buffer)
        isRecording = false
        
        // Stop the file writer (this will flush remaining data and close the file)
        fileWriter?.stop()
        fileWriter = nil
        
        // Clear circular buffer
        audioBuffer = nil
        
        os_log("Recording stopped and saved to: %@", log: logger, type: .info, path)
        
        return path
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
    
    /// Loads the accented click sound into memory
    func loadAccentedClickSound(from url: URL) throws {
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
        
        accentedClickBufferLength = Int(buffer.frameLength)
        accentedClickBuffer = Array(UnsafeBufferPointer(
            start: floatChannelData[0],
            count: accentedClickBufferLength
        ))
        
        os_log("Accented click sound loaded: %d samples", log: logger, type: .info, accentedClickBufferLength)
    }
    
    /// Sets the time signature (beats per bar)
    func setTimeSignature(_ ts: Int) {
        self.timeSignature = ts
        currentBeat = 0  // Reset beat counter
        os_log("Time signature set to %d", log: logger, type: .info, ts)
    }
    
    /// Sets the beat callback handler
    func setBeatCallback(_ callback: @escaping (Int) -> Void) {
        self.beatCallback = callback
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(
            .playAndRecord,
            mode: .default,  // Low latency mode
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
        
        // Log detailed latency information
        let inputLatency = session.inputLatency
        let outputLatency = session.outputLatency
        let bufferDuration = session.ioBufferDuration
        let totalLatency = inputLatency + outputLatency
        
        os_log("Audio session configured: %f Hz, buffer: %f s",
               log: logger, type: .info,
               session.sampleRate,
               session.ioBufferDuration)
        os_log("Latency - Input: %f s, Output: %f s, Total: %f s (%f samples)",
               log: logger, type: .info,
               inputLatency,
               outputLatency,
               totalLatency,
               totalLatency * sampleRate)
        
        // Calculate latency compensation based on measured input latency
        // We use inputLatency because that's the delay from mic capture to render callback
        self.latencyCompensationInSamples = Int(inputLatency * sampleRate)
        
        // Initialize the delay buffer (stereo, so 2x the sample count)
        let bufferSize = latencyCompensationInSamples * 2
        self.clickDelayBuffer = [Float](repeating: 0.0, count: bufferSize)
        
        os_log("Latency compensation: %d samples (%f ms) based on input latency",
               log: logger, type: .info,
               latencyCompensationInSamples,
               inputLatency * 1000.0)
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
        
        // Allocate input buffer for pulling mic samples
        // We'll reuse this buffer in every render callback for efficiency
        setupInputBuffer()
        
        os_log("Audio Unit created and configured", log: logger, type: .info)
    }
    
    /// Allocates buffer for pulling mic input in render callback
    /// This buffer is reused every render cycle for efficiency
    private func setupInputBuffer() {
        // Mic input is typically mono, but we'll allocate for stereo just in case
        let channelCount = 2
        let bufferSize = 4096  // Max buffer size we might encounter
        
        // Calculate required size for AudioBufferList with multiple buffers
        let bufferListSize = MemoryLayout<AudioBufferList>.size + 
                            (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        
        // Allocate raw memory for the buffer list
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        
        // Bind memory to AudioBufferList type
        let bufferListPointer = storage.bindMemory(
            to: AudioBufferList.self,
            capacity: 1
        )
        
        inputBufferListStorage = bufferListPointer
        
        // Create typed pointer for easier access
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        inputBufferList = bufferList
        
        // Set up each buffer
        bufferList.count = channelCount
        for i in 0..<channelCount {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
            bufferList[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bufferSize * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
        
        os_log("Input buffer allocated for %d channels", log: logger, type: .info, channelCount)
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
        
        // Deallocate input buffers
        if let bufferList = inputBufferList {
            for i in 0..<bufferList.count {
                if let data = bufferList[i].mData {
                    // Deallocate the Float buffer
                    let floatBuffer = data.assumingMemoryBound(to: Float.self)
                    floatBuffer.deallocate()
                }
            }
        }
        if let storage = inputBufferListStorage {
            // Calculate the size we allocated
            let channelCount = 2
            let bufferListSize = MemoryLayout<AudioBufferList>.size + 
                                (channelCount - 1) * MemoryLayout<AudioBuffer>.size
            // Deallocate as raw pointer
            UnsafeMutableRawPointer(storage).deallocate()
        }
        inputBufferList = nil
        inputBufferListStorage = nil
        
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
        let outputBuffers = UnsafeMutableAudioBufferListPointer(ioData)

        // Get output buffers (assuming stereo)
        guard outputBuffers.count >= 2 else { return }

        let left = outputBuffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = outputBuffers[1].mData!.assumingMemoryBound(to: Float.self)

        // Pull mic input samples from the audio unit
        var micLeft: UnsafeMutablePointer<Float>?
        var micRight: UnsafeMutablePointer<Float>?

        if isRecording, let audioUnit = ioUnit, let inputBufferStorage = inputBufferListStorage {
            var flags = AudioUnitRenderActionFlags(rawValue: 0)
            if let bufferList = inputBufferList {
                for i in 0..<bufferList.count {
                    bufferList[i].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
                }
            }
            let status = AudioUnitRender(audioUnit, &flags, timeStamp, 1, frameCount, inputBufferStorage)
            if status == noErr, let bufferList = inputBufferList {
                micLeft = bufferList[0].mData?.assumingMemoryBound(to: Float.self)
                micRight = bufferList.count > 1 ? bufferList[1].mData?.assumingMemoryBound(to: Float.self) : micLeft
            }
        }

        // 1. Generate LIVE clicks into the output buffers. This is what the user hears.
        if isPlaying && !clickBuffer.isEmpty {
            generateClicks(leftBuffer: left, rightBuffer: right, frameCount: Int(frameCount))
        } else {
            // Silence if not playing
            memset(left, 0, Int(frameCount) * MemoryLayout<Float>.size)
            memset(right, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }

        // Process mic and recording logic
        if isRecording, let micL = micLeft, let micR = micRight {
            
            // Append live clicks to delay buffer for latency compensation
            for i in 0..<Int(frameCount) {
                clickDelayBuffer.append(left[i])   // Left channel
                clickDelayBuffer.append(right[i])  // Right channel
            }
            
            // Maintain buffer at the target size (trim excess from the front)
            let targetBufferSize = latencyCompensationInSamples * 2  // Stereo
            if clickDelayBuffer.count > targetBufferSize {
                let excess = clickDelayBuffer.count - targetBufferSize
                clickDelayBuffer.removeFirst(excess)
            }
            
            // Write mixed audio (delayed clicks + mic) to circular buffer for file writing
            if let buffer = audioBuffer {
                for i in 0..<Int(frameCount) {
                    var delayedClickLeft: Float = 0.0
                    var delayedClickRight: Float = 0.0
                    
                    // Read delayed clicks from the buffer (only if buffer is full enough)
                    if clickDelayBuffer.count >= targetBufferSize {
                        let readIndex = i * 2
                        if (readIndex + 1) < clickDelayBuffer.count {
                            delayedClickLeft = clickDelayBuffer[readIndex]
                            delayedClickRight = clickDelayBuffer[readIndex + 1]
                        }
                    }
                    
                    // Mix the DELAYED clicks with the LIVE mic signal for recording
                    let finalRecordLeft = delayedClickLeft + (micL[i] * micVolume)
                    let finalRecordRight = delayedClickRight + (micR[i] * micVolume)
                    
                    _ = buffer.write(finalRecordLeft)
                    _ = buffer.write(finalRecordRight)
                }
            }

            // If direct monitoring enabled, add the LIVE mic to the LIVE clicks for monitoring
            // (No delay here - we want monitoring to feel immediate)
            if directMonitoringEnabled {
                for i in 0..<Int(frameCount) {
                    left[i] += micL[i] * micVolume
                    right[i] += micR[i] * micVolume
                }
            }
        }

        // Update global playback position
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
            
            // Calculate which beat we're on
            let beatNumber = Int(samplePos / samplesPerBeat)
            
            // Fire beat callback on beat transitions (not every sample!)
            if beatNumber != lastBeatFired && beatPosition < 100 { // Within first 100 samples of beat
                lastBeatFired = beatNumber
                let tickInBar = timeSignature > 1 ? (beatNumber % timeSignature) : 0
                
                // Fire callback on main thread (not real-time safe, but necessary)
                if let callback = beatCallback {
                    DispatchQueue.main.async {
                        callback(tickInBar)
                    }
                }
                
                // Update current beat for accent pattern
                currentBeat = tickInBar
            }
            
            // If we're at the start of a beat (within click buffer length)
            if beatPosition < Float64(clickBufferLength) {
                let clickIndex = Int(beatPosition)
                
                // Choose click buffer based on accent pattern
                let useAccent = (timeSignature > 1) && (currentBeat == 0) && !accentedClickBuffer.isEmpty
                let buffer = useAccent ? accentedClickBuffer : clickBuffer
                let bufferLength = useAccent ? accentedClickBufferLength : clickBufferLength
                
                if clickIndex < bufferLength && clickIndex < buffer.count {
                    let sample = buffer[clickIndex]
                    leftBuffer[frameIndex] = sample
                    rightBuffer[frameIndex] = sample
                }
            }
            
            samplePos += 1
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
