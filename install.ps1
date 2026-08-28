$ErrorActionPreference = "Stop"

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Write-Stderr {
  param([string]$Message)
  [Console]::Error.WriteLine($Message)
}

function Get-LexicalEntry {
  param([string]$Path)

  $parent = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  if (-not [IO.Directory]::Exists($parent)) {
    return $null
  }
  return @(
    Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
      Where-Object { $_.Name -ieq $leaf }
  ) | Select-Object -First 1
}

function Test-ReparsePoint {
  param($Item)
  return ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Get-PythonLaunchers {
  $specifications = @(
    [PSCustomObject]@{
      Name = "py.exe"
      Arguments = @("-3", "-X", "utf8")
    },
    [PSCustomObject]@{
      Name = "python.exe"
      Arguments = @("-X", "utf8")
    }
  )

  $launchers = @()
  $seenPaths = @{}
  foreach ($specification in $specifications) {
    $excludedCandidates = @{}
    $currentDirectories = @([Environment]::CurrentDirectory)
    try {
      $providerDirectory = [string]$ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path
      if (-not [string]::IsNullOrWhiteSpace($providerDirectory)) {
        $currentDirectories += $providerDirectory
      }
    } catch {
      # The Win32 process directory remains the fail-safe when no FileSystem
      # provider location is available.
    }
    foreach ($currentDirectory in $currentDirectories) {
      try {
        $candidate = [IO.Path]::GetFullPath(
          (Join-Path $currentDirectory $specification.Name)
        )
        $excludedCandidates[$candidate.ToLowerInvariant()] = $true
      } catch {
        continue
      }
    }
    $commands = @(
      Get-Command $specification.Name -CommandType Application -All -ErrorAction SilentlyContinue
    )
    foreach ($command in $commands) {
      try {
        $absolute = [IO.Path]::GetFullPath([string]$command.Source)
      } catch {
        continue
      }
      $pathKey = $absolute.ToLowerInvariant()
      if (
        $excludedCandidates.ContainsKey($pathKey) -or
        -not [IO.File]::Exists($absolute) -or
        $seenPaths.ContainsKey($pathKey)
      ) {
        continue
      }
      $seenPaths[$pathKey] = $true
      $launchers += [PSCustomObject]@{
        Path = $absolute
        Arguments = @($specification.Arguments)
      }
    }
  }
  return $launchers
}

function Get-ConfiguredLanguage {
  param([string]$ProjectDir)

  $configScript = Join-Path $ProjectDir "bin\onevoke_config.py"
  if (-not [IO.File]::Exists($configScript)) {
    return $null
  }

  $previousNoBytecode = [Environment]::GetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "Process")
  try {
    [Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1", "Process")
    foreach ($launcher in @(Get-PythonLaunchers)) {
      try {
        $result = @(
          & $launcher.Path @($launcher.Arguments) $configScript "configured-language" 2>$null
        )
      } catch {
        continue
      }
      if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) {
        continue
      }
      $language = ([string]$result[0]).Trim().ToLowerInvariant()
      if ($language -in @("cn", "en")) {
        return $language
      }
    }
  } finally {
    [Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", $previousNoBytecode, "Process")
  }
  return $null
}

function Invoke-OnevokeConfig {
  param([string]$SourceRoot, [string[]]$Arguments, [string]$Language)

  $configScript = Join-Path $SourceRoot "bin\onevoke_config.py"
  if (-not [IO.File]::Exists($configScript)) {
    throw [InvalidOperationException]::new("onevoke_config.py not found: $configScript")
  }
  $previousNoBytecode = [Environment]::GetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "Process")
  $previousLanguage = [Environment]::GetEnvironmentVariable("ONEVOKE_LANG", "Process")
  $lastError = ""
  try {
    [Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1", "Process")
    [Environment]::SetEnvironmentVariable("ONEVOKE_LANG", $Language, "Process")
    foreach ($launcher in @(Get-PythonLaunchers)) {
      try {
        $output = @(
          & $launcher.Path @($launcher.Arguments) $configScript @Arguments 2>&1
        )
      } catch {
        $lastError = [string]$_.Exception.Message
        continue
      }
      if ($LASTEXITCODE -eq 0) {
        return ($output -join "`n")
      }
      $lastError = ($output -join "`n")
    }
  } finally {
    [Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", $previousNoBytecode, "Process")
    [Environment]::SetEnvironmentVariable("ONEVOKE_LANG", $previousLanguage, "Process")
  }
  if ([string]::IsNullOrWhiteSpace($lastError)) {
    $lastError = "no usable native Python 3 launcher was found"
  }
  throw [InvalidOperationException]::new($lastError)
}

function New-OnevokeRulesLink {
  param([string]$LinkPath, [string]$TargetPath, [bool]$Chinese)

  if (Test-PathEntryExists $LinkPath) {
    return $false
  }
  try {
    New-Item -ItemType HardLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
    return $true
  } catch {
    try {
      New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
      return $true
    } catch {
      if ($Chinese) {
        throw [InvalidOperationException]::new("错误: 无法安全创建 $LinkPath; 文件系统需支持硬链接或符号链接")
      }
      throw [InvalidOperationException]::new("error: could not safely create $LinkPath; the file system must support hard links or symbolic links")
    }
  }
}

function Show-Usage {
  param([bool]$Chinese, [bool]$ErrorStream)

  if ($Chinese) {
    $lines = @(
      "用法: install.ps1 [--lang {cn,en}] [--project <目录>]",
      "把 Onevoke 命令装到 ~/.local/bin, 规则装到 ~/.agents.",
      "指定 --project 时只装到 Git 项目主 worktree 的 .onevoke/, 不写全局路径, 也不运行 welcome."
    )
  } else {
    $lines = @(
      "usage: install.ps1 [--lang {cn,en}] [--project <directory>]",
      "Install Onevoke commands to ~/.local/bin and rules to ~/.agents.",
      "With --project, install only into the Git project's main worktree .onevoke/, skip global paths, and do not run welcome."
    )
  }
  foreach ($line in $lines) {
    if ($ErrorStream) {
      Write-Stderr $line
    } else {
      [Console]::Out.WriteLine($line)
    }
  }
}

function Fail-Install {
  param([string]$Message)
  throw [InvalidOperationException]::new($Message)
}

function Assert-DirectoryTarget {
  param([string]$Path, [bool]$Chinese)

  $item = Get-LexicalEntry $Path
  if ($null -eq $item) {
    return
  }
  if (-not $item.PSIsContainer) {
    if ($Chinese) {
      Fail-Install "错误: 安装目标不是目录: $Path"
    } else {
      Fail-Install "error: installation target is not a directory: $Path"
    }
  }
  if (Test-ReparsePoint $item) {
    if ($Chinese) {
      Fail-Install "错误: 安装目录不得为重解析点: $Path"
    } else {
      Fail-Install "error: installation directory must not be a reparse point: $Path"
    }
  }
}

function Assert-FileTarget {
  param([string]$Path, [bool]$Chinese, [bool]$Legacy)

  $item = Get-LexicalEntry $Path
  if ($null -eq $item) {
    return
  }
  if ($item.PSIsContainer) {
    if ($Legacy -and $Chinese) {
      Fail-Install "错误: 旧版安装目标是目录: $Path"
    } elseif ($Legacy) {
      Fail-Install "error: legacy installation target is a directory: $Path"
    } elseif ($Chinese) {
      Fail-Install "错误: 安装目标是目录: $Path"
    } else {
      Fail-Install "error: installation target is a directory: $Path"
    }
  }
  if (Test-ReparsePoint $item) {
    if ($Chinese) {
      Fail-Install "错误: 安装文件目标不得为重解析点: $Path"
    } else {
      Fail-Install "error: installation file target must not be a reparse point: $Path"
    }
  }
}

function Get-SourceFiles {
  param([string]$Directory, [string]$Extension)

  if (-not [IO.Directory]::Exists($Directory)) {
    return @()
  }
  $files = @(
    Get-ChildItem -LiteralPath $Directory -Force -File -ErrorAction Stop |
      Where-Object { [string]::IsNullOrEmpty($Extension) -or $_.Extension -ieq $Extension } |
      Sort-Object Name
  )
  return $files
}

function Test-PathEntryExists {
  param([string]$Path)
  return $null -ne (Get-LexicalEntry $Path)
}

$installArgs = @($args)
$languageSet = $false
$requestedLanguage = ""
$missingLanguageValue = $false
$projectSet = $false
$requestedProject = ""
$missingProjectValue = $false
$duplicateProject = $false
$showHelp = $false
$parseError = $false

$index = 0
while ($index -lt $installArgs.Count) {
  $argument = [string]$installArgs[$index]
  if ($argument -eq "--lang") {
    $languageSet = $true
    if ($index + 1 -ge $installArgs.Count) {
      $missingLanguageValue = $true
      $parseError = $true
      break
    }
    $requestedLanguage = [string]$installArgs[$index + 1]
    $index += 2
    continue
  }
  if ($argument -like "--lang=*") {
    $languageSet = $true
    $requestedLanguage = $argument.Substring(7)
    $index += 1
    continue
  }
  if ($argument -eq "--project") {
    if ($projectSet) {
      $duplicateProject = $true
      $parseError = $true
      break
    }
    $projectSet = $true
    if ($index + 1 -ge $installArgs.Count) {
      $missingProjectValue = $true
      $parseError = $true
      break
    }
    $requestedProject = [string]$installArgs[$index + 1]
    if ($requestedProject.StartsWith("--")) {
      $missingProjectValue = $true
      $parseError = $true
      break
    }
    $index += 2
    continue
  }
  if ($argument -like "--project=*") {
    if ($projectSet) {
      $duplicateProject = $true
      $parseError = $true
      break
    }
    $projectSet = $true
    $requestedProject = $argument.Substring(10)
    if ([string]::IsNullOrEmpty($requestedProject)) {
      $missingProjectValue = $true
      $parseError = $true
      break
    }
    $index += 1
    continue
  }
  if ($argument -in @("-h", "--help")) {
    $showHelp = $true
    $index += 1
    continue
  }
  $parseError = $true
  break
}

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$locale = ""
if ($requestedLanguage -in @("cn", "en")) {
  $locale = $requestedLanguage
}
if ((-not $languageSet -or [string]::IsNullOrEmpty($locale)) -and -not $projectSet) {
  $locale = Get-ConfiguredLanguage $projectDir
}
if ([string]::IsNullOrEmpty($locale)) {
  foreach ($name in @("ONEVOKE_LANG", "LC_ALL", "LC_MESSAGES", "LANG")) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrEmpty($value)) {
      $locale = $value
      break
    }
  }
}
$chinese = -not ([string]$locale -match "^(?i:en)")

if ($missingLanguageValue) {
  Show-Usage $chinese $true
  exit 2
}
if ($languageSet -and $requestedLanguage -notin @("cn", "en")) {
  Show-Usage $chinese $true
  if ($chinese) {
    Write-Stderr "错误: --lang 只接受 cn 或 en"
  } else {
    Write-Stderr "error: --lang must be cn or en"
  }
  exit 2
}
if ($missingProjectValue) {
  Show-Usage $chinese $true
  if ($chinese) {
    Write-Stderr "错误: --project 需要目录"
  } else {
    Write-Stderr "error: --project requires a directory"
  }
  exit 2
}
if ($duplicateProject) {
  Show-Usage $chinese $true
  if ($chinese) {
    Write-Stderr "错误: --project 只能指定一次"
  } else {
    Write-Stderr "error: --project may be given only once"
  }
  exit 2
}
if ($showHelp -and -not $parseError) {
  Show-Usage $chinese $false
  exit 0
}
if ($parseError) {
  Show-Usage $chinese $true
  exit 2
}

try {
  $shareSource = Join-Path $projectDir "share\kanban-web"
  $binSource = Join-Path $projectDir "bin"
  $rulesSource = Join-Path $projectDir "rules"
  $binFiles = @(Get-SourceFiles $binSource "")
  $ruleFiles = @(Get-SourceFiles $rulesSource ".md")
  $shareFiles = @()
  if ([IO.Directory]::Exists($shareSource)) {
    $shareFiles = @(Get-SourceFiles $shareSource "")
  }

  if ($projectSet) {
    $helperLanguage = if ($chinese) { "cn" } else { "en" }
    $layoutJson = Invoke-OnevokeConfig -SourceRoot $projectDir -Arguments @("project-layout", $requestedProject) -Language $helperLanguage
    try {
      $layout = $layoutJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
      if ($chinese) {
        Fail-Install "错误: 无法解析项目安装路径"
      } else {
        Fail-Install "error: failed to resolve project installation paths"
      }
    }
    $projectRoot = [IO.Path]::GetFullPath([string]$layout.project_root)
    $installRoot = [IO.Path]::GetFullPath([string]$layout.install_root)
    $binDir = [IO.Path]::GetFullPath([string]$layout.bin_dir)
    $agentsDir = [IO.Path]::GetFullPath([string]$layout.rules_dir)
    $shareDir = [IO.Path]::GetFullPath([string]$layout.share_dir)

    $directoryTargets = @(
      $projectRoot,
      $installRoot,
      $binDir,
      $agentsDir,
      (Split-Path -Parent $shareDir),
      $shareDir
    )
    foreach ($directory in $directoryTargets | Select-Object -Unique) {
      Assert-DirectoryTarget $directory $chinese
    }
    $projectAgentRules = Join-Path $projectRoot "AGENTS.md"
    Assert-FileTarget $projectAgentRules $chinese $false
    foreach ($source in $binFiles) {
      Assert-FileTarget (Join-Path $binDir $source.Name) $chinese $false
    }
    foreach ($source in $ruleFiles) {
      Assert-FileTarget (Join-Path $agentsDir $source.Name) $chinese $false
    }
    foreach ($source in $shareFiles) {
      Assert-FileTarget (Join-Path $shareDir $source.Name) $chinese $false
    }

    Invoke-OnevokeConfig -SourceRoot $projectDir -Arguments @("project-exclude", $projectRoot) -Language $helperLanguage | Out-Null
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
    foreach ($source in $binFiles) {
      Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $binDir $source.Name) -Force
    }
    foreach ($source in $ruleFiles) {
      Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $agentsDir $source.Name) -Force
    }
    if ([IO.Directory]::Exists($shareSource)) {
      New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
      foreach ($source in $shareFiles) {
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $shareDir $source.Name) -Force
      }
    }

    $entryRules = Join-Path $agentsDir "ONEVOKE-AGENTS.md"
    $internalAgentRules = Join-Path $agentsDir "AGENTS.md"
    if ([IO.File]::Exists($entryRules)) {
      New-OnevokeRulesLink $internalAgentRules $entryRules $chinese | Out-Null
    }
    $projectRulesCreated = $false
    if ([IO.File]::Exists($entryRules) -and -not (Test-PathEntryExists $projectAgentRules)) {
      $projectRulesCreated = New-OnevokeRulesLink $projectAgentRules $entryRules $chinese
      if ($projectRulesCreated) {
        try {
          Invoke-OnevokeConfig -SourceRoot $projectDir -Arguments @("project-exclude", "--agents", $projectRoot) -Language $helperLanguage | Out-Null
        } catch {
          if (Test-PathEntryExists $projectAgentRules) {
            [IO.File]::Delete($projectAgentRules)
          }
          throw
        }
      }
    }

    if ($chinese) {
      [Console]::Out.WriteLine("Onevoke 已安装")
      if ($projectRulesCreated) {
        Write-Stderr "Codex 项目规则已接入: $projectAgentRules"
      } else {
        Write-Stderr "保留现有项目规则入口: $projectAgentRules; 请用项目 onevoke doctor 核验接入状态"
      }
      Write-Stderr "项目安装完成, 未修改 PATH, 也未改动全局 Onevoke 安装."
      Write-Stderr "请使用以下绝对路径."
    } else {
      [Console]::Out.WriteLine("Onevoke installed")
      if ($projectRulesCreated) {
        Write-Stderr "Codex project rules connected: $projectAgentRules"
      } else {
        Write-Stderr "Existing project rules entry kept: $projectAgentRules; verify it with the project onevoke doctor"
      }
      Write-Stderr "Project install finished; PATH and the global Onevoke install were not changed."
      Write-Stderr "Use the absolute paths below."
    }
    [Console]::Out.WriteLine((Join-Path $binDir "onevoke.cmd"))
    [Console]::Out.WriteLine((Join-Path $binDir "kanban.cmd"))
    exit 0
  }

  # Native Windows Python resolves Path.home() from USERPROFILE. Keep the
  # installer on the same boundary; HOME is commonly inherited from Git Bash
  # and may point somewhere else.
  $homeValue = [Environment]::GetEnvironmentVariable("USERPROFILE")
  if ([string]::IsNullOrWhiteSpace($homeValue)) {
    $homeValue = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  }
  if ([string]::IsNullOrWhiteSpace($homeValue)) {
    if ($chinese) {
      Fail-Install "错误: 无法确定用户主目录"
    } else {
      Fail-Install "error: could not determine the user home directory"
    }
  }
  $userHome = [IO.Path]::GetFullPath($homeValue)

  $binDir = Join-Path $userHome ".local\bin"
  $agentsDir = Join-Path $userHome ".agents"
  $shareDir = Join-Path $userHome ".local\share\onevoke\kanban-web"

  # Preflight every managed directory and file before creating or copying anything.
  $directoryTargets = @(
    $userHome,
    (Join-Path $userHome ".local"),
    $binDir,
    $agentsDir
  )
  if ([IO.Directory]::Exists($shareSource)) {
    $directoryTargets += @(
      (Join-Path $userHome ".local\share"),
      (Join-Path $userHome ".local\share\onevoke"),
      $shareDir
    )
  }
  foreach ($directory in $directoryTargets | Select-Object -Unique) {
    Assert-DirectoryTarget $directory $chinese
  }
  foreach ($source in $binFiles) {
    Assert-FileTarget (Join-Path $binDir $source.Name) $chinese $false
  }
  foreach ($source in $ruleFiles) {
    Assert-FileTarget (Join-Path $agentsDir $source.Name) $chinese $false
  }
  foreach ($source in $shareFiles) {
    Assert-FileTarget (Join-Path $shareDir $source.Name) $chinese $false
  }

  $legacyNames = @("codex-review.sh", "claude-review.sh", "grok-review.sh")
  $legacyFound = @()
  foreach ($name in $legacyNames) {
    $target = Join-Path $binDir $name
    Assert-FileTarget $target $chinese $true
    if (Test-PathEntryExists $target) {
      $legacyFound += $name
    }
  }

  $removeLegacy = $false
  if ($legacyFound.Count -gt 0) {
    if ($chinese) {
      Write-Stderr "检测到已退役的 Reviewer 脚本:"
      Write-Stderr ("  " + ($legacyFound -join " "))
      Write-Stderr "审核入口现已统一为 onevoke-review.cmd."
      [Console]::Error.Write("是否删除这些旧脚本? [y/N] ")
    } else {
      Write-Stderr "Retired reviewer scripts were detected:"
      Write-Stderr ("  " + ($legacyFound -join " "))
      Write-Stderr "The review entry point is now unified as onevoke-review.cmd."
      [Console]::Error.Write("Delete these legacy scripts? [y/N] ")
    }
    $legacyAnswer = [Console]::In.ReadLine()
    if ([Console]::IsInputRedirected) {
      [Console]::Error.WriteLine()
    }
    if ($legacyAnswer -in @("y", "Y", "yes", "YES", "Yes", "是")) {
      $removeLegacy = $true
    } elseif ($chinese) {
      Write-Stderr "已保留旧 Reviewer 脚本."
    } else {
      Write-Stderr "Legacy reviewer scripts were kept."
    }
  }

  New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
  foreach ($source in $binFiles) {
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $binDir $source.Name) -Force
  }
  foreach ($source in $ruleFiles) {
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $agentsDir $source.Name) -Force
  }
  if ([IO.Directory]::Exists($shareSource)) {
    New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
    foreach ($source in $shareFiles) {
      Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $shareDir $source.Name) -Force
    }
  }

  $agentRules = Join-Path $agentsDir "AGENTS.md"
  $entryRules = Join-Path $agentsDir "ONEVOKE-AGENTS.md"
  if ([IO.File]::Exists($entryRules) -and -not (Test-PathEntryExists $agentRules)) {
    $linked = $false
    try {
      New-Item -ItemType HardLink -Path $agentRules -Target $entryRules -ErrorAction Stop | Out-Null
      $linked = $true
    } catch {
      try {
        New-Item -ItemType SymbolicLink -Path $agentRules -Target $entryRules -ErrorAction Stop | Out-Null
        $linked = $true
      } catch {
        $linked = $false
      }
    }
    if (-not $linked) {
      if ($chinese) {
        Fail-Install "错误: 无法安全创建 $agentRules; 文件系统需支持硬链接或符号链接"
      } else {
        Fail-Install "error: could not safely create $agentRules; the file system must support hard links or symbolic links"
      }
    }
  }

  if ($removeLegacy) {
    $reviewEntry = Join-Path $binDir "onevoke-review.cmd"
    $reviewItem = Get-LexicalEntry $reviewEntry
    if ($null -eq $reviewItem -or $reviewItem.PSIsContainer -or (Test-ReparsePoint $reviewItem)) {
      if ($chinese) {
        Fail-Install "错误: 新审核入口不可用, 已保留旧 Reviewer 脚本: $reviewEntry"
      } else {
        Fail-Install "error: the new review entry is unavailable; legacy reviewer scripts were kept: $reviewEntry"
      }
    }
    foreach ($name in $legacyFound) {
      [IO.File]::Delete((Join-Path $binDir $name))
    }
    if ($chinese) {
      Write-Stderr "已删除旧 Reviewer 脚本."
    } else {
      Write-Stderr "Legacy reviewer scripts were removed."
    }
  }

  $pathEntries = @($env:PATH -split ";" | ForEach-Object { $_.Trim().Trim('"').TrimEnd("\") })
  if (-not ($pathEntries -contains $binDir.TrimEnd("\"))) {
    if ($chinese) {
      Write-Stderr "提示: $binDir 不在 PATH 中. 安装器不会自动修改用户 PATH; 请手动添加并重新打开终端."
    } else {
      Write-Stderr "note: $binDir is not on PATH. The installer does not modify the user PATH; add it manually and reopen the terminal."
    }
  }

  if ($chinese) {
    [Console]::Out.WriteLine("Onevoke 已安装")
  } else {
    [Console]::Out.WriteLine("Onevoke installed")
  }

  # Installation is complete. A failed welcome is reported but never rolls files back.
  $welcomeEntry = Join-Path $binDir "onevoke.cmd"
  $welcomeArgs = @()
  if (-not [string]::IsNullOrEmpty($requestedLanguage)) {
    $welcomeArgs = @("--lang", $requestedLanguage)
  }
  $welcomeSucceeded = $false
  try {
    & $welcomeEntry @welcomeArgs "welcome"
    $welcomeSucceeded = $LASTEXITCODE -eq 0
  } catch {
    $welcomeSucceeded = $false
  }
  if (-not $welcomeSucceeded) {
    if ($chinese) {
      Write-Stderr "警告: Onevoke 文件已安装, 但 welcome 未完成; 请修复提示问题后重新运行 onevoke welcome."
      Write-Stderr "说明: MemSearch 为可选项, 其安装失败不影响本工具包; 可稍后自行安装或再跑 welcome."
    } else {
      Write-Stderr "warning: Onevoke files were installed, but welcome did not complete; fix the reported issue and rerun onevoke welcome."
      Write-Stderr "note: MemSearch is optional; installation failure does not affect this toolkit and can be retried later."
    }
  }
  exit 0
} catch {
  Write-Stderr ([string]$_.Exception.Message)
  exit 1
}
