using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
namespace Zhengxin.Core;
public record RuntimeAsset(string Name,string Url,string Sha256);
public sealed class EnvironmentSetup {
 public const string ModelName="translategemma-4b-it.Q4_K_M.gguf";
 public const string ModelHash="81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330";
 public const long ModelSize=2489909760;
 public string Root {get;}
 public string ModelPath=>Path.Combine(Root,"Models",ModelName);
 readonly HttpClient http=new(){Timeout=TimeSpan.FromMinutes(60)};
 public EnvironmentSetup(string? root=null){Root=root??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"正心Translate");Directory.CreateDirectory(Root);}
 public static async Task<bool> Valid(string path,string hash,CancellationToken ct){if(!File.Exists(path))return false;await using var s=File.OpenRead(path);return Convert.ToHexString(await SHA256.HashDataAsync(s,ct)).Equals(hash,StringComparison.OrdinalIgnoreCase);}
 public async Task Download(string url,string destination,string hash,IProgress<string> log,CancellationToken ct) {
  Directory.CreateDirectory(Path.GetDirectoryName(destination)!);if(await Valid(destination,hash,ct))return;
  var part=destination+".partial";long offset=File.Exists(part)?new FileInfo(part).Length:0;
  using var request=new HttpRequestMessage(HttpMethod.Get,url);if(offset>0)request.Headers.Range=new RangeHeaderValue(offset,null);
  using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
  if(response.StatusCode==HttpStatusCode.RequestedRangeNotSatisfiable){if(offset==0)throw new IOException("下载服务器拒绝请求。");File.Delete(part);await Download(url,destination,hash,log,ct);return;}
  response.EnsureSuccessStatusCode();bool append=response.StatusCode==HttpStatusCode.PartialContent&&offset>0;
  if(append&&response.Content.Headers.ContentRange?.From!=offset)throw new IOException("服务器断点响应不匹配，请重试。");
  if(!append)offset=0;var total=response.Content.Headers.ContentLength+offset;
  await using(var source=await response.Content.ReadAsStreamAsync(ct))await using(var output=new FileStream(part,append?FileMode.Append:FileMode.Create,FileAccess.Write,FileShare.None)) {
   byte[] buffer=new byte[1024*256];int read;long received=offset;var last=DateTime.MinValue;
   while((read=await source.ReadAsync(buffer,ct))>0){await output.WriteAsync(buffer.AsMemory(0,read),ct);received+=read;if(DateTime.UtcNow-last>TimeSpan.FromSeconds(2)){log.Report($"正在下载：{received/1048576} MB / {(total.HasValue?total.Value/1048576:0)} MB");last=DateTime.UtcNow;}}
  }
  if(!await Valid(part,hash,ct)){File.Delete(part);throw new InvalidDataException("下载文件校验失败，请重试。");}File.Move(part,destination,true);
 }
 public async Task PrepareModel(string assets,IProgress<string> log,CancellationToken ct) {
  log.Report("正在校验模型…");if(await Valid(ModelPath,ModelHash,ct))return;
  foreach(var candidate in new[]{Environment.GetEnvironmentVariable("ZHENGXIN_MODEL_PATH"),Path.Combine(AppContext.BaseDirectory,"Models",ModelName),Path.Combine(AppContext.BaseDirectory,ModelName)})
   if(candidate!=null&&await Valid(candidate,ModelHash,ct)){Directory.CreateDirectory(Path.GetDirectoryName(ModelPath)!);File.Copy(candidate,ModelPath,true);return;}
  var config=JsonDocument.Parse(File.ReadAllText(Path.Combine(assets,"model-manifest.json")));
  var url=config.RootElement.GetProperty("url").GetString();if(string.IsNullOrEmpty(url))throw new InvalidOperationException("模型自动下载源尚未配置；请将模型放在程序旁的Models目录后重试。");
  var drive=new DriveInfo(Path.GetPathRoot(Root)!);if(drive.AvailableFreeSpace<ModelSize+1024L*1024*1024)throw new IOException("可用磁盘空间不足，模型准备至少需要约3.5GB空闲空间。");
  await Download(url,ModelPath,ModelHash,log,ct);
 }
 public async Task<string> PrepareRuntime(RuntimeAsset asset,IProgress<string> log,CancellationToken ct) {
  var directory=Path.Combine(Root,"Runtime","b10783",asset.Name);var zip=Path.Combine(Root,"Downloads",asset.Name+"-b10783.zip");
  log.Report($"正在检查 {asset.Name} 运行组件…");await Download(asset.Url,zip,asset.Sha256,log,ct);
  // Re-extract the verified archive to repair missing or modified DLLs.
  var staging=directory+"-"+Guid.NewGuid().ToString("N");Directory.CreateDirectory(staging);
  try {ZipFile.ExtractToDirectory(zip,staging);var exe=Directory.GetFiles(staging,"llama-server.exe",SearchOption.AllDirectories).Single();if(Directory.Exists(directory))Directory.Delete(directory,true);Directory.Move(staging,directory);return Path.Combine(directory,Path.GetRelativePath(staging,exe));}
  finally{if(Directory.Exists(staging))Directory.Delete(staging,true);}
 }
}
