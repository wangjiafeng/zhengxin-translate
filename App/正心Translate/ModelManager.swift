import Foundation

struct ModelDownloadSource: Sendable {
    let name: String
    let url: URL
    let size: Int64
    let sha256: String

    static let huggingFace = ModelDownloadSource(
        name: "Hugging Face · MoMonir",
        url: URL(string: "https://huggingface.co/MoMonir/translategemma-4b-it-GGUF/resolve/main/translategemma-4b-it-Q4_K_M.gguf")!,
        size: 2_489_909_216,
        sha256: "9056dcfb6f0b2fe4fe2a2597559156d30b00241edc70e819a85f380716c8c615")

}

actor ModelManager {
    static let shared = ModelManager()
    static let expectedFileName = "translategemma-4b-it.Q4_K_M.gguf"
    // Continue accepting the model supported by earlier releases.
    static let expectedSHA256 = "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330"
    static let expectedSize: Int64 = 2_489_909_760

    private let source: ModelDownloadSource
    private let installationDirectory: URL?
    private var isDownloading = false
    private let connectionTimeout: TimeInterval
    private let stallTimeout: TimeInterval

    init(source: ModelDownloadSource = .huggingFace,
         installationDirectory: URL? = nil,
         connectionTimeout: TimeInterval = 20, stallTimeout: TimeInterval = 30) {
        self.connectionTimeout = connectionTimeout
        self.stallTimeout = stallTimeout
        self.source = source
        self.installationDirectory = installationDirectory
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void,
                       activity: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
                       verifying: @escaping @Sendable () -> Void = {}) async throws {
        guard !isDownloading else { throw AppError.processFailed("模型正在下载，请稍候") }
        isDownloading = true
        defer { isDownloading = false }
        let fm = FileManager.default
        let directory: URL
        if let installationDirectory {
            directory = installationDirectory
        } else {
            directory = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
                .appendingPathComponent("正心Translate/Models", isDirectory: true)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.expectedFileName)
        try await download(source, to: destination, progress: progress, activity: activity, verifying: verifying)
    }

    private func download(_ source: ModelDownloadSource, to destination: URL,
                          progress: @escaping @Sendable (Double) -> Void,
                          activity: @escaping @Sendable (Int64, Int64) -> Void,
                          verifying: @escaping @Sendable () -> Void) async throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).download")
        defer { try? fm.removeItem(at: staging) }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(connectionTimeout, stallTimeout) + 5
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegate = ModelDownloadProgress(expectedSize: source.size, progress: progress, activity: activity)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let connectionTimeout = self.connectionTimeout
        let stallTimeout = self.stallTimeout
        let watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if delegate.checkTimeout(connection: connectionTimeout, stall: stallTimeout) {
                    session.invalidateAndCancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        let response: URLResponse
        do {
            response = try await delegate.download(session: session, from: source.url, to: staging)
        } catch {
            throw AppError.processFailed(delegate.timeoutReason ?? Self.downloadErrorDescription(error, url: source.url))
        }
        // Stop the network watchdog before filesystem work and checksum validation.
        watchdog.cancel()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppError.processFailed("下载服务器返回 HTTP \(code)，未取得完整模型文件。地址：\(source.url.host ?? "")。请检查网络或代理后重试。")
        }
        verifying()
        let status = await validateModel(at: staging, allowed: [source])
        guard case .ready = status else {
            if case .invalid(let reason) = status { throw AppError.processFailed("下载模型校验失败：\(reason)") }
            throw AppError.modelMissing
        }
        try Task.checkCancellation()
        // Publish only a fully verified model; never overwrite an existing file.
        try fm.moveItem(at: staging, to: destination)
    }

    static func downloadErrorDescription(_ error: Error, url: URL) -> String {
        let ns = error as NSError
        let advice: String
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut): advice = "连接或数据传输超时，请检查网络和代理后重试。"
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost): advice = "网络连接中断，请检查代理节点及下载站点的连接后重试。"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): advice = "当前没有可用网络，请联网后重试。"
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed): advice = "无法解析下载站点，请检查 DNS 或代理后重试。"
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost): advice = "无法连接下载服务器，请检查网络或代理后重试。"
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted): advice = "HTTPS 安全连接失败，请检查网络、代理和系统时间后重试。"
        default: advice = "下载失败，请检查网络或代理后重试。"
        }
        return "\(advice)\n\(ns.domain)（\(ns.code)）：\(ns.localizedDescription)\n下载站点：\(url.host ?? "未知")"
    }

    func modelURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["ZHENGXIN_MODEL_PATH"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if let installationDirectory {
            candidates.append(installationDirectory.appendingPathComponent(Self.expectedFileName))
        } else if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("正心Translate/Models/\(Self.expectedFileName)"))
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/正心Translate/Models/\(Self.expectedFileName)"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    func validateInstalledModel() async -> ModelStatus {
        guard let url = modelURL() else { return .missing }
        var allowed = [source]
        allowed.append(.init(name: "原版模型", url: url, size: Self.expectedSize, sha256: Self.expectedSHA256))
        return await validateModel(at: url, allowed: allowed)
    }

    private func validateModel(at url: URL, allowed: [ModelDownloadSource]) async -> ModelStatus {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return .invalid("模型路径不是普通文件") }
            let size = Int64(values.fileSize ?? 0)
            let matching = allowed.filter { $0.size == size }
            guard !matching.isEmpty else { return .invalid("文件大小不符：\(size) 字节") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let magic = try handle.read(upToCount: 4)
            guard magic == Data([0x47, 0x47, 0x55, 0x46]) else { return .invalid("文件头不是 GGUF") }
            let checksum = try await checksum(of: url)
            guard matching.contains(where: { $0.sha256 == checksum }) else { return .invalid("SHA-256 不匹配") }
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

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedSize: Int64
    let progress: @Sendable (Double) -> Void
    let activity: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastDataAt: TimeInterval?
    private var lastReportedAt: TimeInterval = 0
    private var timeout: String?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var task: URLSessionDownloadTask?
    private var staging: URL?
    private var fileError: Error?
    private var cancelled = false
    private var networkFinished = false

    init(expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void,
         activity: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
        self.activity = activity
    }

    func download(session: URLSession, from url: URL, to staging: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                lock.lock()
                self.continuation = continuation
                self.task = task
                self.staging = staging
                let cancelled = self.cancelled
                lock.unlock()
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    var timeoutReason: String? {
        lock.lock(); defer { lock.unlock() }
        return timeout
    }

    func checkTimeout(connection: TimeInterval, stall: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !networkFinished else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastDataAt {
            if now - lastDataAt >= stall {
                timeout = "下载已连续 \(Int(stall)) 秒未收到数据，传输已停止。请检查网络或代理，点击“重试下载模型”。"
            }
        } else if now - startedAt >= connection {
            timeout = "连接超时：\(Int(connection)) 秒内未收到模型数据。请检查网络、代理节点或 Hugging Face 连接，点击“重试下载模型”。"
        }
        return timeout != nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let firstData = lastDataAt == nil
        lastDataAt = now
        let report = firstData || now - lastReportedAt >= 0.25 || totalBytesWritten >= expectedSize
        if report { lastReportedAt = now }
        lock.unlock()
        guard report else { return }
        activity(totalBytesWritten, expectedSize)
        progress(min(1, Double(totalBytesWritten) / Double(expectedSize)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock(); networkFinished = true; lock.unlock()
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        lock.lock()
        let staging = self.staging
        lock.unlock()
        do {
            guard let staging else { throw AppError.processFailed("下载临时路径不可用") }
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            lock.lock(); fileError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let failure = fileError ?? error
        lock.unlock()
        if let failure { continuation?.resume(throwing: failure) }
        else if let response = task.response { continuation?.resume(returning: response) }
        else { continuation?.resume(throwing: AppError.processFailed("下载服务器没有返回响应")) }
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

