import AVFoundation
import AudioToolbox
import SwiftUI

struct ScanRow: Identifiable {
    let id = UUID()
    let o1: String
    let l1: String
    let s1: Int = 1
}

enum ScanStep {
    case step1
    case step2

    var title: String {
        switch self {
        case .step1:
            return "Step 1/2: Scan ID QR"
        case .step2:
            return "Step 2/2: Scan Post Code128"
        }
    }
}

struct ContentView: View {
    @State private var currentStep: ScanStep = .step1
    @State private var currentO1: String = ""
    @State private var currentL1: String = ""
    @State private var rows: [ScanRow] = []

    @State private var lastScanDate: Date = .distantPast
    @State private var lastScanValue: String = ""

    @State private var messageText: String = ""
    @State private var showingShareSheet = false
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ScannerView(onScan: handleScan)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.6), lineWidth: 2)
                    )

                VStack {
                    Text(currentStep.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)

                    if currentStep == .step2 {
                        Text("Captured o1: \(currentO1)")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                    }
                }
            }
            .frame(height: 320)

            if !messageText.isEmpty {
                Text(messageText)
                    .foregroundColor(.orange)
                    .font(.callout)
            }

            Text("Total rows: \(rows.count)")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Cancel current") {
                    cancelCurrent()
                }
                .buttonStyle(.bordered)

                Button("Undo last row") {
                    undoLastRow()
                }
                .buttonStyle(.bordered)
                .disabled(rows.isEmpty)
            }

            Button("Export CSV") {
                exportCSV()
            }
            .buttonStyle(.borderedProminent)
            .disabled(rows.isEmpty)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showingShareSheet) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
    }

    private func handleScan(value: String, type: AVMetadataObject.ObjectType) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()
        if trimmed == lastScanValue, now.timeIntervalSince(lastScanDate) < 0.8 {
            return
        }

        switch currentStep {
        case .step1:
            guard type == .qr else {
                showMessage("Only QR codes accepted for Step 1")
                return
            }
            lastScanValue = trimmed
            lastScanDate = now
            AudioServicesPlaySystemSound(1108)
            currentO1 = trimmed
            currentStep = .step2
        case .step2:
            guard type == .code128 else {
                showMessage("Only Code128 accepted for Step 2")
                return
            }
            lastScanValue = trimmed
            lastScanDate = now
            AudioServicesPlaySystemSound(1108)
            currentL1 = trimmed
            rows.append(ScanRow(o1: currentO1, l1: currentL1))
            resetToStep1()
        }
    }

    private func resetToStep1() {
        currentO1 = ""
        currentL1 = ""
        currentStep = .step1
    }

    private func cancelCurrent() {
        resetToStep1()
        showMessage("Current scan canceled")
    }

    private func undoLastRow() {
        _ = rows.popLast()
        showMessage("Last row removed")
    }

    private func showMessage(_ text: String) {
        messageText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if messageText == text {
                messageText = ""
            }
        }
    }

    private func exportCSV() {
        let header = "o1,l1,s1"
        let body = rows.map { row in
            [row.o1, row.l1, String(row.s1)]
                .map(escapeCSV)
                .joined(separator: ",")
        }
        let csvString = ([header] + body).joined(separator: "\n")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "scan_export_\(formatter.string(from: Date())).csv"

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let fileURL = documents?.appendingPathComponent(filename) else {
            showMessage("Failed to create export file")
            return
        }

        do {
            try csvString.data(using: .utf8)?.write(to: fileURL)
            shareURL = fileURL
            showingShareSheet = true
        } catch {
            showMessage("Export failed: \(error.localizedDescription)")
        }
    }

    private func escapeCSV(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if needsQuotes {
            return "\"\(escaped)\""
        }
        return escaped
    }
}

struct ScannerView: UIViewControllerRepresentable {
    var onScan: (String, AVMetadataObject.ObjectType) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String, AVMetadataObject.ObjectType) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }

        session.addInput(input)

        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            return
        }

        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = metadataOutput.availableMetadataObjectTypes

        session.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue else { continue }
            onScan?(value, readable.type)
            return
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

#Preview {
    ContentView()
}
