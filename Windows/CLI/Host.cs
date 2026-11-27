using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Zhengxin.Core;

namespace Zhengxin.Cli;

sealed record Options(string Source, string Target, string Input, string Output, string Format, bool Bilingual) {
    public static Options Parse(JsonObject args, Languages languages) {
        string Read(string key, string fallback) => args[key]?.GetValue<string>() ?? fallback;
        var source = Read("source", "auto"); var target = Read("target", "zh-CN");
        if(source == "zh") source = "zh-CN"; if(target == "zh") target = "zh-CN";
        if((source != "auto" && !languages.All.Any(x=>x.Code==source)) || target=="auto" || !languages.All.Any(x=>x.Code==target)) throw new ArgumentException("不支持的语言代码");
        var format = Read("format", "md"); if(format is not "md" and not "docx") throw new ArgumentException("format 仅支持 md 或 docx");
        return new(source,target,Read("input",""),Read("output",""),format,args["bilingual"]?.GetValue<bool>() ?? false);
    }
    public void ValidateFile() {
        if(string.IsNullOrWhiteSpace(Input)||string.IsNullOrWhiteSpace(Output)) throw new ArgumentException("input 与 output 必填");
        if(!File.Exists(Input)) throw new FileNotFoundException("输入文件不存在");
        if(Path.GetFullPath(Input).Equals(Path.GetFullPath(Output),OperatingSystem.IsWindows()?StringComparison.OrdinalIgnoreCase:StringComparison.Ordinal)) throw new ArgumentException("输出不能覆盖输入文件");
        if(File.Exists(Output)||Directory.Exists(Output)) throw new IOException("输出已存在，拒绝覆盖");
        if(!Path.GetExtension(Output).Equals("."+Format,StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("输出扩展名必须与 format 一致");
    }
}

sealed class Job(string id) {
    public readonly object Sync = new();
    public readonly CancellationTokenSource Cancellation = new();
    public Task Work = Task.CompletedTask;
    public string Status="queued"; public int Completed, Total; public string? Output, Error;
    public object Snapshot() { lock(Sync) return new {job_id=id,status=Status,completed=Completed,total=Total,output=Output,error=Error}; }
}

sealed class Host : IAsyncDisposable {
    readonly Inference inference = new();
    readonly SemaphoreSlim gate = new(1,1);
    readonly ConcurrentDictionary<string,Job> jobs = new();
    readonly CancellationTokenSource stopping = new();
    public readonly Languages Languages = new(Path.Combine(AppContext.BaseDirectory,"Assets"));
    readonly bool mock = Environment.GetEnvironmentVariable("ZHENGXIN_TRANSLATE_MOCK")=="1";
    readonly string root = Environment.GetEnvironmentVariable("ZHENGXIN_DATA_ROOT") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"正心Translate");
    bool initialized;
    string? ModelPath() => new[]{Environment.GetEnvironmentVariable("ZHENGXIN_MODEL_PATH"),Path.Combine(root,"Models",EnvironmentSetup.ModelName),Path.Combine(AppContext.BaseDirectory,"Models",EnvironmentSetup.ModelName)}.FirstOrDefault(p=>p!=null&&File.Exists(p));
    string? RuntimePath() {
        var explicitPath=Environment.GetEnvironmentVariable("ZHENGXIN_LLAMA_SERVER");
        if(!string.IsNullOrWhiteSpace(explicitPath))return File.Exists(explicitPath)?explicitPath:null;
        var directory=Path.Combine(root,"Runtime","b10783");
        return Directory.Exists(directory)?Directory.GetFiles(directory,"llama-server.exe",SearchOption.AllDirectories).OrderBy(p=>p.Contains("cpu")?0:1).FirstOrDefault():null;
    }
    public async Task<object> ModelStatus(CancellationToken ct) {
        var model=ModelPath();var runtime=RuntimePath();
        var valid=model!=null&&await EnvironmentSetup.Valid(model,EnvironmentSetup.ModelHash,ct);
        return new {model_present=model!=null,model_path=model,runtime_available=runtime!=null,ready=valid&&runtime!=null,mock,error=model!=null&&!valid?"模型校验失败":null};
    }
    async Task Prepare(CancellationToken ct) {
        if(mock||initialized)return;
        var model=ModelPath();var runtime=RuntimePath();
        if(model==null||!await EnvironmentSetup.Valid(model,EnvironmentSetup.ModelHash,ct))throw new IOException("模型缺失或校验失败，请先在桌面程序中准备模型，或设置 ZHENGXIN_MODEL_PATH。");
        if(runtime==null)throw new IOException("未找到运行组件，请先在桌面程序中准备环境，或设置 ZHENGXIN_LLAMA_SERVER。");
        await inference.InitializeLocal(runtime,model,root,ct);initialized=true;
    }
    async Task<string> Translate(string text,Options options,CancellationToken ct) {
        if(mock){await Task.Delay(30,ct);return $"[{options.Target}] {text}";}
        return await inference.Translate(text,options.Source,options.Target,Languages.English,ct);
    }
    public async Task<object> Text(string text,Options options,CancellationToken ct) {
        if(string.IsNullOrWhiteSpace(text))throw new ArgumentException("text 不能为空");
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(ct,stopping.Token); ct=linked.Token;
        await gate.WaitAsync(ct);
        try {await Prepare(ct);return new {translation=await Translate(text,options,ct),source=options.Source,target=options.Target};}
        finally {gate.Release();}
    }
    public object Submit(Options options) {
        options.ValidateFile();stopping.Token.ThrowIfCancellationRequested();
        if(jobs.Count>=1000)throw new IOException("当前会话任务已达上限，请重启 MCP 服务");
        var id=Guid.NewGuid().ToString();var job=new Job(id);jobs[id]=job;
        // Snapshot is deliberately queued even if a small job immediately starts.
        var snapshot=job.Snapshot();job.Work=Task.Run(()=>Run(job,options));return snapshot;
    }
    async Task Run(Job job,Options options) {
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(job.Cancellation.Token,stopping.Token);var ct=linked.Token;
        var entered=false;
        try {
            await gate.WaitAsync(ct);entered=true;
            lock(job.Sync)job.Status="preparing";
            var doc=Documents.Parse(options.Input);ct.ThrowIfCancellationRequested();await Prepare(ct);
            lock(job.Sync){job.Total=doc.Segments.Count;job.Status="translating";}
            var translations=new List<Translation>();
            foreach(var segment in doc.Segments) {
                ct.ThrowIfCancellationRequested();var text=segment.Kind=="code"?segment.Text:await Translate(segment.Text,options,ct);
                translations.Add(new(segment,text));lock(job.Sync)job.Completed++;
            }
            ct.ThrowIfCancellationRequested();lock(job.Sync)job.Status="exporting";
            var destination=Path.GetFullPath(options.Output);var parent=Path.GetDirectoryName(destination)!;Directory.CreateDirectory(parent);
            var staging=Path.Combine(parent,".zhengxin-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(staging);
            try {
                var path=Documents.Export(doc,translations,staging,options.Target,options.Bilingual,options.Format=="docx");
                lock(job.Sync){ct.ThrowIfCancellationRequested();File.Move(path,destination);job.Output=destination;job.Status="completed";}
            } finally {Directory.Delete(staging,true);}
        } catch(OperationCanceledException){lock(job.Sync)job.Status="cancelled";}
        catch(Exception e){lock(job.Sync){job.Status="failed";job.Error=e.Message;}}
        finally {if(entered)gate.Release();}
    }
    Job Find(string id)=>jobs.TryGetValue(id,out var job)?job:throw new ArgumentException("任务不存在："+id);
    public object Get(string id)=>Find(id).Snapshot();
    public object Cancel(string id) {
        var job=Find(id);lock(job.Sync){if(job.Status is not "completed" and not "failed" and not "cancelled"){job.Cancellation.Cancel();job.Status="cancelling";}return job.Snapshot();}
    }
    public async ValueTask DisposeAsync() {
        stopping.Cancel();foreach(var job in jobs.Values)job.Cancellation.Cancel();
        await Task.WhenAll(jobs.Values.Select(j=>j.Work));await inference.DisposeAsync();
        foreach(var job in jobs.Values)job.Cancellation.Dispose();stopping.Dispose();gate.Dispose();
    }
}
