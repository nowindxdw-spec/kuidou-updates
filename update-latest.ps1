# SkillEval 一键更新 —— 流程对齐 aisites/UFO 的 install-latest：
#   读 latest.json（机器可读清单）-> 比对本地版本 -> 下载 zip -> 校验 SHA-256 -> 解压落盘 -> 提示切换
#
#   powershell -File scripts\update-latest.ps1                          # 从 GitHub 更新仓拉最新版
#   powershell -File scripts\update-latest.ps1 -Tag v0.2.0              # 指定版本
#   powershell -File scripts\update-latest.ps1 -SourceDir \\nas\kuidou  # 内网镜像目录（含 latest.json + zip），不访问外网
param(
    [string]$Repo = "nowindxdw-spec/kuidou-updates",
    [string]$Tag = "",
    [string]$ManifestUrl = "",
    [string]$SourceDir = "",
    [switch]$DownloadOnly
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
function Say($m) { Write-Host "[kuidou-update] $m" }
function Die($m) { Write-Host "[kuidou-update] x $m" -ForegroundColor Red; exit 1 }
# GitHub 通道下让 .NET 默认代理跟随系统 IE 代理设置（直连可能被重置；内网 -SourceDir 通道不受影响）
if (-not $SourceDir) {
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
            $px = ($ie.ProxyServer -split ';')[0]
            if ($px -notmatch '^https?://') { $px = 'http://' + $px }
            [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy($px, $true)
            $env:HTTP_PROXY = $px; $env:HTTPS_PROXY = $px # curl.exe 下载走环境变量
        }
    } catch {}
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# 1) 清单
if ($SourceDir) {
    $manifest = Get-Content (Join-Path $SourceDir "latest.json") -Raw | ConvertFrom-Json
} else {
    $u = if ($ManifestUrl) { $ManifestUrl } elseif ($Tag) { "https://api.github.com/repos/$Repo/releases/tags/$Tag" } else { "https://api.github.com/repos/$Repo/releases/latest" }
    $rel = Invoke-RestMethod -Uri $u -Headers @{ Accept = "application/vnd.github+json" }
    $manifest = $rel.assets | Where-Object { $_.name -eq "latest.json" } | ForEach-Object { Invoke-RestMethod -Uri $_.browser_download_url }
    if (-not $manifest) { Die "该 Release 未附带 latest.json 清单" }
}
Say ("清单版本：" + $manifest.tag + "（" + $manifest.publishedAt + "）")

# 2) 比对本地版本（单一事实源 = skilleval/__init__.py 的 __version__，不依赖解释器）
$verText = [System.IO.File]::ReadAllText((Join-Path $root "skilleval\__init__.py"))
$local = [regex]::Match($verText, '__version__\s*=\s*"([^"]+)"').Groups[1].Value
if ("v" + $local -eq $manifest.tag) { Say ("已是本地同版本 v$local，如要强装请换目录或改版本") }

# 3) 下载
$asset = $manifest.assets | Select-Object -First 1
$zipPath = Join-Path $env:TEMP $asset.name
if ($SourceDir) { Copy-Item (Join-Path $SourceDir $asset.name) $zipPath -Force }
else {
    Say ("下载：" + $manifest.download)
    curl.exe -sL -H "Expect:" --speed-limit 4096 --speed-time 60 -o $zipPath $manifest.download
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipPath)) { Die "下载失败" }
}

# 4) SHA-256 校验，不过不落盘
$sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
if ($sha -ne $manifest.sha256) { Remove-Item $zipPath -Force; Die ("SHA-256 复核失败！期望 " + $manifest.sha256 + " 实际 " + $sha) }
Say ("SHA-256 复核通过 " + $sha.Substring(0, 16) + "...")
if ($DownloadOnly) { Say ("-DownloadOnly：包在 " + $zipPath); exit 0 }

# 5) 解压到 releases/<tag>/，新目录需自建 .venv 装依赖
$dest = Join-Path (Join-Path $root "releases") $manifest.tag
if (Test-Path $dest) { Die ("目标目录已存在：" + $dest + "（同版本重复更新？先手动移除）") }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Expand-Archive -LiteralPath $zipPath -DestinationPath $dest
Say ("已落盘：" + $dest)
Say "后续：cd $dest ; python -m venv .venv ; uv pip install --python .venv/Scripts/python.exe -r requirements.txt ; .venv/Scripts/python.exe -m skilleval serve"
Say "Web 界面：http://127.0.0.1:8000"
