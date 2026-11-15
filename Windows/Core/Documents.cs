using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;
using UglyToad.PdfPig;
namespace Zhengxin.Core;
public record Segment(string Id, string Kind, string Text, string Location);
public record Document(string Title, List<Segment> Segments);
public record Translation(Segment Source, string Text);
public static class Documents {
 public static Document Parse(string path) {
  var ext=Path.GetExtension(path).ToLowerInvariant(); var list=new List<Segment>();
  void Add(string kind,string text,string location) { if(!string.IsNullOrWhiteSpace(text)) list.Add(new($"s-{list.Count+1}",kind,text.Trim(),location)); }
  if(ext==".pdf") { using var pdf=PdfDocument.Open(path); foreach(var page in pdf.GetPages()) Add("paragraph",page.Text,$"第 {page.Number} 页"); if(list.Sum(s=>s.Text.Length)<20) throw new InvalidDataException("此PDF没有可提取文字层；不支持扫描版PDF。"); }
  else if(ext is ".docx" or ".epub") {
   using var zip=ZipFile.OpenRead(path);
   var entries=ext==".docx" ? zip.Entries.Where(e=>e.FullName=="word/document.xml") : zip.Entries.Where(e=>new[]{".xhtml",".html",".htm"}.Contains(Path.GetExtension(e.FullName).ToLowerInvariant())&&!Path.GetFileName(e.FullName).Contains("nav",StringComparison.OrdinalIgnoreCase)).OrderBy(e=>e.FullName,StringComparer.Ordinal);
   foreach(var entry in entries) {
    using var stream=entry.Open(); using var reader=XmlReader.Create(stream,new XmlReaderSettings{DtdProcessing=DtdProcessing.Ignore,XmlResolver=null});
    var xml=XDocument.Load(reader); var tags=new[]{"p","h1","h2","h3","h4","h5","h6","li","td","th"};
    foreach(var block in xml.Descendants().Where(e=>tags.Contains(e.Name.LocalName)&&!e.Descendants().Any(d=>tags.Contains(d.Name.LocalName)))) {
     var tag=block.Name.LocalName; var text=ext==".docx" ? string.Concat(block.Descendants().Select(e=>e.Name.LocalName switch {"t"=>e.Value,"tab"=>"\t","br"=>"\n",_=>""})) : block.Value;
     Add(tag.StartsWith('h')?"heading":tag=="li"?"listItem":"paragraph",Regex.Replace(text,@"\s+"," "),entry.FullName);
    }
   }
  } else if(ext is ".txt" or ".md" or ".markdown") {
   var text=ReadText(path).Replace("\r\n","\n"); var buffer=new StringBuilder(); bool code=false;
   void Flush(string kind="paragraph") { Add(kind,buffer.ToString(),$"段落 {list.Count+1}"); buffer.Clear(); }
   if(ext==".txt") foreach(var chunk in text.Split("\n\n")) Add("paragraph",chunk,$"段落 {list.Count+1}");
   else { foreach(var line in text.Split('\n')) {
    if(line.TrimStart().StartsWith("```")) { if(code){buffer.AppendLine(line);Flush("code");}else{Flush();buffer.AppendLine(line);}code=!code; }
    else if(code)buffer.AppendLine(line);
    else if(Regex.IsMatch(line,@"^\s*#+\s*")){Flush();Add("heading",Regex.Replace(line,@"^\s*#+\s*",""),$"段落 {list.Count+1}");}
    else if(Regex.IsMatch(line,@"^\s*[-*]\s+")){Flush();Add("listItem",Regex.Replace(line,@"^\s*[-*]\s+",""),$"段落 {list.Count+1}");}
    else if(string.IsNullOrWhiteSpace(line))Flush();else buffer.AppendLine(line);
   } Flush(code?"code":"paragraph"); }
  } else throw new InvalidDataException("暂不支持此文件类型。");
  if(list.Count==0)throw new InvalidDataException("文档中没有可翻译的正文。"); return new(Path.GetFileNameWithoutExtension(path),list);
 }
 static string ReadText(string path){var b=File.ReadAllBytes(path);if(b.Length>=2&&(b[0]==255&&b[1]==254||b[0]==254&&b[1]==255))return (b[0]==255?Encoding.Unicode:Encoding.BigEndianUnicode).GetString(b,2,b.Length-2);try{return new UTF8Encoding(false,true).GetString(b).TrimStart('\uFEFF');}catch(DecoderFallbackException){return Encoding.Latin1.GetString(b);}}
 public static string Export(Document doc,List<Translation> items,string directory,string language,bool bilingual,bool word) {
  var title=string.Concat(doc.Title.Select(c=>Path.GetInvalidFileNameChars().Contains(c)?'-':c)).Trim().TrimEnd('.');if(title.Length==0)title="整书翻译";
  var stem=$"{title}.{language}.{(bilingual?"bilingual":"translated")}";var ext=word?".docx":".md";var path=Path.Combine(directory,stem+ext);int n=2;while(File.Exists(path))path=Path.Combine(directory,$"{stem}-{n++}{ext}");
  var temp=Path.Combine(directory,$".zhengxin-{Guid.NewGuid():N}.tmp");
  try {
   if(!word){var b=new StringBuilder($"# {doc.Title}\n\n");foreach(var t in items){if(t.Source.Kind=="code"){b.Append(t.Source.Text+"\n\n");continue;}var prefix=t.Source.Kind=="heading"?"## ":t.Source.Kind=="listItem"?"- ":"";if(bilingual)b.Append(prefix+t.Source.Text+"\n\n");b.Append(prefix+t.Text+"\n\n");}File.WriteAllText(temp,b.ToString(),new UTF8Encoding(false));}
   else {
    using var zip=ZipFile.Open(temp,ZipArchiveMode.Create);
    void Put(string name,string value){using var w=new StreamWriter(zip.CreateEntry(name).Open(),new UTF8Encoding(false));w.Write(value);}
    XNamespace w="http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    XElement Para(string text,bool heading=false,bool gray=false)=>new(w+"p",new XElement(w+"pPr",new XElement(w+"pStyle",new XAttribute(w+"val",heading?"Heading1":"Normal"))),new XElement(w+"r",gray?new XElement(w+"rPr",new XElement(w+"color",new XAttribute(w+"val","666666"))):null,text.Split('\n').Select((line,i)=>new object?[]{i>0?new XElement(w+"br"):null,new XElement(w+"t",new XAttribute(XNamespace.Xml+"space","preserve"),line)})));
    var body=new XElement(w+"body",Para(doc.Title,true));foreach(var t in items){if(bilingual)body.Add(Para(t.Source.Text,t.Source.Kind=="heading",true));body.Add(Para(t.Text,t.Source.Kind=="heading"));}body.Add(new XElement(w+"sectPr",new XElement(w+"pgSz",new XAttribute(w+"w","11906"),new XAttribute(w+"h","16838"))));
    Put("word/document.xml",new XDocument(new XElement(w+"document",body)).ToString());
    Put("[Content_Types].xml","<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>");
    Put("_rels/.rels","<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>");
    Put("word/_rels/document.xml.rels","<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>");
    Put("word/styles.xml",$"<w:styles xmlns:w=\"{w}\"><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:rPr><w:b/><w:sz w:val=\"28\"/></w:rPr></w:style></w:styles>");
   } File.Move(temp,path);return path;
  } finally {if(File.Exists(temp))File.Delete(temp);}
 }
}
