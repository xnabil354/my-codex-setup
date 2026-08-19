[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$HomeDir = [Environment]::GetFolderPath('UserProfile')
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HomeDir '.codex' }
$Issues = New-Object 'System.Collections.Generic.List[string]'

function Out([string]$Message) { if (-not $Quiet) { Write-Host $Message } }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Out "[ OK ] $Name $(if ($Detail) { $Detail })" }
    else { [void]$Issues.Add("$Name $Detail"); Out "[FAIL] $Name $Detail" }
}
function Run([string]$File, [string[]]$Arguments) {
    $output = @(& $File @Arguments 2>&1)
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output }
}
function Find-ExecutableCommand([string]$Name) {
    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    $application = $commands | Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.(cmd|exe)$' } | Select-Object -First 1
    if ($application) { return $application }
    return $commands | Select-Object -First 1
}
function Find-CodeCommand {
    foreach ($name in @('code', 'code-insiders')) {
        $command = Find-ExecutableCommand $name
        if ($command) { return $command }
    }
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd')
    )) {
        if (Test-Path -LiteralPath $path) {
            $command = Get-Command $path -ErrorAction SilentlyContinue
            if ($command) { return $command }
        }
    }
    return $null
}

$codex = Find-ExecutableCommand 'codex'
Check 'Codex CLI' ([bool]$codex) $(if ($codex) { $codex.Source } else { 'not found' })
$configPath = Join-Path $CodexHome 'config.toml'
Check 'config.toml exists' (Test-Path -LiteralPath $configPath) $configPath
$configRaw = ''
if (Test-Path -LiteralPath $configPath) {
    $configRaw = Get-Content -LiteralPath $configPath -Raw
    Check 'managed block present once' (($configRaw -split 'CODEX-VIBE-SETUP MANAGED').Count -eq 3)
    Check 'router provider present' ($configRaw -match '\[model_providers\.9router\]')
    $managedMatch = [regex]::Match($configRaw, '(?s)# >>> CODEX-VIBE-SETUP MANAGED.*?# <<< CODEX-VIBE-SETUP MANAGED')
    Check 'router key not embedded' ($managedMatch.Success -and $managedMatch.Value -notmatch '(?i)sk-[A-Za-z0-9._-]{20,}')
    $catalogToml = (Join-Path $CodexHome 'model_catalog-hemat.json').Replace('\', '\\')
    Check 'target model catalog path' ($configRaw -match [regex]::Escape($catalogToml))
}
$model = Join-Path $CodexHome 'model_catalog-hemat.json'
Check 'hemat model catalog' (Test-Path -LiteralPath $model) $model
$skills = Join-Path $HomeDir '.agents\skills'
Check 'skills directory' (Test-Path -LiteralPath $skills) $skills
foreach ($name in @('antislop', 'brainstorming', 'ponytail')) {
    Check "skill $name" (Test-Path -LiteralPath (Join-Path $skills "$name\SKILL.md"))
}

$routerKey = [Environment]::GetEnvironmentVariable('NINEROUTER_API_KEY', 'User')
Check 'credential NINEROUTER_API_KEY' (-not [string]::IsNullOrWhiteSpace($routerKey)) 'required'
if ($configRaw -match '\[mcp_servers\.stitch\]') {
    $stitchKey = [Environment]::GetEnvironmentVariable('STITCH_API_KEY', 'User')
    Check 'credential STITCH_API_KEY' (-not [string]::IsNullOrWhiteSpace($stitchKey)) 'configured MCP'
}
if ($configRaw -match '\[mcp_servers\.testsprite\]') {
    $testKey = [Environment]::GetEnvironmentVariable('TESTSPRITE_API_KEY', 'User')
    Check 'credential TESTSPRITE_API_KEY' (-not [string]::IsNullOrWhiteSpace($testKey)) 'configured MCP'
    Check 'TestSprite wrapper' (Test-Path -LiteralPath (Join-Path $CodexHome 'codex-vibe-mcp\testsprite-wrapper.ps1'))
}

if ($codex) {
    $version = Run $codex.Source @('--version')
    Check 'Codex CLI responds' ($version.ExitCode -eq 0) (($version.Output -join ' ') -replace '\s+', ' ')
    foreach ($args in @(@('doctor'), @('mcp', 'list'), @('plugin', 'list'))) {
        $result = Run $codex.Source $args
        Check "codex $($args -join ' ')" ($result.ExitCode -eq 0)
    }
}
$code = Find-CodeCommand
if ($code) {
    $extensions = Run $code.Source @('--list-extensions', '--show-versions')
    Check 'VS Code extension query' ($extensions.ExitCode -eq 0)
    $foundExtension = @($extensions.Output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^openai\.(chatgpt|codex)@' })
    if ($foundExtension.Count) { Out "[ OK ] Codex extension $($foundExtension[0])" }
    else { Out '[WARN] Codex extension not detected.' }
} else {
    Out '[WARN] VS Code/code command not found.'
}

if ($Issues.Count) {
    Out "Verification failed: $($Issues.Count) issue(s)"
    exit 1
}
Out 'Verification passed.'
