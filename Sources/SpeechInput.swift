import Foundation
import AVFoundation
import Speech

// All lifecycle changes and UI callbacks run on the main queue. The audio tap
// only feeds its own request; a session token rejects late callbacks after cancel.
final class SpeechInput {
    var onStatus: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onComplete: ((Result<String, Error>) -> Void)?
    var onLevel: ((Double, String) -> Void)?
    private var session: UUID?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var hasTap = false
    private var finishing = false
    private var transcript = ""
    private var deadline: DispatchWorkItem?
    private var finalDeadline: DispatchWorkItem?
    private var levelTimer: Timer?
    private var signal: MicrophoneSignal?
    private var inputName = "microphone"
    var isActive: Bool { session != nil }
    var canFinish: Bool { engine?.isRunning == true && !finishing }

    func start() {
        guard !isActive else { return }
        let id = UUID()
        session = id; transcript = ""; finishing = false
        onStatus?("Allow speech recognition and microphone access if macOS asks.")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, self.session == id else { return }
                guard status == .authorized else {
                    self.fail("Speech recognition is unavailable or not allowed. Enable Apple Jack in System Settings → Privacy & Security → Speech Recognition, or use typing.")
                    return
                }
                self.authorizeMicrophone(id)
            }
        }
    }
    private func authorizeMicrophone(_ id: UUID) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording(id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self = self, self.session == id else { return }
                    if allowed { self.beginRecording(id) }
                    else { self.fail("Microphone access was declined. You can enable Apple Jack in System Settings → Privacy & Security → Microphone.") }
                }
            }
        default:
            fail("Microphone access is unavailable. Enable Apple Jack in System Settings → Privacy & Security → Microphone, or use typing.")
        }
    }
    private func beginRecording(_ id: UUID) {
        guard session == id else { return }
        guard let device = AudioInputDevice.preferred() else {
            fail("The selected microphone is unavailable. Choose Studio Display Microphone under Menu → Speech & Input → Microphone."); return
        }
        inputName = device.name
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail("Speech recognition is unavailable for your current language or connection. Try again later, or type your request."); return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Let Apple choose its available recognition service. A device's
        // advertised support does not guarantee its local model is ready.
        self.request = request
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        do { try device.select(on: input) }
        catch { fail(error.localizedDescription); return }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            fail("The microphone is not ready. Check your Mac’s sound input and try again."); return
        }
        let signal = MicrophoneSignal()
        self.signal = signal
        let feedAudio: AVAudioNodeTapBlock = { buffer, _ in request.append(signal.prepare(buffer)) }
        if #available(macOS 27.0, *) {
            do {
                try input.__installTap(onBus: 0, bufferSize: 8192, format: format, error: (), block: feedAudio)
            } catch {
                fail("Could not access the microphone: \(error.localizedDescription)")
                return
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 8192, format: format, block: feedAudio)
        }
        hasTap = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self = self, self.session == id else { return }
                if let response = response {
                    self.transcript = response.bestTranscription.formattedString
                    self.onTranscript?(self.transcript)
                    if response.isFinal { self.completeTranscript(); return }
                }
                if let error = error {
                    // A recognizer may end with a cancellation error after endAudio.
                    if self.finishing && !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.completeTranscript()
                    } else {
                        self.fail(self.failureMessage(error.localizedDescription))
                    }
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            onStatus?("Listening through \(inputName)… Speak, check that the input meter moves, then click Done & Send.")
            let meter = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, self.session == id, let signal = self.signal else { return }
                let sample = signal.read()
                self.onLevel?(sample.level, self.inputName)
            }
            levelTimer = meter
            RunLoop.main.add(meter, forMode: .common)
            let timeout = DispatchWorkItem { [weak self] in
                guard self?.session == id else { return }
                self?.finish()
            }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 55, execute: timeout)
        } catch {
            fail("Could not start the microphone: \(error.localizedDescription)")
        }
    }
    func finish() {
        guard let id = session, !finishing, canFinish else { return }
        finishing = true
        stopMicrophone()
        deadline?.cancel()
        onStatus?("Finishing your dictation…")
        request?.endAudio()
        // Give the recognizer time to deliver its final words, but don't leave
        // the UI stuck if the service never provides a final result.
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.session == id else { return }
            self?.completeTranscript()
        }
        finalDeadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }
    func cancel() {
        session = nil
        deadline?.cancel(); deadline = nil
        finalDeadline?.cancel(); finalDeadline = nil
        stopMicrophone()
        request?.endAudio()
        recognition?.cancel(); recognition = nil
        request = nil; engine = nil; recognizer = nil; finishing = false
    }
    private func stopMicrophone() {
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        levelTimer?.invalidate(); levelTimer = nil
        onLevel?(0, inputName)
    }
    private func completeTranscript() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { fail(failureMessage("No transcript was returned.")); return }
        cancel() // Microphone is off before the request or spoken reply starts.
        onComplete?(.success(text))
    }
    private func fail(_ message: String) {
        cancel()
        onComplete?(.failure(NSError(domain: "AppleJack.Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
    }
    private func failureMessage(_ detail: String) -> String {
        let sample = signal?.read()
        if let sample = sample, sample.frames == 0 {
            return "\(inputName) opened, but no audio reached Jack. Choose your microphone under Menu → Speech & Input → Microphone, then try again."
        }
        if let sample = sample, sample.highest < 0.0001 {
            return "\(inputName) delivered silence. Check its input volume and mute state in System Settings → Sound → Input. The meter in Jack should move when you speak."
        }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Audio reached Jack from \(inputName), but speech recognition returned no words. Try speaking clearly and check your internet connection. \(detail)"
        }
        return "Dictation stopped: \(detail) Your transcribed text is still above; you can edit and submit it."
    }
}
