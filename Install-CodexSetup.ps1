[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$SkipUpdates,
    [switch]$SkipPlugins
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BundleRoot = $PSScriptRoot
$HomeDir = [Environment]::GetFolderPath('UserProfile')
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HomeDir '.codex' }
$Snapshot = Join-Path $BundleRoot 'snapshot'
$BackupStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Results = New-Object 'System.Collections.Generic.List[object]'
$PluginSet = [ordered]@{
    'openai-primary-runtime' = @('documents', 'spreadsheets', 'presentations')
    'codex-vibe-curated'     = @('github', 'gmail', 'google-calendar', 'google-drive')
    'codex-vibe-bundled'     = @('browser', 'sites')
}

function Add-Result([string]$Component, [string]$Status, [string]$Detail = '') {
    [void]$Results.Add([pscustomobject]@{ Component = $Component; Status = $Status; Detail = $Detail })
}
function Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Good([string]$Message) { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Run([string]$File, [string[]]$Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $File @Arguments 2>&1)
        $nativeExitCode = Get-Variable LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
        $exitCode = if ($null -eq $nativeExitCode) { 1 } else { [int]$nativeExitCode }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}
function First-Version([object[]]$Lines) {
    foreach ($line in $Lines) {
        if ([string]$line -match '(?<!\d)(\d+\.\d+\.\d+)(?!\d)') {
            try { return [version]$Matches[1] } catch { }
        }
    }
    return $null
}
function Ask([string]$Prompt, [string]$Default = 'Y') {
    if ($NonInteractive) { return $Default.ToUpperInvariant() }
    $suffix = if ($Default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default.ToUpperInvariant() }
    return $answer.Trim().Substring(0, 1).ToUpperInvariant()
}
function Quote-Toml([string]$Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}
function Install-NodeFallback {
    $baseUri = 'https://nodejs.org/dist'
    $tempMsi = Join-Path ([IO.Path]::GetTempPath()) ("node-lts-" + [guid]::NewGuid().ToString('N') + '.msi')
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        Info 'winget tidak tersedia/gagal. Mengambil Node.js LTS dari nodejs.org...'
        $releases = Invoke-RestMethod -UseBasicParsing -Uri "$baseUri/index.json"
        $release = @($releases | Where-Object {
            $_.lts -and @($_.files) -contains 'win-x64-msi'
        }) | Select-Object -First 1
        if (-not $release) { throw 'Release Node.js LTS dengan MSI Windows x64 tidak ditemukan.' }

        $version = [string]$release.version
        if ($version -notmatch '^v\d+\.\d+\.\d+$') { throw "Versi Node.js tidak valid: $version" }
        $msiName = "node-$version-x64.msi"
        $releaseUri = "$baseUri/$version"
        $msiUri = "$releaseUri/$msiName"
        $hashUri = "$releaseUri/SHASUMS256.txt"
        Info "Node.js LTS $version dipilih. Mengunduh MSI..."
        Invoke-WebRequest -UseBasicParsing -Uri $msiUri -OutFile $tempMsi
        $hashText = (Invoke-WebRequest -UseBasicParsing -Uri $hashUri).Content
        $hashPattern = '^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($msiName) + '\s*$'
        $hashLine = @($hashText -split '\r?\n' | Where-Object { $_ -match $hashPattern }) | Select-Object -First 1
        if (-not $hashLine) { throw "Checksum $msiName tidak ditemukan." }

        $expectedHash = ([regex]::Match($hashLine, '^\s*([0-9a-fA-F]{64})')).Groups[1].Value.ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $tempMsi -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'Checksum MSI Node.js tidak cocok; instalasi dibatalkan.' }
        Good 'Checksum MSI Node.js cocok.'

        $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
        if (-not (Test-Path -LiteralPath $msiexec)) { throw 'msiexec.exe tidak ditemukan.' }
        $installer = Start-Process -FilePath $msiexec -ArgumentList @('/i', "`"$tempMsi`"", '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
        if (@(0, 3010) -notcontains $installer.ExitCode) {
            throw "Instalasi Node.js LTS via MSI gagal (exit code $($installer.ExitCode))."
        }
    }
    catch {
        throw "Node.js LTS fallback gagal: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tempMsi) { Remove-Item -LiteralPath $tempMsi -Force -ErrorAction SilentlyContinue }
    }
}
function Ensure-NodeNpm {
    Refresh-Path
    $node = Find-ExecutableCommand 'node'
    $npm = Find-ExecutableCommand 'npm'
    if ($node -and $npm) {
        $nodeVersion = First-Version (Run $node.Source @('--version')).Output
        $npmVersion = First-Version (Run $npm.Source @('--version')).Output
        Info "Node.js/npm sudah tersedia: node $(if ($nodeVersion) { $nodeVersion } else { 'versi tidak terbaca' }), npm $(if ($npmVersion) { $npmVersion } else { 'versi tidak terbaca' })"
        $update = if ($SkipUpdates) { 'N' } else { Ask 'Node.js sudah ada. Update Node.js ke LTS terbaru?' 'N' }
        if ($update -eq 'Y') {
            if ($DryRun) {
                Info 'Dry-run: update Node.js dilewati.'
                return $true
            }
            $updated = $false
            $updateFailed = $false
            $winget = Find-ExecutableCommand 'winget'
            if ($winget) {
                Info 'Mengupdate Node.js LTS via winget...'
                try {
                    $result = Run $winget.Source @('upgrade', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements')
                    $updated = $result.ExitCode -eq 0
                }
                catch { Warn 'Update via winget gagal; mencoba installer resmi Node.js.' }
            }
            if (-not $updated) {
                Warn 'Update via winget tidak berhasil; memakai installer resmi Node.js.'
                try { Install-NodeFallback; $updated = $true }
                catch { $updateFailed = $true; Warn "Update Node.js gagal; versi yang sudah ada dipertahankan: $($_.Exception.Message)" }
            }
            Refresh-Path
            $node = Find-ExecutableCommand 'node'
            $npm = Find-ExecutableCommand 'npm'
            if (-not ($node -and $npm)) {
                throw 'Update Node.js selesai tetapi node/npm belum masuk PATH. Tutup PowerShell, buka kembali, lalu jalankan installer lagi.'
            }
            if ($updateFailed) {
                Info 'Node.js/npm tetap memakai versi yang sudah ada.'
            }
            else {
                Good 'Node.js/npm siap setelah pemeriksaan/update.'
            }
        }
        elseif ($SkipUpdates) {
            Info 'SkipUpdates aktif; update Node.js/npm dilewati.'
        }
        else {
            Info 'Node.js/npm sudah ada; update dilewati.'
        }
        return $true
    }
    if ($DryRun) {
        Warn 'Dry-run: Node.js/npm tidak ditemukan; instalasi Node.js LTS dilewati.'
        return $false
    }

    $installed = $false
    $winget = Find-ExecutableCommand 'winget'
    if ($winget) {
        Info 'Node.js/npm tidak ditemukan. Menginstal Node.js LTS via winget...'
        try {
            $result = Run $winget.Source @('install', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements')
            if ($result.ExitCode -eq 0) {
                Refresh-Path
                $installed = [bool](Find-ExecutableCommand 'node' -and Find-ExecutableCommand 'npm')
            }
            if (-not $installed) { Warn 'Instalasi via winget belum menghasilkan node/npm; mencoba installer resmi.' }
        }
        catch { Warn 'Instalasi via winget gagal; mencoba installer resmi.' }
    }
    else {
        Warn 'winget tidak tersedia; memakai installer resmi Node.js.'
    }

    if (-not $installed) {
        Install-NodeFallback
        Refresh-Path
    }
    $node = Find-ExecutableCommand 'node'
    $npm = Find-ExecutableCommand 'npm'
    if (-not ($node -and $npm)) {
        throw 'Node.js terpasang tetapi node/npm belum masuk PATH. Tutup PowerShell, buka kembali, lalu jalankan installer lagi.'
    }
    Good "Node.js/npm siap: $($node.Source)"
    return $true
}
function Read-Secret([string]$Prompt, [bool]$Required) {
    while ($true) {
        if ($NonInteractive) { return $null }
        $secure = Read-Host "$Prompt (paste: Ctrl+V, Ctrl+Shift+V, Shift+Insert, klik kanan, atau ketik CLIPBOARD)" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        if ($null -ne $value) { $value = $value.Trim() }
        if ($value -and [string]::Equals($value, 'CLIPBOARD', [StringComparison]::OrdinalIgnoreCase)) {
            try {
                $clipboard = Get-Clipboard -Raw -ErrorAction Stop
                $value = if ($null -ne $clipboard) { $clipboard.Trim() } else { '' }
            }
            catch { Warn 'Clipboard tidak dapat dibaca. Coba paste langsung dengan Ctrl+V atau klik kanan.'; $value = '' }
        }
        if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
            Warn 'Nilai wajib diisi.'
            continue
        }
        return $value
    }
}
function Mask-Secret([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<kosong>' }
    return "panjang=$($Value.Length)"
}
function Confirm-Secret([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Warn "${Name}: API key kosong."
        return $false
    }
    if ($DryRun) {
        Info "${Name}: diterima ($(Mask-Secret $Value)); dry-run tidak menyimpan."
        return $true
    }
    $user = [Environment]::GetEnvironmentVariable($Name, 'User')
    $process = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($user -eq $Value -and $process -eq $Value) {
        Good "${Name}: terdeteksi dan tersimpan ($(Mask-Secret $Value))."
        return $true
    }
    Warn "${Name}: input diterima, tetapi tidak terbaca dari environment user/process."
    return $false
}
function Get-CurrentSecret([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($Name, 'Process') }
    return $value
}
function Get-Secret([string]$Name, [bool]$Required) {
    $existingValue = Get-CurrentSecret $Name
    if ($existingValue) {
        Info "$Name sudah ada; dipertahankan ($(Mask-Secret $existingValue))."
        return $existingValue
    }
    $value = Read-Secret "Masukkan $Name" $Required
    if ($value -and -not $DryRun) {
        [Environment]::SetEnvironmentVariable($Name, $value, 'User')
        [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
    }
    if ($value) {
        $confirmed = Confirm-Secret $Name $value
        if ($Required -and -not $confirmed -and -not $DryRun) {
            throw "$Name tidak berhasil disimpan ke user environment."
        }
    }
    return $value
}
function Backup([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $destination = "$Path.codex-vibe-backup-$BackupStamp"
    if (-not $DryRun) { Copy-Item -LiteralPath $Path -Destination $destination -Force }
    Info "Backup: $destination"
    return $destination
}
function Copy-Tree([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Sumber tidak ditemukan: $Source" }
    if ($DryRun) { return }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}
function Find-ExecutableCommand([string]$Name) {
    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    $application = $commands | Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.(cmd|exe)$' } | Select-Object -First 1
    if ($application) { return $application }
    return $commands | Select-Object -First 1
}
function Find-CodexCommand {
    return Find-ExecutableCommand 'codex'
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
function Get-CliInfo {
    $command = Find-CodexCommand
    if (-not $command) {
        return [pscustomobject]@{ Found = $false; Path = $null; Version = $null; Latest = $null; Method = 'missing' }
    }
    $versionResult = Run $command.Source @('--version')
    $version = First-Version $versionResult.Output
    $method = 'unknown'
    $npm = Find-ExecutableCommand 'npm'
    if ($npm) {
        $npmResult = Run $npm.Source @('list', '-g', '@openai/codex', '--depth=0', '--json')
        try {
            $json = ($npmResult.Output -join "`n") | ConvertFrom-Json
            if ($json.dependencies.'@openai/codex') { $method = 'npm' }
        }
        catch { }
    }
    $latest = $null
    if ($npm -and -not $SkipUpdates) {
        $latestResult = Run $npm.Source @('view', '@openai/codex', 'version', '--silent')
        $latest = First-Version $latestResult.Output
    }
    return [pscustomobject]@{ Found = $true; Path = $command.Source; Version = $version; Latest = $latest; Method = $method }
}
function Get-VsCodeInfo {
    $command = Find-CodeCommand
    $extensionId = $null
    $extensionVersion = $null
    if ($command) {
        $extensionResult = Run $command.Source @('--list-extensions', '--show-versions')
        $extensions = @($extensionResult.Output) |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^(openai\.(chatgpt|codex))@(.+)$' } |
        Select-Object -First 1
        if ($extensions -and $extensions[0] -match '^(openai\.(chatgpt|codex))@(.+)$') {
            $extensionId = $Matches[1]
            $extensionVersion = $Matches[2]
        }
    }
    if (-not $extensionId) {
        foreach ($root in @(
                (Join-Path $HomeDir '.vscode\extensions'),
                (Join-Path $HomeDir '.vscode-insiders\extensions')
            )) {
            $extension = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(openai\.(chatgpt|codex))-(.+)$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
            if ($extension -and $extension.Name -match '^(openai\.(chatgpt|codex))-(.+)$') {
                $extensionId = $Matches[1]
                $extensionVersion = $Matches[3]
                break
            }
        }
    }
    $version = $null
    if ($command) { $versionResult = Run $command.Source @('--version'); $version = First-Version $versionResult.Output }
    return [pscustomobject]@{
        Found            = [bool]($command -or $extensionId)
        Path             = if ($command) { $command.Source } else { $null }
        Version          = $version
        ExtensionId      = $extensionId
        ExtensionVersion = $extensionVersion
    }
}
function Get-Preserved([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
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
        if ($line -match '^\s*# >>> CODEX-VIBE-SETUP MANAGED') {
            $inManagedBlock = $true
            continue
        }
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
function New-Managed([string]$Office, [string]$Wrapper, [string]$Node, [string]$Stitch, [string]$Test, [string]$Marketplaces) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $add = { param([string]$Line) [void]$lines.Add($Line) }
    & $add '# >>> CODEX-VIBE-SETUP MANAGED'
    & $add 'model = "hemat"'
    & $add ('model_catalog_json = ' + (Quote-Toml (Join-Path $CodexHome 'model_catalog-hemat.json')))
    & $add 'model_provider = "9router"'
    & $add 'model_reasoning_effort = "xhigh"'
    & $add 'model_reasoning_summary = "auto"'
    & $add 'model_verbosity = "medium"'
    & $add 'service_tier = "default"'
    & $add 'approvals_reviewer = "user"'
    & $add ''
    & $add '[windows]'
    & $add 'sandbox = "elevated"'
    & $add ''
    & $add '[features]'
    & $add 'multi_agent = true'
    & $add 'js_repl = false'
    & $add ''
    & $add '[model_providers.9router]'
    & $add 'name = "9Router"'
    & $add 'base_url = "http://103.150.226.167:20128/v1"'
    & $add 'env_key = "NINEROUTER_API_KEY"'
    & $add 'wire_api = "responses"'
    & $add 'request_max_retries = 4'
    & $add 'stream_max_retries = 5'
    & $add 'stream_idle_timeout_ms = 300000'
    & $add ''
    & $add '[agents.subagent]'
    & $add 'description = "General-purpose coding subagent"'
    & $add 'model = "hemat"'
    & $add ''
    foreach ($marketplace in $PluginSet.Keys) {
        $source = Join-Path $Marketplaces $marketplace
        if ((Test-Path -LiteralPath $source) -or $DryRun) {
            & $add "[marketplaces.$marketplace]"
            & $add 'source_type = "local"'
            & $add ('source = ' + (Quote-Toml $source))
            & $add ''
            foreach ($plugin in $PluginSet[$marketplace]) {
                & $add ('[plugins."' + $plugin + '@' + $marketplace + '"]')
                & $add 'enabled = true'
                & $add ''
            }
        }
    }
    if ($Node -or $DryRun) {
        $nodePath = if ($Node) { $Node } else { Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node\<version>\bin\node_repl.exe' }
        $nodeBin = Split-Path $nodePath -Parent
        & $add '[mcp_servers.node_repl]'
        & $add ('command = ' + (Quote-Toml $nodePath))
        & $add 'startup_timeout_sec = 120'
        & $add ''
        & $add '[mcp_servers.node_repl.env]'
        & $add 'BROWSER_USE_AVAILABLE_BACKENDS = "chrome,iab"'
        & $add ('CODEX_HOME = ' + (Quote-Toml $CodexHome))
        & $add ('NODE_REPL_NODE_MODULE_DIRS = ' + (Quote-Toml (Join-Path $nodeBin 'node_modules')))
        & $add ('NODE_REPL_NODE_PATH = ' + (Quote-Toml (Join-Path $nodeBin 'node.exe')))
        & $add ''
    }
    if ($Stitch -or $DryRun) {
        & $add '[mcp_servers.stitch]'
        & $add 'url = "https://stitch.googleapis.com/mcp"'
        & $add 'startup_timeout_sec = 20'
        & $add 'tool_timeout_sec = 120'
        & $add ''
        & $add '[mcp_servers.stitch.env_http_headers]'
        & $add 'X-Goog-Api-Key = "STITCH_API_KEY"'
        & $add ''
    }
    if ($Test -or $DryRun) {
        & $add '[mcp_servers.testsprite]'
        & $add 'command = "powershell.exe"'
        & $add ('args = [ "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ' + (Quote-Toml $Wrapper) + ' ]')
        & $add ''
        & $add '[mcp_servers.testsprite.tools.testsprite_check_account_info]'
        & $add 'approval_mode = "approve"'
        & $add ''
        & $add '[mcp_servers.testsprite.tools.testsprite_open_test_result_dashboard]'
        & $add 'approval_mode = "approve"'
        & $add ''
    }
    if ($Office -or $DryRun) {
        $officePath = if ($Office) { $Office } else { Join-Path $HomeDir 'AppData\Local\OfficeCLI\officecli.exe' }
        & $add '[mcp_servers.officecli]'
        & $add ('command = ' + (Quote-Toml $officePath))
        & $add 'args = [ "mcp" ]'
        & $add ''
        & $add '[mcp_servers.officecli.tools.officecli]'
        & $add 'approval_mode = "approve"'
        & $add ''
    }
    & $add '# <<< CODEX-VIBE-SETUP MANAGED'
    return @($lines)
}
function Write-ManagedConfig([string]$Office, [string]$Wrapper, [string]$Node, [string]$Stitch, [string]$Test, [string]$Marketplaces) {
    $path = Join-Path $CodexHome 'config.toml'
    $all = @(Get-Preserved $path) + @('') + @(New-Managed $Office $Wrapper $Node $Stitch $Test $Marketplaces)
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
        [IO.File]::WriteAllText($path, (($all -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $path
}
function Find-NodeRepl {
    $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    return Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'node_repl.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
function Ensure-Office {
    $command = Get-Command officecli -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $bundleExe = Join-Path $Snapshot 'officecli\officecli.exe'
    if (Test-Path -LiteralPath $bundleExe) {
        $targetDir = Join-Path $HomeDir 'AppData\Local\OfficeCLI'
        $target = Join-Path $targetDir 'officecli.exe'
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            Copy-Item -LiteralPath $bundleExe -Destination $target -Force
        }
        return $target
    }
    Warn 'OfficeCLI tidak ditemukan; MCP OfficeCLI dilewati.'
    return $null
}
function Install-CLI([object]$Info) {
    $npm = Find-ExecutableCommand 'npm'
    if (-not $Info.Found) {
        if (-not $npm) {
            if ($DryRun) {
                Add-Result 'Codex CLI' 'dry-run' 'Node.js/npm missing'
                return
            }
            throw 'Node.js/npm tidak tersedia. Instalasi Codex CLI dibatalkan.'
        }
        if ((Ask 'Codex CLI belum ada. Install latest?' 'Y') -eq 'Y' -and -not $DryRun) {
            $result = Run $npm.Source @('install', '-g', '@openai/codex@latest')
            if ($result.ExitCode -ne 0) { throw 'Codex CLI install gagal.' }
            Refresh-Path
            Add-Result 'Codex CLI' 'installed' 'latest'
        }
        else {
            Add-Result 'Codex CLI' 'skipped' 'declined/dry-run'
        }
        return
    }
    Info "Codex CLI: $($Info.Version) via $($Info.Method); latest: $(if ($Info.Latest) { $Info.Latest } else { 'unavailable' })"
    if (-not $npm) {
        if ($DryRun) {
            Add-Result 'Codex CLI' 'dry-run' 'Node.js/npm missing'
            return
        }
        throw 'Node.js/npm tidak tersedia. Instalasi Codex CLI dibatalkan.'
    }
    $shouldUpdate = -not $SkipUpdates -and $Info.Latest -and $Info.Version -and $Info.Latest -gt $Info.Version
    if ($shouldUpdate -and (Ask 'Update Codex CLI ke latest?' 'N') -eq 'Y' -and -not $DryRun) {
        $result = Run $npm.Source @('install', '-g', '@openai/codex@latest')
        if ($result.ExitCode -eq 0) {
            Refresh-Path
            Add-Result 'Codex CLI' 'updated' 'latest'
        }
        else {
            Warn 'Update Codex CLI gagal; versi lama dipertahankan.'
            Add-Result 'Codex CLI' 'kept' ([string]$Info.Version)
        }
    }
    else {
        Add-Result 'Codex CLI' 'kept' ([string]$Info.Version)
    }
}
function Install-Extension([object]$Info) {
    if (-not $Info.Found) {
        Warn 'VS Code/code command tidak ditemukan; extension dilewati.'
        Add-Result 'VS Code extension' 'skipped' 'VS Code missing'
        return
    }
    if (-not $Info.Path) {
        Info "Codex extension terdeteksi: $($Info.ExtensionId) $($Info.ExtensionVersion)"
        Warn 'code command tidak tersedia; extension tidak diubah.'
        Add-Result 'VS Code extension' 'kept' 'code command missing'
        return
    }
    if (-not $Info.ExtensionId) {
        if ((Ask 'Codex extension belum ada. Install openai.chatgpt?' 'Y') -eq 'Y' -and -not $DryRun) {
            $result = Run $Info.Path @('--install-extension', 'openai.chatgpt', '--force')
            Add-Result 'VS Code extension' $(if ($result.ExitCode -eq 0) { 'installed' } else { 'failed' }) 'openai.chatgpt'
        }
        else {
            Add-Result 'VS Code extension' 'skipped' 'declined/dry-run'
        }
        return
    }
    Info "VS Code extension: $($Info.ExtensionId) $($Info.ExtensionVersion)"
    if (-not $SkipUpdates -and (Ask 'Update Codex extension ke latest?' 'N') -eq 'Y' -and -not $DryRun) {
        $result = Run $Info.Path @('--install-extension', $Info.ExtensionId, '--force')
        Add-Result 'VS Code extension' $(if ($result.ExitCode -eq 0) { 'updated' } else { 'failed' }) $Info.ExtensionId
    }
    else {
        Add-Result 'VS Code extension' 'kept' "$($Info.ExtensionId) $($Info.ExtensionVersion)"
    }
}
function Install-Plugins([string]$Marketplaces) {
    if ($DryRun) {
        Add-Result 'Plugins' 'dry-run' 'no changes'
        return
    }
    if ($SkipPlugins) {
        Add-Result 'Plugins' 'skipped' 'SkipPlugins'
        return
    }
    $command = Find-CodexCommand
    if (-not $command) {
        Warn 'Codex CLI tidak tersedia; plugin install dilewati.'
        Add-Result 'Plugins' 'skipped' 'Codex CLI missing'
        return
    }
    foreach ($marketplace in $PluginSet.Keys) {
        $source = Join-Path $Marketplaces $marketplace
        if (-not (Test-Path -LiteralPath $source)) {
            Warn "Marketplace tidak ditemukan: $marketplace"
            Add-Result "Marketplace $marketplace" 'skipped' 'snapshot missing'
            continue
        }
        $addMarketplace = Run $command.Source @('plugin', 'marketplace', 'add', $source)
        if ($addMarketplace.ExitCode -eq 0) {
            Add-Result "Marketplace $marketplace" 'configured' ''
        }
        else {
            Warn "Marketplace $marketplace sudah ada atau gagal dikonfigurasi; plugin tetap dicoba."
            Add-Result "Marketplace $marketplace" 'kept/warn' ''
        }
        foreach ($plugin in $PluginSet[$marketplace]) {
            $selector = "$plugin@$marketplace"
            $result = Run $command.Source @('plugin', 'add', $selector)
            if ($result.ExitCode -eq 0) {
                Add-Result "Plugin $selector" 'installed/enabled' ''
            }
            else {
                Warn "Plugin $selector gagal dipasang atau sudah terpasang; lanjut."
                Add-Result "Plugin $selector" 'kept/warn' ''
            }
        }
    }
}
function Install-TestSpriteWrapper([string]$Wrapper, [bool]$Enabled) {
    if (-not $Enabled -or $DryRun) { return }
    $directory = Split-Path $Wrapper -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    @(
        '$ErrorActionPreference = ''Stop'''
        'if ([string]::IsNullOrWhiteSpace($env:TESTSPRITE_API_KEY)) { throw ''TESTSPRITE_API_KEY is not set.'' }'
        '$env:API_KEY = $env:TESTSPRITE_API_KEY'
        'if ($env:TESTSPRITE_USERNAME) { $env:USERNAME = $env:TESTSPRITE_USERNAME }'
        '& npx -y @testsprite/testsprite-mcp@latest'
        'exit $LASTEXITCODE'
    ) | Set-Content -LiteralPath $Wrapper -Encoding UTF8
}
function Verify-Setup {
    if ($DryRun) { return }
    $command = Find-CodexCommand
    if (-not $command) {
        Add-Result 'Post-install verification' 'warn' 'Codex CLI missing'
        return
    }
    foreach ($args in @(
            @('--version'),
            @('doctor'),
            @('mcp', 'list'),
            @('plugin', 'list')
        )) {
        $result = Run $command.Source $args
        $name = if ($args.Count -eq 1) { $args[0] } else { $args -join ' ' }
        Add-Result "codex $name" $(if ($result.ExitCode -eq 0) { 'ok' } else { 'warn' }) ''
    }
    $code = Find-CodeCommand
    if ($code) {
        $result = Run $code.Source @('--list-extensions', '--show-versions')
        Add-Result 'VS Code extension verification' $(if ($result.ExitCode -eq 0) { 'ok' } else { 'warn' }) ''
    }
}

if (-not (Test-Path -LiteralPath $Snapshot)) { throw 'Snapshot tidak ditemukan. Jalankan Build-CodexBundle.ps1 dahulu.' }
Write-Host '=== Codex Vibe Setup ===' -ForegroundColor White
[void](Ensure-NodeNpm)
$cli = Get-CliInfo
$vs = Get-VsCodeInfo
if ($cli.Found) { Info "Codex CLI terdeteksi: $($cli.Path)" } else { Warn 'Codex CLI tidak terdeteksi.' }
if ($vs.Found) { Info "VS Code terdeteksi: $($vs.Path)" } else { Warn 'VS Code tidak terdeteksi.' }
Install-CLI $cli
Install-Extension $vs
$router = Get-CurrentSecret 'NINEROUTER_API_KEY'
$stitch = Get-CurrentSecret 'STITCH_API_KEY'
$test = Get-CurrentSecret 'TESTSPRITE_API_KEY'
if (-not $router) { $router = Get-Secret 'NINEROUTER_API_KEY' $true }
$testUser = if ($test) {
    $storedTestUser = Get-CurrentSecret 'TESTSPRITE_USERNAME'
    if ($storedTestUser) { $storedTestUser } else { Get-Secret 'TESTSPRITE_USERNAME' $false }
}
else { $null }
if (-not $router -and -not $DryRun) { throw 'NINEROUTER_API_KEY wajib diisi.' }
$office = Ensure-Office
$node = Find-NodeRepl
if ($node) { Info "node_repl: $node" } else { Warn 'node_repl tidak ditemukan; MCP node_repl dilewati.' }

$market = Join-Path $CodexHome 'codex-vibe-marketplaces'
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $market -Force | Out-Null
    foreach ($marketplace in $PluginSet.Keys) {
        $source = Join-Path $Snapshot "marketplaces\$marketplace"
        if (Test-Path -LiteralPath $source) { Copy-Tree $source (Join-Path $market $marketplace) }
    }
}
$chromeSnapshot = Join-Path $Snapshot 'chrome-runtime'
if (-not $DryRun -and (Test-Path -LiteralPath (Join-Path $chromeSnapshot 'chrome'))) {
    Copy-Tree (Join-Path $chromeSnapshot 'chrome') (Join-Path $CodexHome 'plugins\cache\openai-bundled\chrome')
}
$wrapper = Join-Path $CodexHome 'codex-vibe-mcp\testsprite-wrapper.ps1'
Install-TestSpriteWrapper $wrapper ([bool]$test)
if (-not $DryRun) {
    Copy-Item -LiteralPath (Join-Path $BundleRoot 'templates\model_catalog-hemat.json') -Destination (Join-Path $CodexHome 'model_catalog-hemat.json') -Force
    Copy-Tree (Join-Path $Snapshot 'skills') (Join-Path $HomeDir '.agents\skills')
    $combo = Join-Path $Snapshot 'tools\switch-combo.ps1'
    if (Test-Path -LiteralPath $combo) { Copy-Item -LiteralPath $combo -Destination (Join-Path $CodexHome 'switch-combo.ps1') -Force }
}
Backup (Join-Path $CodexHome 'config.toml') | Out-Null
$config = Write-ManagedConfig $office $wrapper $node $stitch $test $market
Install-Plugins $market
Add-Result 'Config' $(if ($DryRun) { 'dry-run' } else { 'written' }) $config
Add-Result 'Skills' $(if ($DryRun) { 'dry-run' } else { 'installed' }) ''
Verify-Setup
$Results | Format-Table -AutoSize
if (-not $DryRun) {
    Good 'Setup selesai.'
    Warn 'Tutup semua jendela VS Code, buka kembali, lalu buat thread Codex baru agar API key terbaca.'
}



