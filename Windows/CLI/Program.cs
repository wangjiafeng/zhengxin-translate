using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using Zhengxin.Cli;

const string Help="""
正心Translate CLI v1.0.1
  zhengxin-translate text TEXT [--from auto] [--to zh-CN] [--json]
  zhengxin-translate text --stdin [--to zh-CN] [--json]
  zhengxin-translate file INPUT --output OUTPUT [--format md|docx] [--bilingual] [--from auto] [--to zh-CN] [--json]
  zhengxin-translate model-status [--json]
  zhengxin-translate mcp --stdio
模型与运行组件需预先在桌面程序中准备；命令行不会下载或安装环境。
""";

Console.InputEncoding = new UTF8Encoding(false);
Console.OutputEncoding = new UTF8Encoding(false);
using var stop = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Cancel(); };
using var term = !OperatingSystem.IsWindows() ? PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx=>{ctx.Cancel=true;stop.Cancel();}) : null;
await using var host = new Host();
try {
    if(args.Length==0||args is ["--help"] or ["-h"]) { Console.WriteLine(Help);return 0; }
    if(args is ["--version"]) { Console.WriteLine("1.0.1");return 0; }
    if(args is ["mcp","--stdio"]) { await Mcp(host,stop.Token);return 0; }
    var command=args[0];if(command is not "text" and not "file" and not "model-status")throw new ArgumentException("未知命令。使用 --help 查看帮助");
    var values=new JsonObject();var positional=new List<string>();var seen=new HashSet<string>();var json=false;var stdin=false;
    for(int i=1;i<args.Length;i++) {
        var arg=args[i];if(arg=="--"){positional.AddRange(args.Skip(i+1));break;}
        if(!arg.StartsWith("--")){positional.Add(arg);continue;}
        if(!seen.Add(arg))throw new ArgumentException("重复参数："+arg);
        switch(arg) {
            case "--json":json=true;break;
            case "--stdin":stdin=true;break;
            case "--bilingual":values["bilingual"]=true;break;
            case "--from": case "--to": case "--output": case "--format":
                if(++i>=args.Length)throw new ArgumentException(arg+" 缺少值");
                values[arg switch {"--from"=>"source","--to"=>"target","--output"=>"output",_=>"format"}]=args[i];break;
            default:throw new ArgumentException("未知参数："+arg);
        }
    }
    string[] allowed=command switch {"file"=>["--json","--from","--to","--output","--format","--bilingual"],"text"=>["--json","--stdin","--from","--to"],_=>["--json"]};
    if(!seen.IsSubsetOf(allowed))throw new ArgumentException("该命令不支持此参数");
    if(command=="model-status") {
        if(positional.Count!=0)throw new ArgumentException("model-status 不接受位置参数");
        Emit(await host.ModelStatus(stop.Token));
    } else if(command=="text") {
        if(!((stdin&&positional.Count==0)||(!stdin&&positional.Count==1)))throw new ArgumentException("提供一段文本，或使用 --stdin");
        var text=stdin?await Console.In.ReadToEndAsync(stop.Token):positional[0];
        var result=await host.Text(text,Options.Parse(values,host.Languages),stop.Token);
        if(json)Emit(result);else Console.WriteLine(JsonSerializer.SerializeToNode(result)!["translation"]!.GetValue<string>());
    } else {
        if(positional.Count!=1)throw new ArgumentException("file 需要一个输入路径");
        values["input"]=positional[0];
        if(values["format"]==null&&values["output"]!=null)values["format"]=Path.GetExtension(values["output"]!.GetValue<string>()).TrimStart('.').ToLowerInvariant();
        var job=JsonSerializer.SerializeToNode(host.Submit(Options.Parse(values,host.Languages)))!;var id=job["job_id"]!.GetValue<string>();int last=-1;
        while(true) {
            var state=JsonSerializer.SerializeToNode(host.Get(id))!;var status=state["status"]!.GetValue<string>();
            if(status is "completed" or "failed" or "cancelled") {
                if(status!="completed")throw new IOException(state["error"]?.GetValue<string>()??status);
                if(json)Emit(state);else Console.WriteLine(state["output"]!.GetValue<string>());break;
            }
            var done=state["completed"]!.GetValue<int>();if(done!=last){Console.Error.WriteLine($"{done}/{state["total"]} {status}");last=done;}
            await Task.Delay(100,stop.Token);
        }
    }
    return 0;
} catch(OperationCanceledException) {Console.Error.WriteLine("已取消");return 130;}
catch(Exception e) {Console.Error.WriteLine("错误："+e.Message);return 1;}

static void Emit(object value) {Console.WriteLine(JsonSerializer.Serialize(value));Console.Out.Flush();}
static void Validate(JsonObject arguments,JsonObject tool) {
    var schema=tool["inputSchema"]!;var properties=schema["properties"]!.AsObject();
    if(arguments.Any(k=>!properties.ContainsKey(k.Key)))throw new ArgumentException("未知工具参数");
    foreach(var key in schema["required"]!.AsArray())if(!arguments.ContainsKey(key!.GetValue<string>()))throw new ArgumentException("缺少参数："+key);
    foreach(var (key,value) in arguments) {
        var property=properties[key]!;var expected=property["type"]!.GetValue<string>();
        if(expected=="string"&&(value is not JsonValue v||!v.TryGetValue<string>(out var text)||string.IsNullOrWhiteSpace(text)))throw new ArgumentException(key+" 必须是非空字符串");
        if(expected=="boolean"&&(value is not JsonValue b||!b.TryGetValue<bool>(out _)))throw new ArgumentException(key+" 必须是布尔值");
        if(property["enum"] is JsonArray choices&&!choices.Any(c=>JsonNode.DeepEquals(c,value)))throw new ArgumentException(key+" 值无效");
    }
}
static async Task Mcp(Host host,CancellationToken ct) {
    var tools=JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory,"tools.json"),ct))!.AsArray();
    var pending=new ConcurrentDictionary<string,Pending>();
    bool initialized=false,ready=false;
    try {
    while(await Console.In.ReadLineAsync(ct) is {} line) {
        JsonObject request;
        try {var node=JsonNode.Parse(line);if(node is not JsonObject obj){Emit(new {jsonrpc="2.0",id=(object?)null,error=new {code=-32600,message="Invalid Request"}});continue;}request=obj;}
        catch(JsonException){Emit(new {jsonrpc="2.0",id=(object?)null,error=new {code=-32700,message="Parse error"}});continue;}
        var id=request["id"];
        void Failure(int code,string message)=>Emit(new {jsonrpc="2.0",id,error=new {code,message}});
        if(request["jsonrpc"] is not JsonValue rpc||!rpc.TryGetValue<string>(out var version)||version!="2.0"||request["method"] is not JsonValue methodValue||!methodValue.TryGetValue<string>(out var method)||
           (request.ContainsKey("id")&&(id==null||id.GetValueKind() is not JsonValueKind.Number and not JsonValueKind.String))) {Failure(-32600,"Invalid Request");continue;}
        if(id==null) {
            if(method=="notifications/initialized"&&initialized)ready=true;
            if(method=="notifications/cancelled"&&request["params"] is JsonObject cancellation&&cancellation["requestId"] is {} requestID&&pending.TryGetValue(requestID.ToJsonString(),out var item))item.CancelRequest();
            continue;
        }
        if(request.ContainsKey("params")&&request["params"] is not JsonObject){Failure(-32602,"params 必须是对象");continue;}
        var p=request["params"] as JsonObject??new();object result;
        if(method=="initialize") {
            if(initialized){Failure(-32600,"Already initialized");continue;}
            if(p["protocolVersion"] is not JsonValue pv||!pv.TryGetValue<string>(out var protocol)||p["capabilities"] is not JsonObject||p["clientInfo"] is not JsonObject){Failure(-32602,"Invalid initialize parameters");continue;}
            initialized=true;
            result=new {protocolVersion=new[]{"2025-11-25","2025-06-18","2025-03-26"}.Contains(protocol)?protocol:"2025-11-25",capabilities=new {tools=new {listChanged=false}},serverInfo=new {name="zhengxin-translate",version="1.0.1"},instructions="Document jobs are session-local and cancelled on disconnect. Poll get_job until terminal. Prepare models in the desktop app first."};
        } else if(method=="ping")result=new {};
        else {
            if(!ready){Failure(-32000,"Server not initialized");continue;}
            if(method=="tools/list")result=new {tools};
            else if(method=="tools/call") {
                var name=p["name"] is JsonValue nv&&nv.TryGetValue<string>(out var n)?n:null;
                var tool=tools.OfType<JsonObject>().FirstOrDefault(t=>t["name"]!.GetValue<string>()==name);
                if(tool==null){Failure(-32602,"Unknown tool");continue;}
                if(p.ContainsKey("arguments")&&p["arguments"] is not JsonObject){Failure(-32602,"arguments 必须是对象");continue;}
                var arguments=p["arguments"] as JsonObject??new();
                try {Validate(arguments,tool);}catch(ArgumentException e){Failure(-32602,e.Message);continue;}
                var key=id.ToJsonString();var work=new Pending(CancellationTokenSource.CreateLinkedTokenSource(ct));
                if(pending.Count>=128||!pending.TryAdd(key,work)){work.Finish();Failure(-32000,"Duplicate request ID or too many pending requests");continue;}
                _=Task.Run(async ()=> {
                    object response;
                    try {
                        work.Token.ThrowIfCancellationRequested();
                        var options=Options.Parse(arguments,host.Languages);
                        object value=name switch {
                            "translate_text"=>await host.Text(arguments["text"]!.GetValue<string>(),options,work.Token),
                            "submit_document"=>host.Submit(options),
                            "get_job"=>host.Get(arguments["job_id"]!.GetValue<string>()),
                            "cancel_job"=>host.Cancel(arguments["job_id"]!.GetValue<string>()),
                            _=>await host.ModelStatus(work.Token)
                        };
                        response=new {content=new[]{new {type="text",text=JsonSerializer.Serialize(value)}},isError=false};
                    } catch(Exception e){response=new {content=new[]{new {type="text",text=e.Message}},isError=true};}
                    try {Emit(new {jsonrpc="2.0",id,result=response});}
                    finally {pending.TryRemove(key,out _);work.Finish();}
                });
                continue;
            } else {Failure(-32601,"Method not found");continue;}
        }
        Emit(new {jsonrpc="2.0",id,result});
    }
    } finally {
        var active=pending.Values.ToArray();foreach(var work in active)work.CancelRequest();
        await Task.WhenAll(active.Select(work=>work.Done.Task));
    }
}

sealed class Pending(CancellationTokenSource cancel) {
    readonly object sync=new(); bool finished;
    public CancellationToken Token => cancel.Token;
    public readonly TaskCompletionSource Done=new(TaskCreationOptions.RunContinuationsAsynchronously);
    public void CancelRequest() { lock(sync) { if(!finished)cancel.Cancel(); } }
    public void Finish() { lock(sync) { if(finished)return;finished=true;cancel.Dispose();Done.SetResult(); } }
}

