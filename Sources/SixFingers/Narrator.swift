import AVFoundation
import CryptoKit
import Foundation

private let openers = [
    "Alright, let me draw {prompt} for you.",
    "Okay, {prompt}. I've got this.",
    "{prompt}. Nice choice. Let me get started.",
    "Let's see. {prompt}. I know just how to do this.",
]
private let genericOpeners = [
    "Alright, let me draw something for you.",
    "Okay, I have got something in mind. Let me get started.",
    "Let us see what I can do. Here we go.",
    "Time to draw. Watch this.",
]
private let progressEarly = [
    "Starting with the big shapes first.",
    "Let me lay down the main outline.",
    "Getting the structure in place.",
    "Okay, the basic form is going down.",
]
private let progressMid = [
    "Now I'm adding some detail.",
    "This is coming along nicely.",
    "Getting into the fun part now.",
    "The shape is really taking form.",
    "I like how this is turning out.",
]
private let progressLate = [
    "Almost there. Just a few more lines.",
    "Finishing up the details now.",
    "Just putting on the final touches.",
    "Last few strokes. Almost there.",
]
private let paused = [
    "A dramatic pause. Very artistic.",
    "Taking a moment to contemplate. I respect that.",
]
private let resumed = [
    "Back to work. The muse has returned.",
    "Lets continue. Where were we?",
]
private let cancelled = [
    "Okay, stopping here. Maybe next time.",
    "No worries, we can try again later.",
]
private let closers = [
    "And done! What do you think?",
    "There we go. Not bad, right?",
    "Finished! That was fun.",
    "All done. Hope you like it.",
]

class Narrator: NSObject, AVAudioPlayerDelegate {
    let prompt: String
    let enabled: Bool
    private var cache: [String: String] = [:]
    private var lastSpeakTime: Date = .distantPast
    private let minGap: TimeInterval = 8
    private var spokeEarly = false, spokeMid = false, spokeLate = false
    private var preEarly = "", preMid = "", preLate = "", preCloser = ""
    private var player: AVAudioPlayer?
    private var speaking = false

    init(prompt: String, enabled: Bool = true) {
        self.prompt = prompt
        self.enabled = enabled
        super.init()
    }

    private static func audioHash(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func findBundledAudio(_ text: String) -> String? {
        let h = audioHash(text)
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/narrator_audio/\(h).mp3" },
            Bundle.main.resourcePath.map { "\($0)/Resources/narrator_audio/\(h).mp3" },
        ].compactMap { $0 }
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func speak(_ text: String) {
        guard enabled, !speaking else { return }
        speaking = true

        DispatchQueue.global().async { [weak self] in
            // Check memory cache
            if let cached = self?.cache[text] {
                self?.lastSpeakTime = Date()
                self?.play(cached)
                return
            }

            // Check bundled audio
            if let bundled = Narrator.findBundledAudio(text) {
                self?.cache[text] = bundled
                self?.lastSpeakTime = Date()
                self?.play(bundled)
                return
            }

            // Generate TTS via provider
            Task {
                if let path = await speakText(text) {
                    self?.cache[text] = path
                    self?.lastSpeakTime = Date()
                    self?.play(path)
                } else {
                    // Nothing played — don't block future speaks
                    self?.speaking = false
                }
            }
        }
    }

    private func play(_ path: String) {
        // Stop any currently playing audio
        player?.stop()

        let url = URL(fileURLWithPath: path)
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            speaking = false
            return
        }
        player = p
        p.delegate = self
        p.play()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        speaking = false
    }

    private func canSpeak() -> Bool {
        Date().timeIntervalSince(lastSpeakTime) > minGap
    }

    func onStart() {
        preEarly = progressEarly.randomElement()!
        preMid = progressMid.randomElement()!
        preLate = progressLate.randomElement()!
        preCloser = closers.randomElement()!

        // Try prompt-specific opener, fall back to generic (which has bundled audio)
        let specificOpener = openers.randomElement()!.replacingOccurrences(of: "{prompt}", with: prompt)
        if Narrator.findBundledAudio(specificOpener) != nil || SettingsManager.shared.getApiKey() != nil {
            speak(specificOpener)
        } else {
            speak(genericOpeners.randomElement()!)
        }

        // Pre-cache
        for line in [preEarly, preMid, preLate, preCloser] {
            Task { let _ = await speakText(line) }
        }
    }

    func onProgress(current: Int, total: Int) {
        guard canSpeak() else { return }
        let pct = Double(current) / Double(max(1, total))

        if pct < 0.2 && !spokeEarly { spokeEarly = true; speak(preEarly) }
        else if pct > 0.35 && pct < 0.65 && !spokeMid { spokeMid = true; speak(preMid) }
        else if pct > 0.8 && !spokeLate { spokeLate = true; speak(preLate) }
    }

    func onDone() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.speak(self.preCloser)
        }
    }

    func onPaused() {
        speak(paused.randomElement()!)
    }

    func onResumed() {
        speak(resumed.randomElement()!)
    }

    func onCancelled() {
        speak(cancelled.randomElement()!)
    }
}
