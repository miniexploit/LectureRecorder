import AppIntents
import AVFoundation
import SwiftUI
import Speech
import UniformTypeIdentifiers

@main
struct LectureRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            RecorderView()
        }
    }
}

enum RecordingError: LocalizedError {
    case microphoneDenied
    case couldNotStart
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Allow microphone access in Settings to record."
        case .couldNotStart:
            return "The recorder couldn’t start."
        case .noActiveRecording:
            return "There’s no recording in progress."
        }
    }
}

@MainActor
final class LectureRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = LectureRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var lastRecording: URL?

    private var recorder: AVAudioRecorder?

    func start() async throws {
        guard recorder == nil else { return }

        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { throw RecordingError.microphoneDenied }
        guard recorder == nil else { return }

        let folder = URL.documentsDirectory
            .appendingPathComponent("Lectures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let filename = "Lecture-\(UUID().uuidString).m4a"
        let url = folder.appendingPathComponent(filename)
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])

            newRecorder.delegate = self
            guard newRecorder.record() else {
                throw RecordingError.couldNotStart
            }

            recorder = newRecorder
            isRecording = true
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() throws -> URL {
        guard let recorder else {
            throw RecordingError.noActiveRecording
        }

        recorder.stop()
        finish(url: recorder.url)
        return recorder.url
    }

    private func finish(url: URL?) {
        recorder = nil
        isRecording = false
        if let url {
            lastRecording = url
        }

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        let url = recorder.url
        Task { @MainActor in
            guard self.recorder?.url == url else { return }
            self.finish(url: flag ? url : nil)
        }
    }
}

struct RecorderView: View {
    @ObservedObject private var recorder = LectureRecorder.shared
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Lecture Recorder")
                .font(.largeTitle.bold())

            Text(recorder.isRecording ? "Recording…" : "Ready to record")
                .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)

            Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                Task {
                    errorMessage = nil
                    do {
                        if recorder.isRecording {
                            _ = try recorder.stop()
                        } else {
                            try await recorder.start()
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            if let url = recorder.lastRecording, !recorder.isRecording {
                ShareLink("Share Last Recording", item: url)
                LectureTranscriptView(audioURL: url)
                    .id(url)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }
}

struct StartLectureRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Lecture Recording"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LectureRecorder.shared.start()
        return .result()
    }
}

struct StopAndGetLectureAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop and Get Lecture Audio"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let url = try LectureRecorder.shared.stop()
        return .result(value: IntentFile(
            fileURL: url,
            filename: "lecture.m4a",
            type: .mpeg4Audio
        ))
    }
}

enum LectureTranscriptionError: LocalizedError {
    case unsupportedDevice
    case unsupportedLanguage
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "On-device transcription requires iOS 26 and a supported iPhone."
        case .unsupportedLanguage:
            return "US English transcription is unavailable on this device."
        case .noSpeech:
            return "No speech was detected in this recording."
        }
    }
}

enum LectureTranscriber {
    static func transcribe(_ url: URL) async throws -> String {
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable else {
            throw LectureTranscriptionError.unsupportedDevice
        }

        let english = Locale(identifier: "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: english
        ) else {
            throw LectureTranscriptionError.unsupportedLanguage
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let transcript: String = collectResults(from: transcriber)

        do {
            try await analyzer.start(
                inputAudioFile: audioFile,
                finishAfterFile: true
            )
            return try await transcript
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    @available(iOS 26.0, *)
    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> String {
        var passages: [String] = []

        for try await result in transcriber.results {
            let passage = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !passage.isEmpty {
                passages.append(passage)
            }
        }

        guard !passages.isEmpty else {
            throw LectureTranscriptionError.noSpeech
        }

        return passages.joined(separator: " ")
    }
}

struct LectureTranscriptView: View {
    let audioURL: URL

    @State private var transcript = ""
    @State private var isTranscribing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Button("Transcribe Last Recording") {
                isTranscribing = true
                errorMessage = nil

                Task {
                    defer { isTranscribing = false }

                    do {
                        transcript = try await LectureTranscriber.transcribe(audioURL)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .disabled(isTranscribing)

            if isTranscribing {
                ProgressView("Preparing or transcribing audio…")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if !transcript.isEmpty {
                ScrollView {
                    Text(transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)

                ShareLink(item: transcript) {
                    Label("Share Transcript", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

struct TranscribeLectureAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Lecture Audio"
    static let openAppWhenRun = true

    @Parameter(title: "Audio File")
    var audioFile: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let url = audioFile.fileURL {
            return .result(value: try await LectureTranscriber.transcribe(url))
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let filename = URL(fileURLWithPath: audioFile.filename).lastPathComponent
        let url = folder.appendingPathComponent(filename)
        try audioFile.data.write(to: url)

        return .result(value: try await LectureTranscriber.transcribe(url))
    }
}