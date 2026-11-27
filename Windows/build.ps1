$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '构建机需要 .NET 10 SDK；最终用户无需安装。' }
dotnet run --project "$root\Tests" -- "$root\Assets"
if ($LASTEXITCODE -ne 0) { throw '核心验收失败' }
dotnet publish "$root\正心Translate\Zhengxin.Windows.csproj" -c Release -r win-x64 --self-contained true -o "$root\artifacts\app"
if ($LASTEXITCODE -ne 0) { throw '发布失败' }
# Console subsystem executable uses the same prepared local model and runtime.
dotnet publish "$root\CLI\Zhengxin.Cli.csproj" -c Release -r win-x64 --self-contained true -o "$root\artifacts\app"
if ($LASTEXITCODE -ne 0) { throw 'CLI/MCP 发布失败' }
$previousMock = $env:ZHENGXIN_TRANSLATE_MOCK
try {
    $env:ZHENGXIN_TRANSLATE_MOCK = '1'
    $cliResult = & "$root\artifacts\app\zhengxin-translate.exe" text 'Hello' --to en --json
    if ($LASTEXITCODE -ne 0 -or ($cliResult | ConvertFrom-Json).translation -ne '[en] Hello') { throw 'CLI 冒烟测试失败' }
} finally { $env:ZHENGXIN_TRANSLATE_MOCK = $previousMock }
$payload = "$root\artifacts\payload.zip"
if (Test-Path $payload) { Remove-Item $payload }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory("$root\artifacts\app", $payload)
dotnet publish "$root\Bootstrapper\Zhengxin.Setup.csproj" -c Release -r win-x64 --self-contained true -o "$root\artifacts\setup"
if ($LASTEXITCODE -ne 0) { throw '安装器构建失败' }
Copy-Item "$root\artifacts\setup\ZhengxinTranslate-Setup.exe" "$root\artifacts\正心Translate-Windows-Setup.exe" -Force
Get-FileHash "$root\artifacts\正心Translate-Windows-Setup.exe" -Algorithm SHA256
