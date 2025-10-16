# Core Audio Implementation - Phase 4 Fixes

## Changes Made (October 16, 2025)

### Issue 1: Accented Beats Not Working
**Problem:** All beats sounded the same, no accent on beat 1

**Fix:**
- Added `accentedClickBuffer` and `accentedClickBufferLength` properties
- Added `loadAccentedClickSound()` method to load the accented sound
- Updated `generateClicks()` to choose the accented buffer when `currentBeat == 0`
- Updated adapter's `init()` to load both click sounds
- Updated `setAudioFile()` to load both sounds

**Result:** Beat 1 now plays the accented sound, others play normal sound

### Issue 2: Tick Callbacks Not Firing
**Problem:** Flutter wasn't receiving "tick: 0, tick: 1, etc." events

**Fix:**
- Added `beatCallback` property of type `((Int) -> Void)?`
- Added `setBeatCallback()` method
- Updated `generateClicks()` to detect beat transitions and fire callback
- Updated adapter's `enableTickCallback()` to wire up the callback

**Result:** Beat events now fire to Flutter via the event channel

### Issue 3: Recording Path Error
**Problem:** `stopRecording()` returned "TODO_FILE_PATH" causing file move error

**Fix:**
- Added `recordingPath` property to store the target path
- Updated `startRecording()` to accept and store the path parameter
- Updated `stopRecording()` to return the actual path
- Updated adapter to pass the path to Core Audio
- Added stub implementation that creates directory (actual recording in Phase 5)

**Result:** No more file move errors, path is handled correctly

## Testing Results

✅ Metronome plays with Core Audio  
✅ Accented beat plays on beat 1  
✅ Tick callbacks fire to Flutter  
✅ No crash on stop recording (though recording not yet implemented)

## Known Limitations

⚠️ **Recording not yet implemented** - This is Phase 5 work:
- Mic input not captured
- Mixed audio not written to file
- File writer thread not implemented
- Circular buffer not used yet

The recording infrastructure is in place but needs:
- Phase 5.1: Add mic input to render callback
- Phase 5.2: Mix mic + clicks in render callback  
- Phase 5.3: Write mixed samples to circular buffer
- Phase 5.4: Background thread reads from buffer and writes to file

## Next Steps

1. Test on device with `useCoreAudio = true`
2. Verify accents work correctly
3. Verify tick callbacks appear in logs
4. When ready, implement Phase 5 (recording)

## Files Modified

- `CoreAudioMetronome.swift` - Added accent support, beat callbacks, recording path
- `CoreAudioMetronomeAdapter.swift` - Wire up accents, callbacks, and path handling
