using System.IO.Compression;
using System.Text;
using System.Xml.Linq;
using Zhengxin.Core;
var assets=Path.GetFullPath(args[0]);int assertions=0;
void Check(bool ok,string name){if(!ok)throw new Exception(name);assertions++;Console.WriteLine("PASS "+name);}
var languages=new Languages(assets);
for(int i=0;i<4;i++){var tier=languages.Tier(i);Check(tier.Count==new[]{13,55,160,581}[i],$"语言层级{i}数量");Check(tier.Select(l=>l.Code).Distinct().Count()==tier.Count,$"语言层级{i}唯一性");if(i>0)Check(tier.Take(languages.Tier(i-1).Count).SequenceEqual(languages.Tier(i-1)),"展开保留顺序");}
Check(languages.Tier(3).Any(l=>l.Code=="zh-CN")&&!languages.Tier(3).Any(l=>l.Code=="zh"),"简体中文快捷项");
Check(languages.Tier(3).All(l=>!string.IsNullOrWhiteSpace(languages.English(l.Code))),"提示词名称完整");
var longText=string.Concat(Enumerable.Repeat("中文。😀 Mixed text! ",100));var(a,b)=Inference.Split(longText);Check(a+b==longText,"Unicode分段无丢字");Check(a.Length>0&&b.Length>0,"分段非空");
Check(Inference.Detect("これは漢字です")=="ja"&&Inference.Detect("中文")=="zh-CN","语言启发式");
var temp=Path.Combine(Path.GetTempPath(),"zhengxin-tests-"+Guid.NewGuid());Directory.CreateDirectory(temp);
try{
 var md=Path.Combine(temp,"样本.md");File.WriteAllText(md,"# Title\n\nHello & <world>.\n\n- Item\n\n```c\nvar a = 1;\n```\n");var doc=Documents.Parse(md);
 Check(doc.Segments.Count==4&&doc.Segments[3].Kind=="code","Markdown结构与代码块");
 var items=doc.Segments.Select(s=>new Translation(s,s.Kind=="code"?s.Text:"译文 & <示例>")).ToList();
 var path=Documents.Export(doc,items,temp,"zh-CN",true,true);using(var zip=ZipFile.OpenRead(path)){using var stream=zip.GetEntry("word/document.xml")!.Open();var xml=XDocument.Load(stream);Check(xml.Root!.Value.Contains("译文 & <示例>")&&xml.Root!.Value.Contains("Hello & <world>"),"DOCX双语XML转义");Check(zip.GetEntry("word/_rels/document.xml.rels")!=null,"DOCX样式关系");}
 Check(Documents.Parse(path).Segments.Count==9,"DOCX回读段落");Check(Documents.Export(doc,items,temp,"zh-CN",true,true)!=path,"避免覆盖同名文件");
 var epub=Path.Combine(temp,"样本.epub");using(var zip=ZipFile.Open(epub,ZipArchiveMode.Create)){using var writer=new StreamWriter(zip.CreateEntry("OEBPS/01.xhtml").Open());writer.Write("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>标题</h1><p>正文</p></body></html>");}Check(Documents.Parse(epub).Segments.Count==2,"EPUB容器导入");
 var export=Documents.Export(doc,items,temp,"zh-CN",false,false);Check(File.ReadAllText(export).Contains("```c\nvar a = 1;"),"Markdown导出保留代码");
 var bytes=Encoding.UTF8.GetBytes("校验测试");var valid=Path.Combine(temp,"hash");File.WriteAllBytes(valid,bytes);var hash=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));Check(await EnvironmentSetup.Valid(valid,hash,default),"文件SHA256验证");File.AppendAllText(valid,"损坏");Check(!await EnvironmentSetup.Valid(valid,hash,default),"损坏文件拒绝");
}finally{Directory.Delete(temp,true);}
Console.WriteLine($"{assertions} checks passed.");
