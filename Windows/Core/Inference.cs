using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
namespace Zhengxin.Core;
public sealed class Inference : IAsyncDisposable {
 readonly HttpClient http=new(){Timeout=TimeSpan.FromSeconds(300)};
 Process? process; StreamWriter? log;string? endpoint;string key="";
 public string Backend {get;private set;}="未启动";
 public async Task Initialize(EnvironmentSetup setup,string assets,IProgress<string> progress,CancellationToken ct) {
  if(endpoint!=null)return;
  await WindowsPrerequisites.Ensure(setup.Root,progress,ct);
  await setup.PrepareModel(assets,progress,ct);
  var entries=JsonSerializer.Deserialize<List<RuntimeAsset>>(File.ReadAllText(Path.Combine(assets,"runtime-manifest.json")),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})!;
  foreach(var asset in entries.OrderBy(a=>a.Name=="vulkan"?0:1)) {
   try {var exe=await setup.PrepareRuntime(asset,progress,ct);await Start(exe,setup.ModelPath,asset.Name,setup.Root,ct);Backend=asset.Name;progress.Report($"环境已就绪：{Backend}");return;}
   catch(OperationCanceledException){await Stop();throw;}
   catch(Exception e){await Stop();progress.Report($"{asset.Name} 不可用：{e.Message}");}
  }
  throw new InvalidOperationException("本地推理组件无法启动，请查看日志后重试。");
 }
 async Task Start(string exe,string model,string backend,string root,CancellationToken ct) {
  using(var listener=new TcpListener(IPAddress.Loopback,0)){listener.Start();endpoint=$"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}";}
  key=Guid.NewGuid().ToString("N");var port=new Uri(endpoint).Port;
  var psi=new ProcessStartInfo(exe){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=Path.GetDirectoryName(exe)!};
  foreach(var arg in new[]{"--host","127.0.0.1","--port",port.ToString(),"--api-key",key,"-m",model,"-c","8192","-np","1","--no-jinja","--chat-template","gemma","-ngl",backend=="cpu"?"0":"99"})psi.ArgumentList.Add(arg);
  var logs=Path.Combine(root,"Logs");Directory.CreateDirectory(logs);foreach(var f in Directory.GetFiles(logs).OrderByDescending(File.GetLastWriteTimeUtc).Skip(9))File.Delete(f);
  log=new StreamWriter(Path.Combine(logs,$"llama-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.log")){AutoFlush=true};
  process=new Process{StartInfo=psi};var gate=new object();void Line(object sender,DataReceivedEventArgs e){if(e.Data!=null)lock(gate)log?.WriteLine(e.Data);}
  process.OutputDataReceived+=Line;process.ErrorDataReceived+=Line;process.Start();process.BeginOutputReadLine();process.BeginErrorReadLine();
  using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);timeout.CancelAfter(TimeSpan.FromSeconds(90));
  try {while(true){timeout.Token.ThrowIfCancellationRequested();if(process.HasExited)throw new IOException($"运行组件退出（{process.ExitCode}），日志：{logs}");try{using var request=new HttpRequestMessage(HttpMethod.Get,endpoint+"/health");request.Headers.Add("Authorization","Bearer "+key);using var response=await http.SendAsync(request,timeout.Token);if(response.IsSuccessStatusCode)break;}catch(HttpRequestException){}await Task.Delay(500,timeout.Token);}
   // An authenticated generation verifies that the responding service belongs to us.
   await Translate("Hello.","en","zh-CN",_=>"English",timeout.Token);
  }catch(OperationCanceledException)when(!ct.IsCancellationRequested){throw new TimeoutException("90秒内未完成模型加载与推理自检。");}
 }
 public static string Detect(string text)=>text.Any(c=>c>='\u3040'&&c<='\u30ff')?"ja":text.Any(c=>c>='\uac00'&&c<='\ud7af')?"ko":text.Any(c=>c>='\u4e00'&&c<='\u9fff')?"zh-CN":text.Any(c=>c>='\u0400'&&c<='\u04ff')?"ru":"en";
 public static (string,string) Split(string text){var elements=System.Globalization.StringInfo.GetTextElementEnumerator(text);var list=new List<string>();while(elements.MoveNext())list.Add(elements.GetTextElement());if(list.Count<2)throw new InvalidDataException("无法继续拆分超长段落。");int mid=list.Count/2;var choices=Enumerable.Range(Math.Max(1,list.Count/4),Math.Min(list.Count-1,list.Count*3/4)-Math.Max(1,list.Count/4)+1).Where(i=>"。！？；.!?;\n ".Contains(list[i-1],StringComparison.Ordinal));int split=choices.OrderBy(i=>Math.Abs(i-mid)).FirstOrDefault(mid);return(string.Concat(list.Take(split)),string.Concat(list.Skip(split)));}
 public async Task<string> Translate(string text,string source,string target,Func<string,string> english,CancellationToken ct) {
  ct.ThrowIfCancellationRequested();source=source=="auto"?Detect(text):source;
  async Task<string> Parts(){var(a,b)=Split(text);return await Translate(a,source,target,english,ct)+"\n"+await Translate(b,source,target,english,ct);}
  if(Encoding.UTF8.GetByteCount(text)>1800)return await Parts();
  var from=source=="zh-CN"?"Simplified Chinese":english(source);var to=target=="zh-CN"?"Simplified Chinese":english(target);
  var prompt=$"You are a professional {from} ({source}) to {to} ({target}) translator. Your goal is to accurately convey the meaning and nuances of the original {from} text while adhering to {to} grammar, vocabulary, and cultural sensitivities.\nProduce only the {to} translation, without any additional explanations or commentary. Please translate the following {from} text into {to}:\n\n\n{text.Trim()}";
  using var request=new HttpRequestMessage(HttpMethod.Post,endpoint+"/v1/chat/completions"){Content=JsonContent.Create(new{model="translategemma-4b-it",messages=new[]{new{role="user",content=prompt}},temperature=0.1,top_p=0.95,max_tokens=1536,stream=false})};request.Headers.Add("Authorization","Bearer "+key);
  using var response=await http.SendAsync(request,ct);var raw=await response.Content.ReadAsStringAsync(ct);
  if(!response.IsSuccessStatusCode){if(raw.Contains("exceed_context_size_error"))return await Parts();throw new IOException("本地翻译请求失败："+raw[..Math.Min(1000,raw.Length)]);}
  using var json=JsonDocument.Parse(raw);var choice=json.RootElement.GetProperty("choices")[0];if(choice.GetProperty("finish_reason").GetString()=="length")return await Parts();var content=choice.GetProperty("message").GetProperty("content").GetString();if(string.IsNullOrWhiteSpace(content))throw new IOException("模型返回空译文。");return content.Trim();
 }
 async Task Stop(){endpoint=null;if(process!=null){if(!process.HasExited){process.Kill(true);await process.WaitForExitAsync();}process.Dispose();process=null;}log?.Dispose();log=null;}
 public async ValueTask DisposeAsync(){await Stop();http.Dispose();}
}
