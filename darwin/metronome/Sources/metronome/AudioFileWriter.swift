import AVFoundation
import AudioToolbox
import os.log

/// Writes audio samples from a circular buffer to disk using ExtAudioFile
/// Runs on a background thread to avoid blocking the real-time audio thread
class AudioFileWriter {
    
    // MARK: - Properties
    
    /// The circular buffer to read from
    private let circularBuffer: CircularBuffer<Float>
    
    /// Output file path
    private let filePath: String
    
    /// Audio format for the file
    private let format: AudioStreamBasicDescription
    
    /// ExtAudioFile reference for writing
    private var extAudioFile: ExtAudioFileRef?
    
    /// Whether the writer is currently active
    private var isWriting: Bool = false
    
    /// Background queue for file writing
    private let writerQueue: DispatchQueue
    
    /// Temporary buffer for reading from circular buffer
    private var tempBuffer: [Float]
    
    /// Logger
    private let logger = OSLog(subsystem: "com.grooveshed.metronome", category: "FileWriter")
    
    // MARK: - Initialization
    
    init(
        circularBuffer: CircularBuffer<Float>,
        filePath: String,
        format: AudioStreamBasicDescription,
        writerQueue: DispatchQueue
    ) throws {
        self.circularBuffer = circularBuffer
        self.filePath = filePath
        self.format = format
        self.writerQueue = writerQueue
        
        // Allocate temp buffer (1024 frames = 2048 samples for stereo)
        self.tempBuffer = [Float](repeating: 0, count: 2048)
        
        // Create the audio file
        try createAudioFile()
        
        os_log("AudioFileWriter initialized for %@", log: logger, type: .info, filePath)
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    /// Starts the file writer thread
    func start() {
        guard !isWriting else { return }
        
        isWriting = true
        
        // Start background thread that continuously reads from buffer and writes to file
        writerQueue.async { [weak self] in
            self?.writeLoop()
        }
        
        os_log("AudioFileWriter started", log: logger, type: .info)
    }
    
    /// Stops the file writer and flushes remaining data
    func stop() {
        guard isWriting else { return }
        
        isWriting = false
        
        // Wait a bit for any remaining writes
        Thread.sleep(forTimeInterval: 0.1)
        
        // Flush any remaining data in circular buffer
        flushRemainingData()
        
        // Close the file
        closeAudioFile()
        
        os_log("AudioFileWriter stopped", log: logger, type: .info)
    }
    
    // MARK: - File Operations
    
    private func createAudioFile() throws {
        let fileURL = URL(fileURLWithPath: filePath)
        
        os_log("Creating audio file at: %@", log: logger, type: .info, filePath)
        os_log("Format: %f Hz, %d channels, %d bits", log: logger, type: .info, 
               format.mSampleRate, format.mChannelsPerFrame, format.mBitsPerChannel)
        
        // Create directory if needed
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            os_log("Directory created/verified", log: logger, type: .info)
        } catch {
            os_log("Failed to create directory: %@", log: logger, type: .error, error.localizedDescription)
            throw error
        }
        
        // Delete existing file if present
        try? FileManager.default.removeItem(at: fileURL)
        
        // Define output format (same as our internal format)
        var outputFormat = format
        
        os_log("Calling ExtAudioFileCreateWithURL...", log: logger, type: .info)
        
        // Create the ExtAudioFile
        var audioFile: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            fileURL as CFURL,
            kAudioFileCAFType,  // CAF format supports our format perfectly
            &outputFormat,
            nil,  // No channel layout
            AudioFileFlags.eraseFile.rawValue,
            &audioFile
        )
        
        os_log("ExtAudioFileCreateWithURL returned status: %d", log: logger, type: .info, status)
        
        guard status == noErr, let file = audioFile else {
            os_log("Failed to create ExtAudioFile, status: %d", log: logger, type: .error, status)
            throw CoreAudioError.osStatus(status, "Failed to create audio file")
        }
        
        self.extAudioFile = file
        
        os_log("Audio file created successfully: %@", log: logger, type: .info, filePath)
    }
    
    private func closeAudioFile() {
        guard let file = extAudioFile else { return }
        
        ExtAudioFileDispose(file)
        self.extAudioFile = nil
        
        os_log("Audio file closed", log: logger, type: .info)
    }
    
    // MARK: - Write Loop
    
    /// Continuously reads from circular buffer and writes to file
    /// Runs on background thread
    private func writeLoop() {
        while isWriting {
            // Read a chunk from circular buffer
            let samplesToRead = min(tempBuffer.count, circularBuffer.availableToRead())
            
            if samplesToRead > 0 {
                // Read samples from circular buffer
                let readCount = circularBuffer.read(into: &tempBuffer, maxCount: samplesToRead)
                
                if readCount > 0 {
                    // Write to file
                    writeToFile(samples: tempBuffer, count: readCount)
                }
            } else {
                // Buffer empty, sleep briefly to avoid busy waiting
                usleep(1000)  // 1ms
            }
        }
    }
    
    private func flushRemainingData() {
        // Read everything remaining in the buffer
        while circularBuffer.availableToRead() > 0 {
            let samplesToRead = min(tempBuffer.count, circularBuffer.availableToRead())
            
            let readCount = circularBuffer.read(into: &tempBuffer, maxCount: samplesToRead)
            
            if readCount > 0 {
                writeToFile(samples: tempBuffer, count: readCount)
            }
        }
        
        os_log("Flushed remaining data to file", log: logger, type: .info)
    }
    
    private func writeToFile(samples: [Float], count: Int) {
        guard let file = extAudioFile else { return }
        
        // Our samples are interleaved stereo: L, R, L, R, L, R...
        // So sample count / 2 = frame count
        let frameCount = count / 2
        
        guard frameCount > 0 else { return }
        
        // Allocate temporary deinterleaved buffers
        var leftChannel = [Float](repeating: 0, count: frameCount)
        var rightChannel = [Float](repeating: 0, count: frameCount)
        
        // Deinterleave samples
        for i in 0..<frameCount {
            leftChannel[i] = samples[i * 2]
            rightChannel[i] = samples[i * 2 + 1]
        }
        
        // Create AudioBufferList
        let bufferListSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        
        let bufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // Set buffer pointers
        leftChannel.withUnsafeMutableBufferPointer { leftPtr in
            rightChannel.withUnsafeMutableBufferPointer { rightPtr in
                buffers.count = 2
                buffers[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(leftPtr.baseAddress)
                )
                buffers[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(rightPtr.baseAddress)
                )
                
                // Write to file
                let status = ExtAudioFileWrite(
                    file,
                    UInt32(frameCount),
                    bufferList
                )
                
                if status != noErr {
                    os_log("Failed to write audio: %d", log: logger, type: .error, status)
                }
            }
        }
    }
}
