import AVFoundation

class Metronome: MetronomeInterface {
    private var eventTick: EventTickHandler?
    private var audioPlayerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    private var audioEngine: AVAudioEngine = AVAudioEngine()
    private var mixerNode: AVAudioMixerNode
    private var audioBuffer: AVAudioPCMBuffer?
    //
    private var inputNode: AVAudioInputNode?
    private var micVolumeNode: AVAudioMixerNode?
    private var audioFileRecording: AVAudioFile?
    private var isRecording = false
    private var recordingStartTime: AVAudioTime?
    private var clickTimeStamps: [Double] = []
    //
    private var audioFileMain: AVAudioFile
    private var audioFileAccented: AVAudioFile
    public var audioBpm: Int = 120
    public var audioVolume: Float = 0.5
    public var audioTimeSignature: Int = 0

    private var sampleRate: Int = 44100
    private var timer: DispatchSourceTimer?
    private var startTime: AVAudioTime?
    /// Initialize the metronome with the main and accented audio files.
    init(mainFileBytes: Data, accentedFileBytes: Data, bpm: Int, timeSignature: Int = 0, volume: Float, sampleRate: Int) {
        self.sampleRate = sampleRate
        audioTimeSignature = timeSignature
        audioBpm = bpm
        audioVolume = volume
        // Initialize audio files
        audioFileMain = try! AVAudioFile(fromData: mainFileBytes)
        if accentedFileBytes.isEmpty {
            audioFileAccented = audioFileMain
        }else{
            audioFileAccented = try! AVAudioFile(fromData: accentedFileBytes)
        }
        var hardwareSampleRate: Double = 48000.0
#if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            
            try audioSession.setActive(true)
            hardwareSampleRate = audioSession.sampleRate
        } catch {
            print("Failed to set audio session category: \(error)")
        }
#endif
        // Initialize audio engine and player node
        audioEngine.attach(audioPlayerNode)
        // Set up mixer node
        mixerNode = audioEngine.mainMixerNode
        mixerNode.outputVolume = audioVolume
        // Set up microphone input BEFORE starting engine
        inputNode = audioEngine.inputNode
        micVolumeNode = AVAudioMixerNode()
        audioEngine.attach(micVolumeNode!)
           
        // Connect all nodes with nil format - let engine figure it out
        audioEngine.connect(audioPlayerNode, to: mixerNode, format: audioFileMain.processingFormat)
        // audioEngine.connect(inputNode!, to: micVolumeNode!, format: nil)
        // audioEngine.connect(micVolumeNode!, to: mixerNode, format: nil)
        
        // micVolumeNode?.outputVolume = 0.0
        
        audioEngine.prepare()
        // Start the audio engine
        if !self.audioEngine.isRunning {
            do {
                try self.audioEngine.start()
                print("Start the audio engine")
            } catch {
                print("Failed to start audio engine: \(error.localizedDescription)")
            }
        }
        // Set volume
        setVolume(volume:volume)
#if os(iOS)
        setupNotifications()
#endif
    }
    /// Enable microphone input and connect it to the mixer
    /// This must be called before recording to capture mic audio
    public func enableMicrophone() throws {
        guard inputNode != nil && micVolumeNode != nil else {
            throw NSError(domain: "Metronome", code: -1, userInfo: [NSLocalizedDescriptionKey: "Microphone input not initialized"])
        }
        
#if os(iOS)
        // Check microphone permission status
        let permissionStatus = AVAudioSession.sharedInstance().recordPermission
        print("[Metronome] Microphone permission status: \(permissionStatus.rawValue)")
        
        if permissionStatus == .denied {
            print("[Metronome] Microphone permission DENIED")
            throw NSError(domain: "Metronome", code: -2, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        } else if permissionStatus == .undetermined {
            print("[Metronome] Microphone permission UNDETERMINED - need to request")
            throw NSError(domain: "Metronome", code: -3, userInfo: [NSLocalizedDescriptionKey: "Microphone permission not requested yet"])
        }
#endif
        
        print("[Metronome] Microphone ready for recording")
    }
    
    public func setRecordedClickVolume(_ volume: Float) {
        // Legacy implementation doesn't support separate click volume for recording
        // This is a no-op for legacy mode
        print("[Metronome] setRecordedClickVolume(\(volume)) - no effect in legacy mode")
    }
    
    public func setDirectMonitoring(enabled: Bool) {
        // For legacy implementation, direct monitoring is controlled by connecting/disconnecting
        // the mic input node to the mixer. Currently mic is always disconnected (lines 70-73),
        // so this is a no-op for now. When/if we enable monitoring in legacy mode,
        // we would connect/disconnect the nodes here.
        print("[Metronome] Direct monitoring \(enabled ? "enabled" : "disabled") (legacy mode - no effect)")
    }
    
    /// Start recording audio from the mic (mic only, no clicks)
    public func startRecording(path: String) -> Bool {
        guard !isRecording else {
            print("[Metronome] Already recording")
            return false
        }
        
        guard let inputNode = inputNode else {
            print("[Metronome] Input node not available")
            return false
        }
        
        do {
            let url = URL(fileURLWithPath: path)
            
            // Use the input node's actual hardware format instead of hardcoded values
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Create recording format matching input hardware
            guard let recordingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,  // Use hardware sample rate
                channels: inputFormat.channelCount,   // Use hardware channel count
                interleaved: false
            ) else {
                print("[Metronome] Failed to create recording format")
                return false
            }
            
            print("[Metronome] Starting recording:")
            print(" Input HW format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
            print(" Recording format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount) channels")
            print(" Path: \(path)")
            
            // Create the audio file for recording
            audioFileRecording = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)
            
            // Capture the start time for click timing
            recordingStartTime = audioPlayerNode.lastRenderTime
            clickTimeStamps = []
            print("[Metronome] Recording start time captured")
            
            // Install tap - format will match now
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
                guard let self = self, let file = self.audioFileRecording else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    print("[Metronome] Error writing audio buffer: \(error)")
                }
            }
            
            isRecording = true
            print("[Metronome] Recording started (mic only, no monitoring)")
            return true
        } catch {
            print("[Metronome] Failed to start recording: \(error)")
            return false
        }
    }
    /// Stop recording and finalize the audio file
    public func stopRecording() -> [String: Any]? {
        guard isRecording else {
            print("[Metronome] Not currently recording")
            return nil
        }
        
        inputNode?.removeTap(onBus: 0)
        
        let filePath = audioFileRecording?.url.path
        
        audioFileRecording = nil
        isRecording = false
        recordingStartTime = nil
        
        let result: [String: Any] = [
            "path": filePath ?? "",
            "timings": clickTimeStamps,
            "bpm": audioBpm,
            "timeSignature": audioTimeSignature
        ]
        
        clickTimeStamps = []
        
        print("[Metronome] Recording stopped with \(result["timings"] as? [Double] ?? []).count clicks")
        return result
    }
    
    /// Start the metronome.
    func play() throws {
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        audioBuffer = generateBuffer()
    }

    /// Pause the metronome.
    func pause() throws {
        stop()
    }
    
    /// Stop the metronome.
    func stop() {
        if audioBuffer != nil {
            audioBuffer?.frameLength = 0
            self.audioPlayerNode.scheduleBuffer(audioBuffer!, at: nil, options: .interruptsAtLoop, completionHandler: nil)
        }
        audioPlayerNode.stop()
        stopBeatTimer()
    }
    
    /// Set the BPM of the metronome.
    func setBPM(bpm: Int) {
        if audioBpm != bpm {
            audioBpm = bpm
            if isPlaying {
                try? pause()
                try? play()
            }
        }
    }
    ///Set the TimeSignature of the metronome.
    func setTimeSignature(timeSignature: Int) {
        if audioTimeSignature != timeSignature {
            audioTimeSignature = timeSignature
            if isPlaying {
                try? pause()
                try? play()
            }
        }
    }
    
    func setAudioFile(mainFileBytes: Data, accentedFileBytes: Data) {
        if !mainFileBytes.isEmpty {
            audioFileMain = try! AVAudioFile(fromData: mainFileBytes)
        }
        if !accentedFileBytes.isEmpty {
            audioFileAccented = try! AVAudioFile(fromData: accentedFileBytes)
        }
        if !mainFileBytes.isEmpty || !accentedFileBytes.isEmpty {
            if isPlaying {
                try? pause()
                try? play()
            }
        }
    }
    
    var getTimeSignature: Int {
        return audioTimeSignature
    }
    
    var getVolume: Float {
        return audioVolume
    }
    
    func setVolume(volume: Float) {
        audioVolume = volume
        mixerNode.outputVolume = volume
    }
    
    var isPlaying: Bool {
        return audioPlayerNode.isPlaying
    }
    
    /// Enable the tick callback.
    public func enableTickCallback(_eventTickSink: EventTickHandler) {
        self.eventTick = _eventTickSink
    }
#if os(iOS)
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
            using: handleInterruption
        )
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
            using: handleRouteChange
        )
    }

    private func handleInterruption(_ notification: Notification) {
        if isPlaying {
            try? pause()
        }
    }
    private func handleRouteChange(_ notification: Notification) {
        // let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        // let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue ?? 0)
        // print("Audio route changed. Reason: \(String(describing: reason))")
        let wasPlaying = isPlaying
        if wasPlaying {
            try? pause()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                // let session = AVAudioSession.sharedInstance()
                // let outputs = session.currentRoute.outputs
                // print("Current audio outputs: \(outputs.map { $0.portType.rawValue })")
                self.audioPlayerNode.stop()
                self.audioEngine.stop()
                self.audioEngine.reset()

                do {
                    try self.audioEngine.start()
                } catch {
                    print("Audio engine failed to restart: \(error.localizedDescription)")
                }

                if wasPlaying {
                    try? self.play()
                }
            } catch {
                print("Failed to handle audio route change: \(error.localizedDescription)")
            }
        }
    }
#endif
    /// Generate buffer with accents based on time signature
    private func generateBuffer() -> AVAudioPCMBuffer {
        audioFileMain.framePosition = 0
        audioFileAccented.framePosition = 0

        let beatLength = AVAudioFrameCount(Double(self.sampleRate) * 60 / Double(self.audioBpm))
        // let beatLength = AVAudioFrameCount(audioFileMain.processingFormat.sampleRate * 60 / Double(self.audioBpm))
        let bufferMainClick = AVAudioPCMBuffer(pcmFormat: audioFileMain.processingFormat, frameCapacity: beatLength)!
        try! audioFileMain.read(into: bufferMainClick)
        bufferMainClick.frameLength = beatLength

        let bufferBar: AVAudioPCMBuffer
        if self.audioTimeSignature < 2 {
            bufferBar = AVAudioPCMBuffer(pcmFormat: audioFileMain.processingFormat, frameCapacity: beatLength)!
            bufferBar.frameLength = beatLength

            let channelCount = Int(audioFileMain.processingFormat.channelCount)
            let mainClickArray = Array(UnsafeBufferPointer(start: bufferMainClick.floatChannelData![0], count: channelCount * Int(beatLength)))

            bufferBar.floatChannelData!.pointee.update(from: mainClickArray, count: channelCount * Int(bufferBar.frameLength))
        } else {
            let bufferAccentedClick = AVAudioPCMBuffer(pcmFormat: audioFileAccented.processingFormat, frameCapacity: beatLength)!
            try! audioFileAccented.read(into: bufferAccentedClick)
            bufferAccentedClick.frameLength = beatLength

            bufferBar = AVAudioPCMBuffer(pcmFormat: audioFileMain.processingFormat, frameCapacity: beatLength * AVAudioFrameCount(self.audioTimeSignature))!
            bufferBar.frameLength = beatLength * AVAudioFrameCount(self.audioTimeSignature)

            let channelCount = Int(audioFileMain.processingFormat.channelCount)
            let mainClickArray = Array(UnsafeBufferPointer(start: bufferMainClick.floatChannelData![0], count: channelCount * Int(beatLength)))
            let accentedClickArray = Array(UnsafeBufferPointer(start: bufferAccentedClick.floatChannelData![0], count: channelCount * Int(beatLength)))

            var barArray = [Float]()
            for i in 0..<self.audioTimeSignature {
                if i == 0 {
                    barArray.append(contentsOf: accentedClickArray)
                } else {
                    barArray.append(contentsOf: mainClickArray)
                }
            }

            bufferBar.floatChannelData!.pointee.update(from: barArray, count: channelCount * Int(bufferBar.frameLength))
        }
        //
        self.startTime = self.audioPlayerNode.lastRenderTime
        self.audioPlayerNode.scheduleBuffer(bufferBar, at: nil, options: .loops,completionHandler: nil)
        self.audioPlayerNode.play()
        startBeatTimer()
        return bufferBar
    }
    
    func stopBeatTimer() {
        if timer != nil {
            timer?.cancel()
            timer = nil
        }
    }
    
    private func startBeatTimer() {
        if self.eventTick == nil {return}
        let beatDuration = 60.0 / Double(audioBpm)
        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer?.schedule(deadline: .now(), repeating: beatDuration, leeway: .milliseconds(10))
        timer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let startTime = self.startTime,
                  let currentTime = self.audioPlayerNode.lastRenderTime,
                  let elapsedTime = self.getElapsedTime(from: startTime, to: currentTime) else { return }

            let currentBeat = Int(elapsedTime / beatDuration)
            let currentTick = (self.audioTimeSignature > 1) ? (currentBeat % self.audioTimeSignature) : 0
            
            if self.isRecording, let recordingStart = self.recordingStartTime {
                let recordingElapsed = self.getElapsedTime(from: recordingStart, to: currentTime) ?? 0
                self.clickTimeStamps.append(recordingElapsed)
            }

            DispatchQueue.main.async {
                self.eventTick?.send(res: currentTick)
            }
        }

        timer?.resume()
    }
    
    private func getElapsedTime(from startTime: AVAudioTime, to currentTime: AVAudioTime) -> TimeInterval? {
//        guard let sampleRate = startTime.sampleRate as Double? else { return nil }
        let elapsedSamples = currentTime.sampleTime - startTime.sampleTime
        return Double(elapsedSamples) / Double(self.sampleRate)
    }

    func destroy() {
        audioPlayerNode.reset()
        audioPlayerNode.stop()
        audioEngine.reset()
        audioEngine.stop()
        audioEngine.detach(audioPlayerNode)
        audioBuffer = nil
        stopBeatTimer()
    }
}
extension AVAudioFile {
    convenience init(fromData data: Data) throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try data.write(to: tempURL)
            //print("Temporary file created at: \(tempURL)")
        } catch {
            //print("Failed to write data to temporary file: \(error.localizedDescription)")
            throw error
        }
        do {
            try self.init(forReading: tempURL)
        } catch {
            //print("Failed to initialize AVAudioFile: \(error.localizedDescription)")
            throw error
        }
    }
}
