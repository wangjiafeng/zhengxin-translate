import Foundation
import CoreFoundation
import Darwin

let help = """
正心Translate CLI v1.0.1
  zhengxin-translate text TEXT [--from auto] [--to zh-CN] [--json]
  zhengxin-translate text --stdin [--to zh-CN] [--json]
  zhengxin-translate file INPUT --output OUTPUT [--format md|docx] [--bilingual] [--from auto] [--to zh-CN] [--json]
  zhengxin-translate model-status [--json]
  zhengxin-translate mcp --stdio
模型需预先在桌面程序中准备；命令行不会自动下载模型。
"""

func catalog() throws -> [[String: Any]] {
    let directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent()
    let url = directory.appendingPathComponent("tools.json")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
}
func validate(_ arguments: [String: Any], tool: [String: Any]) throws {
    let schema = tool["inputSchema"] as! [String: Any]
    let properties = schema["properties"] as! [String: [String: Any]]
    guard Set(arguments.keys).isSubset(of: Set(properties.keys)) else { throw HostError("未知工具参数") }
    for key in schema["required"] as? [String] ?? [] {
        guard arguments[key] != nil else { throw HostError("缺少参数：\(key)") }
    }
    for (key, value) in arguments {
        let property = properties[key]!
        if property["type"] as? String == "string" {
            guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostError("\(key) 必须是非空字符串") }
        } else if CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() { throw HostError("\(key) 必须是布尔值") }
        if let choices = property["enum"] as? [String], !choices.contains(value as? String ?? "") { throw HostError("\(key) 值无效") }
    }
}

func mcp(_ host: TranslationHost) async throws {
    let tools = try catalog()
    let requests = Requests()
    var initialized = false
    var ready = false
    while let line = await Task.detached(operation: { readLine() }).value {
        var request: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]]); continue }
            request = object
        } catch { emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue }
        let id = request["id"]
        func failure(_ code: Int, _ message: String) { emit(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]) }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              id == nil || id is String || (id is NSNumber && CFGetTypeID(id! as CFTypeRef) != CFBooleanGetTypeID()) else { failure(-32600, "Invalid Request"); continue }
        if id == nil {
            if method == "notifications/initialized", initialized { ready = true }
            if method == "notifications/cancelled", let params = request["params"] as? [String: Any], let requestID = params["requestId"], let key = try? jsonString(requestID) { await requests.cancel(key) }
            continue
        }
        guard request["params"] == nil || request["params"] is [String: Any] else { failure(-32602, "params 必须是对象"); continue }
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        switch method {
        case "initialize":
            guard !initialized else { failure(-32600, "Already initialized"); continue }
            guard let version = params["protocolVersion"] as? String, params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else { failure(-32602, "Invalid initialize parameters"); continue }
            initialized = true
            result = ["protocolVersion": ["2025-11-25", "2025-06-18", "2025-03-26"].contains(version) ? version : "2025-11-25", "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "zhengxin-translate", "version": "1.0.1"], "instructions": "Document jobs are session-local and cancelled on disconnect. Poll get_job until terminal. Prepare models in the desktop app first."]
        case "ping": break
        default:
            guard ready else { failure(-32000, "Server not initialized"); continue }
            if method == "tools/list" { result = ["tools": tools] }
            else if method == "tools/call" {
                guard let name = params["name"] as? String, let tool = tools.first(where: { $0["name"] as? String == name }) else { failure(-32602, "Unknown tool"); continue }
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else { failure(-32602, "arguments 必须是对象"); continue }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do { try validate(arguments, tool: tool) } catch { failure(-32602, error.localizedDescription); continue }
                let responseID = id!
                let accepted = await requests.start(try jsonString(responseID)) {
                    let response: [String: Any]
                    do {
                        try Task.checkCancellation()
                        let options = try TranslationOptions(arguments)
                        let value: Any
                        switch name {
                        case "translate_text": value = try await host.text(arguments["text"] as! String, options: options)
                        case "submit_document": value = try jsonObject(await host.submit(options))
                        case "get_job": value = try jsonObject(await host.get(arguments["job_id"] as! String))
                        case "cancel_job": value = try jsonObject(await host.cancel(arguments["job_id"] as! String))
                        default: value = await host.modelStatus()
                        }
                        response = ["content": [["type": "text", "text": try jsonString(value)]], "isError": false]
                    } catch { response = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
                    emit(["jsonrpc": "2.0", "id": responseID, "result": response])
                }
                if !accepted { failure(-32000, "Duplicate request ID or too many pending requests") }
                continue
            } else { failure(-32601, "Method not found"); continue }
        }
        emit(["jsonrpc": "2.0", "id": id!, "result": result])
    }
    await requests.shutdown()
}

@main
struct Main {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let host = TranslationHost()
        // Retain signal sources for the entire process; gracefully reap llama-server.
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { Task { await host.shutdown(); exit(130) } }
            source.resume(); return source
        }
        var code: Int32 = 0
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty || args == ["--help"] || args == ["-h"] { print(help) }
            else if args == ["--version"] { print("1.0.1") }
            else if args == ["mcp", "--stdio"] { try await mcp(host) }
            else {
                let command = args[0]
                guard ["text", "file", "model-status"].contains(command) else { throw HostError("未知命令。使用 --help 查看帮助") }
                var values: [String: Any] = [:]; var positional: [String] = []; var json = false; var stdin = false
                var index = 1; var seen = Set<String>()
                while index < args.count {
                    let arg = args[index]
                    if arg == "--" { positional += args.dropFirst(index + 1); break }
                    if arg.hasPrefix("--") {
                        guard seen.insert(arg).inserted else { throw HostError("重复参数：\(arg)") }
                        switch arg {
                        case "--json": json = true
                        case "--stdin": stdin = true
                        case "--bilingual": values["bilingual"] = true
                        case "--from", "--to", "--output", "--format":
                            index += 1; guard index < args.count else { throw HostError("\(arg) 缺少值") }
                            values[["--from": "source", "--to": "target", "--output": "output", "--format": "format"][arg]!] = args[index]
                        default: throw HostError("未知参数：\(arg)")
                        }
                    } else { positional.append(arg) }
                    index += 1
                }
                let allowed: Set<String> = command == "file" ? ["--json", "--from", "--to", "--output", "--format", "--bilingual"] : command == "text" ? ["--json", "--stdin", "--from", "--to"] : ["--json"]
                guard seen.isSubset(of: allowed) else { throw HostError("该命令不支持此参数") }
                if command == "model-status" {
                    guard positional.isEmpty else { throw HostError("model-status 不接受位置参数") }
                    emit(await host.modelStatus())
                } else if command == "text" {
                    guard (stdin && positional.isEmpty) || (!stdin && positional.count == 1) else { throw HostError("提供一段文本，或使用 --stdin") }
                    let text = stdin ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : positional[0]
                    let result = try await host.text(text, options: TranslationOptions(values))
                    if json { emit(result) } else { print(result["translation"] as! String) }
                } else {
                    guard positional.count == 1 else { throw HostError("file 需要一个输入路径") }
                    values["input"] = positional[0]
                    if values["format"] == nil, let output = values["output"] as? String { values["format"] = URL(fileURLWithPath: output).pathExtension.lowercased() }
                    let job = try await host.submit(TranslationOptions(values))
                    var last = -1
                    while true {
                        let state = try await host.get(job.job_id)
                        if ["completed", "failed", "cancelled"].contains(state.status) {
                            guard state.status == "completed" else { throw HostError(state.error ?? state.status) }
                            if json { emit(try jsonObject(state)) } else { print(state.output!) }; break
                        }
                        if state.completed != last { fputs("\(state.completed)/\(state.total) \(state.status)\n", stderr); last = state.completed }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        } catch { fputs("错误：\(error.localizedDescription)\n", stderr); code = 1 }
        await host.shutdown()
        withExtendedLifetime(signals) {}
        exit(code)
    }
}
