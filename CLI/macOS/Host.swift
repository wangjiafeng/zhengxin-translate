import Foundation
import CoreFoundation
import Darwin

struct HostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Shared by CLI and MCP; no SwiftUI state or windows are created.
struct TranslationOptions {
    var source = "auto"
    var target = "zh-CN"
    var input = ""
    var output = ""
    var format = "md"
    var bilingual = false
    init(_ args: [String: Any]) throws {
        let allowed: Set<String> = ["source", "target", "input", "output", "format", "bilingual", "text", "job_id"]
        guard Set(args.keys).isSubset(of: allowed) else { throw HostError("未知参数") }
        for key in ["source", "target", "input", "output", "format", "text", "job_id"] {
            if let value = args[key], !(value is String) { throw HostError("\(key) 必须是字符串") }
        }
        if let value = args["bilingual"], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() { throw HostError("bilingual 必须是布尔值") }
        source = args["source"] as? String ?? source
        target = args["target"] as? String ?? target
        if source == "zh" { source = "zh-CN" }; if target == "zh" { target = "zh-CN" }
        input = args["input"] as? String ?? input
        output = args["output"] as? String ?? output
        format = args["format"] as? String ?? format
        bilingual = args["bilingual"] as? Bool ?? false
        guard source == "auto" || LanguageOption.supported.contains(where: { $0.code == source }),
              target != "auto", LanguageOption.supported.contains(where: { $0.code == target }) else { throw HostError("不支持的语言代码") }
        guard ["md", "docx"].contains(format) else { throw HostError("format 仅支持 md 或 docx") }
    }
    func validateFile() throws {
        guard !input.isEmpty, !output.isEmpty else { throw HostError("input 与 output 必填") }
        guard FileManager.default.fileExists(atPath: input) else { throw HostError("输入文件不存在") }
        guard URL(fileURLWithPath: input).standardizedFileURL != URL(fileURLWithPath: output).standardizedFileURL else { throw HostError("输出不能覆盖输入文件") }
        guard !FileManager.default.fileExists(atPath: output) else { throw HostError("输出已存在，拒绝覆盖") }
        guard URL(fileURLWithPath: output).pathExtension.lowercased() == format else { throw HostError("输出扩展名必须与 format 一致") }
    }
}

struct JobSnapshot: Codable {
    var job_id: String
    var status = "queued"
    var completed = 0
    var total = 0
    var output: String? = nil
    var error: String? = nil
}

actor TranslationHost {
    private let translator = TranslationService(isolated: true)
    private var jobs: [String: JobSnapshot] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    // A task chain serializes model use even when actor methods suspend.
    private var tail: Task<Void, Never> = Task {}
    private var texts: [UUID: Task<String, Error>] = [:]
    private var modelValidated = false
    private let mock = ProcessInfo.processInfo.environment["ZHENGXIN_TRANSLATE_MOCK"] == "1"

    func modelStatus() async -> [String: Any] {
        let url = await ModelManager.shared.modelURL()
        let status = await ModelManager.shared.validateInstalledModel()
        let runtime = await LlamaRuntime(isolated: true).runtimeAvailable()
        var result: [String: Any] = ["model_present": url != nil, "runtime_available": runtime, "mock": mock, "ready": false]
        if let url { result["model_path"] = url.path }
        switch status {
        case .ready: result["ready"] = runtime
        case .invalid(let reason): result["error"] = reason
        default: break
        }
        return result
    }
    private func prepare() async throws {
        if mock || modelValidated { return }
        guard case .ready = await ModelManager.shared.validateInstalledModel() else { throw HostError("模型缺失或校验失败。请先在桌面程序中准备模型，或设置 ZHENGXIN_MODEL_PATH。") }
        modelValidated = true
    }
    func text(_ text: String, options: TranslationOptions) async throws -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostError("text 不能为空") }
        let previous = tail
        let task = Task { () throws -> String in
            await previous.value
            try Task.checkCancellation()
            try await self.prepare()
            let doc = ParsedDocument(title: "Text", segments: [.init(id: "text", kind: .paragraph, text: text, location: "text")])
            let result = try await self.translator.translate(document: doc, sourceLanguage: options.source, targetLanguage: options.target, glossary: [], control: JobControl(), progress: { _, _, _ in })
            return result[0].translation
        }
        let textID = UUID()
        texts[textID] = task
        defer { texts[textID] = nil }
        tail = Task { _ = try? await task.value }
        let translated = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        return ["translation": translated, "source": options.source, "target": options.target]
    }
    func submit(_ options: TranslationOptions) throws -> JobSnapshot {
        try options.validateFile()
        guard jobs.count < 1000 else { throw HostError("当前会话任务已达上限，请重启 MCP 服务") }
        let id = UUID().uuidString
        let snapshot = JobSnapshot(job_id: id)
        jobs[id] = snapshot
        let previous = tail
        let task = Task {
            await previous.value
            await self.run(id, options: options)
        }
        tasks[id] = task; tail = task
        return snapshot
    }
    private func progress(_ id: String, _ completed: Int, _ total: Int) {
        jobs[id]?.completed = completed; jobs[id]?.total = total
    }
    private func run(_ id: String, options: TranslationOptions) async {
        do {
            try Task.checkCancellation()
            jobs[id]?.status = "preparing"
            let document = try await DocumentService.shared.parse(url: URL(fileURLWithPath: options.input))
            try Task.checkCancellation()
            try await prepare()
            jobs[id]?.total = document.segments.count; jobs[id]?.status = "translating"
            let segments = try await translator.translate(document: document, sourceLanguage: options.source, targetLanguage: options.target, glossary: [], control: JobControl()) { done, total, _ in
                Task { await self.progress(id, done, total) }
            }
            try Task.checkCancellation()
            jobs[id]?.status = "exporting"
            let destination = URL(fileURLWithPath: options.output).standardizedFileURL
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".zhengxin-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let file = try await ExportService.shared.export(title: document.title, segments: segments, mode: options.bilingual ? .bilingual : .translated, format: options.format == "docx" ? .word : .markdown, targetLanguage: options.target, to: staging)
            try Task.checkCancellation()
            // moveItem refuses to replace a destination created since submission.
            try FileManager.default.moveItem(at: file, to: destination)
            jobs[id]?.output = destination.path; jobs[id]?.completed = document.segments.count; jobs[id]?.status = "completed"
        } catch {
            jobs[id]?.status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            if jobs[id]?.status == "failed" { jobs[id]?.error = error.localizedDescription }
        }
        tasks[id] = nil
    }
    func get(_ id: String) throws -> JobSnapshot {
        guard let job = jobs[id] else { throw HostError("任务不存在：\(id)") }; return job
    }
    func cancel(_ id: String) throws -> JobSnapshot {
        _ = try get(id)
        if let task = tasks[id] { task.cancel(); jobs[id]?.status = "cancelling" }
        return try get(id)
    }
    func shutdown() async {
        for task in texts.values { task.cancel() }
        for task in tasks.values { task.cancel() }
        await tail.value
        await translator.shutdown()
    }
}

func jsonObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
func jsonString(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self) }
private let outputLock = NSLock()
func emit(_ value: Any) {
    outputLock.lock(); defer { outputLock.unlock() }
    if let text = try? jsonString(value) { print(text); fflush(stdout) }
}

actor Requests {
    private var pending: [String: Task<Void, Never>] = [:]
    func start(_ id: String, operation: @escaping () async -> Void) -> Bool {
        guard pending[id] == nil, pending.count < 128 else { return false }
        pending[id] = Task { await operation(); self.finished(id) }
        return true
    }
    private func finished(_ id: String) { pending[id] = nil }
    func cancel(_ id: String) { pending[id]?.cancel() }
    func shutdown() async {
        let tasks = Array(pending.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}
