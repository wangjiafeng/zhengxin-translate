import SwiftUI
import AppKit

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await TranslationService.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ZhengxinTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("正心Translate") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 720)
        }
        .defaultSize(width: 1080, height: 800)

        Window("术语建议与检查列表", id: "utility-panel") {
            UtilityPanelView()
                .environmentObject(state)
                .frame(minWidth: 420, minHeight: 660)
        }
        .defaultSize(width: 460, height: 760)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
        .commands {
            ApplicationMenuCommands()
            CommandMenu("任务") {
                Button("开始翻译") { state.startTranslation() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!state.canStart)
                Button("暂停") { state.pause() }
                    .disabled(!state.canPause)
                Button("继续") { state.resume() }
                    .disabled(!state.canResume)
                Divider()
                Button("取消任务") { state.cancel() }
                    .disabled(!state.canCancel)
            }
        }
    }
}

struct ApplicationMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于正心Translate") { AboutPanel.show() }
        }

        CommandGroup(replacing: .help) {
            Button("正心Translate 帮助") { HelpWindowController.shared.show() }
            Divider()
            Button("访问官网") { openWebsite("https://translate.zhengxinshushe.com") }
            Button("获取更新与支持") { openWebsite("https://translate.zhengxinshushe.com/download.php") }
            Button("反馈问题") { openWebsite("https://translate.zhengxinshushe.com/download.php#feedback") }
        }
    }

    private func openWebsite(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "V" + (info["CFBundleShortVersionString"] as? String ?? "1.0")
        let build = info["CFBundleVersion"] as? String ?? "1"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let applicationIcon = NSApp.applicationIconImage ?? NSImage()
        let credits = NSAttributedString(
            string: "基于 TranslateGemma 4B、llama.cpp\n与 BookForge 编译\n发布时间：2026年9月20日",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "正心Translate",
            .applicationVersion: version,
            .version: build,
            .applicationIcon: applicationIcon,
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = NSHostingController(rootView: HelpDocumentView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "正心Translate 帮助"
        window.contentMinSize = NSSize(width: 660, height: 620)
        window.contentViewController = content
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct HelpBlock: Identifiable {
    enum Kind { case title, section, subsection, paragraph, bullet }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct HelpDocumentView: View {
    private let blocks: [HelpBlock]

    init() {
        let markdown: String
        if let url = Bundle.main.url(forResource: "正心Translate帮助", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            markdown = content
        } else {
            markdown = "# 正心Translate 帮助\n\n帮助文件未能载入，请访问 https://translate.zhengxinshushe.com 获取支持。"
        }
        blocks = Self.parse(markdown)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block.kind {
        case .title:
            Text(inlineMarkdown(block.text))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.primary)
                .padding(.bottom, 8)
        case .section:
            Text(inlineMarkdown(block.text))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.primary)
                .padding(.top, 20)
                .padding(.bottom, 2)
        case .subsection:
            Text(inlineMarkdown(block.text))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .padding(.top, 10)
        case .paragraph:
            Text(inlineMarkdown(block.text))
                .font(.system(size: 14))
                .foregroundStyle(Color.primary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("•").font(.system(size: 14, weight: .semibold))
                Text(inlineMarkdown(block.text))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 10)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func parse(_ markdown: String) -> [HelpBlock] {
        var result: [HelpBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(HelpBlock(kind: .paragraph, text: paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("### ") {
                flushParagraph()
                result.append(HelpBlock(kind: .subsection, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                result.append(HelpBlock(kind: .section, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                result.append(HelpBlock(kind: .title, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                result.append(HelpBlock(kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return result
    }
}
