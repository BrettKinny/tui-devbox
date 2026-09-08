#!/usr/bin/env pwsh
#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "lifecycle PowerShell regression: $Message" }
}

foreach ($name in @('install.ps1', 'uninstall.ps1', 'scripts/migrate-windows-adapter.ps1')) {
    $path = Join-Path $Root $name
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "$name has parser errors: $($errors -join '; ')"

    if ($name -ceq 'scripts/migrate-windows-adapter.ps1') { continue }
    $releaseFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-ReleaseTag'
    }, $true)
    Assert-True ($null -ne $releaseFunction) "$name has no Test-ReleaseTag function"
    Invoke-Expression $releaseFunction.Extent.Text
    Assert-True (Test-ReleaseTag 'v1.1.0') "$name rejects a stable tag"
    Assert-True (Test-ReleaseTag 'v1.1.0-rc.1') "$name rejects a prerelease tag"
    Assert-True (-not (Test-ReleaseTag 'v1.1.0-01')) "$name accepts a leading-zero prerelease"
    Assert-True (-not (Test-ReleaseTag 'v1.1.0+build-1')) "$name accepts excluded build metadata"
    Assert-True (-not (Test-ReleaseTag ("v1.1.0-" + ('a' * 122)))) "$name accepts a tag longer than 128 characters"
}

$migration = [IO.File]::ReadAllText((Join-Path $Root 'scripts/migrate-windows-adapter.ps1'))
Assert-True ($migration.Contains("[ValidateSet('PowerShell', 'GitBash')]")) 'migration command has no closed target set'
Assert-True ($migration.Contains('Box ownership check failed') -and $migration.Contains('Managed-home ownership check failed')) 'migration skips runtime ownership checks'
Assert-True ($migration.Contains('[IO.File]::Move($temp, $Path, $true)')) 'migration does not publish state/profile files atomically'
Assert-True (-not ($migration -match 'Invoke-Expression|\biex\b')) 'migration evaluates Install identity data'

$installTokens = $null; $installErrors = $null
$installAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Root 'install.ps1'), [ref]$installTokens, [ref]$installErrors)
Assert-True ($installErrors.Count -eq 0) "install.ps1 has parser errors: $($installErrors -join '; ')"
$digestFunction = $installAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Select-ImageRepoDigest'
}, $true)
Assert-True ($null -ne $digestFunction) 'install.ps1 has no exact RepoDigests selector'
Invoke-Expression $digestFunction.Extent.Text
$expectedDigest = 'ghcr.io/squarewavesystems/squarebox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$decoyDigest = 'ghcr.io/squarewavesystems/squarebox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
Assert-True ((Select-ImageRepoDigest @($decoyDigest, $expectedDigest) $expectedDigest) -ceq $expectedDigest) `
    'multi-entry RepoDigests does not select the exact Candidate reference'
Assert-True (-not (Select-ImageRepoDigest @($decoyDigest) $expectedDigest)) `
    'RepoDigests selector accepts a different digest when the Candidate is absent'

$install = [IO.File]::ReadAllText((Join-Path $Root 'install.ps1'))
$uninstall = [IO.File]::ReadAllText((Join-Path $Root 'uninstall.ps1'))
Assert-True ($install.Contains('--userns=keep-id:uid=1000,gid=1000')) 'rootless Podman does not map host identity to dev'
Assert-True ($install.Contains("'--security-opt', 'label=disable'")) 'Podman does not disable private SELinux relabeling'
Assert-True ($install.Contains("'--pids-limit=4096'")) 'installer does not bound Box PID exhaustion'
Assert-True (-not ($install -match ':ro,Z|BindSuffix.*:Z')) 'PowerShell adapter still emits private :Z binds'
Assert-True ($install.Contains('$HomeVolume -cne $State.HOME_VOLUME')) 'Managed-home identity comparison is not case-sensitive'
Assert-True ($install.Contains('$owner.Trim() -cne ''__INSTALL_ID__''')) 'generated adapter case-folds Install identity'
Assert-True (-not (($install + $uninstall) -match '\$owner(?:\.Trim\(\))?\s+-ne\s+\$InstallId')) 'ownership comparison uses case-insensitive -ne'
Assert-True ($install.Contains('Unable to verify ownership label')) 'installer does not fail closed on label inspection'
Assert-True ($uninstall.Contains('changed ownership after confirmation')) 'uninstaller does not revalidate ownership after planning'
Assert-True ($install.Contains('$script:RollbackArmed')) 'installer has no pre-state rollback transaction'
Assert-True ($install.Contains('$script:CandidateName')) 'installer has no temporary Candidate Box identity'
Assert-True ($install.Contains('& $Runtime rename $ContainerName $script:RollbackName')) 'installer does not preserve the prior Box before promotion'
Assert-True ($install.Contains('& $Runtime rename $script:CandidateName $ContainerName')) 'installer does not promote the Candidate Box by rename'
foreach ($boundary in @('checkout', 'image-alias', 'managed-home-create', 'managed-config', 'candidate-create', 'host-profile', 'candidate-start', 'provision', 'old-box-preserved', 'candidate-promoted', 'state-publish')) {
    Assert-True ($install.Contains("Invoke-FailureInjection '$boundary'")) "installer lacks deterministic failure boundary '$boundary'"
}
Assert-True ($install.Contains('Malformed squarebox marker block') -and $uninstall.Contains('Malformed squarebox marker block')) 'profile marker validation is absent'
Assert-True ($install.Contains('[regex]::Replace($profileBlock')) 'profile interpolation can rescan inserted path placeholders'
Assert-True ($uninstall.Contains('Assert-PurgeCheckout')) 'purge does not revalidate checkout identity'
Assert-True ($install.Contains('Get-BoundedJson') -and $install.Contains('MaximumRetryCount 3')) 'release metadata HTTP is unbounded or lacks retries'
Assert-True ($install.Contains('{{range .RepoDigests}}{{println .}}{{end}}') -and -not $install.Contains('index .RepoDigests 0')) 'PowerShell trusts the first repository digest instead of enumerating identities'
Assert-True ($install -match '\$repoDigestOutput = @\(\)\s+if \(-not \$Build\)') 'local builds still derive identity from unordered RepoDigests'
Assert-True ($install.Contains('$SelectionStateFiles') -and $install.Contains('Selection state file must not be a reparse point or symlink')) 'PowerShell seeding can follow Workspace Selection links'

# Execute the native rollback implementation against an in-memory runtime. This
# complements source-contract assertions by proving both rename phases restore
# the canonical Box and remove the Candidate without requiring Docker on CI.
foreach ($functionName in @('Invoke-InstallRollback', 'Invoke-FailureInjection')) {
    $definition = $installAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
    }, $true)
    Assert-True ($null -ne $definition) "install.ps1 has no $functionName function"
    Invoke-Expression $definition.Extent.Text
}
function global:docker {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$RuntimeArgs)
    $global:LASTEXITCODE = 0
    $command = @($RuntimeArgs | ForEach-Object { [string]$_ })
    switch ($command[0]) {
        'rename' {
            if (-not $script:RuntimeBoxes.ContainsKey($command[1]) -or $script:RuntimeBoxes.ContainsKey($command[2])) {
                $global:LASTEXITCODE = 1; return
            }
            $script:RuntimeBoxes[$command[2]] = $script:RuntimeBoxes[$command[1]]
            $script:RuntimeBoxes.Remove($command[1])
        }
        'container' {
            if ($command[1] -cne 'inspect' -or -not $script:RuntimeBoxes.ContainsKey($command[-1])) { $global:LASTEXITCODE = 1 }
            else { '{}' }
        }
        'inspect' {
            if (-not $script:RuntimeBoxes.ContainsKey($command[-1])) { $global:LASTEXITCODE = 1 }
            else { $script:RuntimeBoxes[$command[-1]] }
        }
        'rm' { $script:RuntimeBoxes.Remove($command[-1]) }
        'tag' {}
        'image' { $global:LASTEXITCODE = 1 }
        'volume' { $global:LASTEXITCODE = 1 }
        default { throw "unexpected mock runtime command: $($command -join ' ')" }
    }
}
function global:git { $global:LASTEXITCODE = 0 }
$Runtime = 'docker'; $ContainerName = 'custom.box'; $InstallId = 'test-install-123'
$HomeVolume = 'custom-home'; $ImageAlias = 'custom-image'; $StateFile = ''
$script:StatePublished = $false; $script:RuntimeReady = $true; $script:VolumeCreated = $false
$script:ImageAliasMutated = $false; $script:PriorSourceCommit = ''; $script:CheckoutCreated = $false
$script:ProfileBackups = @(); $script:ManagedBackupDir = ''; $script:ManagedBackups = @()
foreach ($phase in @('candidate-created', 'old-preserved', 'candidate-promoted')) {
    $script:CandidateName = 'custom.box-candidate-test'; $script:RollbackName = 'custom.box-rollback-test'
    $script:RuntimeBoxes = @{ 'custom.box' = $InstallId; 'custom.box-candidate-test' = $InstallId }
    $script:ContainerCreated = $true; $script:OldContainerRenamed = $false; $script:CandidatePromoted = $false
    if ($phase -cin @('old-preserved', 'candidate-promoted')) {
        $script:RuntimeBoxes[$script:RollbackName] = $script:RuntimeBoxes[$ContainerName]
        $script:RuntimeBoxes.Remove($ContainerName)
        $script:OldContainerRenamed = $true
    }
    if ($phase -ceq 'candidate-promoted') {
        $script:RuntimeBoxes[$ContainerName] = $script:RuntimeBoxes[$script:CandidateName]
        $script:RuntimeBoxes.Remove($script:CandidateName)
        $script:CandidatePromoted = $true
    }
    $script:RollbackArmed = $true; $script:RollbackInProgress = $false
    Invoke-InstallRollback
    Assert-True ($script:RuntimeBoxes.ContainsKey($ContainerName)) "rollback phase '$phase' lost canonical custom Box"
    Assert-True ($script:RuntimeBoxes[$ContainerName] -ceq $InstallId) "rollback phase '$phase' changed canonical ownership"
    Assert-True (-not $script:RuntimeBoxes.ContainsKey($script:CandidateName)) "rollback phase '$phase' retained Candidate"
    Assert-True (-not $script:RuntimeBoxes.ContainsKey($script:RollbackName)) "rollback phase '$phase' retained rollback name"
}
$env:SQUAREBOX_FAIL_AT = 'candidate-promoted'
$injected = $false
try { Invoke-FailureInjection 'candidate-promoted' } catch { $injected = $_.Exception.Message -like '*candidate-promoted*' }
Remove-Item Env:SQUAREBOX_FAIL_AT
Assert-True $injected 'native failure injection did not throw at the selected boundary'
Remove-Item Function:docker, Function:git -ErrorAction SilentlyContinue

$schema = Get-Content -Raw (Join-Path $Root 'scripts/lib/install-state-schema.json') | ConvertFrom-Json
$cases = Get-Content -Raw (Join-Path $Root 'tests/fixtures/install-state-cases.json') | ConvertFrom-Json
$StateFields = @($schema.fields)
$Repo = 'https://github.com/SquareWaveSystems/squarebox.git'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "squarebox-state-$([guid]::NewGuid().ToString('N'))"
$UserHome = Join-Path $fixtureRoot 'home'
$fixtureInstall = Join-Path $fixtureRoot 'squarebox'
$stateDir = Join-Path $fixtureInstall '.squarebox'
[void](New-Item -ItemType Directory -Force $UserHome, $stateDir)

function Abort([string]$Message) { throw $Message }
try {
    foreach ($adapter in @('install.ps1', 'uninstall.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $Root $adapter), [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "$adapter has parser errors"
        foreach ($functionName in @('Test-ReleaseTag', 'Test-StatePath', 'Test-SamePath', 'Test-StateId', 'Assert-InstallState', 'Read-InstallState')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            }, $true)
            Assert-True ($null -ne $definition) "$adapter has no $functionName function"
            Invoke-Expression $definition.Extent.Text
        }
        foreach ($case in $cases) {
            $values = [ordered]@{
                FORMAT = '1'; INSTALL_ID = 'test-install-123'; RUNTIME = 'docker'
                INSTALL_DIR = $fixtureInstall; WORKSPACE_DIR = (Join-Path $fixtureRoot 'workspace')
                GIT_CONFIG_DIR = (Join-Path $fixtureInstall '.squarebox/identity/git')
                HOME_VOLUME = 'squarebox-home'; CONTAINER_NAME = 'squarebox'; IMAGE_ALIAS = 'squarebox'
                IMAGE_REPOSITORY = 'ghcr.io/squarewavesystems/squarebox'
                IMAGE_REF = 'ghcr.io/squarewavesystems/squarebox@sha256:' + ('b' * 64)
                IMAGE_ID = 'sha256:' + ('c' * 64)
                IMAGE_DIGEST = 'ghcr.io/squarewavesystems/squarebox@sha256:' + ('b' * 64)
                SOURCE_REF = 'v1.2.3'; SOURCE_COMMIT = 'a' * 40; RELEASE_TAG = 'v1.2.3'
                REQUESTED_TAG = 'latest'; PUID = '1000'; PGID = '1000'; BUILD = '0'; EDGE = '0'
                SHELL_INIT = $PROFILE.CurrentUserAllHosts; SHELL_RC = $PROFILE.CurrentUserAllHosts
                ORIGIN = $Repo; HOME_VOLUME_ADOPTED = '0'
            }
            foreach ($property in $case.set.PSObject.Properties) {
                $fixtureValue = [string]$property.Value
                if ($fixtureValue.StartsWith('{ROOT}/', [StringComparison]::Ordinal)) {
                    $values[$property.Name] = $fixtureRoot + $fixtureValue.Substring('{ROOT}'.Length).Replace(
                        '/', [IO.Path]::DirectorySeparatorChar)
                } else {
                    $values[$property.Name] = $fixtureValue.Replace('{ROOT}', $fixtureRoot)
                }
            }
            $removed = @($case.remove)
            $lines = @($StateFields | Where-Object { $_ -cnotin $removed } | ForEach-Object { "$_=$($values[$_])" })
            $lines += @($case.append)
            $separator = if ($case.encoding -ceq 'crlf') { "`r`n" } else { [Environment]::NewLine }
            $stateFile = Join-Path $stateDir 'install-state'
            [IO.File]::WriteAllText($stateFile, (($lines -join $separator) + $separator), [Text.UTF8Encoding]::new($false))
            $accepted = $true
            try { [void](Read-InstallState $stateFile $fixtureInstall) } catch { $accepted = $false }
            Assert-True ($accepted -eq [bool]$case.accept) "$adapter fixture '$($case.name)' had unexpected result"
        }
    }
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Execute both migration directions with native Windows paths, isolated profile
# files, and a mock runtime. State and profiles must be accepted after each
# conversion without touching a real Box or the runner's user profiles.
$migrationRoot = Join-Path ([IO.Path]::GetTempPath()) "squarebox-migration-test-$([guid]::NewGuid().ToString('N'))"
$migrationHome = Join-Path $migrationRoot 'Üser Home'
$migrationInstall = Join-Path $migrationHome 'Squarebox Space'
$migrationStateDir = Join-Path $migrationInstall '.squarebox'
$migrationState = Join-Path $migrationStateDir 'install-state'
$profileAll = Join-Path $migrationHome 'Documents\PowerShell\profile.ps1'
$profileHost = Join-Path $migrationHome 'Documents\PowerShell\host-profile.ps1'
$gitBashInit = (Join-Path $migrationHome '.squarebox-shell-init').Replace('\', '/')
$gitBashRc = (Join-Path $migrationHome '.bashrc').Replace('\', '/')
$mockBin = Join-Path $migrationRoot 'bin'
[IO.Directory]::CreateDirectory($migrationStateDir) | Out-Null
[IO.Directory]::CreateDirectory($mockBin) | Out-Null
$mockRuntime = Join-Path $mockBin 'mock-runtime.ps1'
[IO.File]::WriteAllText($mockRuntime, @'
$command = $args -join ' '
if ($command.Contains('{{.Id}}')) { Write-Output ('sha256:' + ('c' * 64)) }
elseif ($command.Contains('io.squarebox.install-id')) { Write-Output 'test-install-123' }
exit 0
'@, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $mockBin 'docker.cmd'), "@echo off`r`npwsh -NoProfile -File `"%~dp0mock-runtime.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.ASCIIEncoding]::new())
if (-not $IsWindows) {
    $unixRuntime = Join-Path $mockBin 'docker'
    [IO.File]::WriteAllText($unixRuntime, @'
#!/usr/bin/env bash
exec pwsh -NoProfile -File "$(dirname "$0")/mock-runtime.ps1" "$@"
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::SetUnixFileMode($unixRuntime, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}
[IO.File]::WriteAllLines($gitBashInit, @('# squarebox-install-id=test-install-123'), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllLines($gitBashRc, @('# >>> squarebox >>>', '[ -f "$HOME/.squarebox-shell-init" ] && . "$HOME/.squarebox-shell-init"', '# <<< squarebox <<<'), [Text.UTF8Encoding]::new($false))
$migrationValues = [ordered]@{
    FORMAT='1'; INSTALL_ID='test-install-123'; RUNTIME='docker'; INSTALL_DIR=$migrationInstall.Replace('\', '/')
    WORKSPACE_DIR=(Join-Path $migrationInstall 'Wørkspace').Replace('\', '/'); GIT_CONFIG_DIR=(Join-Path $migrationInstall '.squarebox\identity\git').Replace('\', '/')
    HOME_VOLUME='custom-home'; CONTAINER_NAME='custom.box'; IMAGE_ALIAS='squarebox'; IMAGE_REPOSITORY='ghcr.io/squarewavesystems/squarebox'
    IMAGE_REF='ghcr.io/squarewavesystems/squarebox@sha256:' + ('b' * 64); IMAGE_ID='sha256:' + ('c' * 64)
    IMAGE_DIGEST='ghcr.io/squarewavesystems/squarebox@sha256:' + ('b' * 64); SOURCE_REF='v1.2.3'; SOURCE_COMMIT='a' * 40
    RELEASE_TAG='v1.2.3'; REQUESTED_TAG='latest'; PUID='1000'; PGID='1000'; BUILD='0'; EDGE='0'
    SHELL_INIT=$gitBashInit; SHELL_RC=$gitBashRc; ORIGIN='https://github.com/SquareWaveSystems/squarebox.git'; HOME_VOLUME_ADOPTED='0'
}
[IO.File]::WriteAllLines($migrationState, @($StateFields | ForEach-Object { "$_=$($migrationValues[$_])" }), [Text.UTF8Encoding]::new($false))
$oldPath = $env:PATH
try {
    $env:PATH = "$mockBin$([IO.Path]::PathSeparator)$oldPath"
    & pwsh -NoProfile -File (Join-Path $Root 'scripts/migrate-windows-adapter.ps1') -Target PowerShell -InstallDir $migrationInstall `
        -PowerShellProfile $profileAll -PowerShellCurrentHostProfile $profileHost -UserHomePath $migrationHome -Yes
    Assert-True ($LASTEXITCODE -eq 0) 'Git Bash to PowerShell migration failed'
    $powerState = @{}; Get-Content $migrationState | ForEach-Object { $key, $value = $_ -split '=', 2; $powerState[$key] = $value }
    Assert-True ($powerState.SHELL_INIT -ceq $profileAll) 'PowerShell migration published the wrong profile identity'
    Assert-True ($powerState.INSTALL_DIR -ceq [IO.Path]::GetFullPath($migrationInstall)) 'PowerShell migration did not normalize INSTALL_DIR'
    Assert-True ((Get-Content $profileAll) -ccontains '# squarebox-install-id=test-install-123') 'PowerShell profile ownership was not installed'
    Assert-True (-not (Test-Path $gitBashInit)) 'source Git Bash adapter survived migration'

    & pwsh -NoProfile -File (Join-Path $Root 'scripts/migrate-windows-adapter.ps1') -Target GitBash -InstallDir $migrationInstall `
        -PowerShellProfile $profileAll -PowerShellCurrentHostProfile $profileHost -UserHomePath $migrationHome -Yes
    Assert-True ($LASTEXITCODE -eq 0) 'PowerShell to Git Bash migration failed'
    $bashState = @{}; Get-Content $migrationState | ForEach-Object { $key, $value = $_ -split '=', 2; $bashState[$key] = $value }
    Assert-True ($bashState.INSTALL_DIR -ceq $migrationInstall.Replace('\', '/')) 'Git Bash migration did not publish drive-form path spelling'
    Assert-True ((Get-Content $gitBashInit) -ccontains '# squarebox-install-id=test-install-123') 'Git Bash adapter ownership was not installed'

    $beforeMalformed = [IO.File]::ReadAllBytes($migrationState)
    [IO.File]::AppendAllText($migrationState, "UNKNOWN_FIELD=unsafe`n", [Text.UTF8Encoding]::new($false))
    $malformedState = [IO.File]::ReadAllBytes($migrationState)
    & pwsh -NoProfile -File (Join-Path $Root 'scripts/migrate-windows-adapter.ps1') -Target PowerShell -InstallDir $migrationInstall `
        -PowerShellProfile $profileAll -PowerShellCurrentHostProfile $profileHost -UserHomePath $migrationHome -Yes 2>$null
    Assert-True ($LASTEXITCODE -ne 0) 'migration accepted malformed Install state'
    Assert-True ([Convert]::ToBase64String($malformedState) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($migrationState))) 'malformed migration changed Install state'
    [IO.File]::WriteAllBytes($migrationState, $beforeMalformed)

    $beforeForeign = [IO.File]::ReadAllBytes($migrationState)
    [IO.File]::WriteAllText($gitBashInit, "# squarebox-install-id=foreign-owner`n", [Text.UTF8Encoding]::new($false))
    & pwsh -NoProfile -File (Join-Path $Root 'scripts/migrate-windows-adapter.ps1') -Target PowerShell -InstallDir $migrationInstall `
        -PowerShellProfile $profileAll -PowerShellCurrentHostProfile $profileHost -UserHomePath $migrationHome -Yes 2>$null
    Assert-True ($LASTEXITCODE -ne 0) 'migration accepted a foreign Git Bash adapter'
    Assert-True ([Convert]::ToBase64String($beforeForeign) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($migrationState))) 'foreign migration changed Install state'
    [IO.File]::WriteAllLines($gitBashInit, @('# squarebox-install-id=test-install-123'), [Text.UTF8Encoding]::new($false))

    & pwsh -NoProfile -File (Join-Path $Root 'scripts/migrate-windows-adapter.ps1') -Target PowerShell -InstallDir $migrationInstall `
        -PowerShellProfile $profileAll -PowerShellCurrentHostProfile $profileHost -UserHomePath $migrationHome -Yes
    Assert-True ($LASTEXITCODE -eq 0) 'Git Bash to PowerShell migration before target uninstall failed'

    $uninstallHarness = Join-Path $migrationRoot 'invoke-target-uninstall.ps1'
    [IO.File]::WriteAllText($uninstallHarness, @'
$PROFILE.CurrentUserAllHosts = $env:SQUAREBOX_TEST_PROFILE_ALL
$PROFILE.CurrentUserCurrentHost = $env:SQUAREBOX_TEST_PROFILE_HOST
& $env:SQUAREBOX_TEST_UNINSTALL -InstallDir $env:SQUAREBOX_TEST_INSTALL_DIR -Yes
exit $LASTEXITCODE
'@, [Text.UTF8Encoding]::new($false))
    $oldUserProfile = $env:USERPROFILE
    $env:USERPROFILE = $migrationHome
    $env:SQUAREBOX_TEST_PROFILE_ALL = $profileAll
    $env:SQUAREBOX_TEST_PROFILE_HOST = $profileHost
    $env:SQUAREBOX_TEST_UNINSTALL = Join-Path $Root 'uninstall.ps1'
    $env:SQUAREBOX_TEST_INSTALL_DIR = $migrationInstall
    try {
        & pwsh -NoProfile -File $uninstallHarness
        Assert-True ($LASTEXITCODE -eq 0) 'PowerShell uninstaller rejected migrated Install state'
        Assert-True (-not ((Get-Content $profileAll) -ccontains '# squarebox-install-id=test-install-123')) 'target uninstaller did not remove migrated adapter'
    } finally {
        $env:USERPROFILE = $oldUserProfile
        Remove-Item Env:SQUAREBOX_TEST_PROFILE_ALL, Env:SQUAREBOX_TEST_PROFILE_HOST, Env:SQUAREBOX_TEST_UNINSTALL, Env:SQUAREBOX_TEST_INSTALL_DIR -ErrorAction SilentlyContinue
    }
    $global:LASTEXITCODE = 0
} finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $migrationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "ok - native PowerShell lifecycle syntax, safety, and $($cases.Count) shared state fixtures"
