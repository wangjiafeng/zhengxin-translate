using System.Diagnostics;
using System.Runtime.InteropServices;
namespace Zhengxin.Core;
public static class WindowsPrerequisites {
 static bool HasRuntime(){if(!NativeLibrary.TryLoad("vcruntime140.dll",out var a))return false;NativeLibrary.Free(a);if(!NativeLibrary.TryLoad("msvcp140.dll",out var b))return false;NativeLibrary.Free(b);return true;}
 public static async Task Ensure(string root,IProgress<string> progress,CancellationToken ct){
  if(!OperatingSystem.IsWindows()||HasRuntime())return;
  progress.Report("正在自动安装 Microsoft Visual C++ 运行库，可能需要系统授权…");
  var file=Path.Combine(root,"Downloads","vc_redist.x64.exe");Directory.CreateDirectory(Path.GetDirectoryName(file)!);
  using(var http=new HttpClient{Timeout=TimeSpan.FromMinutes(10)})await using(var source=await http.GetStreamAsync("https://aka.ms/vs/17/release/vc_redist.x64.exe",ct))await using(var output=File.Create(file))await source.CopyToAsync(output,ct);
  // The official redirect can change; validate Microsoft's Authenticode signature before execution.
  var verify=new ProcessStartInfo("powershell.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
  verify.ArgumentList.Add("-NoProfile");verify.ArgumentList.Add("-NonInteractive");verify.ArgumentList.Add("-Command");verify.ArgumentList.Add("$s=Get-AuthenticodeSignature -LiteralPath $env:ZHENGXIN_REDIST; if($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation,'){exit 0}else{exit 1}");verify.Environment["ZHENGXIN_REDIST"]=file;
  using(var process=Process.Start(verify)!){var stdout=process.StandardOutput.ReadToEndAsync(ct);var stderr=process.StandardError.ReadToEndAsync(ct);await process.WaitForExitAsync(ct);await Task.WhenAll(stdout,stderr);if(process.ExitCode!=0)throw new InvalidDataException("Microsoft运行库签名验证失败，已停止安装。");}
  ct.ThrowIfCancellationRequested();
  using(var install=Process.Start(new ProcessStartInfo(file,"/install /quiet /norestart"){UseShellExecute=true,Verb="runas"})!){await install.WaitForExitAsync(ct);if(install.ExitCode is not 0 and not 3010 and not 1638)throw new IOException($"运行库安装失败：{install.ExitCode}");}
  if(!HasRuntime())throw new IOException("运行库安装后仍不可用，请重启Windows后重试。");
 }
}
