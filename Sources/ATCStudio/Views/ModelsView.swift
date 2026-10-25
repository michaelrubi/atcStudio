import RestorationStation
import SwiftUI

/// Download state for the six models, plus the shared pipeline that uses them.
@MainActor @Observable
final class ModelManager {
    enum Status: Equatable {
        case missing
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var status: [PipelineModel: Status] = [:]
    private(set) var isWorking = false
    private(set) var message: String?
    private var pipelineInstance: MLPipelineActor?

    init() {
        refresh()
    }

    var allReady: Bool { PipelineModel.allCases.allSatisfy { status[$0] == .ready } }

    func refresh() {
        for model in PipelineModel.allCases where !isWorking {
            status[model] = model.isDownloaded ? .ready : .missing
        }
    }

    /// One pipeline for the whole app, so models load once.
    func pipeline() throws -> MLPipelineActor {
        if let pipelineInstance { return pipelineInstance }
        let made = MLPipelineActor(ffmpeg: try FFmpegRunner.locate())
        pipelineInstance = made
        return made
    }

    /// Downloads whatever is missing, then loads every model once for the Neural Engine.
    func downloadAll() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            for model in PipelineModel.allCases where !model.isDownloaded {
                status[model] = .downloading(0)
                do {
                    try await model.download { fraction in
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.status[model] { self?.status[model] = .downloading(fraction) }
                        }
                    }
                    status[model] = .ready
                } catch {
                    status[model] = .failed(error.localizedDescription)
                    message = "\(model.name) did not download. Check the internet connection and try again."
                    return
                }
            }

            message = "Restoration Station: Preparing models for this Mac's Neural Engine…"
            do {
                try await pipeline().warmUp { model, fraction in
                    Task { @MainActor [weak self] in
                        self?.status[model] = fraction < 1 ? .preparing : .ready
                    }
                }
                message = nil
            } catch {
                message = "Models downloaded, but preparing them failed: \(error.localizedDescription)"
            }
        }
    }
}

struct ModelsView: View {
    @Environment(ModelManager.self) private var models
    var onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restoration Station Models").font(.title2.weight(.semibold))
                Text("ATC Studio uses six on-device models. They download once (about 0.9 GB), then work with no internet. Your audio never leaves this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(PipelineModel.allCases) { model in
                    ModelRow(model: model, status: models.status[model] ?? .missing)
                    if model != PipelineModel.allCases.last { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))

            if let message = models.message {
                Text(message).foregroundStyle(.secondary)
            }
            if !MLPipelineActor.titleRuntimeAvailable {
                Label("This build cannot run Title. Build the app with Xcode (xcodebuild) to get title suggestions.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                Link("On-device AI by Desert Ant Labs 🐜", destination: URL(string: "https://desertant.com")!)
                    .font(.callout)
                Spacer()
                if models.allReady && !models.isWorking {
                    Label("All models ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    if let onDone { Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
                } else {
                    if let onDone { Button("Later", action: onDone) }
                    Button(models.isWorking ? "Downloading…" : "Download All") { models.downloadAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(models.isWorking)
                }
            }
        }
        .padding()
    }
}

private struct ModelRow: View {
    let model: PipelineModel
    let status: ModelManager.Status

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.headline)
                Text(model.purpose).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .missing:
                Text("Not downloaded").foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 140)
                Text("\(Int(fraction * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
            }
        }
        .padding(.vertical, 10)
    }
}
