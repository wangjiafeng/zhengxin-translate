import Foundation

actor TranslationService {
    static let shared = TranslationService()

    func shutdown() async { await runtime.shutdown() }
    private let runtime = LlamaRuntime()

    func translate(
        document: ParsedDocument,
        sourceLanguage: String,
        targetLanguage: String,
        glossary: [GlossaryItem],
        control: JobControl,
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> [TranslatedSegment] {
        let mock = ProcessInfo.processInfo.environment["ZHENGXIN_TRANSLATE_MOCK"] == "1"
        if !mock { try await runtime.ensureRunning() }
        var output: [TranslatedSegment] = []
        output.reserveCapacity(document.segments.count)

        for (index, segment) in document.segments.enumerated() {
            try Task.checkCancellation()
            try await control.checkpoint()

            if segment.kind == .code {
                output.append(.init(source: segment, translation: segment.text))
            } else {
                let translated: String
                if mock {
                    try await Task.sleep(for: .milliseconds(30))
                    translated = "[\(targetLanguage)] \(segment.text)"
                } else {
                    translated = try await runtime.translate(
                        text: segment.text,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                }
                output.append(.init(source: segment, translation: Self.applyLockedGlossary(translated, glossary: glossary)))
            }
            progress(index + 1, document.segments.count, segment.location)
        }
        return output
    }

    private static func applyLockedGlossary(_ text: String, glossary: [GlossaryItem]) -> String {
        glossary.filter { $0.locked && !$0.target.isEmpty }.reduce(text) { partial, item in
            partial.replacingOccurrences(of: item.source, with: item.target, options: [.caseInsensitive])
        }
    }
}

actor LlamaRuntime {
    private var process: Process?
    private let port = 18_765
    private var logHandle: FileHandle?
    private var logURL: URL?

    func shutdown() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func ensureRunning() async throws {
        if await isHealthy() { return }
        guard let modelURL = await ModelManager.shared.modelURL() else { throw AppError.modelMissing }
        guard let binaryURL = locateBinary() else { throw AppError.runtimeMissing }

        let process = Process()
        // Unread pipes fill up and block llama.cpp's logging thread, which can
        // then stall inference while /health continues to report success.
        let logDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("正心Translate/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("llama-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        self.logURL = logURL
        self.logHandle = logHandle
        process.executableURL = binaryURL
        process.arguments = [
            "--host", "127.0.0.1", "--port", String(port),
            "-m", modelURL.path, "-c", "8192", "-np", "1",
            "--no-jinja", "--chat-template", "gemma",
            "-ngl", gpuLayerCount
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        self.process = process

        for _ in 0..<180 {
            if await isHealthy() { return }
            if !process.isRunning {
                let data = (try? Data(contentsOf: logURL)) ?? Data()
                let message = String(decoding: data, as: UTF8.self)
                throw AppError.serverFailed(message.isEmpty ? "进程已退出" : message)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        process.terminate()
        throw AppError.serverFailed("90 秒内未能加载模型")
    }

    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        try Task.checkCancellation()
        // Bound input by UTF-8 bytes, rather than characters: token density varies
        // widely between languages. Keep ample room for the prompt and translation.
        if text.utf8.count > 1800 {
            return try await translateParts(text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        }
        let source = sourceLanguage == "auto" ? Self.detectLanguage(in: text) : sourceLanguage
        let sourceName = Self.languageName(for: source)
        let targetName = Self.languageName(for: targetLanguage)
        let prompt = "You are a professional \(sourceName) (\(source)) to \(targetName) (\(targetLanguage)) translator. Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities.\nProduce only the \(targetName) translation, without any additional explanations or commentary. Please translate the following \(sourceName) text into \(targetName):\n\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        let body: [String: Any] = [
            "model": "translategemma-4b-it",
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
            "top_p": 0.95,
            "max_tokens": 1536,
            "stream": false
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any],
               error["type"] as? String == "exceed_context_size_error", text.count > 1 {
                return try await translateParts(text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            }
            throw AppError.translationFailed(String(decoding: data, as: UTF8.self))
        }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AppError.invalidResponse }
        if choices.first?["finish_reason"] as? String == "length" {
            guard text.count > 1 else { throw AppError.translationFailed("译文超过输出长度限制") }
            return try await translateParts(text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translateParts(_ text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        let parts = Self.splitText(text)
        guard parts.count == 2 else { throw AppError.translationFailed("无法继续拆分超长段落") }
        // Detect once for the entire original paragraph, including mixed-language text.
        let source = sourceLanguage == "auto" ? Self.detectLanguage(in: text) : sourceLanguage
        var translations: [String] = []
        for part in parts {
            try Task.checkCancellation()
            translations.append(try await translate(text: part, sourceLanguage: source, targetLanguage: targetLanguage))
        }
        return translations.joined(separator: "\n")
    }

    static func splitText(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return [text] }
        let midpoint = characters.count / 2
        let lower = max(1, characters.count / 4)
        let upper = min(characters.count - 1, characters.count * 3 / 4)
        let boundaries = Set<Character>("。！？；.!?;\n ")
        let split = (lower...upper).filter { boundaries.contains(characters[$0 - 1]) }
            .min { abs($0 - midpoint) < abs($1 - midpoint) } ?? midpoint
        return [String(characters[..<split]), String(characters[split...])]
    }

    private static func languageName(for code: String) -> String {
        LanguageOption.englishName(for: code)
    }

    private static func detectLanguage(in text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { scalar in (0x3040...0x30FF).contains(Int(scalar.value)) }) { return "ja" }
        if scalars.contains(where: { scalar in (0xAC00...0xD7AF).contains(Int(scalar.value)) }) { return "ko" }
        if scalars.contains(where: { scalar in (0x4E00...0x9FFF).contains(Int(scalar.value)) }) { return "zh-CN" }
        if scalars.contains(where: { scalar in (0x0400...0x04FF).contains(Int(scalar.value)) }) { return "ru" }
        return "en"
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func locateBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["ZHENGXIN_LLAMA_SERVER"] {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Runtime/\(architecture)/llama-server"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/llama-server"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private var gpuLayerCount: String {
        #if arch(arm64)
        return "99"
        #else
        return "0"
        #endif
    }
}

