[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Self-test failed: $Message" }
}
function First-Version([object[]]$Lines) {
    foreach ($line in $Lines) {
        if ([string]$line -match '(?<!\d)(\d+\.\d+\.\d+)(?!\d)') { return [version]$Matches[1] }
    }
    return $null
}
function Quote-Toml([string]$Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}
function Get-Preserved([string]$Path) {
    $keep = New-Object 'System.Collections.Generic.List[string]'
    $section = ''
    $include = $true
    $inManagedBlock = $false
    $managedSection = '(?i)^(windows|features|marketplaces(?:\.|$)|plugins(?:\.|$)|agents\.subagent(?:\.|$)|model_providers\.9router(?:\.|$)|mcp_servers\.(?:node_repl|stitch|testsprite|officecli)(?:\.|$))'
    $managedTop = '(?i)^\s*(model|model_catalog_json|model_provider|model_reasoning_effort|model_reasoning_summary|model_verbosity|service_tier|notify|approvals_reviewer)\s*='
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($inManagedBlock) {
            if ($line -match '^\s*# <<< CODEX-VIBE-SETUP MANAGED') { $inManagedBlock = $false }
            continue
        }
        if ($line -match '^\s*# >>> CODEX-VIBE-SETUP MANAGED') { $inManagedBlock = $true; continue }
        if ($line -match '^\s*\[\[?([^]]+)\]\]?\s*$') {
            $section = $Matches[1]
            $include = $section -notmatch $managedSection
            if ($include) { [void]$keep.Add($line) }
            continue
        }
        if ($section -eq '' -and $line -match $managedTop) { continue }
        if ($include) { [void]$keep.Add($line) }
    }
    return @($keep)
}
function Write-TestConfig([string]$Path, [string]$CodexHome) {
    $managed = @(
        '# >>> CODEX-VIBE-SETUP MANAGED'
        'model = "hemat"'
        ('model_catalog_json = ' + (Quote-Toml (Join-Path $CodexHome 'model_catalog-hemat.json')))
        'model_provider = "9router"'
        '[features]'
        'multi_agent = true'
        '# <<< CODEX-VIBE-SETUP MANAGED'
    )
    $all = @(Get-Preserved $Path) + @('') + $managed
    [IO.File]::WriteAllText($Path, (($all -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-vibe-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Assert-That ((First-Version @('codex-cli 0.147.0')) -lt (First-Version @('latest 0.148.0'))) 'semantic version comparison'
    Assert-That ((Quote-Toml 'C:\Users\friend\.codex\model_catalog.json') -eq '"C:\\Users\\friend\\.codex\\model_catalog.json"') 'TOML Windows path escaping'

    $codexHome = Join-Path $temp 'codex'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $fixture = @(
        'model = "old"'
        '[projects."C:\keep"]'
        'trust_level = "trusted"'
        '# >>> CODEX-VIBE-SETUP MANAGED'
        'model = "duplicate"'
        '[features]'
        'old = true'
        '# <<< CODEX-VIBE-SETUP MANAGED'
        '[model_providers.9router]'
        'base_url = "old router"'
        '[model_providers.user]'
        'base_url = "keep router"'
        '[mcp_servers.node_repl]'
        'command = "old node"'
        '[mcp_servers.user]'
        'command = "keep mcp"'
        '[[array]]'
        'value = 1'
        '[other]'
        'enabled = true'
    )
    $config = Join-Path $codexHome 'config.toml'
    $fixture | Set-Content -LiteralPath $config -Encoding UTF8
    Write-TestConfig $config $codexHome
    Write-TestConfig $config $codexHome
    $raw = Get-Content -LiteralPath $config -Raw
    Assert-That (([regex]::Matches($raw, '# >>> CODEX-VIBE-SETUP MANAGED')).Count -eq 1) 'managed block start is not duplicated'
    Assert-That (([regex]::Matches($raw, '# <<< CODEX-VIBE-SETUP MANAGED')).Count -eq 1) 'managed block end is not duplicated'
    Assert-That ($raw -match '\[projects\."C:\\keep"\]') 'project trust section preserved'
    Assert-That ($raw -match '\[other\]') 'unmanaged section preserved'
    Assert-That ($raw -match '\[model_providers\.user\]' -and $raw -match 'base_url = "keep router"') 'unmanaged provider preserved'
    Assert-That ($raw -match '\[mcp_servers\.user\]' -and $raw -match 'command = "keep mcp"') 'unmanaged MCP preserved'
    Assert-That ($raw -match '\[\[array\]\]' -and $raw -match 'value = 1') 'array table preserved'
    Assert-That ($raw -notmatch '\[model_providers\.9router\]') 'managed provider removed'
    Assert-That ($raw -notmatch '\[mcp_servers\.node_repl\]') 'managed MCP removed'
    Assert-That ($raw -notmatch 'model = "old"|old = true|duplicate|old router|old node') 'old managed values removed'

    $bundleRoot = $PSScriptRoot
    $textExtensions = @('.ps1', '.cmd', '.md', '.json', '.toml', '.txt', '.yaml', '.yml', '.js', '.mjs', '.cjs', '.py', '.sh', '.html', '.css', '.csv', '.xml', '.ini')
    $files = @(
        Get-ChildItem -LiteralPath (Join-Path $bundleRoot 'snapshot'), (Join-Path $bundleRoot 'templates') -Recurse -File -Force
        Get-Item -LiteralPath (Join-Path $bundleRoot 'manifest.json')
    ) | Where-Object { $textExtensions -contains $_.Extension.ToLowerInvariant() }
    $marketplaceJson = @(Get-ChildItem -LiteralPath (Join-Path $bundleRoot 'snapshot\marketplaces') -Recurse -File -Filter 'marketplace.json' -Force)
    foreach ($file in $marketplaceJson) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Assert-That ($bytes.Count -gt 0 -and $bytes[0] -eq [byte][char]'{') "marketplace JSON has no UTF-8 BOM: $($file.FullName)"
    }
    Assert-That (@($files | Select-String -Pattern 'sk-[A-Za-z0-9._-]{20,}' -List -ErrorAction SilentlyContinue).Count -eq 0) 'bundle text contains no API key'
    Assert-That (@($files | Select-String -Pattern '@openai-(curated|bundled)' -List -ErrorAction SilentlyContinue).Count -eq 0) 'bundle uses installable local marketplace names'
    $sourceProfile = [Environment]::GetFolderPath('UserProfile')
    Assert-That (@($files | Select-String -Pattern $sourceProfile -SimpleMatch -List -ErrorAction SilentlyContinue).Count -eq 0) 'bundle text contains no source profile path'
    Write-Host 'Self-test passed.' -ForegroundColor Green
    exit 0
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

