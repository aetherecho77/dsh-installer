#Requires -RunAsAdministrator
<#
install-dsh.ps1 — 从零装一套 DeepSeek Harness 到「能填 key」的状态

一眼看懂：装本体 → 初始化 profile → 装插件 → 出报告。
登录和 key 留给人，这里不碰。

用法：
  .\install-dsh.ps1 -Source "C:\Downloads\setup.exe"
  .\install-dsh.ps1 -Source "..." -SkipWeChat -SkipVoiceInput

参数：
  -Source        官方安装包路径（必填）
  -OfflineDir    你自己的离线插件包目录（可选，没有就跳过）
  -Profile       profile 名，默认 desktop
  -SkipPlugins   只装本体，不装插件
  -SkipImageGen  不装生图插件（体积大）
  -SkipWeChat    不装微信通道
  -SkipVoiceInput 不装语音输入
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [string]$OfflineDir = (Join-Path $PSScriptRoot "plugins"),
    [string]$Profile = "desktop",
    [switch]$SkipPlugins,
    [switch]$SkipImageGen,
    [switch]$SkipWeChat,
    [switch]$SkipVoiceInput
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$ErrorActionPreference = 'Continue'
$report = New-Object System.Collections.ArrayList
$failed = New-Object System.Collections.ArrayList

function Say {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[{0}] {1}" -f $Level, $Msg
    Write-Host $line
    [void]$report.Add($line)
}

function Step {
    param([string]$Title)
    Say ("=== " + $Title + " ===")
}

function Get-DshProcs {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*DeepSeek*' })
}

# ---------- 0. 前置检查 ----------
Step "前置检查"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say "不是管理员权限，退出" ERROR
    exit 1
}
Say "管理员权限 OK"

if (-not (Test-Path $Source)) {
    Say ("安装包不存在：" + $Source) ERROR
    exit 1
}
Say ("安装包 " + [math]::Round((Get-Item $Source).Length / 1MB, 1) + " MB")

$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Say ("C 盘剩余 " + $freeGB + " GB")
if ($freeGB -lt 5) { Say "C 盘不足 5 GB，继续但可能失败" WARN }

$os = Get-CimInstance Win32_OperatingSystem
Say ("系统 " + $os.Caption + " build " + $os.BuildNumber)

# ---------- 1. 装本体 ----------
Step "安装 DeepSeek Harness"

$exe = Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\DeepSeek Harness.exe"
$cli = Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd"

if (Test-Path $exe) {
    Say "已经装过了，跳过安装"
} else {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Source -ArgumentList '/S' -PassThru -Wait
    $sw.Stop()
    Say ("安装退出码 " + $p.ExitCode + "，耗时 " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + " 秒")
}

if (-not (Test-Path $exe)) { Say ("找不到主程序：" + $exe) ERROR; exit 1 }
if (-not (Test-Path $cli)) { Say ("找不到 CLI：" + $cli) ERROR; exit 1 }
Say ("主程序 OK，CLI 版本 " + ((& $cli --version 2>&1 | Out-String).Trim()))

# ---------- 2. 初始化 profile ----------
# 新装的 DSH 没有 ~\.dsh\profiles\desktop，而 dsh plugin 必须先有它。
# desktop profile 只能由 Electron 应用创建（命令行会报 "managed exclusively by the Electron application"），
# 所以这里启动一次 GUI，等 package.json 出现，再把进程杀干净。
#
# 注意：这一步要求脚本跑在有交互桌面的会话里。在服务会话 / 远程无桌面环境里会失败。
Step "初始化 profile"

$profilePkg = Join-Path $env:USERPROFILE (".dsh\profiles\" + $Profile + "\package.json")

if (Test-Path $profilePkg) {
    Say "profile 已存在，跳过"
} else {
    Say "第一次启动，初始化 profile（正常 2–15 秒）"
    Start-Process -FilePath $exe | Out-Null
    $waited = 0
    while ($waited -lt 90) {
        Start-Sleep -Seconds 3
        $waited += 3
        if (Test-Path $profilePkg) { break }
    }
    if (-not (Test-Path $profilePkg)) {
        Say "profile 没初始化出来。请手动打开一次 DeepSeek Harness，看到登录界面后完全关闭，再重跑本脚本。" ERROR
        Say "（这种情况多半是脚本跑在没有桌面的会话里，GUI 起不来）" ERROR
        exit 1
    }
    Say ("profile 初始化完成，用了 " + $waited + " 秒")

    $procs = Get-DshProcs
    Say ("启动后进程数 " + $procs.Count + "，现在全部退出")
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $left = Get-DshProcs
    if ($left.Count -gt 0) {
        Say ("还有 " + $left.Count + " 个进程没退，再杀一次") WARN
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Say ("退出后剩余进程 " + (Get-DshProcs).Count)
}

if (Test-Path $profilePkg) {
    $txt = Get-Content $profilePkg -Raw -Encoding UTF8
    if ($txt -match '"[^"]*\.\.\."|正在安装|installing') { Say "profile 文件内容可疑，请人工看一眼" WARN }
}

# ---------- 3. 装插件 ----------
# 下面这份清单是「常用的一组」，按需增删。
# 任何一个不在 npm 公共源上的包，都放进 -OfflineDir 用 .tgz 装。
$publicPlugins = @(
    'dsh-plugin-marketplace',
    'dsh-image-gen',
    '@anionex/dsh-vision-toolkit',
    '@xmanrui/dsh-im',
    '@fooxe/dsh-memory',
    'billion-context',
    'dsh-better-sidebar',
    'dsh-handoff',
    '@deepseek-ai/dsh-experimental-voice-input-bundle'
)
if ($SkipImageGen) { $publicPlugins = $publicPlugins | Where-Object { $_ -ne 'dsh-image-gen' } }
if ($SkipWeChat) { $publicPlugins = $publicPlugins | Where-Object { $_ -ne '@xmanrui/dsh-im' } }
if ($SkipVoiceInput) { $publicPlugins = $publicPlugins | Where-Object { $_ -ne '@deepseek-ai/dsh-experimental-voice-input-bundle' } }

if ($SkipPlugins) {
    Say "跳过插件安装（-SkipPlugins）" WARN
} else {
    Step ("安装插件（公共源 " + $publicPlugins.Count + " 个）")
    $i = 0
    foreach ($name in $publicPlugins) {
        $i++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = & $cli plugin --profile $Profile add $name 2>&1
        $sw.Stop()
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Say ("[{0}/{1}] {2} OK ({3}s)" -f $i, $publicPlugins.Count, $name, [math]::Round($sw.Elapsed.TotalSeconds, 1))
        } elseif (($out -join ' ') -match 'allow-version') {
            Say ("[{0}/{1}] {2} 版本门禁：插件没声明兼容当前 Harness" -f $i, $publicPlugins.Count, $name) WARN
            Say ("  要装的话手动跑：dsh plugin --profile " + $Profile + " allow-version <包>@<版本> --dsh-version <当前版本> --accept-risk") WARN
            [void]$failed.Add($name + " (版本门禁)")
        } else {
            $tail = (($out | Select-Object -Last 3) -join ' | ') -replace '\s+', ' '
            Say ("[{0}/{1}] {2} 失败 exit={3} {4}" -f $i, $publicPlugins.Count, $name, $code, $tail) ERROR
            [void]$failed.Add($name)
        }
    }

    # 离线包：把 .tgz 放进 -OfflineDir，文件名以包名开头即可
    if (Test-Path $OfflineDir) {
        $tgzs = @(Get-ChildItem $OfflineDir -Filter '*.tgz' -ErrorAction SilentlyContinue)
        if ($tgzs.Count -gt 0) {
            Step ("安装离线插件包（" + $tgzs.Count + " 个）")
            foreach ($tgz in $tgzs) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $out = & $cli plugin --profile $Profile add $tgz.FullName 2>&1
                $sw.Stop()
                $code = $LASTEXITCODE
                if ($code -eq 0) {
                    Say ($tgz.Name + " OK (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s)")
                } else {
                    $tail = (($out | Select-Object -Last 3) -join ' | ') -replace '\s+', ' '
                    Say ($tgz.Name + " 失败 exit=" + $code + " " + $tail) ERROR
                    [void]$failed.Add($tgz.Name)
                }
            }
        }
    }
}

# ---------- 4. 盘点 ----------
Step "盘点"

if (Test-Path $profilePkg) {
    try {
        $pj = Get-Content $profilePkg -Raw -Encoding UTF8 | ConvertFrom-Json
        $bundles = @($pj.dsh.profile.bundles)
        Say ("bundles " + $bundles.Count + " 项")
        foreach ($b in $bundles) { Say ("  - " + $b) }
        Say ("dependencies " + @($pj.dependencies.PSObject.Properties.Name).Count + " 项")
    } catch {
        Say ("profile 解析失败：" + $_.Exception.Message) ERROR
    }
} else {
    Say ("profile 配置不存在：" + $profilePkg) ERROR
}

$creds = Join-Path $env:USERPROFILE ".dsh\.credentials.yaml"
if (Test-Path $creds) { Say "凭据文件已存在" } else { Say "凭据文件还没有（正常，登录后才生成）" }

# ---------- 5. 报告 ----------
Step "报告"

Say "已完成：装本体、初始化 profile、装插件。"
Say ""
Say "还需要你手动做三件事："
Say "  1. 打开 DeepSeek Harness，点 Sign in 或 Add API Key"
Say "  2. 填你自己的模型 key（用官方渠道的，不要用第三方中转）"
Say "  3. 微信通道如果要开，扫码登录一次"
Say ""

if ($failed.Count -gt 0) {
    Say ("有 " + $failed.Count + " 个没装成：") WARN
    foreach ($f in $failed) { Say ("  - " + $f) WARN }
    Say "分开处理：网络原因的，重跑同一条命令；标「版本门禁」的，按上面给的命令手动 allow-version；离线包的，检查 OfflineDir 路径。" WARN
} else {
    Say "全部装好了。"
}

$outFile = Join-Path $env:TEMP ("install-dsh-report-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
$report -join "`r`n" | Set-Content -Path $outFile -Encoding UTF8
Say ("完整报告：" + $outFile)

exit 0
