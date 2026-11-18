import AVFoundation
import AudioToolbox

/// アラームの音を試しに鳴らす（アプリに入れた音、または標準の音）
enum SoundPreview {
    private static var player: AVAudioPlayer?
    static func play(_ name: String?) {
        player?.stop()
        guard let name, let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension) else {
            AudioServicesPlaySystemSound(1005)
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        // 長い音は3秒で止める
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { player?.stop() }
    }
}
