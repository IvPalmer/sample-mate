import AVFoundation
import Accelerate

enum AudioLoader {
    static func loadMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.fileFormat.sampleRate
        let framesToRead = AVAudioFrameCount(min(file.length, AVAudioFramePosition(30.0 * sr)))
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                      channels: file.fileFormat.channelCount, interleaved: false),
              file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: framesToRead),
              (try? file.read(into: buf, frameCount: framesToRead)) != nil,
              let data = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<ch { let p = data[c]; for i in 0..<n { mono[i] += p[i] } }
        if ch > 1 { var s = Float(ch); vDSP_vsdiv(mono, 1, &s, &mono, 1, vDSP_Length(n)) }
        return (mono, sr)
    }
}
