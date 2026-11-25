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
                    denied(tr("Нет доступа к распознаванию речи. Разреши его: Системные настройки → Конфиденциальность и безопасность → Распознавание речи.",
                               "No access to speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."))
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            denied(tr("Нет доступа к микрофону. Разреши его: Системные настройки → Конфиденциальность и безопасность → Микрофон.",
                                       "No access to the microphone. Allow it in System Settings → Privacy & Security → Microphone."))
                            return
                        }
                        self.begin(denied: denied)
                    }
                }
            }
        }
    }

    private func begin(denied: (String) -> Void) {
        // Russian for the Russian interface; otherwise the Mac's own language, which is what the user most likely speaks.
        let language = Language.isRussian ? Locale(identifier: "ru-RU") : Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: language) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            denied(tr("Распознавание речи сейчас недоступно.", "Speech recognition isn't available right now."))
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
            denied(tr("Не получилось включить микрофон.", "Couldn't turn on the microphone."))
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
        let fallback = Language.isRussian ? "ru-RU" : "en-US"
        let code = recognizer.dominantLanguage?.rawValue ?? String(fallback.prefix(2))
        utterance.voice = AVSpeechSynthesisVoice(language: code == "ru" ? "ru-RU" : code) ?? AVSpeechSynthesisVoice(language: fallback)
        synth.speak(utterance)
    }

    func hush() { synth.stopSpeaking(at: .immediate) }
}
