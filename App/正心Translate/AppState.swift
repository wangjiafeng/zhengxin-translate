import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var inputURL: URL?
    @Published var outputDirectoryURL: URL?
    @Published var sourceLanguage = LanguageOption.supported[0]
    @Published var targetLanguage = LanguageOption.supported[1]
    @Published var outputFormat: OutputFormat = .word
    @Published var outputMode: OutputMode = .translated
    @Published var modelDownloadedBytes: Int64 = 0
    @Published var modelTotalBytes: Int64 = ModelDownloadSource.huggingFace.size
    @Published var modelStatus: ModelStatus = .unchecked
    @Published var jobStatus: JobStatus = .idle
    @Published var progress = 0.0
    @Published var completedSegments = 0
    @Published var totalSegments = 0
    @Published var currentLocation = "—"
    @Published var logs: [String] = []
    @Published var glossary: [GlossaryItem] = []
    @Published var reviewItems: [ReviewItem] = []
    @Published var utilitySelection = 0

    private var modelTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    private var jobControl = JobControl()

    init() {
        appendLog("正心Translate 已启动，等待选择文件。")
        validateModel()
        let environment = ProcessInfo.processInfo.environment
        if let input = environment["ZHENGXIN_INPUT_PATH"] { inputURL = URL(fileURLWithPath: input) }
        if let output = environment["ZHENGXIN_OUTPUT_DIR"] { outputDirectoryURL = URL(fileURLWithPath: output, isDirectory: true) }
        if environment["ZHENGXIN_OUTPUT_FORMAT"] == "md" { outputFormat = .markdown }
        if environment["ZHENGXIN_OUTPUT_MODE"] == "bilingual" { outputMode = .bilingual }
        if environment["ZHENGXIN_AUTORUN"] == "1" {
            Task {
                for _ in 0..<120 {
                    if self.canStart { self.startTranslation(); return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    var architectureLabel: String {
        #if arch(arm64)
        return "Apple Silicon · llama.cpp / Metal"
        #else
        return "Intel · llama.cpp / Accelerate"
        #endif
    }

    var canStart: Bool {
        inputURL != nil && outputDirectoryURL != nil && {
            if case .ready = modelStatus { return true }
            return ProcessInfo.processInfo.environment["ZHENGXIN_TRANSLATE_MOCK"] == "1"
        }() && !isRunning
    }

    var canPause: Bool { jobStatus == .translating }
    var canResume: Bool { jobStatus == .paused }
    var canCancel: Bool { isRunning || jobStatus == .paused }
    var isRunning: Bool { jobStatus == .preparing || jobStatus == .translating || jobStatus == .exporting }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.title = "选择需要翻译的整书文件"
        panel.allowedContentTypes = ["epub", "pdf", "docx", "txt", "md"].compactMap { ext in UTType(filenameExtension: ext) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            inputURL = url
            if outputDirectoryURL == nil { outputDirectoryURL = url.deletingLastPathComponent() }
            appendLog("已选择输入文件：\(url.lastPathComponent)")
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择输出目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectoryURL = url
            appendLog("输出目录：\(url.path)")
        }
    }

    var isModelBusy: Bool { modelTask != nil }

    var modelActionTitle: String {
        if case .downloadFailed = modelStatus { return "重试下载模型" }
        return "验证本地模型"
    }

    var modelDetail: String? {
        switch modelStatus {
        case .connecting:
            return "正在建立 HTTPS 连接，20 秒内未收到数据将提示连接超时。"
        case .downloading:
            return "已下载 \(ByteCountFormatter.string(fromByteCount: modelDownloadedBytes, countStyle: .decimal)) / \(ByteCountFormatter.string(fromByteCount: modelTotalBytes, countStyle: .decimal))；连续 30 秒无数据将停止并允许重试。"
        case .downloadFailed(let reason), .invalid(let reason): return reason
        default: return nil
        }
    }

    func validateModel() {
        guard modelTask == nil else { return }
        modelDownloadedBytes = 0
        modelStatus = .checking
        appendLog("正在校验 TranslateGemma 4B 模型…")
        modelTask = Task { [self] in
            defer { modelTask = nil }
            var result = await ModelManager.shared.validateInstalledModel()
            if case .missing = result {
                modelStatus = .connecting
                appendLog("未找到模型，正在连接 Hugging Face（MoMonir）；连接成功后将下载约 2.49 GB 模型到用户 Application Support 目录。")
                do {
                    try await ModelManager.shared.downloadModel(progress: { _ in }, activity: { [weak self] received, total in
                        Task { @MainActor in
                            guard let self, self.isModelBusy else { return }
                            switch self.modelStatus {
                            case .connecting:
                                self.appendLog("已连接下载服务器，开始接收模型数据。")
                            case .downloading: break
                            default: return
                            }
                            self.modelDownloadedBytes = received
                            self.modelTotalBytes = total
                            self.modelStatus = .downloading(min(1, Double(received) / Double(total)))
                        }
                    }, verifying: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isModelBusy else { return }
                            switch self.modelStatus {
                            case .connecting, .downloading:
                                self.modelStatus = .checking
                                self.appendLog("下载完成，正在校验模型文件…")
                            default: break
                            }
                        }
                    })
                    modelStatus = .checking
                    result = await ModelManager.shared.validateInstalledModel()
                } catch {
                    modelStatus = .downloadFailed(error.localizedDescription)
                    appendLog("模型下载失败：\(error.localizedDescription)。请点击“重试下载模型”重新连接。")
                    return
                }
            }
            modelStatus = result
            switch result {
            case .ready(let path, let size):
                appendLog("模型校验通过：\((Double(size) / 1_000_000_000).formatted(.number.precision(.fractionLength(2)))) GB · \(path)")
            case .missing: appendLog("未找到模型，请点击“验证本地模型”重试自动下载。")
            case .invalid(let reason): appendLog("模型校验失败：\(reason)")
            default: break
            }
        }
    }

    func swapLanguages() {
        guard sourceLanguage.code != "auto" else { return }
        let old = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = old
    }

    func startTranslation() {
        guard canStart, let inputURL, let outputDirectoryURL else { return }
        progress = 0
        completedSegments = 0
        totalSegments = 0
        currentLocation = "正在准备"
        reviewItems.removeAll()
        glossary.removeAll()
        jobStatus = .preparing
        jobControl = JobControl()
        let control = jobControl
        appendLog("开始任务：\(inputURL.lastPathComponent)")

        jobTask = Task { [self] in
            do {
                let document = try await DocumentService.shared.parse(url: inputURL)
                totalSegments = document.segments.count
                glossary = TermExtractor.suggestions(from: document.segments)
                appendLog("解析完成：\(document.segments.count) 个翻译段落，发现 \(glossary.count) 个术语候选。")
                jobStatus = .translating

                let translated = try await TranslationService.shared.translate(
                    document: document,
                    sourceLanguage: sourceLanguage.code,
                    targetLanguage: targetLanguage.code,
                    glossary: glossary.filter { $0.state == .confirmed },
                    control: control
                ) { [weak self] completed, total, location in
                    Task { @MainActor in
                        guard let self else { return }
                        self.completedSegments = completed
                        self.totalSegments = total
                        self.progress = total == 0 ? 0 : Double(completed) / Double(total)
                        self.currentLocation = location
                    }
                }

                try Task.checkCancellation()
                jobStatus = .exporting
                currentLocation = "生成 \(outputFormat.rawValue)"
                let resultURL = try await ExportService.shared.export(
                    title: document.title,
                    segments: translated,
                    mode: outputMode,
                    format: outputFormat,
                    targetLanguage: targetLanguage.code,
                    to: outputDirectoryURL
                )
                progress = 1
                jobStatus = .completed(resultURL)
                currentLocation = resultURL.lastPathComponent
                appendLog("翻译完成：\(resultURL.path)")
                if ProcessInfo.processInfo.environment["ZHENGXIN_EXIT_AFTER_COMPLETION"] == "1" {
                    await TranslationService.shared.shutdown()
                    exit(EXIT_SUCCESS)
                }
            } catch is CancellationError {
                jobStatus = .cancelled
                appendLog("任务已安全取消，已完成状态已保留。")
            } catch {
                jobStatus = .failed(error.localizedDescription)
                appendLog("任务失败：\(error.localizedDescription)")
            }
        }
    }

    func pause() {
        Task { await jobControl.pause() }
        jobStatus = .paused
        appendLog("已请求暂停，当前段落完成后停止调度。")
    }

    func resume() {
        Task { await jobControl.resume() }
        jobStatus = .translating
        appendLog("任务继续。")
    }

    func cancel() {
        Task { await jobControl.cancel() }
        jobTask?.cancel()
    }

    func openResult() {
        if case .completed(let url) = jobStatus { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
}

