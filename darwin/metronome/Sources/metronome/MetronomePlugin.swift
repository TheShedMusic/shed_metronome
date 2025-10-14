#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
// import Cocoa
#endif
public class MetronomePlugin: NSObject, FlutterPlugin {
    var channel:FlutterMethodChannel?
    var metronome:Metronome?
    //
    private let eventTickListener: EventTickHandler = EventTickHandler()
    private var eventTick: FlutterEventChannel?
    //
    init(with registrar: FlutterPluginRegistrar) {}
    //
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MetronomePlugin(with: registrar)
#if os(iOS)
    let messenger = registrar.messenger()
#else
    let messenger = registrar.messenger
#endif
        instance.channel = FlutterMethodChannel(name: "metronome", binaryMessenger: messenger)

        registrar.addApplicationDelegate(instance)
        registrar.addMethodCallDelegate(instance, channel: instance.channel!)
        //
        instance.eventTick = FlutterEventChannel(name: "metronome_tick", binaryMessenger: messenger)
        instance.eventTick?.setStreamHandler(instance.eventTickListener )
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
          let attributes = call.arguments as? NSDictionary
          switch call.method {
              case "init":
                  metronomeInit(attributes: attributes)
                break;
              case "play":
                  metronome?.play()
                break;
              case "pause":
                  metronome?.pause()
                break;
              case "stop":
                  metronome?.stop()
                break;
              case "getVolume":
                  result(metronome?.getVolume)
                break;
              case "setVolume":
                  setVolume(attributes: attributes)
                break;
              case "isPlaying":
                  result(metronome?.isPlaying)
                break;
              case "setBPM":
                  setBPM(attributes: attributes)
                break;
              case "getBPM":
                  result(metronome?.audioBpm)
                break;
              case "setTimeSignature":
                  setTimeSignature(attributes: attributes)
                break;
              case "getTimeSignature":
                  result(metronome?.audioTimeSignature)
                break;
              case "setAudioFile":
                  setAudioFile(attributes: attributes)
                break;
              case "destroy":
                  metronome?.destroy()
                break;
          case "enableMicrophone":
              do {
                  try metronome?.enableMicrophone()
                  result(true)
              } catch {
                  result(FlutterError(code: "MICROPHONE_ERROR",
                                      message: "Failed to enable microphone: \(error.localizedDescription)",
                                      details: nil))
              }
          case "setMicVolume":
              guard let volume = call.arguments as? Double else {
                  result(FlutterError(code: "INVALID_ARGUMENT",
                                      message: "Volume must be a number between 0.0 and 1.0",
                                      details: nil))
                  return
              }
              metronome?.setMicVolume(Float(volume))
              result(nil)
          case "startRecording":
              guard let args = call.arguments as? [String: Any],
                    let path = args["path"] as? String else {
                  result(FlutterError(code: "INVALID_ARGUMENT",
                                            message: "Recording path is required",
                                            details: nil))
                          return
              }
              let success = metronome?.startRecording(path: path) ?? false
              result(success)
          case "stopRecording":
              let recordingResult = metronome?.stopRecording()
              result(recordingResult)
          case "generateClickTrack":
              let args = call.arguments as? [String: Any]
              let clickTrackResult = generateClickTrack(attributes: args as NSDictionary?)
              result(clickTrackResult)
              
          case "mixAudioFiles":
              let args = call.arguments as? [String: Any]
              let mixResult = mixAudioFiles(attributes: args as NSDictionary?)
              result(mixResult)
              default:
                  result("unkown")
                break;
        }
    }
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        channel?.setMethodCallHandler(nil)
        eventTick?.setStreamHandler(nil)
    }
    private func setBPM( attributes:NSDictionary?) {
        if metronome != nil {
            let bpm: Int = (attributes?["bpm"] as? Int) ?? 120
            metronome?.setBPM(bpm: bpm)
        }
    }
    private func setTimeSignature( attributes:NSDictionary?) {
        if metronome != nil {
            let timeSignature: Int = (attributes?["timeSignature"] as? Int) ?? 0
            metronome?.setTimeSignature(timeSignature: timeSignature)
        }
    }
    private func metronomeInit( attributes:NSDictionary?) {
        let mainFileBytes = (attributes?["mainFileBytes"] as? FlutterStandardTypedData) ?? FlutterStandardTypedData()
        let accentedFileBytes = (attributes?["accentedFileBytes"] as? FlutterStandardTypedData) ?? FlutterStandardTypedData()
        let mainBytes: Data = mainFileBytes.data
        let accentedBytes: Data = accentedFileBytes.data
        
        let enableTickCallback: Bool = (attributes?["enableTickCallback"] as? Bool) ?? true
        let timeSignature: Int = (attributes?["timeSignature"] as? Int) ?? 0
        let bpm: Int = (attributes?["bpm"] as? Int) ?? 120
        let volume: Float = (attributes?["volume"] as? Float) ?? 0.5
        let sampleRate: Int = (attributes?["sampleRate"] as? Int) ?? 44100
        metronome =  Metronome( mainFileBytes:mainBytes,accentedFileBytes: accentedBytes,bpm:bpm,timeSignature:timeSignature,volume:volume,sampleRate:sampleRate)
        if(enableTickCallback){
            metronome?.enableTickCallback(_eventTickSink: eventTickListener);
        }
    }
    private func setAudioFile( attributes:NSDictionary?) {
        if metronome != nil {
            let mainFileBytes = (attributes?["mainFileBytes"] as? FlutterStandardTypedData) ?? FlutterStandardTypedData()
            let accentedFileBytes = (attributes?["accentedFileBytes"] as? FlutterStandardTypedData) ?? FlutterStandardTypedData()
            let mainBytes: Data = mainFileBytes.data
            let accentedBytes: Data = accentedFileBytes.data
            metronome?.setAudioFile( mainFileBytes:mainBytes,accentedFileBytes: accentedBytes)
        }
    }
    private func setVolume( attributes:NSDictionary?) {
        if metronome != nil {
            let volume: Double = (attributes?["volume"] as? Double) ?? 0.5
            metronome?.setVolume(volume: Float(volume))
        }
    }
    private func generateClickTrack(attributes: NSDictionary?) -> String? {
        guard let timestampsArray = attributes?["timestamps"] as? [Double],
              let bpm = attributes?["bpm"] as? Int,
              let timeSignature = attributes?["timeSignature"] as? Int,
              let outputPath = attributes?["outputPath"] as? String,
              let mainClickData = (attributes?["mainClickBytes"] as? FlutterStandardTypedData)?.data,
              let accentedClickData = (attributes?["accentedClickBytes"] as? FlutterStandardTypedData)?.data else {
            print("[MetronomePlugin] Invalid arguments for generateClickTrack")
            return nil
        }
        
        return ClickTrackGenerator.generateClickTrack(
            clickTimestamps: timestampsArray,
            bpm: bpm,
            timeSignature: timeSignature,
            mainClickData: mainClickData,
            accentedClickData: accentedClickData,
            outputPath: outputPath
        )
    }

    private func mixAudioFiles(attributes: NSDictionary?) -> String? {
        guard let micPath = attributes?["micAudioPath"] as? String,
              let clickPath = attributes?["clickTrackPath"] as? String,
              let outputPath = attributes?["outputPath"] as? String else {
            print("[MetronomePlugin] Invalid arguments for mixAudioFiles")
            return nil
        }
        
        return AudioMixer.mixAudioFiles(
            micAudioPath: micPath,
            clickTrackPath: clickPath,
            outputPath: outputPath
        )
    }
}
