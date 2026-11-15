import Foundation

actor ModelManager {
    static let shared = ModelManager()
    static let expectedFileName = "translategemma-4b-it.Q4_K_M.gguf"
    static let expectedSHA256 = "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330"
    static let expectedSize: Int64 = 2_489_909_760

    func modelURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["ZHENGXIN_MODEL_PATH"] {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("正心Translate/Models/\(Self.expectedFileName)"))
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/正心Translate/Models/\(Self.expectedFileName)"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    func validateInstalledModel() async -> ModelStatus {
        guard let url = modelURL() else { return .missing }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return .invalid("模型路径不是普通文件") }
            let size = Int64(values.fileSize ?? 0)
            guard size == Self.expectedSize else {
                return .invalid("文件大小不符：\(size) 字节")
            }
            let magic = try FileHandle(forReadingFrom: url).read(upToCount: 4)
            guard magic == Data([0x47, 0x47, 0x55, 0x46]) else { return .invalid("文件头不是 GGUF") }
            let checksum = try await checksum(of: url)
            guard checksum == Self.expectedSHA256 else { return .invalid("SHA-256 不匹配") }
            return .ready(path: url.path, size: size)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private func checksum(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            process.arguments = ["-a", "256", url.path]
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AppError.processFailed("无法计算模型校验和")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        }.value
    }
}

enum AppError: LocalizedError {
    case unsupportedFile(String)
    case scannedPDF
    case emptyDocument
    case processFailed(String)
    case runtimeMissing
    case modelMissing
    case serverFailed(String)
    case translationFailed(String)
    case invalidResponse
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext): return "暂不支持 .\(ext) 文件"
        case .scannedPDF: return "此 PDF 没有可提取文字层；V1 仅支持文本型 PDF"
        case .emptyDocument: return "文档中没有可翻译的正文"
        case .processFailed(let text): return text
        case .runtimeMissing: return "未找到 llama-server 运行组件"
        case .modelMissing: return "未找到 TranslateGemma GGUF 模型"
        case .serverFailed(let text): return "本地推理服务启动失败：\(text)"
        case .translationFailed(let text): return "本地翻译请求失败：\(text)"
        case .invalidResponse: return "模型返回了无法解析的结果"
        case .exportFailed(let text): return "输出失败：\(text)"
        }
    }
}

