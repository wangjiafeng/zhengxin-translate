using System.Text.Json;
namespace Zhengxin.Core;
public record Language(string Code,string Name,string English);
public sealed class Languages {
 public List<Language> All {get;}
 readonly string[] major,expanded;
 public Languages(string directory) {
  using var json=JsonDocument.Parse(File.ReadAllText(Path.Combine(directory,"languages.json")));
  var root=json.RootElement;var labels=JsonSerializer.Deserialize<Dictionary<string,string>>(File.ReadAllText(Path.Combine(directory,"language-labels.json")))!;
  var names=root.GetProperty("names").Deserialize<Dictionary<string,string>>()!;
  major=root.GetProperty("major").Deserialize<string[]>()!;expanded=root.GetProperty("expanded").Deserialize<string[]>()!;
  All=names.Select(k=>new Language(k.Key,$"{labels.GetValueOrDefault(k.Key,k.Value)}（{k.Key}）",k.Value)).ToList();
  All.Add(new("zh-CN","简体中文（zh-CN）","Simplified Chinese"));
  var index=All.FindIndex(l=>l.Code=="zh-TW");if(index>=0)All[index]=new("zh-TW","繁体中文（zh-TW）","Traditional Chinese");
 }
 public List<Language> Tier(int level) {
  var codes=level==0?major:level==1?expanded:expanded.Concat(All.Where(l=>!l.Code.Contains('-')&&!expanded.Contains(l.Code)).Select(l=>l.Code).Order(StringComparer.Ordinal)).ToArray();
  if(level>=3) codes=codes.Concat(All.Where(l=>l.Code.Contains('-')&&l.Code!="zh-CN").Select(l=>l.Code).Order(StringComparer.Ordinal)).ToArray();
  return codes.Select(c=>All.Single(l=>l.Code==(c=="zh"?"zh-CN":c))).ToList();
 }
 public string English(string code)=>code=="auto"?"English":All.First(l=>l.Code==code).English;
 public static Language Automatic=>new("auto","自动检测","English");
}
