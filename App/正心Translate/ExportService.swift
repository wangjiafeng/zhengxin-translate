import Foundation

actor ExportService {
    static let shared = ExportService()

    func export(
        title: String,
        segments: [TranslatedSegment],
        mode: OutputMode,
        format: OutputFormat,
        targetLanguage: String,
        to directory: URL
    ) async throws -> URL {
        let safeTitle = sanitizeFileName(title)
        let modeSuffix = mode == .bilingual ? "bilingual" : "translated"
        let destination = uniqueURL(in: directory, baseName: "\(safeTitle).\(targetLanguage).\(modeSuffix)", extension: format.fileExtension)
        switch format {
        case .markdown:
            let markdown = renderMarkdown(title: title, segments: segments, mode: mode)
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
        case .word:
            try await DOCXWriter.write(title: title, segments: segments, mode: mode, destination: destination)
        }
        return destination
    }

    private func renderMarkdown(title: String, segments: [TranslatedSegment], mode: OutputMode) -> String {
        var output = "# \(title)\n\n"
        for item in segments {
            let source = item.source.text
            let translation = item.translation
            switch item.source.kind {
            case .heading, .title:
                let cleanSource = source.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                output += mode == .bilingual ? "## \(cleanSource)\n\n## \(translation)\n\n" : "## \(translation)\n\n"
            case .listItem:
                let cleanSource = source.replacingOccurrences(of: "^[-*]\\s*", with: "", options: .regularExpression)
                output += mode == .bilingual ? "- \(cleanSource)\n  \(translation)\n" : "- \(translation)\n"
            case .code:
                output += "\(source)\n\n"
            default:
                if mode == .bilingual { output += "\(source)\n\n> \(translation.replacingOccurrences(of: "\n", with: "\n> "))\n\n" }
                else { output += "\(translation)\n\n" }
            }
        }
        return output
    }

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = name.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "-").isEmpty ? "整书翻译" : parts.joined(separator: "-")
    }

    private func uniqueURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

private enum DOCXWriter {
    static func write(title: String, segments: [TranslatedSegment], mode: OutputMode, destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("zhengxin-docx-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            try fm.createDirectory(at: root.appendingPathComponent("_rels"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("word"), withIntermediateDirectories: true)

            try contentTypes.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
            try relationships.write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
            try styles.write(to: root.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)
            let document = renderDocument(title: title, segments: segments, mode: mode)
            try document.write(to: root.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)

            let process = Process()
            let errors = Pipe()
            process.currentDirectoryURL = root
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", "-r", destination.path, "[Content_Types].xml", "_rels", "word"]
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw AppError.exportFailed(message.isEmpty ? "无法生成 DOCX 容器" : message)
            }
        }.value
    }

    private static func renderDocument(title: String, segments: [TranslatedSegment], mode: OutputMode) -> String {
        var body = paragraph(title, style: "Title")
        for item in segments {
            let style = [SegmentKind.heading, .title].contains(item.source.kind) ? "Heading1" : "Normal"
            if mode == .bilingual { body += paragraph(item.source.text, style: style, color: "666666") }
            body += paragraph(item.translation, style: style)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(body)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
    }

    private static func paragraph(_ text: String, style: String, color: String? = nil) -> String {
        let runs = text.components(separatedBy: .newlines).enumerated().map { index, line in
            let breakTag = index == 0 ? "" : "<w:br/>"
            let colorTag = color.map { "<w:color w:val=\"\($0)\"/>" } ?? ""
            return "<w:r><w:rPr>\(colorTag)</w:rPr>\(breakTag)<w:t xml:space=\"preserve\">\(escape(line))</w:t></w:r>"
        }.joined()
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runs)</w:p>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """
    private static let relationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:sz w:val="22"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
    </w:styles>
    """
}

