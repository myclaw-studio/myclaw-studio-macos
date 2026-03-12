import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
class VoiceService: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var isListening = false
    @Published var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    /// 回调：(前缀, 语音识别的完整文本) → 调用方拼接为 prefix + transcript
    var onTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var generation: Int = 0

    /// 开始语音时输入框已有的内容，作为不可变前缀
    private(set) var inputPrefix = ""

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                self?.authStatus = status
            }
        }
    }

    func startListening(currentInput: String) throws {
        if isListening {
            stopListening()
        }

        generation += 1
        let currentGen = generation
        inputPrefix = currentInput

#if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
#endif

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = recognitionRequest else { return }
        req.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGen else { return }
                if let result {
                    self.onTranscript?(result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    self.stopListening()
                }
            }
        }

        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
