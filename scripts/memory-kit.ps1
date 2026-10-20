#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('install', 'init-project', 'check', 'export', 'import')][string]$Command,
  [Alias('Home')][string]$HomeDir,
  [Alias('Repo')][string]$RepoRoot,
  [string]$ProjectName,
  [ValidateSet('codex', 'dsh', 'mimocode', 'zcode', 'antigravity', 'all', 'none')][string]$Agent = 'codex',
  [string]$CodexDir, [string]$DshDir, [string]$MimocodeConfigDir,
  [string]$ZcodeDir, [string]$AntigravityDir, [string]$GlobalMemoryDir,
  [string]$SourceRoot, [string]$InputDir, [string]$OutputDir,
  [ValidateSet('global', 'project', 'all')][string]$Mode = 'all',
  [switch]$Strict, [switch]$Force, [switch]$DryRun, [switch]$UpdateAdapters,
  [switch]$VerboseLog
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CodeRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$HostIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$Utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
$BlockBegin = '<!-- memory-kit:begin -->'
$BlockEnd = '<!-- memory-kit:end -->'
$LocatorReference = '~/.agents/memory-kit.conf'
$Plan = New-Object 'System.Collections.Generic.List[object]'
$Failures = 0

function Assert-PathText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match "[\r\n\t]") {
    throw 'Paths must be nonempty and cannot contain CR, LF or TAB.'
  }
}
function Convert-NativePath([string]$Value) {
  Assert-PathText $Value
  if ($HostIsWindows -and $Value -match '^/(?:mnt/)?([A-Za-z])(?:/(.*))?$') {
    $rest = if ($null -ne $Matches[2]) { $Matches[2] } else { '' }
    return $Matches[1] + ':\' + $rest.Replace('/', '\')
  }
  return $Value
}
function Resolve-PathValue([string]$Value, [switch]$RequireAbsolute) {
  $Value = Convert-NativePath $Value
  if ($Value -eq '~') { $Value = $HOME }
  elseif ($Value.StartsWith('~/') -or $Value.StartsWith('~\')) { $Value = Join-Path $HOME $Value.Substring(2) }
  if (-not [IO.Path]::IsPathRooted($Value)) {
    if ($RequireAbsolute) { throw "Expected an absolute path: $Value" }
    $Value = Join-Path (Get-Location).Path $Value
  }
  $resolved = [IO.Path]::GetFullPath($Value)
  if ($resolved -eq [IO.Path]::GetPathRoot($resolved)) { return $resolved }
  return $resolved.TrimEnd([char[]]@('\', '/'))
}
function Join-Relative([string]$Base, [string]$Relative) {
  foreach ($part in ($Relative -split '/')) { $Base = Join-Path $Base $part }
  return $Base
}
function Path-Equal([string]$First, [string]$Second) {
  $comparison = if ($HostIsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  return (Resolve-PathValue $First -RequireAbsolute).Equals((Resolve-PathValue $Second -RequireAbsolute), $comparison)
}
function Read-Text([string]$Path) { return [IO.File]::ReadAllText($Path, $Utf8) }
function Read-Data([string]$Path, [string[]]$Keys, [string]$Version) {
  $values = @{}
  foreach ($line in ((Read-Text $Path) -split '\r?\n')) {
    if ($line -eq '') { continue }
    $equal = $line.IndexOf('=')
    if ($equal -lt 1) { throw "Malformed data file: $Path" }
    $key = $line.Substring(0, $equal)
    if ($Keys -notcontains $key -or $values.ContainsKey($key)) { throw "Unknown or duplicate key in ${Path}: $key" }
    $values[$key] = $line.Substring($equal + 1)
  }
  foreach ($key in $Keys) { if (-not $values.ContainsKey($key) -or $values[$key] -eq '') { throw "Missing $key in $Path" } }
  if ($values.VERSION -ne $Version) { throw "Unsupported data version in $Path" }
  return $values
}
function Resolve-HarnessRoot([string]$Explicit, [string]$EnvironmentName, [string]$Default) {
  if ($Explicit) { return Resolve-PathValue $Explicit }
  if (-not $HomeDir -and $EnvironmentName) {
    $value = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return Resolve-PathValue $value }
  }
  return Resolve-PathValue $Default
}
function Initialize-Context {
  $script:TargetHome = if ($HomeDir) { Resolve-PathValue $HomeDir } else { Resolve-PathValue $HOME }
  $script:TemplateRoot = if ($SourceRoot) { Resolve-PathValue $SourceRoot } else { $CodeRoot }
  $script:LocatorPath = Join-Relative $TargetHome '.agents/memory-kit.conf'
  $script:Locator = $null
  if (Test-Path -LiteralPath $LocatorPath -PathType Leaf) {
    $script:Locator = Read-Data $LocatorPath @('VERSION', 'GLOBAL_MEMORY_DIR', 'KIT_ROOT') '1'
    $null = Resolve-PathValue $Locator.GLOBAL_MEMORY_DIR -RequireAbsolute
    $null = Resolve-PathValue $Locator.KIT_ROOT -RequireAbsolute
  }
  $mimoDefault = Join-Relative $TargetHome '.config/mimocode'
  if (-not $HomeDir) {
    if ($env:MIMOCODE_HOME) { $mimoDefault = Join-Path $env:MIMOCODE_HOME 'config' }
    elseif ($env:XDG_CONFIG_HOME) { $mimoDefault = Join-Path $env:XDG_CONFIG_HOME 'mimocode' }
  }
  $script:Roots = @{
    CODEX_DIR = Resolve-HarnessRoot $CodexDir 'CODEX_HOME' (Join-Path $TargetHome '.codex')
    DSH_DIR = Resolve-HarnessRoot $DshDir 'DSH_HOME' (Join-Path $TargetHome '.dsh')
    MIMOCODE_CONFIG_DIR = Resolve-HarnessRoot $MimocodeConfigDir 'MIMOCODE_CONFIG_DIR' $mimoDefault
    ZCODE_DIR = Resolve-HarnessRoot $ZcodeDir '' (Join-Path $TargetHome '.zcode')
    ANTIGRAVITY_DIR = Resolve-HarnessRoot $AntigravityDir '' (Join-Path $TargetHome '.gemini')
  }
  $legacy = Join-Path $Roots.CODEX_DIR 'memories'
  $shared = Join-Relative $TargetHome '.agents/memories'
  if ($GlobalMemoryDir) { $script:MemoryDir = Resolve-PathValue $GlobalMemoryDir }
  elseif ($null -ne $Locator) { $script:MemoryDir = Resolve-PathValue $Locator.GLOBAL_MEMORY_DIR -RequireAbsolute }
  elseif ($CodexDir) { $script:MemoryDir = $legacy }
  elseif ((Test-Path -LiteralPath $legacy -PathType Container) -and (Test-Path -LiteralPath $shared -PathType Container)) {
    throw 'Both shared and legacy memory exist; select -GlobalMemoryDir explicitly.'
  } elseif (Test-Path -LiteralPath $legacy -PathType Container) { $script:MemoryDir = $legacy }
  else { $script:MemoryDir = $shared }
  $script:TargetRepo = $null
  if ($RepoRoot) { $script:TargetRepo = Resolve-PathValue $RepoRoot }
  elseif ($Command -eq 'init-project' -or ($Command -eq 'check' -and $Mode -ne 'global')) { $script:TargetRepo = Resolve-PathValue (Get-Location).Path }
  if ($TargetRepo) { $Roots.REPO_ROOT = $TargetRepo }
  $script:ProfileRecords = @(Import-Csv -LiteralPath (Join-Relative $CodeRoot 'profiles/agents.tsv') -Delimiter "`t" -Encoding UTF8 | Where-Object { $Agent -eq 'all' -or $_.agent -eq $Agent })
}
function Get-Records([string]$Scope) { return @($ProfileRecords | Where-Object { $_.scope -eq $Scope }) }
function Get-RecordPath($Record) { return Join-Relative $Roots[$Record.root] $Record.file }
function Render-Text([string]$Relative) {
  $source = Join-Relative $TemplateRoot $Relative
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing template: $source" }
  $value = (Read-Text $source).Replace("`r`n", "`n")
  $variables = @{} + $Roots
  $variables.HOME_DIR = $TargetHome
  $variables.GLOBAL_MEMORY_DIR = $MemoryDir
  $variables.KIT_ROOT = $CodeRoot
  if ($TargetRepo) { $variables.PROJECT_NAME = if ($ProjectName) { $ProjectName } else { Split-Path -Leaf $TargetRepo } }
  foreach ($key in @($variables.Keys)) {
    $item = [string]$variables[$key]
    $value = $value.Replace("{{$key}}", $item)
    if ($key -ne 'PROJECT_NAME') {
      $posix = $item.Replace('\', '/')
      if ($posix -match '^([A-Za-z]):/(.*)$') { $posix = '/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2] }
      $value = $value.Replace("{{${key}_POSIX}}", $posix).Replace("{{${key}_WINDOWS}}", $item)
    }
  }
  if ($value -match '{{[A-Z_][A-Z0-9_]*}}') { throw "Unresolved template placeholder: $source" }
  return $value
}
function Assert-WritableLeaf([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing to replace a directory or symbolic link: $Path" }
  }
  $parent = Split-Path -Parent $Path
  while ($parent -and -not (Test-Path -LiteralPath $parent)) { $parent = Split-Path -Parent $parent }
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Parent is not a directory: $parent" }
}
function Add-Skip([string]$Path) { $Plan.Add([pscustomobject]@{ Status = 'SKIP'; Path = $Path; Kind = 'skip' }) }
function Add-Text([string]$Path, [string]$Content, [switch]$Replace, [switch]$WithBom) {
  Assert-WritableLeaf $Path
  $exists = Test-Path -LiteralPath $Path -PathType Leaf
  if ($exists -and -not $Replace) { Add-Skip $Path; return }
  if ($exists -and (Read-Text $Path) -ceq $Content) { Add-Skip $Path; return }
  $bytes = $Utf8.GetBytes($Content)
  if ($WithBom) { $bytes = [byte[]](@(239, 187, 191) + $bytes) }
  $status = if ($exists) { 'OVERWRITE' } else { 'CREATE' }
  $Plan.Add([pscustomobject]@{ Status = $status; Path = $Path; Kind = 'text'; Bytes = $bytes })
}
function Get-Block([string]$Content) {
  $starts = [regex]::Matches($Content, [regex]::Escape($BlockBegin)).Count
  $ends = [regex]::Matches($Content, [regex]::Escape($BlockEnd)).Count
  if ($starts -eq 0 -and $ends -eq 0) { return $null }
  if ($starts -ne 1 -or $ends -ne 1) { throw 'Malformed or repeated memory-kit managed markers.' }
  $found = [regex]::Match($Content, '(?s)' + [regex]::Escape($BlockBegin) + '.*?' + [regex]::Escape($BlockEnd))
  if (-not $found.Success) { throw 'Managed block markers are out of order.' }
  return $found
}
function Add-Adapter([string]$Path, [string]$Template, [string]$ArchiveSource = '') {
  $desired = Render-Text $Template
  $desiredBlock = Get-Block $desired
  if ($null -eq $desiredBlock) { throw "Missing managed block in template: $Template" }
  $exists = Test-Path -LiteralPath $Path -PathType Leaf
  $base = if ($exists) { $Path } elseif ($ArchiveSource -and (Test-Path -LiteralPath $ArchiveSource -PathType Leaf)) { $ArchiveSource } else { '' }
  if (-not $base) { Add-Text $Path $desired -Replace; return }
  $content = Read-Text $base
  $block = Get-Block $content
  if ($null -eq $block) {
    $separator = if ($content -eq '') { '' } elseif ($content.EndsWith("`n")) { "`n" } else { "`n`n" }
    $updated = $content + $separator + $desiredBlock.Value + "`n"
  } elseif ($block.Value.Replace("`r`n", "`n") -ceq $desiredBlock.Value.Replace("`r`n", "`n")) { $updated = $content }
  else {
    if ($exists -and -not ($Force -or $UpdateAdapters)) { throw "Existing memory-kit block differs; review and use -UpdateAdapters to update its managed block: $Path" }
    $updated = $content.Substring(0, $block.Index) + $desiredBlock.Value + $content.Substring($block.Index + $block.Length)
  }
  $baseBytes = [IO.File]::ReadAllBytes($base)
  $bom = $baseBytes.Length -ge 3 -and $baseBytes[0] -eq 239 -and $baseBytes[1] -eq 187 -and $baseBytes[2] -eq 191
  Add-Text $Path $updated -Replace -WithBom:$bom
}
function Add-Locator {
  if ($null -ne $Locator -and (Path-Equal $Locator.GLOBAL_MEMORY_DIR $MemoryDir) -and (Path-Equal $Locator.KIT_ROOT $CodeRoot)) {
    Add-Skip $LocatorPath; return
  }
  Add-Text $LocatorPath ("VERSION=1`nGLOBAL_MEMORY_DIR=$MemoryDir`nKIT_ROOT=$CodeRoot`n") -Replace
}
function Add-Copy([string]$Source, [string]$Destination, [switch]$Required) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    if ($Required) { throw "Missing source file: $Source" }; return
  }
  if ((Get-Item -LiteralPath $Source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Symbolic links require explicit review: $Source" }
  Assert-WritableLeaf $Destination
  if ((Test-Path -LiteralPath $Destination) -and -not $Force) { Add-Skip $Destination; return }
  $status = if (Test-Path -LiteralPath $Destination) { 'OVERWRITE' } elseif ($Command -eq 'export') { 'EXPORT' } else { 'IMPORT' }
  $Plan.Add([pscustomobject]@{ Status = $status; Path = $Destination; Kind = 'copy'; Source = $Source })
}
function Assert-DisjointTrees([string]$Source, [string]$Destination) {
  $sourcePath = (Resolve-PathValue $Source).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  $targetPath = (Resolve-PathValue $Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  $comparison = if ($HostIsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  if ($sourcePath.StartsWith($targetPath, $comparison) -or $targetPath.StartsWith($sourcePath, $comparison)) { throw 'Copy source and destination trees must not overlap.' }
}
function Add-Tree([string]$Source, [string]$Destination, [switch]$Required) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    if ($Required) { throw "Missing source directory: $Source" }; return
  }
  Assert-DisjointTrees $Source $Destination
  $Plan.Add([pscustomobject]@{ Status = ''; Path = $Destination; Kind = 'directory' })
  foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -Recurse)) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Symbolic links require explicit review: $($item.FullName)" }
    $relative = $item.FullName.Substring($Source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $relative
    if ($item.PSIsContainer) { $Plan.Add([pscustomobject]@{ Status = ''; Path = $target; Kind = 'directory' }) }
    else { Add-Copy $item.FullName $target }
  }
}
function Execute-Plan {
  foreach ($operation in $Plan) {
    $label = if ($DryRun) { 'DRY-RUN ' } else { '' }
    if ($operation.Status) { Write-Output ($label + $operation.Status + ' ' + $operation.Path) }
    if ($DryRun -or $operation.Kind -eq 'skip') { continue }
    if ($operation.Kind -eq 'directory') { $null = [IO.Directory]::CreateDirectory($operation.Path); continue }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $operation.Path))
    $temporary = Join-Path (Split-Path -Parent $operation.Path) ([IO.Path]::GetRandomFileName())
    try {
      if ($operation.Kind -eq 'copy') { [IO.File]::Copy($operation.Source, $temporary) }
      else { [IO.File]::WriteAllBytes($temporary, $operation.Bytes) }
      if (Test-Path -LiteralPath $operation.Path) {
        $backup = Join-Path (Split-Path -Parent $operation.Path) ([IO.Path]::GetRandomFileName())
        [IO.File]::Replace($temporary, $operation.Path, $backup)
        [IO.File]::Delete($backup)
      }
      else { [IO.File]::Move($temporary, $operation.Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
  }
}
function Plan-Install {
  foreach ($file in @('global-collaboration-rules.md', 'memory-architecture.md')) {
    Add-Text (Join-Path $MemoryDir $file) (Render-Text ('templates/global/' + $file)) -Replace:$Force
  }
  Add-Locator
  foreach ($record in @(Get-Records 'global')) { Add-Adapter (Get-RecordPath $record) $record.template }
}
function Plan-Project {
  if (-not (Test-Path -LiteralPath $TargetRepo -PathType Container)) { throw "Project directory not found: $TargetRepo" }
  $files = @('AGENTS.md', 'START-HERE.md', 'assistant-memory.md', 'memory/current-work-queue.md', 'memory/topic-memory-improvement.md', 'memory/_templates/daily.md', 'memory/_templates/topic.md')
  foreach ($file in $files) { Add-Text (Join-Relative $TargetRepo $file) (Render-Text ('templates/project/' + $file + '.template')) -Replace:$Force }
  $date = Get-Date -Format 'yyyy-MM-dd'
  Add-Text (Join-Relative $TargetRepo ('memory/' + $date + '.md')) ((Render-Text 'templates/project/memory/_templates/daily.md.template').Replace('YYYY-MM-DD', $date)) -Replace:$Force
  foreach ($record in @(Get-Records 'project')) { Add-Adapter (Get-RecordPath $record) $record.template }
}
function Check-Failure([string]$Path, [string]$Reason) { $script:Failures++; [Console]::Error.WriteLine("CHECK FAIL ${Path}: $Reason") }
function Require-File([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) { Write-Output "CHECK OK $Path" }
  else { Check-Failure $Path 'required file is missing' }
}
function Check-Text([string]$Path, [string[]]$Needles) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  try { $content = Read-Text $Path } catch { Check-Failure $Path $_.Exception.Message; return }
  if ([string]::IsNullOrWhiteSpace($content)) { Check-Failure $Path 'required memory text is empty' }
  if ($content -match '{{[A-Z_][A-Z0-9_]*}}|__PROJECT_ROOT__|__PROJECT_NAME__') { Check-Failure $Path 'unresolved placeholder' }
  foreach ($needle in $Needles) { if (-not $content.Contains($needle)) { Check-Failure $Path "missing reference: $needle" } }
}
function Check-Adapter([string]$Path, [string]$Activation, [string]$Profile) {
  Require-File $Path
  if (-not $Strict -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  Check-Text $Path @()
  $content = Read-Text $Path
  try {
    $block = Get-Block $content
    if ($null -eq $block) { Check-Failure $Path 'managed block is absent' }
    else {
      foreach ($needle in @($LocatorReference, 'global-collaboration-rules.md', 'memory-architecture.md')) {
        if (-not $block.Value.Contains($needle)) { Check-Failure $Path "managed block is missing reference: $needle" }
      }
    }
  } catch { Check-Failure $Path $_.Exception.Message }
  if ($Profile -eq 'antigravity' -and [IO.File]::ReadAllBytes($Path).Length -gt 24000) { Check-Failure $Path 'Antigravity rule exceeds 24000 UTF-8 bytes' }
  if ($Activation -eq 'always_on') {
    $front = [regex]::Match($content, '\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)', 'Singleline')
    if (-not $front.Success -or [regex]::Matches($front.Groups[1].Value, '(?m)^trigger:').Count -ne 1 -or $front.Groups[1].Value -notmatch '(?m)^trigger:\s*(?:always_on|''always_on''|"always_on")\s*(?:#.*)?$') {
      Check-Failure $Path 'missing or inactive YAML trigger: always_on'
    }
  }
}
function Invoke-Check {
  if ($Mode -eq 'global' -or $Mode -eq 'all' -or $Strict) {
    if ($null -eq $Locator) { Check-Failure $LocatorPath 'locator is missing; run install for this home' }
    else {
      if (-not (Path-Equal $Locator.GLOBAL_MEMORY_DIR $MemoryDir)) { Check-Failure $LocatorPath 'locator points to another shared memory directory' }
      $configuredKit = Resolve-PathValue $Locator.KIT_ROOT -RequireAbsolute
      foreach ($file in @('scripts/memory-kit.ps1', 'scripts/install.sh', 'profiles/agents.tsv')) {
        if (-not (Test-Path -LiteralPath (Join-Relative $configuredKit $file) -PathType Leaf)) { Check-Failure $LocatorPath "kit source is unavailable or incomplete: $file" }
      }
    }
    foreach ($file in @('global-collaboration-rules.md', 'memory-architecture.md')) {
      $path = Join-Path $MemoryDir $file; Require-File $path
      if ($Strict) { Check-Text $path @() }
    }
  }
  if ($Mode -eq 'global' -or $Mode -eq 'all') {
    foreach ($record in @(Get-Records 'global')) { Check-Adapter (Get-RecordPath $record) $record.activation $record.agent }
    if ($Agent -eq 'codex' -or $Agent -eq 'all') {
      $override = Join-Path $Roots.CODEX_DIR 'AGENTS.override.md'
      if ((Test-Path -LiteralPath $override -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace((Read-Text $override))) { Check-Failure $override 'override hides the configured Codex bootstrap; inspect it explicitly' }
    }
  }
  if ($Mode -eq 'project' -or $Mode -eq 'all') {
    foreach ($file in @('AGENTS.md', 'START-HERE.md', 'assistant-memory.md', 'memory/current-work-queue.md', 'memory/topic-memory-improvement.md', 'memory/_templates/daily.md', 'memory/_templates/topic.md')) { Require-File (Join-Relative $TargetRepo $file) }
    if ($Strict) {
      Check-Text (Join-Path $TargetRepo 'AGENTS.md') @($LocatorReference, 'global-collaboration-rules.md', 'memory-architecture.md', 'memory/current-work-queue.md')
      Check-Text (Join-Path $TargetRepo 'START-HERE.md') @('AGENTS.md', 'assistant-memory.md')
      Check-Text (Join-Path $TargetRepo 'assistant-memory.md') @('AGENTS.md')
    }
    foreach ($record in @(Get-Records 'project')) { Check-Adapter (Get-RecordPath $record) $record.activation $record.agent }
  }
  if ($Failures -gt 0) { if ($Strict) { exit 3 }; exit 1 }
}
function Plan-Export {
  if (-not $OutputDir) { throw 'Specify -OutputDir.' }
  $destination = Resolve-PathValue $OutputDir
  foreach ($file in @('global-collaboration-rules.md', 'memory-architecture.md')) { if (-not (Test-Path -LiteralPath (Join-Path $MemoryDir $file) -PathType Leaf)) { throw "Missing canonical memory file: $file" } }
  Add-Tree $MemoryDir (Join-Relative $destination 'global/memories') -Required
  Add-Text (Join-Path $destination 'memory-kit-export.conf') ("VERSION=2`nAGENT=$Agent`n") -Replace:$Force
  foreach ($record in @(Get-Records 'global')) { Add-Copy (Get-RecordPath $record) (Join-Relative $destination ('global/agents/' + $record.agent + '/' + $record.file)) }
  if ($TargetRepo) {
    foreach ($file in @('AGENTS.md', 'START-HERE.md', 'assistant-memory.md')) { Add-Copy (Join-Path $TargetRepo $file) (Join-Relative $destination ('project/' + $file)) -Required }
    foreach ($file in @('technical-specification-mvp.md', 'article-notes.md')) { Add-Copy (Join-Path $TargetRepo $file) (Join-Relative $destination ('project/' + $file)) }
    Add-Tree (Join-Path $TargetRepo 'memory') (Join-Relative $destination 'project/memory') -Required
    foreach ($record in @(Get-Records 'project')) { Add-Copy (Get-RecordPath $record) (Join-Relative $destination ('project/' + $record.file)) }
  }
}
function Plan-Import {
  if (-not $InputDir) { throw 'Specify -InputDir.' }
  $archive = Resolve-PathValue $InputDir
  $manifest = Join-Path $archive 'memory-kit-export.conf'
  if (Test-Path -LiteralPath $manifest -PathType Leaf) {
    $data = Read-Data $manifest @('VERSION', 'AGENT') '2'
    if (@('codex', 'dsh', 'mimocode', 'zcode', 'antigravity', 'all', 'none') -notcontains $data.AGENT) { throw 'Unknown profile in archive manifest.' }
  } else {
    [Console]::Error.WriteLine('LEGACY ARCHIVE: original user text is preserved; old absolute project links require a separately authorized migration.')
  }
  $memory = Join-Relative $archive 'global/memories'
  if (-not (Test-Path -LiteralPath $memory -PathType Container)) { $memory = Join-Relative $archive 'global/.codex/memories' }
  foreach ($file in @('global-collaboration-rules.md', 'memory-architecture.md')) { if (-not (Test-Path -LiteralPath (Join-Path $memory $file) -PathType Leaf)) { throw "Incomplete global memory archive: $archive" } }
  Add-Tree $memory $MemoryDir -Required
  Add-Locator
  foreach ($record in @(Get-Records 'global')) { Add-Adapter (Get-RecordPath $record) $record.template (Join-Relative $archive ('global/agents/' + $record.agent + '/' + $record.file)) }
  if ($TargetRepo) {
    foreach ($file in @('AGENTS.md', 'START-HERE.md', 'assistant-memory.md', 'technical-specification-mvp.md', 'article-notes.md')) { Add-Copy (Join-Relative $archive ('project/' + $file)) (Join-Path $TargetRepo $file) }
    Add-Tree (Join-Relative $archive 'project/memory') (Join-Path $TargetRepo 'memory')
    foreach ($record in @(Get-Records 'project')) { Add-Adapter (Get-RecordPath $record) $record.template (Join-Relative $archive ('project/' + $record.file)) }
  }
}
try {
  Initialize-Context
  switch ($Command) {
    'install' { Plan-Install }
    'init-project' { Plan-Project }
    'check' { Invoke-Check }
    'export' { Plan-Export }
    'import' { Plan-Import }
  }
  if ($VerboseLog) { Write-Output "MEMORY $MemoryDir" }
  Execute-Plan
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
