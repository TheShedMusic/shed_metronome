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
        
        // Create directory if needed
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Delete existing file if present
        try? FileManager.default.removeItem(at: fileURL)
        
        // Define output format (same as our internal format)
        var outputFormat = format
        
        // Create the ExtAudioFile
        var audioFile: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            fileURL as CFURL,
            kAudioFileCAFFile,  // CAF format supports our format perfectly
            &outputFormat,
            nil,  // No channel layout
            AudioFileFlags.eraseFile.rawValue,
            &audioFile
        )
        
        guard status == noErr, let file = audioFile else {
            throw CoreAudioError.fileOperationFailed("Failed to create audio file: \(status)")
        }
        
        self.extAudioFile = file
        
        os_log("Audio file created: %@", log: logger, type: .info, filePath)
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
            let samplesToRead = min(tempBuffer.count, circularBuffer.availableToRead)
            
            if samplesToRead > 0 {
                // Read samples from circular buffer
                var readCount = 0
                for i in 0..<samplesToRead {
                    if let sample = circularBuffer.read() {
                        tempBuffer[i] = sample
                        readCount += 1
                    } else {
                        break
                    }
                }
                
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
        while circularBuffer.availableToRead > 0 {
            let samplesToRead = min(tempBuffer.count, circularBuffer.availableToRead)
            
            var readCount = 0
            for i in 0..<samplesToRead {
                if let sample = circularBuffer.read() {
                    tempBuffer[i] = sample
                    readCount += 1
                } else {
                    break
                }
            }
            
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
        
        // Create AudioBufferList for ExtAudioFile
        var bufferList = AudioBufferList(
            mNumberBuffers: 2,  // Stereo
            mBuffers: (
                AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                    mData: nil
                ),
                AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                    mData: nil
                )
            )
        )
        
        // Allocate temporary deinterleaved buffers
        var leftChannel = [Float](repeating: 0, count: frameCount)
        var rightChannel = [Float](repeating: 0, count: frameCount)
        
        // Deinterleave samples
        for i in 0..<frameCount {
            leftChannel[i] = samples[i * 2]
            rightChannel[i] = samples[i * 2 + 1]
        }
        
        // Set buffer pointers
        leftChannel.withUnsafeMutableBufferPointer { leftPtr in
            rightChannel.withUnsafeMutableBufferPointer { rightPtr in
                bufferList.mBuffers.0.mData = UnsafeMutableRawPointer(leftPtr.baseAddress)
                bufferList.mBuffers.1.mData = UnsafeMutableRawPointer(rightPtr.baseAddress)
                
                // Write to file
                let status = ExtAudioFileWrite(
                    file,
                    UInt32(frameCount),
                    &bufferList
                )
                
                if status != noErr {
                    os_log("Failed to write audio: %d", log: logger, type: .error, status)
                }
            }
        }
    }
}
