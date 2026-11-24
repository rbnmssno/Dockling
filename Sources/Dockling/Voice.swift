import AVFoundation
import NaturalLanguage
import Speech

/// Speech to text while the button is held, and reading answers aloud. Both use macOS's own engines;
/// the microphone and the recognizer start only while the user is talking.
final class Voice: NSObject {
    var onText: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var finish: ((String) -> Void)?
    private let synth = AVSpeechSynthesizer()

    /// Asks for the microphone and speech recognition the first time, then starts listening.
    func start(denied: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    denied("Нет доступа к распознаванию речи. Разреши его: Системные настройки → Конфиденциальность и безопасность → Распознавание речи.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            denied("Нет доступа к микрофону. Разреши его: Системные настройки → Конфиденциальность и безопасность → Микрофон.")
                            return
                        }
                        self.begin(denied: denied)
                    }
                }
            }
        }
    }

    private func begin(denied: (String) -> Void) {
        let language = Locale.preferredLanguages.first?.hasPrefix("ru") == false ? Locale.current : Locale(identifier: "ru-RU")
        guard let recognizer = SFSpeechRecognizer(locale: language) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            denied("Распознавание речи сейчас недоступно.")
            return
        }
        stopEngine()
        heard = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            denied("Не получилось включить микрофон.")
            return
        }
        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    self.onText?(self.heard)
                    if result.isFinal { self.done() }
                } else if error != nil {
                    self.done()
                }
            }
        }
    }

    /// Stops listening and hands over what was heard.
    func stop(_ completion: @escaping (String) -> Void) {
        guard engine != nil || task != nil else { completion(heard); return }
        finish = completion
        request?.endAudio()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // The recognizer sends its final result shortly after the audio ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.done() }
    }

    private func done() {
        guard let finish else { return }
        self.finish = nil
        task?.cancel()
        task = nil
        request = nil
        finish(heard.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        task?.cancel()
        task = nil
    }

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(text.prefix(1500)))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let code = recognizer.dominantLanguage?.rawValue ?? "ru"
        utterance.voice = AVSpeechSynthesisVoice(language: code == "ru" ? "ru-RU" : code) ?? AVSpeechSynthesisVoice(language: "ru-RU")
        synth.speak(utterance)
    }

    func hush() { synth.stopSpeaking(at: .immediate) }
}
