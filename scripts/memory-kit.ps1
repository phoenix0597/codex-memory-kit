#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("install", "init-project", "check", "export", "import")]
  [string]$Command,

  [Alias("Home")]
  [string]$HomeDir,

  [Alias("Repo")]
  [string]$RepoRoot,

  [string]$ProjectName,
  [string]$CodexDir,
  [string]$DshDir,
  [ValidateSet("codex", "dsh", "antigravity", "all", "none")]
  [string]$Agent = "codex",
  [string]$GlobalMemoryDir,
  [string]$SourceRoot,
  [string]$OutputDir,
  [string]$InputDir,

  [ValidateSet("global", "project", "all")]
  [string]$Mode = "all",

  [switch]$Strict,
  [switch]$Force,
  [switch]$DryRun,
  [switch]$VerboseLog,
  [switch]$NoHomeAgents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$DefaultSourceRoot = Split-Path -Parent $ScriptDir
$Utf8WithBom = New-Object System.Text.UTF8Encoding -ArgumentList $true

function Show-Usage {
  @"
Использование:
  .\scripts\memory-kit.ps1 install [-Home <path>] [-Agent <codex|dsh|antigravity|all|none>] [-DshDir <path>] [-CodexDir <path>] [-GlobalMemoryDir <path>] [-SourceRoot <path>] [-Force] [-DryRun] [-VerboseLog] [-NoHomeAgents]
  .\scripts\memory-kit.ps1 init-project [-Repo <path>] [-ProjectName <name>] [-Home <path>] [-Agent <codex|dsh|antigravity|all|none>] [-DshDir <path>] [-CodexDir <path>] [-GlobalMemoryDir <path>] [-SourceRoot <path>] [-Force] [-DryRun] [-VerboseLog]
  .\scripts\memory-kit.ps1 check [-Home <path>] [-Repo <path>] [-Agent <codex|dsh|antigravity|all|none>] [-DshDir <path>] [-CodexDir <path>] [-GlobalMemoryDir <path>] [-Mode <global|project|all>] [-Strict] [-VerboseLog]
  .\scripts\memory-kit.ps1 export [-Home <path>] -OutputDir <path> [-Repo <path>] [-Agent <codex|dsh|antigravity|all|none>] [-DshDir <path>] [-CodexDir <path>] [-GlobalMemoryDir <path>] [-Force] [-DryRun] [-VerboseLog]
  .\scripts\memory-kit.ps1 import -InputDir <path> [-Home <path>] [-Repo <path>] [-Agent <codex|dsh|antigravity|all|none>] [-DshDir <path>] [-CodexDir <path>] [-GlobalMemoryDir <path>] [-Force] [-DryRun] [-VerboseLog]
"@
}

function Resolve-KitPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue,
    [string]$BasePath = (Get-Location).Path
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    throw "Пустой путь недопустим."
  }

  if ($PathValue -eq "~") {
    return Normalize-ResolvedPath ([System.IO.Path]::GetFullPath($HOME))
  }

  if ($PathValue.StartsWith("~/") -or $PathValue.StartsWith("~\")) {
    return Normalize-ResolvedPath ([System.IO.Path]::GetFullPath((Join-Path $HOME $PathValue.Substring(2))))
  }

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return Normalize-ResolvedPath ([System.IO.Path]::GetFullPath($PathValue))
  }

  return Normalize-ResolvedPath ([System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue)))
}

function Normalize-ResolvedPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue
  )

  $root = [System.IO.Path]::GetPathRoot($PathValue)
  if ($PathValue.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $PathValue
  }

  return $PathValue.TrimEnd([char[]]@("\", "/"))
}

function Convert-ToMsysPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue
  )

  $normalized = $PathValue.TrimEnd([char[]]@("\", "/"))
  if ($normalized -match "^([A-Za-z]):[\\/](.*)$") {
    $drive = $matches[1].ToLowerInvariant()
    $rest = $matches[2].Replace("\", "/")
    if ([string]::IsNullOrWhiteSpace($rest)) {
      return "/$drive"
    }
    return "/$drive/$rest"
  }

  return $normalized.Replace("\", "/")
}

function Join-KitPath {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Parts
  )

  $result = $Parts[0]
  for ($i = 1; $i -lt $Parts.Count; $i++) {
    $result = Join-Path $result $Parts[$i]
  }
  return $result
}

function Write-KitLog {
  param([string]$Text)
  if ($VerboseLog) {
    Write-Output $Text
  }
}

function Write-KitStatus {
  param([string]$Text)
  if ($DryRun) {
    Write-Output "DRY-RUN $Text"
  } else {
    Write-Output $Text
  }
}

function Write-Utf8WithBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, $Utf8WithBom)
}

function Normalize-RenderedWindowsPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [hashtable]$Variables
  )

  foreach ($key in $Variables.Keys) {
    if ($key -like "*_POSIX") {
      continue
    }

    $value = $Variables[$key]
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      continue
    }

    $path = [string]$value
    if ($path.StartsWith("/")) {
      continue
    }

    $backtick = [char]96
    $pattern = [regex]::Escape($path) + "[^$backtick\s,)]*"
    $Content = [regex]::Replace($Content, $pattern, {
      param($match)
      $match.Value.Replace("/", "\")
    })
  }

  return $Content
}

function Normalize-RenderedPosixPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content
  )

  $backtick = [char]96
  $pattern = "/(?:[A-Za-z]|mnt/[A-Za-z])(?:/|\\)[^$backtick\s,)]*"
  return [regex]::Replace($Content, $pattern, {
    param($match)
    $match.Value.Replace("\", "/")
  })
}

function Get-EffectiveHome {
  if (-not [string]::IsNullOrWhiteSpace($HomeDir)) {
    return Resolve-KitPath $HomeDir
  }

  if (-not [string]::IsNullOrWhiteSpace($HOME)) {
    return Resolve-KitPath $HOME
  }

  $profileHome = [Environment]::GetFolderPath("UserProfile")
  if (-not [string]::IsNullOrWhiteSpace($profileHome)) {
    return Resolve-KitPath $profileHome
  }

  throw "Не удалось определить домашний каталог. Передайте -Home <path>."
}

function Get-EffectiveCodexDir {
  param([Parameter(Mandatory = $true)][string]$EffectiveHome)
  if (-not [string]::IsNullOrWhiteSpace($CodexDir)) {
    return Resolve-KitPath $CodexDir
  }
  return Join-Path $EffectiveHome ".codex"
}

function Get-EffectiveDshDir {
  param([Parameter(Mandatory = $true)][string]$EffectiveHome)
  if (-not [string]::IsNullOrWhiteSpace($DshDir)) { return Resolve-KitPath $DshDir }
  return Join-Path $EffectiveHome ".dsh"
}

function Get-AgentEntrypoints {
  param([string]$EffectiveCodexDir, [string]$EffectiveDshDir)
  if ($Agent -eq "codex" -or $Agent -eq "all") { Join-Path $EffectiveCodexDir "AGENTS.md" }
  if ($Agent -eq "dsh" -or $Agent -eq "all") { Join-Path $EffectiveDshDir "AGENTS.md" }
}

function Get-EffectiveGlobalMemoryDir {
  param([Parameter(Mandatory = $true)][string]$EffectiveCodexDir)
  if (-not [string]::IsNullOrWhiteSpace($GlobalMemoryDir)) {
    return Resolve-KitPath $GlobalMemoryDir
  }
  $legacyMemory = Join-Path $EffectiveCodexDir "memories"
  if (-not [string]::IsNullOrWhiteSpace($CodexDir)) { return $legacyMemory }
  $sharedMemory = Join-KitPath -Parts @((Get-EffectiveHome), ".agents", "memories")
  if ((Test-Path -LiteralPath $sharedMemory -PathType Container) -and (Test-Path -LiteralPath $legacyMemory -PathType Container)) {
    throw "Both shared and legacy memory exist; select -GlobalMemoryDir explicitly."
  }
  if (Test-Path -LiteralPath $legacyMemory -PathType Container) { return $legacyMemory }
  return $sharedMemory
}

function Get-EffectiveSourceRoot {
  if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
    return Resolve-KitPath $SourceRoot
  }
  return Resolve-KitPath $DefaultSourceRoot
}

function Get-RequiredRepoRoot {
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if ($Command -eq "init-project" -or $Command -eq "check") {
      return Resolve-KitPath ((Get-Location).Path)
    }
    throw "Укажите -Repo <path>."
  }
  return Resolve-KitPath $RepoRoot
}

function Read-Utf8File {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Render-Template {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [hashtable]$Variables
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Отсутствует шаблон: $Source"
  }

  $content = Read-Utf8File $Source
  foreach ($name in $Variables.Keys) {
    $content = $content.Replace("{{$name}}", [string]$Variables[$name])
  }
  $content = Normalize-RenderedWindowsPaths -Content $content -Variables $Variables
  $content = Normalize-RenderedPosixPaths -Content $content

  if ($content -match "{{[A-Z_][A-Z0-9_]*}}") {
    throw "После рендера остались незаполненные плейсхолдеры: $Source"
  }

  $exists = Test-Path -LiteralPath $Destination
  if ($exists -and -not $Force) {
    Write-KitStatus "SKIP $Destination"
    return
  }

  if ($DryRun) {
    if ($exists) {
      Write-KitStatus "OVERWRITE $Destination"
    } else {
      Write-KitStatus "CREATE $Destination"
    }
    return
  }

  $parent = Split-Path -Parent $Destination
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Write-Utf8WithBom -Path $Destination -Content $content

  if ($exists -and $Force) {
    Write-KitStatus "OVERWRITE $Destination"
  } else {
    Write-KitStatus "CREATE $Destination"
  }
}

function Render-DailyFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$DateText
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Отсутствует шаблон: $Source"
  }

  $content = (Read-Utf8File $Source).Replace("YYYY-MM-DD", $DateText)
  $exists = Test-Path -LiteralPath $Destination

  if ($exists -and -not $Force) {
    Write-KitStatus "SKIP $Destination"
    return
  }

  if ($DryRun) {
    if ($exists) {
      Write-KitStatus "OVERWRITE $Destination"
    } else {
      Write-KitStatus "CREATE $Destination"
    }
    return
  }

  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Write-Utf8WithBom -Path $Destination -Content $content

  if ($exists -and $Force) {
    Write-KitStatus "OVERWRITE $Destination"
  } else {
    Write-KitStatus "CREATE $Destination"
  }
}

function Invoke-Install {
  $effectiveHome = Get-EffectiveHome
  $effectiveCodexDir = Get-EffectiveCodexDir $effectiveHome
  $effectiveDshDir = Get-EffectiveDshDir $effectiveHome
  $effectiveGlobalMemoryDir = Get-EffectiveGlobalMemoryDir $effectiveCodexDir
  $effectiveSourceRoot = Get-EffectiveSourceRoot

  Write-KitLog "Корень исходного набора: $effectiveSourceRoot"
  Write-KitLog "Глобальная память: $effectiveGlobalMemoryDir"

  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $effectiveGlobalMemoryDir | Out-Null
  }

  $variables = @{
    HOME_DIR = $effectiveHome
    DSH_DIR = $effectiveDshDir
    KIT_ROOT = $effectiveSourceRoot
    CODEX_DIR = $effectiveCodexDir
    GLOBAL_MEMORY_DIR = $effectiveGlobalMemoryDir
    HOME_DIR_POSIX = Convert-ToMsysPath $effectiveHome
    DSH_DIR_POSIX = Convert-ToMsysPath $effectiveDshDir
    KIT_ROOT_POSIX = Convert-ToMsysPath $effectiveSourceRoot
    CODEX_DIR_POSIX = Convert-ToMsysPath $effectiveCodexDir
    GLOBAL_MEMORY_DIR_POSIX = Convert-ToMsysPath $effectiveGlobalMemoryDir
    HOME_DIR_WINDOWS = $effectiveHome
    DSH_DIR_WINDOWS = $effectiveDshDir
    KIT_ROOT_WINDOWS = $effectiveSourceRoot
    CODEX_DIR_WINDOWS = $effectiveCodexDir
    GLOBAL_MEMORY_DIR_WINDOWS = $effectiveGlobalMemoryDir
  }

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "global", "global-collaboration-rules.md")) `
    (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "global-collaboration-rules.md")) `
    $variables

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "global", "memory-architecture.md")) `
    (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "memory-architecture.md")) `
    $variables

  if (-not $NoHomeAgents) {
    Render-Template `
      (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "home", "AGENTS.md.template")) `
      (Join-KitPath -Parts @($effectiveHome, "AGENTS.md")) `
      $variables
  }
  foreach ($entrypoint in @(Get-AgentEntrypoints $effectiveCodexDir $effectiveDshDir)) {
    Render-Template (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "agent", "AGENTS.md.template")) $entrypoint $variables
  }

}

function Invoke-InitProject {
  $effectiveRepoRoot = Get-RequiredRepoRoot
  if (-not (Test-Path -LiteralPath $effectiveRepoRoot -PathType Container)) {
    throw "Каталог репозитория не найден: $effectiveRepoRoot"
  }

  $effectiveHome = Get-EffectiveHome
  $effectiveCodexDir = Get-EffectiveCodexDir $effectiveHome
  $effectiveDshDir = Get-EffectiveDshDir $effectiveHome
  $effectiveGlobalMemoryDir = Get-EffectiveGlobalMemoryDir $effectiveCodexDir
  $effectiveSourceRoot = Get-EffectiveSourceRoot
  $effectiveProjectName = $ProjectName
  if ([string]::IsNullOrWhiteSpace($effectiveProjectName)) {
    $effectiveProjectName = Split-Path -Leaf $effectiveRepoRoot
  }
  $today = (Get-Date).ToString("yyyy-MM-dd")

  Write-KitLog "Корень исходного набора: $effectiveSourceRoot"
  Write-KitLog "Проектная память: $effectiveRepoRoot"

  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "_templates")) | Out-Null
  }

  $variables = @{
    HOME_DIR = $effectiveHome
    DSH_DIR = $effectiveDshDir
    KIT_ROOT = $effectiveSourceRoot
    CODEX_DIR = $effectiveCodexDir
    GLOBAL_MEMORY_DIR = $effectiveGlobalMemoryDir
    REPO_ROOT = $effectiveRepoRoot
    PROJECT_NAME = $effectiveProjectName
    HOME_DIR_POSIX = Convert-ToMsysPath $effectiveHome
    DSH_DIR_POSIX = Convert-ToMsysPath $effectiveDshDir
    KIT_ROOT_POSIX = Convert-ToMsysPath $effectiveSourceRoot
    CODEX_DIR_POSIX = Convert-ToMsysPath $effectiveCodexDir
    GLOBAL_MEMORY_DIR_POSIX = Convert-ToMsysPath $effectiveGlobalMemoryDir
    REPO_ROOT_POSIX = Convert-ToMsysPath $effectiveRepoRoot
    HOME_DIR_WINDOWS = $effectiveHome
    DSH_DIR_WINDOWS = $effectiveDshDir
    KIT_ROOT_WINDOWS = $effectiveSourceRoot
    CODEX_DIR_WINDOWS = $effectiveCodexDir
    GLOBAL_MEMORY_DIR_WINDOWS = $effectiveGlobalMemoryDir
    REPO_ROOT_WINDOWS = $effectiveRepoRoot
  }

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "AGENTS.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "AGENTS.md")) `
    $variables

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "START-HERE.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "START-HERE.md")) `
    $variables

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "assistant-memory.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "assistant-memory.md")) `
    $variables

  if ($Agent -eq "antigravity" -or $Agent -eq "all") {
    Render-Template `
      (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", ".gemini", "rules", "antigravity-memory-adapter.md.template")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, ".gemini", "rules", "antigravity-memory-adapter.md")) `
      $variables
  }


  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "memory", "current-work-queue.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "current-work-queue.md")) `
    $variables

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "memory", "topic-memory-improvement.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "topic-memory-improvement.md")) `
    $variables

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "memory", "_templates", "daily.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "_templates", "daily.md")) `
    $variables

  Render-Template `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "memory", "_templates", "topic.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "_templates", "topic.md")) `
    $variables

  Render-DailyFile `
    (Join-KitPath -Parts @($effectiveSourceRoot, "templates", "project", "memory", "_templates", "daily.md.template")) `
    (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "$today.md")) `
    $today
}

function Add-CheckFailure {
  param(
    [ref]$Failures,
    [string]$Path,
    [string]$Reason
  )
  [Console]::Error.WriteLine("CHECK FAIL ${Path}: $Reason")
  $Failures.Value++
}

function Add-CheckOk {
  param([string]$Path)
  Write-Output "CHECK OK $Path"
}

function Require-File {
  param(
    [ref]$Failures,
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    Add-CheckOk $Path
  } else {
    Add-CheckFailure $Failures $Path "обязательный файл отсутствует"
  }
}

function Require-Contains {
  param(
    [ref]$Failures,
    [string]$Path,
    [string]$Needle,
    [string]$Reason
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-CheckFailure $Failures $Path "обязательный файл отсутствует"
    return
  }

  $content = Read-Utf8File $Path
  if ($content.Contains($Needle)) {
    Add-CheckOk $Path
  } else {
    Add-CheckFailure $Failures $Path $Reason
  }
}

function Require-NoPlaceholders {
  param(
    [ref]$Failures,
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-CheckFailure $Failures $Path "обязательный файл отсутствует"
    return
  }

  $content = Read-Utf8File $Path
  if ($content -match "{{[A-Z_][A-Z0-9_]*}}|__PROJECT_ROOT__|__PROJECT_NAME__") {
    Add-CheckFailure $Failures $Path "содержит незаполненные плейсхолдеры"
  } else {
    Add-CheckOk $Path
  }
}

function Require-MemoryLink {
  param([ref]$Failures, [string]$Path, [string]$Filename, [string]$MemoryDir, [string]$EffectiveHome)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-CheckFailure $Failures $Path "обязательный файл отсутствует"
    return
  }
  $content = Read-Utf8File $Path
  $tick = [string][char]96
  $needles = @((Join-Path $MemoryDir $Filename), ((Convert-ToMsysPath $MemoryDir) + "/" + $Filename))
  if ($MemoryDir.StartsWith($EffectiveHome + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $relative = $MemoryDir.Substring($EffectiveHome.Length + 1).Replace("\", "/") + "/" + $Filename
    $needles += $relative
    $needles += '$HOME/' + $relative
  }
  foreach ($needle in $needles) {
    if ($content.Contains($tick + $needle + $tick)) { Add-CheckOk $Path; return }
  }
  Add-CheckFailure $Failures $Path "нет ссылки на выбранную общую память: $Filename"
}

function Invoke-Check {
  $effectiveHome = Get-EffectiveHome
  $effectiveCodexDir = Get-EffectiveCodexDir $effectiveHome
  $effectiveDshDir = Get-EffectiveDshDir $effectiveHome
  $effectiveGlobalMemoryDir = Get-EffectiveGlobalMemoryDir $effectiveCodexDir
  $effectiveRepoRoot = $null
  if ($Mode -eq "project" -or $Mode -eq "all") {
    $effectiveRepoRoot = Get-RequiredRepoRoot
  }

  $failures = 0

  if ($Mode -eq "global" -or $Mode -eq "all") {
    Write-KitLog "Проверка глобальных файлов: $effectiveGlobalMemoryDir"
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "global-collaboration-rules.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "memory-architecture.md"))
    $override = Join-Path $effectiveCodexDir "AGENTS.override.md"
    if (($Agent -eq "codex" -or $Agent -eq "all") -and (Test-Path -LiteralPath $override -PathType Leaf)) {
      if (-not [string]::IsNullOrWhiteSpace((Read-Utf8File $override))) {
        Add-CheckFailure ([ref]$failures) $override "override скрывает стартовый файл Codex; проверь его содержимое"
      }
    }
    $entrypoints = @(Get-AgentEntrypoints $effectiveCodexDir $effectiveDshDir)
    if (-not $NoHomeAgents) { $entrypoints += Join-Path $effectiveHome "AGENTS.md" }
    foreach ($entrypoint in $entrypoints) {
      Require-File ([ref]$failures) $entrypoint
      if ($Strict) {
        Require-MemoryLink ([ref]$failures) $entrypoint "global-collaboration-rules.md" $effectiveGlobalMemoryDir $effectiveHome
        Require-MemoryLink ([ref]$failures) $entrypoint "memory-architecture.md" $effectiveGlobalMemoryDir $effectiveHome
        Require-NoPlaceholders ([ref]$failures) $entrypoint
      }
    }
    if ($Strict) {
      Require-NoPlaceholders ([ref]$failures) (Join-Path $effectiveGlobalMemoryDir "global-collaboration-rules.md")
      Require-NoPlaceholders ([ref]$failures) (Join-Path $effectiveGlobalMemoryDir "memory-architecture.md")
    }
  }

  if ($Mode -eq "project" -or $Mode -eq "all") {
    Write-KitLog "Проверка проектных файлов: $effectiveRepoRoot"
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "AGENTS.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "START-HERE.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "assistant-memory.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "current-work-queue.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "topic-memory-improvement.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "_templates", "daily.md"))
    Require-File ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "memory", "_templates", "topic.md"))

    if ($Agent -eq "antigravity" -or $Agent -eq "all") {
      $adapter = Join-KitPath -Parts @($effectiveRepoRoot, ".gemini", "rules", "antigravity-memory-adapter.md")
      Require-File ([ref]$failures) $adapter
      if ($Strict) {
        Require-NoPlaceholders ([ref]$failures) $adapter
        Require-MemoryLink ([ref]$failures) $adapter "global-collaboration-rules.md" $effectiveGlobalMemoryDir $effectiveHome
      }
    }

    if ($Strict) {
      foreach ($file in @("AGENTS.md", "START-HERE.md", "assistant-memory.md")) {
        $path = Join-Path $effectiveRepoRoot $file
        Require-MemoryLink ([ref]$failures) $path "global-collaboration-rules.md" $effectiveGlobalMemoryDir $effectiveHome
        Require-MemoryLink ([ref]$failures) $path "memory-architecture.md" $effectiveGlobalMemoryDir $effectiveHome
      }

      Require-Contains ([ref]$failures) `
        (Join-KitPath -Parts @($effectiveRepoRoot, "AGENTS.md")) `
        "memory/current-work-queue.md" `
        "нет ссылки на текущую очередь работы"

      Require-Contains ([ref]$failures) `
        (Join-KitPath -Parts @($effectiveRepoRoot, "START-HERE.md")) `
        "assistant-memory.md" `
        "нет ссылки на assistant-memory.md"

      Require-Contains ([ref]$failures) `
        (Join-KitPath -Parts @($effectiveRepoRoot, "assistant-memory.md")) `
        "memory-architecture.md" `
        "нет ссылки на глобальную архитектуру памяти"

      Require-NoPlaceholders ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "AGENTS.md"))
      Require-NoPlaceholders ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "START-HERE.md"))
      Require-NoPlaceholders ([ref]$failures) (Join-KitPath -Parts @($effectiveRepoRoot, "assistant-memory.md"))
    }
  }

  if ($failures -gt 0) {
    if ($Strict) {
      exit 3
    }
    exit 1
  }
}

function Copy-KitFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$Action,
    [switch]$Required
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    if ($Required) {
      throw "Исходный файл не найден: $Source"
    }
    return
  }

  $exists = Test-Path -LiteralPath $Destination
  if ($exists -and -not $Force) {
    Write-KitStatus "SKIP $Destination"
    return
  }

  if ($DryRun) {
    if ($exists -and $Force) {
      Write-KitStatus "OVERWRITE $Destination"
    } else {
      Write-KitStatus "$Action $Destination"
    }
    return
  }

  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force

  if ($exists -and $Force) {
    Write-KitStatus "OVERWRITE $Destination"
  } else {
    Write-KitStatus "$Action $Destination"
  }
}

function Copy-KitTree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$Action,
    [switch]$Required
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    if ($Required) {
      throw "Исходный каталог не найден: $Source"
    }
    return
  }

  $exists = Test-Path -LiteralPath $Destination
  if ($exists -and -not $Force) {
    Write-KitStatus "SKIP $Destination"
    return
  }

  if ($DryRun) {
    if ($exists -and $Force) {
      Write-KitStatus "OVERWRITE $Destination"
    } else {
      Write-KitStatus "$Action $Destination"
    }
    return
  }

  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
  }

  if ($exists -and $Force) {
    Write-KitStatus "OVERWRITE $Destination"
  } else {
    Write-KitStatus "$Action $Destination"
  }
}

function Invoke-Export {
  if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    throw "Укажите -OutputDir <path>."
  }

  $effectiveHome = Get-EffectiveHome
  $effectiveCodexDir = Get-EffectiveCodexDir $effectiveHome
  $effectiveDshDir = Get-EffectiveDshDir $effectiveHome
  $effectiveGlobalMemoryDir = Get-EffectiveGlobalMemoryDir $effectiveCodexDir
  $effectiveOutputDir = Resolve-KitPath $OutputDir
  $effectiveRepoRoot = $null
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $effectiveRepoRoot = Resolve-KitPath $RepoRoot
  }

  Write-KitLog "Экспорт памяти: $effectiveOutputDir"
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $effectiveOutputDir | Out-Null
  }

  Copy-KitFile (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "global-collaboration-rules.md")) `
    (Join-KitPath -Parts @($effectiveOutputDir, "global", "memories", "global-collaboration-rules.md")) `
    "EXPORT" -Required
  Copy-KitFile (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "memory-architecture.md")) `
    (Join-KitPath -Parts @($effectiveOutputDir, "global", "memories", "memory-architecture.md")) `
    "EXPORT" -Required
  Copy-KitFile (Join-KitPath -Parts @($effectiveHome, "AGENTS.md")) `
    (Join-KitPath -Parts @($effectiveOutputDir, "global", "AGENTS.md")) `
    "EXPORT"
  foreach ($kind in @("codex", "dsh")) {
    if ($Agent -ne $kind -and $Agent -ne "all") { continue }
    $agentDir = if ($kind -eq "codex") { $effectiveCodexDir } else { $effectiveDshDir }
    Copy-KitFile (Join-Path $agentDir "AGENTS.md") (Join-KitPath -Parts @($effectiveOutputDir, "global", "agents", $kind, "AGENTS.md")) "EXPORT"
  }

  if ($null -ne $effectiveRepoRoot) {
    Copy-KitFile (Join-KitPath -Parts @($effectiveRepoRoot, "AGENTS.md")) `
      (Join-KitPath -Parts @($effectiveOutputDir, "project", "AGENTS.md")) `
      "EXPORT" -Required
    Copy-KitFile (Join-KitPath -Parts @($effectiveRepoRoot, "START-HERE.md")) `
      (Join-KitPath -Parts @($effectiveOutputDir, "project", "START-HERE.md")) `
      "EXPORT" -Required
    Copy-KitFile (Join-KitPath -Parts @($effectiveRepoRoot, "assistant-memory.md")) `
      (Join-KitPath -Parts @($effectiveOutputDir, "project", "assistant-memory.md")) `
      "EXPORT" -Required
    Copy-KitFile (Join-KitPath -Parts @($effectiveRepoRoot, "technical-specification-mvp.md")) `
      (Join-KitPath -Parts @($effectiveOutputDir, "project", "technical-specification-mvp.md")) `
      "EXPORT"
    Copy-KitFile (Join-KitPath -Parts @($effectiveRepoRoot, "article-notes.md")) `
      (Join-KitPath -Parts @($effectiveOutputDir, "project", "article-notes.md")) `
      "EXPORT"
    Copy-KitTree (Join-KitPath -Parts @($effectiveRepoRoot, "memory")) `
      (Join-KitPath -Parts @($effectiveOutputDir, "project", "memory")) `
      "EXPORT" -Required
    if ($Agent -eq "antigravity" -or $Agent -eq "all") {
      Copy-KitFile (Join-KitPath -Parts @($effectiveRepoRoot, ".gemini", "rules", "antigravity-memory-adapter.md")) `
        (Join-KitPath -Parts @($effectiveOutputDir, "project", ".gemini", "rules", "antigravity-memory-adapter.md")) "EXPORT"
    }
  }
}

function Invoke-Import {
  if ([string]::IsNullOrWhiteSpace($InputDir)) {
    throw "Укажите -InputDir <path>."
  }

  $effectiveInputDir = Resolve-KitPath $InputDir
  $effectiveHome = Get-EffectiveHome
  $effectiveCodexDir = Get-EffectiveCodexDir $effectiveHome
  $effectiveDshDir = Get-EffectiveDshDir $effectiveHome
  $effectiveGlobalMemoryDir = Get-EffectiveGlobalMemoryDir $effectiveCodexDir
  $effectiveRepoRoot = $null
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $effectiveRepoRoot = Resolve-KitPath $RepoRoot
  }

  Write-KitLog "Импорт памяти: $effectiveInputDir"
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $effectiveGlobalMemoryDir | Out-Null
  }

  $archiveMemoryDir = Join-KitPath -Parts @($effectiveInputDir, "global", "memories")
  if (-not (Test-Path -LiteralPath $archiveMemoryDir -PathType Container)) {
    $archiveMemoryDir = Join-KitPath -Parts @($effectiveInputDir, "global", ".codex", "memories")
  }
  foreach ($file in @("global-collaboration-rules.md", "memory-architecture.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $archiveMemoryDir $file) -PathType Leaf)) {
      throw "Incomplete global memory archive: $effectiveInputDir"
    }
  }

  Copy-KitFile (Join-Path $archiveMemoryDir "global-collaboration-rules.md") `
    (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "global-collaboration-rules.md")) `
    "IMPORT"
  Copy-KitFile (Join-Path $archiveMemoryDir "memory-architecture.md") `
    (Join-KitPath -Parts @($effectiveGlobalMemoryDir, "memory-architecture.md")) `
    "IMPORT"
  Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "global", "AGENTS.md")) `
    (Join-KitPath -Parts @($effectiveHome, "AGENTS.md")) `
    "IMPORT"
  foreach ($kind in @("codex", "dsh")) {
    if ($Agent -ne $kind -and $Agent -ne "all") { continue }
    $agentDir = if ($kind -eq "codex") { $effectiveCodexDir } else { $effectiveDshDir }
    Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "global", "agents", $kind, "AGENTS.md")) (Join-Path $agentDir "AGENTS.md") "IMPORT"
  }

  if ($null -ne $effectiveRepoRoot) {
    if (-not $DryRun) {
      New-Item -ItemType Directory -Force -Path $effectiveRepoRoot | Out-Null
    }
    Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "project", "AGENTS.md")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, "AGENTS.md")) `
      "IMPORT"
    Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "project", "START-HERE.md")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, "START-HERE.md")) `
      "IMPORT"
    Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "project", "assistant-memory.md")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, "assistant-memory.md")) `
      "IMPORT"
    Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "project", "technical-specification-mvp.md")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, "technical-specification-mvp.md")) `
      "IMPORT"
    Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "project", "article-notes.md")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, "article-notes.md")) `
      "IMPORT"
    Copy-KitTree (Join-KitPath -Parts @($effectiveInputDir, "project", "memory")) `
      (Join-KitPath -Parts @($effectiveRepoRoot, "memory")) `
      "IMPORT"
    if ($Agent -eq "antigravity" -or $Agent -eq "all") {
      Copy-KitFile (Join-KitPath -Parts @($effectiveInputDir, "project", ".gemini", "rules", "antigravity-memory-adapter.md")) `
        (Join-KitPath -Parts @($effectiveRepoRoot, ".gemini", "rules", "antigravity-memory-adapter.md")) "IMPORT"
    }
  }
}

try {
  switch ($Command) {
    "install" { Invoke-Install }
    "init-project" { Invoke-InitProject }
    "check" { Invoke-Check }
    "export" { Invoke-Export }
    "import" { Invoke-Import }
  }
} catch {
  $message = $_.Exception.Message
  [Console]::Error.WriteLine($message)
  if ($message -like "Укажите *") {
    [Console]::Error.WriteLine((Show-Usage))
  }
  exit 2
}
