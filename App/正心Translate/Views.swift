import SwiftUI

private let ink = Color(red: 0.16, green: 0.23, blue: 0.30)
private let mutedInk = Color(red: 0.36, green: 0.43, blue: 0.50)
private let gold = Color(red: 0.78, green: 0.67, blue: 0.38)
private let canvas = Color(red: 0.955, green: 0.96, blue: 0.975)

struct MainView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("整书翻译")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(ink)
                    Text("基于 TranslateGemma 4B 与 BookForge 进行本地整书翻译")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(mutedInk)
                }

                HStack(spacing: 14) {
                    Label(state.architectureLabel, systemImage: "cpu")
                    Divider().frame(height: 16)
                    Label(state.modelStatus.label, systemImage: modelIcon)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(mutedInk)

                HStack(spacing: 12) {
                    Button(state.modelActionTitle) { state.validateModel() }
                        .disabled(state.isModelBusy || state.isRunning)
                    if state.isModelBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在准备模型")
                    }
                }
                .buttonStyle(GoldButtonStyle())

                if case .downloading(let fraction) = state.modelStatus {
                    ProgressView(value: fraction, total: 1)
                        .accessibilityLabel("模型下载进度")
                }
                if let detail = state.modelDetail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FormGrid {
                    FormRow(title: "输入文件") {
                        ReadOnlyPath(text: state.inputURL?.path ?? "EPUB、文本型 PDF、DOCX、TXT 或 MD", selectionLabel: "选择输入文件", action: state.chooseInput)
                    }
                    FormRow(title: "输出目录") {
                        ReadOnlyPath(text: state.outputDirectoryURL?.path ?? "翻译结果保存位置", selectionLabel: "选择输出目录", action: state.chooseOutputDirectory)
                    }
                    FormRow(title: "翻译语言") {
                        LanguageSelector(title: "源语言", selection: $state.sourceLanguage, allowsAutomatic: true)
                        Button { state.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                            .buttonStyle(.borderless)
                            .help("交换源语言和目标语言")
                        LanguageSelector(title: "目标语言", selection: $state.targetLanguage, allowsAutomatic: false)
                    }
                    FormRow(title: "输出格式") {
                        Picker("输出格式", selection: $state.outputFormat) {
                            ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(maxWidth: 360)
                        Text("统一输出为可继续校订的 Word 或 Markdown。")
                            .font(.system(size: 12)).foregroundStyle(mutedInk)
                    }
                    FormRow(title: "输出模式") {
                        Picker("输出模式", selection: $state.outputMode) {
                            ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }

                HStack(spacing: 12) {
                    Button(state.canCancel ? "取消翻译" : "开始翻译") {
                        if state.canCancel { state.cancel() } else { state.startTranslation() }
                    }
                    .buttonStyle(GoldButtonStyle(width: 132))
                    .disabled(!state.canCancel && !state.canStart)
                    Button(state.canResume ? "继续" : "暂停") {
                        if state.canResume { state.resume() } else { state.pause() }
                    }
                    .buttonStyle(GoldButtonStyle(width: 88))
                    .disabled(!state.canPause && !state.canResume)
                    Button("术语建议") { state.utilitySelection = 0; openWindow(id: "utility-panel") }
                        .buttonStyle(GoldButtonStyle(width: 108))
                    Button("检查列表") { state.utilitySelection = 1; openWindow(id: "utility-panel") }
                        .buttonStyle(GoldButtonStyle(width: 108))
                    Button("打开结果") { state.openResult() }
                        .buttonStyle(GoldButtonStyle(width: 108))
                        .disabled({ if case .completed = state.jobStatus { return false }; return true }())
                }

                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: state.progress)
                        .tint(gold)
                    HStack {
                        Text(state.jobStatus.label)
                        Spacer()
                        Text("\(state.completedSegments) / \(state.totalSegments)")
                        Text("·")
                        Text(state.currentLocation)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mutedInk)
                }

                Text("任务日志")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(state.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(mutedInk)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .frame(minHeight: 170)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
                    .onChange(of: state.logs.count) { _, count in if count > 0 { proxy.scrollTo(count - 1) } }
                }
            }
            .padding(34)
        }
        .background(canvas)
    }

    private var modelIcon: String {
        if case .ready = state.modelStatus { return "checkmark.seal.fill" }
        if case .checking = state.modelStatus { return "arrow.triangle.2.circlepath" }
        if case .connecting = state.modelStatus { return "network" }
        if case .downloading = state.modelStatus { return "arrow.down.circle" }
        return "exclamationmark.triangle"
    }
}

struct FormGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 13) { content }.frame(maxWidth: .infinity) }
}

struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        GridRow {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink).frame(width: 82, alignment: .leading)
            HStack(spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ReadOnlyPath: View {
    let text: String
    let selectionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(text.hasPrefix("/") ? ink : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                Image("PathSearch")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .frame(width: 27, height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PathSearchButtonStyle())
            .accessibilityLabel(selectionLabel)
            .help(selectionLabel)
        }
        .frame(maxWidth: .infinity, minHeight: 25)
        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(gold.opacity(0.48)))
    }
}

private struct PathSearchButtonStyle: ButtonStyle {
    @State private var isHovered = false
    private let activeColor = Color(red: 206.0 / 255, green: 186.0 / 255, blue: 123.0 / 255)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? activeColor : mutedInk)
            .onHover { isHovered = $0 }
    }
}

struct GoldButtonStyle: ButtonStyle {
    var width: CGFloat? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: width)
            .frame(minHeight: 28)
            .padding(.horizontal, width == nil ? 16 : 0)
            .background(gold.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct UtilityPanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""

    var body: some View {
        VStack(spacing: 14) {
            Picker("工具", selection: $state.utilitySelection) {
                Text("术语建议").tag(0)
                Text("检查列表").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $query).textFieldStyle(.plain)
            }
            .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))

            if state.utilitySelection == 0 { glossaryList } else { reviewList }
        }
        .padding(18)
        .background(canvas)
    }

    private var glossaryList: some View {
        List {
            ForEach($state.glossary.filter { query.isEmpty || $0.wrappedValue.source.localizedCaseInsensitiveContains(query) }) { $item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(item.source).font(.headline)
                        Spacer()
                        Text("出现 \(item.occurrences) 次").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("输入确认译法", text: $item.target)
                    Text(item.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Button("确认") { item.state = .confirmed }
                        Button("忽略") { item.state = .ignored }
                        Toggle("锁定", isOn: $item.locked).toggleStyle(.checkbox)
                        Spacer()
                        Text(item.state.rawValue).font(.caption).foregroundStyle(gold)
                    }
                }.padding(.vertical, 6)
            }
        }
        .overlay {
            if state.glossary.isEmpty { ContentUnavailableView("暂无术语建议", systemImage: "text.book.closed", description: Text("选择文件并开始预扫描后显示。")) }
        }
    }

    private var reviewList: some View {
        List {
            ForEach($state.reviewItems.filter { query.isEmpty || $0.wrappedValue.reason.localizedCaseInsensitiveContains(query) }) { $item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(item.severity.rawValue).font(.caption).foregroundStyle(item.severity == .error ? .red : .orange); Spacer(); Text(item.segmentID).font(.caption2).foregroundStyle(.secondary) }
                    Text(item.reason).font(.headline)
                    Text(item.source).font(.caption).lineLimit(3)
                    TextField("人工修正译文", text: $item.translation, axis: .vertical)
                    Toggle("已处理", isOn: $item.resolved).toggleStyle(.checkbox)
                }.padding(.vertical, 6)
            }
        }
        .overlay {
            if state.reviewItems.isEmpty { ContentUnavailableView("暂无检查项目", systemImage: "checkmark.circle", description: Text("失败段落和质量检查项会显示在这里。")) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        Form {
            LabeledContent("运行架构", value: state.architectureLabel)
            LabeledContent("模型", value: state.modelStatus.label)
            if let detail = state.modelDetail {
                Text(detail).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(state.modelActionTitle) { state.validateModel() }
                .disabled(state.isModelBusy || state.isRunning)
        }
        .padding(24).frame(width: 460)
    }
}


private struct LanguageSelector: View {
    let title: String
    @Binding var selection: LanguageOption
    let allowsAutomatic: Bool
    @State private var isPresented = false
    @State private var level = 0

    var body: some View {
        Button {
            level = 0
            isPresented = true
        } label: {
            HStack {
                Text(selection.name).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).padding(8)
                    if allowsAutomatic {
                        languageRow(LanguageOption.supported[0])
                        Divider()
                    }
                    ForEach(LanguageOption.options(at: level)) { option in
                        languageRow(option)
                    }
                    if level < 3 {
                        Divider()
                        Button { level += 1 } label: {
                            HStack {
                                Text("更多")
                                Spacer()
                                Image(systemName: "chevron.down")
                            }.padding(8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(level == 0 ? "展开到55种语言" : level == 1 ? "展开到160个基础语言" : "增加421个地区或文字变体")
                    }
                }.padding(8)
            }
            .frame(width: 340, height: 420)
        }
    }

    private func languageRow(_ option: LanguageOption) -> some View {
        Button {
            selection = option
            isPresented = false
        } label: {
            HStack {
                Text(option.name)
                Spacer()
                if selection.code == option.code { Image(systemName: "checkmark") }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
