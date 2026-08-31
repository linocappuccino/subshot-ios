import SwiftUI
import Combine
import AVFoundation
import Vision

/// 2026-08-31, Lino: "beim Button oben rechts im einem offenen Skript soll
/// 'Start Rec-Markers' stehen, dieser button öffnen ein kleines
/// rechteckiges kamerafenster (liveview kamera) und darunter zeigt es den
/// timecode, darunter kann man die framerate wählen. mit der kamera kann
/// man den kamerascreen abfilmen (den timecode) und das handy / subshot
/// tool syct direkt mit dem timecode der abgefilmt wird so das man keine
/// zeit differenz mehr hat vom Timecode auf der kamera und den markern von
/// subshot" — point THIS phone's camera at a physical camera's own running
/// timecode display; on-device text recognition (Vision) reads the exact
/// digits it's showing right now and this sheet computes the precise
/// offset between this phone's clock and that reading. Doesn't matter
/// which timecode MODE the other camera uses (Time-of-Day, Record-Run,
/// free-run, ...) — this just reads whatever it currently displays, no
/// assumption about what it means.
///
/// Runs entirely client-side; the resulting (fps, offset) is written to
/// the shared `Section.timecodeFps`/`timecodeOffsetSeconds` (see that
/// column's own doc comment in the backend's models.py) so every OTHER
/// client with this project open picks up the same synced clock on its
/// own next poll — "übernimmt eine person den timecode mit der kamera,
/// ist er bei den anderen... direkt auch mit gesynced".
///
/// **NEW and UNVERIFIED on a real device** — no camera or simulator is
/// available in this development environment, so the whole
/// AVCaptureSession/Vision pipeline below has never actually been run
/// against a real camera's timecode display. The regex/OCR tolerance in
/// particular will very likely need real-world tuning (font, glare,
/// motion blur, exact separator character a given camera's LCD renders)
/// before it reliably reads a real display — this needs genuine on-set
/// iteration, not a one-shot fix.
struct RecMarkersSyncSheet: View {
    let section: SceneSection
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = TimecodeScanner()
    @State private var selectedFps: Double = 25
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(language.t("recMarkersSync.hint"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if scanner.authorizationDenied {
                    ContentUnavailableView(
                        language.t("recMarkersSync.cameraPermissionDenied"),
                        systemImage: "camera.fill"
                    )
                    .frame(height: 160)
                } else {
                    CameraPreviewView(session: scanner.session)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2), lineWidth: 1))
                        .padding(.horizontal)
                }

                VStack(spacing: 6) {
                    if let detected = scanner.detectedTimecode {
                        HStack(spacing: 8) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(detected)
                                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                                .monospacedDigit()
                        }
                    } else {
                        Text(language.t("recMarkersSync.noTimecodeDetected"))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text(language.t("recMarkersSync.framerate"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker(language.t("recMarkersSync.framerate"), selection: $selectedFps) {
                        ForEach(ShotListView.fpsPresets, id: \.self) { preset in
                            Text("\(ShotListView.fpsLabel(preset)) fps").tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                }
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        applySync()
                    } label: {
                        HStack {
                            Spacer()
                            if isApplying {
                                ProgressView().tint(.white)
                            } else {
                                Text(language.t("recMarkersSync.apply")).fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
                    .padding(.horizontal)

                    Button(language.t("recMarkersSync.manualFallback")) {
                        applyManual()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .disabled(isApplying)
                }
                .padding(.bottom, 12)
            }
            .padding(.top, 12)
            .navigationTitle(language.t("recMarkersSync.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("common.cancel")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    private func applySync() {
        guard let detected = scanner.detectedTimecode, let capturedAt = scanner.detectedAt else {
            applyManual()
            return
        }
        let offset = Self.offsetSeconds(forDetectedTimecode: detected, capturedAt: capturedAt) ?? 0
        apply(offsetSeconds: offset)
    }

    /// No camera reading yet (or the user just wants to skip it) — same as
    /// today's old plain "Set Framerate" menu, offset 0 (trusts this
    /// device's own clock, matching the old Time-of-Day assumption).
    private func applyManual() {
        apply(offsetSeconds: 0)
    }

    private func apply(offsetSeconds: Double) {
        isApplying = true
        Task {
            await viewModel.setSectionTimecode(section, fps: selectedFps, offsetSeconds: offsetSeconds)
            isApplying = false
            dismiss()
        }
    }

    /// Parses "HH:MM:SS:FF" into today's calendar date at that time
    /// (frames dropped — sub-second precision beyond what a wall-clock
    /// offset needs here), then computes (that date) − (the moment the
    /// frame was actually captured) — NOT the moment "Übernehmen" was
    /// tapped, so a brief pause before confirming doesn't skew the
    /// calibration.
    private static func offsetSeconds(forDetectedTimecode timecode: String, capturedAt: Date) -> Double? {
        let parts = timecode.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: capturedAt)
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = parts[2]
        guard let cameraDate = Calendar.current.date(from: comps) else { return nil }
        return cameraDate.timeIntervalSince(capturedAt)
    }
}

/// Thin UIViewRepresentable wrapper around AVCaptureVideoPreviewLayer —
/// the standard way to show a live camera feed inside SwiftUI.
private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Runs the phone's camera + Vision text recognition to read a physical
/// camera's own on-screen/on-display running timecode — see
/// RecMarkersSyncSheet's own doc comment for the full feature context.
/// **NEW and UNVERIFIED on a real device.**
final class TimecodeScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var detectedTimecode: String?
    @Published var detectedAt: Date?
    @Published var authorizationDenied = false

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "ch.subshot.timecode-scanner.sample")
    /// Throttles Vision requests — running text recognition on every
    /// single frame (up to 30-60/s) would be wasteful and can visibly lag
    /// the camera preview; a detection every ~0.3s is more than fast
    /// enough for a "hold steady over the display" calibration gesture.
    /// Only ever read/written from `captureOutput` below, which
    /// AVFoundation guarantees runs serialized on `sampleQueue` — no
    /// extra locking needed despite being a plain var.
    private var lastRequestAt = Date.distantPast
    private let minRequestInterval: TimeInterval = 0.3

    /// `\d{2}[:;.]\d{2}[:;.]\d{2}[:;.]\d{2}` — HH:MM:SS:FF (or SS;FF for
    /// drop-frame, or a "." separator some camera fonts render instead of
    /// ":"/";"), tolerant of the exact separator character since OCR often
    /// misreads a thin colon as a period or semicolon on a small LCD/
    /// viewfinder font.
    private static let timecodePattern = try? NSRegularExpression(pattern: #"(\d{2})[:;.](\d{2})[:;.](\d{2})[:;.](\d{2})"#)

    func start() {
        Task {
            let granted = await Self.requestAccessIfNeeded()
            guard granted else {
                await MainActor.run { self.authorizationDenied = true }
                return
            }
            configureSessionIfNeeded()
            let session = self.session
            // AVCaptureSession.startRunning() is a blocking call Apple
            // explicitly documents as unsafe on the main thread.
            await Task.detached(priority: .userInitiated) {
                session.startRunning()
            }.value
        }
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    private static func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRequestAt) >= minRequestInterval else { return }
        lastRequestAt = now

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self else { return }
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      let match = Self.extractTimecode(from: candidate.string) else { continue }
                DispatchQueue.main.async {
                    self.detectedTimecode = match
                    self.detectedAt = now
                }
                return
            }
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        // .right — the standard orientation for a back-camera feed held in
        // portrait (the common way to point a phone at another device's
        // screen). UNVERIFIED: if the preview/detection looks rotated on a
        // real device, this is the first thing to try changing (.up/.left/
        // .down depending on the actual capture connection orientation).
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
    }

    private static func extractTimecode(from text: String) -> String? {
        guard let regex = timecodePattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var parts: [String] = []
        for i in 1...4 {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            parts.append(String(text[r]))
        }
        return parts.joined(separator: ":")
    }
}
