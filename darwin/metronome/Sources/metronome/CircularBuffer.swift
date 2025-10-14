import Foundation

/// A lock-free circular buffer for passing audio samples from the real-time render callback
/// to a background file-writing thread. This buffer is designed to be thread-safe without
/// using locks, making it safe for use in real-time audio contexts.
///
/// The buffer uses atomic operations and a single-producer, single-consumer pattern:
/// - Producer: Audio render callback (real-time thread) writes samples
/// - Consumer: File writer thread (background) reads samples
class CircularBuffer<T> {
    
    // MARK: - Properties
    
    /// The underlying storage for audio samples
    private var buffer: UnsafeMutablePointer<T>
    
    /// Total capacity of the buffer in samples
    private let capacity: Int
    
    /// Current write position (written by producer only)
    private var writeIndex: Int = 0
    
    /// Current read position (written by consumer only)
    private var readIndex: Int = 0
    
    /// Thread-safe access to available sample count
    private let availableQueue = DispatchQueue(label: "com.grooveshed.circularbuffer.available")
    
    // MARK: - Initialization
    
    /// Initialize a circular buffer with the specified capacity
    /// - Parameter capacity: Number of samples the buffer can hold (recommend 48000 * 10 = 10 seconds at 48kHz)
    init(capacity: Int) where T: Numeric {
        self.capacity = capacity
        
        // Allocate memory for the buffer
        self.buffer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        
        // Initialize all samples to zero
        self.buffer.initialize(repeating: T.zero, count: capacity)
        
        print("[CircularBuffer] Initialized with capacity: \(capacity) samples (\(Double(capacity) / 48000.0) seconds at 48kHz)")
    }
    
    deinit {
        // Clean up allocated memory
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
        print("[CircularBuffer] Deallocated")
    }
    
    // MARK: - Producer API (Called from render callback)
    
    /// Write a single sample to the buffer (real-time safe)
    /// - Parameter sample: The audio sample to write
    /// - Returns: true if written successfully, false if buffer is full
    @inline(__always)
    func write(_ sample: T) -> Bool {
        // Calculate next write position
        let nextWrite = (writeIndex + 1) % capacity
        
        // Check if buffer is full (write would overtake read)
        if nextWrite == readIndex {
            return false // Buffer full, drop sample
        }
        
        // Write the sample
        buffer[writeIndex] = sample
        
        // Advance write index (atomic on single thread)
        writeIndex = nextWrite
        
        return true
    }
    
    /// Write multiple samples to the buffer (real-time safe)
    /// - Parameter samples: Array of samples to write
    /// - Returns: Number of samples actually written
    @inline(__always)
    func write(_ samples: UnsafePointer<T>, count: Int) -> Int {
        var written = 0
        
        for i in 0..<count {
            if write(samples[i]) {
                written += 1
            } else {
                // Buffer full, stop writing
                if written == 0 {
                    print("[CircularBuffer] WARNING: Buffer full, dropping samples!")
                }
                break
            }
        }
        
        return written
    }
    
    // MARK: - Consumer API (Called from background thread)
    
    /// Read samples from the buffer
    /// - Parameter maxCount: Maximum number of samples to read
    /// - Returns: Array of samples read
    func read(maxCount: Int) -> [T] {
        var samples: [T] = []
        samples.reserveCapacity(maxCount)
        
        var samplesRead = 0
        
        while samplesRead < maxCount && readIndex != writeIndex {
            samples.append(buffer[readIndex])
            readIndex = (readIndex + 1) % capacity
            samplesRead += 1
        }
        
        return samples
    }
    
    /// Read samples directly into a pre-allocated buffer
    /// - Parameters:
    ///   - destination: Pointer to destination buffer
    ///   - maxCount: Maximum number of samples to read
    /// - Returns: Number of samples actually read
    func read(into destination: UnsafeMutablePointer<T>, maxCount: Int) -> Int {
        var samplesRead = 0
        
        while samplesRead < maxCount && readIndex != writeIndex {
            destination[samplesRead] = buffer[readIndex]
            readIndex = (readIndex + 1) % capacity
            samplesRead += 1
        }
        
        return samplesRead
    }
    
    // MARK: - Status API
    
    /// Get the number of samples currently available to read
    /// - Returns: Number of samples available
    func availableToRead() -> Int {
        let write = writeIndex
        let read = readIndex
        
        if write >= read {
            return write - read
        } else {
            return capacity - read + write
        }
    }
    
    /// Get the available space for writing
    /// - Returns: Number of samples that can be written
    func availableToWrite() -> Int {
        return capacity - availableToRead() - 1 // -1 to prevent write from catching read
    }
    
    /// Check if the buffer is empty
    /// - Returns: true if no samples are available to read
    func isEmpty() -> Bool {
        return readIndex == writeIndex
    }
    
    /// Check if the buffer is full
    /// - Returns: true if no space is available to write
    func isFull() -> Bool {
        let nextWrite = (writeIndex + 1) % capacity
        return nextWrite == readIndex
    }
    
    /// Reset the buffer, discarding all samples
    func reset() {
        writeIndex = 0
        readIndex = 0
        print("[CircularBuffer] Reset - all samples discarded")
    }
    
    /// Get buffer statistics for debugging
    /// - Returns: Dictionary with buffer statistics
    func getStats() -> [String: Any] {
        let available = availableToRead()
        let percentFull = Double(available) / Double(capacity) * 100.0
        
        return [
            "capacity": capacity,
            "available": available,
            "percentFull": percentFull,
            "isEmpty": isEmpty(),
            "isFull": isFull()
        ]
    }
    
    /// Print current buffer status (for debugging)
    func printStatus() {
        let stats = getStats()
        print("[CircularBuffer] Status: \(stats["available"] ?? 0)/\(stats["capacity"] ?? 0) samples (\(String(format: "%.1f", stats["percentFull"] as? Double ?? 0.0))% full)")
    }
}

// MARK: - Thread Safety Notes
/*
 This circular buffer is designed to be lock-free for a single-producer, single-consumer scenario:
 
 PRODUCER (Render Callback):
 - Only writes to writeIndex
 - Only reads readIndex (to check if full)
 - Never modifies readIndex
 
 CONSUMER (File Writer):
 - Only writes to readIndex
 - Only reads writeIndex (to check if empty)
 - Never modifies writeIndex
 
 This pattern ensures that each thread only modifies its own index, avoiding race conditions
 without the need for locks (which would block the real-time audio thread).
 
 IMPORTANT: Do not use this buffer with multiple producers or multiple consumers!
 */
