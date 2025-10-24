/// Simple soft-knee limiter to prevent clipping
class SimpleLimiter {
    private let threshold: Float = 0.8      // Start compressing at 80% (-1.94 dBFS)
    private let ceiling: Float = 0.95       // Hard ceiling at 95% (-0.44 dBFS)
    
    /// Apply soft-knee limiting to prevent harsh clipping
    func process(_ sample: Float) -> Float {
        let absSample = abs(sample)
        
        // Below threshold: pass through unchanged
        if absSample < threshold {
            return sample
        }
        
        // Above threshold: soft compression
        let excess = absSample - threshold
        let range = ceiling - threshold
        
        // Soft knee curve (logarithmic)
        let compressed = threshold + (range * tanh(excess / range))
        
        // Preserve sign
        return sample >= 0 ? compressed : -compressed
    }
}

How it works:

Below 80%: Audio passes through untouched
80-95%: Soft compression using tanh() (smooth, musical)
Above 95%: Hard ceiling (never exceeds)
Why this works:

tanh() creates a smooth "soft knee" - sounds natural
Preserves dynamics for normal playing
Only kicks in for loud hits (drums, aggressive strumming)
No look-ahead needed = zero added latency!
Full Implementation
Want me to add this to your CoreAudioMetronome? Here's what I'd do:

Add the limiter class
Create a limiter instance for each channel (L/R)
Apply it to mic input in the render callback
Switch back to .measurement mode
The render callback change would be simple:

// Before (raw mic):
let finalRecordLeft = delayedClickLeft + (micL[i] * micVolume)

// After (limited mic):
let rawMic = micL[i] * micVolume
let limitedMic = limiter.process(rawMic)
let finalRecordLeft = delayedClickLeft + limitedMic

Should I implement this? It would:

✅ Let you use .measurement mode (low latency!)
✅ Prevent clipping/distortion
✅ Sound much more natural than iOS's heavy processing
✅ Give you the tight monitoring feel back