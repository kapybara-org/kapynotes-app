import AVFoundation
import Foundation
import FlutterMacOS

/// Turns an `.m4a` recording into the raw samples a speech model can read.
///
/// Every recording this app makes is AAC; every speech model wants 16 kHz
/// mono PCM; nothing in Dart decodes AAC. Each platform already has a decoder
/// in the box, and this reaches for this one — `AVAudioConverter`, which does
/// the format change and the resample in a single pass.
///
/// A Mac on macOS 26 never gets here: `Transcription.swift` hands the `.m4a`
/// straight to `SpeechAnalyzer`. This is for the Macs below that, which fall
/// back to the downloaded recogniser, and it is the twin of the decoders the
/// other platforms need.
///
/// The samples are written to a file rather than returned, because thirty
/// minutes is 57 MB and a method channel would hold the native buffer and the
/// Dart copy at the same time. Dart owns the file once this returns.
///
/// The channel also goes the other way: `encode` writes a recording whose
/// noise has been removed, raw PCM by then, back into an `.m4a`.
enum AudioDecode {
  private static let channelName = "kapynotes/audio_decode"

  /// How much is read per pass. Large enough that the per-call overhead
  /// disappears, small enough that the buffers stay off the phone's radar —
  /// half a second of audio at any rate anyone records at.
  private static let inputCapacity: AVAudioFrameCount = 8192

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "decode":
        decode(call.arguments, result)
      case "encode":
        encode(call.arguments, result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private static func decode(_ rawArguments: Any?, _ result: @escaping FlutterResult) {
    guard
      let arguments = rawArguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty
    else {
      result(FlutterError(code: "arguments", message: "A recording is required.", details: nil))
      return
    }
    let sampleRate = Double(arguments["sampleRate"] as? Int ?? 16000)

    // Off the main thread: a thirty-minute recording is seconds of work, and
    // the window it would otherwise block is the one showing the progress.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let (out, frames) = try run(path: path, sampleRate: sampleRate)
        DispatchQueue.main.async {
          result(["path": out, "sampleRate": Int(sampleRate), "frames": frames])
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "decode", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private static func run(path: String, sampleRate: Double) throws -> (String, Int) {
    let input = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
        channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: input.processingFormat, to: target)
    else {
      throw Failure.unreadable
    }

    let out = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("kapynotes-pcm-\(UUID().uuidString).pcm")
    guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
      throw Failure.unreadable
    }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }

    // Room for the resample to produce more frames than it consumed, which it
    // does whenever the recording is below the model's rate.
    let ratio = sampleRate / input.processingFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio) + 1024

    var frames = 0
    var finished = false
    while !finished {
      guard
        let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity)
      else {
        throw Failure.unreadable
      }
      var conversionError: NSError?
      let status = converter.convert(to: outBuffer, error: &conversionError) {
        _, outStatus in
        guard
          let inBuffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat, frameCapacity: inputCapacity)
        else {
          outStatus.pointee = .endOfStream
          return nil
        }
        do {
          try input.read(into: inBuffer, frameCount: inputCapacity)
        } catch {
          outStatus.pointee = .endOfStream
          return nil
        }
        if inBuffer.frameLength == 0 {
          outStatus.pointee = .endOfStream
          return nil
        }
        outStatus.pointee = .haveData
        return inBuffer
      }
      if let conversionError { throw conversionError }
      if outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData {
        let count = Int(outBuffer.frameLength)
        handle.write(Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size))
        frames += count
      }
      // `inputRanDry` with nothing produced means the callback said end of
      // stream and the converter has nothing left buffered; treating it as
      // anything else is an endless loop over an exhausted file.
      if status == .endOfStream || status == .error { finished = true }
      if status == .inputRanDry && outBuffer.frameLength == 0 { finished = true }
    }

    if frames == 0 {
      try? FileManager.default.removeItem(at: out)
      throw Failure.empty
    }
    return (out.path, frames)
  }

  /// Writes raw 16-bit mono PCM back out as the app's own kind of recording.
  ///
  /// The way back from `decode`, for a recording whose noise has been
  /// removed. `AVAudioFile` with AAC settings is Core Audio's AAC encoder and
  /// MPEG-4 writer in one, the same pair behind the recorder, so the cleaned
  /// file is the same kind of `.m4a` the note had before. Dart owns the
  /// rename into place; this only promises to leave nothing behind when it
  /// fails.
  private static func encode(_ rawArguments: Any?, _ result: @escaping FlutterResult) {
    guard
      let arguments = rawArguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty,
      let destination = arguments["destination"] as? String,
      !destination.isEmpty
    else {
      result(FlutterError(code: "arguments", message: "A recording is required.", details: nil))
      return
    }
    let sampleRate = Double(arguments["sampleRate"] as? Int ?? 16000)
    let bitRate = arguments["bitRate"] as? Int ?? 48000

    // Off the main thread for the reason `decode` is: thirty minutes of
    // audio is seconds of work.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        // The pool makes sure the file is closed, which is when its header
        // is written, before Dart is told it is there.
        try autoreleasepool {
          try write(path: path, destination: destination, sampleRate: sampleRate, bitRate: bitRate)
        }
        DispatchQueue.main.async { result(nil) }
      } catch {
        try? FileManager.default.removeItem(atPath: destination)
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "encode", message: "This recording could not be saved.", details: nil))
        }
      }
    }
  }

  private static func write(
    path: String, destination: String, sampleRate: Double, bitRate: Int
  ) throws {
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? input.close() }
    let output = try AVAudioFile(
      forWriting: URL(fileURLWithPath: destination),
      settings: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: bitRate,
      ],
      commonFormat: .pcmFormatInt16, interleaved: true)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: output.processingFormat, frameCapacity: inputCapacity),
      let samples = buffer.int16ChannelData
    else {
      throw CocoaError(.fileWriteUnknown)
    }

    // A chunk at a time, never the whole file: thirty minutes is 57 MB.
    let sampleSize = MemoryLayout<Int16>.size
    while let data = try input.read(upToCount: Int(inputCapacity) * sampleSize), !data.isEmpty {
      let frames = data.count / sampleSize
      data.withUnsafeBytes { bytes in
        UnsafeMutableRawPointer(samples[0]).copyMemory(
          from: bytes.baseAddress!, byteCount: frames * sampleSize)
      }
      buffer.frameLength = AVAudioFrameCount(frames)
      try output.write(from: buffer)
    }
  }

  private enum Failure: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
      switch self {
      case .unreadable: return "This recording could not be read."
      case .empty: return "This recording has no audio in it."
      }
    }
  }
}
