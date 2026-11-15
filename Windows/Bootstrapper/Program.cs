using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
namespace Zhengxin.Setup;
public static class Program {
 static readonly string Root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","ZhengxinTranslate");
 const string RegPath=@"Software\Microsoft\Windows\CurrentVersion\Uninstall\ZhengxinTranslate";
 static string Shortcut=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"正心Translate.lnk");
 [STAThread] public static void Main(string[] args){
  if(args.Contains("--uninstall")){if(MessageBox.Show("卸载正心Translate？模型、日志和用户文档将保留。","正心Translate",MessageBoxButton.YesNo)!=MessageBoxResult.Yes)return;var temp=Path.Combine(Path.GetTempPath(),"Zhengxin-Uninstall-"+Guid.NewGuid()+".exe");File.Copy(Environment.ProcessPath!,temp);Process.Start(new ProcessStartInfo(temp,"--remove "+Environment.ProcessId){UseShellExecute=true});return;}
  if(args.Contains("--remove")){try{if(int.TryParse(args.Last(),out int pid)){try{Process.GetProcessById(pid).WaitForExit(10000);}catch(ArgumentException){}}if(Directory.Exists(Root))Directory.Delete(Root,true);if(File.Exists(Shortcut))File.Delete(Shortcut);Registry.CurrentUser.DeleteSubKeyTree(RegPath,false);MessageBox.Show("正心Translate已卸载，模型和用户数据已保留。");}catch(Exception e){MessageBox.Show("卸载失败，请关闭正心Translate后重试："+e.Message);}return;}
  var app=new Application();var text=new TextBlock{Text="正在安装正心Translate…",Margin=new Thickness(30),TextWrapping=TextWrapping.Wrap};var window=new Window{Title="安装正心Translate",Width=480,Height=180,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterScreen,Content=text};bool working=true;window.Closing+=(_,e)=>e.Cancel=working;
  window.Loaded+=async(_,_)=>{try{if(RuntimeInformation.OSArchitecture!=Architecture.X64)throw new PlatformNotSupportedException("此版本需要Windows x64。");await Task.Run(Install);text.Text="安装完成，正在启动并自动准备运行环境…";Process.Start(new ProcessStartInfo(Path.Combine(Root,"ZhengxinTranslate.exe")){UseShellExecute=true});working=false;window.Close();}catch(Exception e){working=false;text.Text="安装未完成："+e.Message+"\n请关闭旧版程序后重试。";}};app.Run(window);
 }
 static void Install(){var parent=Path.GetDirectoryName(Root)!;Directory.CreateDirectory(parent);var staging=Path.Combine(parent,"ZhengxinTranslate-install-"+Guid.NewGuid());var backup=Root+"-backup-"+Guid.NewGuid();Directory.CreateDirectory(staging);bool moved=false;
  try{using(var payload=Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip")!)using(var zip=new ZipArchive(payload))zip.ExtractToDirectory(staging);File.Copy(Environment.ProcessPath!,Path.Combine(staging,"Uninstall.exe"));
   if(Directory.Exists(Root)){Directory.Move(Root,backup);moved=true;}try{Directory.Move(staging,Root);}catch{if(moved)Directory.Move(backup,Root);throw;}
   Type type=Type.GetTypeFromProgID("WScript.Shell")!;dynamic shell=Activator.CreateInstance(type)!;dynamic link=shell.CreateShortcut(Shortcut);link.TargetPath=Path.Combine(Root,"ZhengxinTranslate.exe");link.WorkingDirectory=Root;link.IconLocation=Path.Combine(Root,"ZhengxinTranslate.exe");link.Save();Marshal.FinalReleaseComObject(link);Marshal.FinalReleaseComObject(shell);
   using var reg=Registry.CurrentUser.CreateSubKey(RegPath);reg.SetValue("DisplayName","正心Translate");reg.SetValue("DisplayVersion","1.0.0-preview");reg.SetValue("Publisher","北京正笔正心文化发展有限公司");reg.SetValue("InstallLocation",Root);reg.SetValue("DisplayIcon",Path.Combine(Root,"ZhengxinTranslate.exe"));reg.SetValue("UninstallString","\""+Path.Combine(Root,"Uninstall.exe")+"\" --uninstall");reg.SetValue("NoModify",1);reg.SetValue("NoRepair",1);
   if(moved)Directory.Delete(backup,true);
  }finally{if(Directory.Exists(staging))Directory.Delete(staging,true);}
 }
}
