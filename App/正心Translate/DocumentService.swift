import Foundation
import PDFKit

actor DocumentService {
    static let shared = DocumentService()

    func parse(url: URL) async throws -> ParsedDocument {
        try await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "txt": return try Self.parsePlainText(url)
            case "md", "markdown": return try Self.parseMarkdown(url)
            case "pdf": return try Self.parsePDF(url)
            case "docx": return try Self.parseArchive(url, type: .docx)
            case "epub": return try Self.parseArchive(url, type: .epub)
            default: throw AppError.unsupportedFile(ext)
            }
        }.value
    }

    private static func parsePlainText(_ url: URL) throws -> ParsedDocument {
        let text = try readText(url)
        let chunks = text.components(separatedBy: "\n\n")
        let segments = chunks.enumerated().compactMap { index, chunk -> DocumentSegment? in
            let clean = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            return .init(id: "txt-\(index + 1)", kind: .paragraph, text: clean, location: "段落 \(index + 1)")
        }
        guard !segments.isEmpty else { throw AppError.emptyDocument }
        return .init(title: url.deletingPathExtension().lastPathComponent, segments: segments)
    }

    private static func parseMarkdown(_ url: URL) throws -> ParsedDocument {
        let text = try readText(url)
        var segments: [DocumentSegment] = []
        var buffer: [String] = []
        var inCode = false
        var index = 0

        func flush(kind: SegmentKind = .paragraph) {
            let clean = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { buffer.removeAll(); return }
            index += 1
            segments.append(.init(id: "md-\(index)", kind: kind, text: clean, location: "Markdown 段落 \(index)"))
            buffer.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { buffer.append(line); flush(kind: .code) } else { flush(); buffer.append(line) }
                inCode.toggle(); continue
            }
            if inCode { buffer.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flush(); buffer = [trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)]; flush(kind: .heading)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush(); buffer = [trimmed.replacingOccurrences(of: "^[-*]\\s*", with: "", options: .regularExpression)]; flush(kind: .listItem)
            } else if trimmed.isEmpty { flush() }
            else { buffer.append(line) }
        }
        flush(kind: inCode ? .code : .paragraph)
        guard !segments.isEmpty else { throw AppError.emptyDocument }
        return .init(title: url.deletingPathExtension().lastPathComponent, segments: segments)
    }

    private static func parsePDF(_ url: URL) throws -> ParsedDocument {
        guard let pdf = PDFDocument(url: url) else { throw AppError.unsupportedFile("pdf") }
        var segments: [DocumentSegment] = []
        var characterCount = 0
        for pageIndex in 0..<pdf.pageCount {
            guard let text = pdf.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            characterCount += text.count
            let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                segments.append(.init(
                    id: "pdf-p\(pageIndex + 1)-\(paragraphIndex + 1)",
                    kind: .paragraph,
                    text: paragraph.trimmingCharacters(in: .whitespacesAndNewlines),
                    location: "第 \(pageIndex + 1) 页"
                ))
            }
        }
        guard characterCount >= 20 else { throw AppError.scannedPDF }
        return .init(title: url.deletingPathExtension().lastPathComponent, segments: segments)
    }

    private enum ArchiveType { case docx, epub }

    private static func parseArchive(_ url: URL, type: ArchiveType) throws -> ParsedDocument {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("zhengxin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try unzip(url, to: temporary)

        let files: [URL]
        switch type {
        case .docx:
            let documentXML = temporary.appendingPathComponent("word/document.xml")
            guard FileManager.default.fileExists(atPath: documentXML.path) else { throw AppError.unsupportedFile("docx") }
            files = [documentXML]
        case .epub:
            let enumerator = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil)
            files = (enumerator?.allObjects as? [URL] ?? [])
                .filter { ["xhtml", "html", "htm"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.lowercased().contains("nav") }
                .sorted { $0.path < $1.path }
        }

        var segments: [DocumentSegment] = []
        for (fileIndex, file) in files.enumerated() {
            let extractor = XMLBlockExtractor(prefix: type == .docx ? "docx" : "epub", fileIndex: fileIndex)
            guard let parser = XMLParser(contentsOf: file) else { continue }
            parser.delegate = extractor
            parser.shouldResolveExternalEntities = false
            _ = parser.parse()
            segments.append(contentsOf: extractor.segments)
        }
        guard !segments.isEmpty else { throw AppError.emptyDocument }
        return .init(title: url.deletingPathExtension().lastPathComponent, segments: segments)
    }

    private static func unzip(_ source: URL, to destination: URL) throws {
        // ditto rejects some readable EPUB ZIPs whose stored mimetype entry uses
        // a data descriptor. unzip reads their central directory correctly.
        // Write diagnostics to disk: an unread Pipe can block a noisy subprocess.
        let diagnosticURL = destination.appendingPathComponent(".unzip-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil) else {
            throw AppError.processFailed("无法创建文档解压日志")
        }
        let diagnostics = try FileHandle(forWritingTo: diagnosticURL)
        defer {
            try? diagnostics.close()
            try? FileManager.default.removeItem(at: diagnosticURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", source.path, "-d", destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: diagnosticURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 4096) ?? Data()
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.processFailed("无法解压文档容器（unzip 退出码 \(process.terminationStatus)）\(detail.isEmpty ? "" : "：\(detail)")")
        }
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .utf16) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        throw AppError.processFailed("无法识别文本编码")
    }
}

private final class XMLBlockExtractor: NSObject, XMLParserDelegate {
    private let prefix: String
    private let fileIndex: Int
    private var current = ""
    private var index = 0
    private var activeBlock: SegmentKind?
    var segments: [DocumentSegment] = []

    init(prefix: String, fileIndex: Int) { self.prefix = prefix; self.fileIndex = fileIndex }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        if ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "td", "th"].contains(name) {
            flush()
            activeBlock = name.hasPrefix("h") ? .heading : (name == "li" ? .listItem : (["td", "th"].contains(name) ? .tableCell : .paragraph))
        }
        if name == "tab" { current.append("\t") }
        if name == "br" { current.append("\n") }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if activeBlock != nil { current.append(string) } }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        if ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "td", "th"].contains(name) { flush() }
    }

    func parserDidEndDocument(_ parser: XMLParser) { flush() }

    private func flush() {
        let clean = current.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            index += 1
            segments.append(.init(id: "\(prefix)-\(fileIndex + 1)-\(index)", kind: activeBlock ?? .paragraph, text: clean, location: "文档单元 \(fileIndex + 1) · 段落 \(index)"))
        }
        current = ""
        activeBlock = nil
    }
}

enum TermExtractor {
    static func suggestions(from segments: [DocumentSegment]) -> [GlossaryItem] {
        let text = segments.prefix(500).map(\.text).joined(separator: "\n")
        let pattern = #"\b[A-Z][A-Za-z0-9]*(?:[ -][A-Z][A-Za-z0-9]*){0,3}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var counts: [String: Int] = [:]
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let swiftRange = Range(match.range, in: text) else { return }
            let term = String(text[swiftRange])
            guard term.count > 2, !["The", "This", "That", "And", "For"].contains(term) else { return }
            counts[term, default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(40).map { term, count in
            let context = segments.first(where: { $0.text.contains(term) })?.text ?? ""
            return GlossaryItem(source: term, occurrences: count, context: context)
        }
    }
}

