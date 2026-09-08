#!/usr/bin/env pwsh
#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$Edge,
    [switch]$Build,
    [switch]$Adopt,
    [string]$InstallDir,
    [string]$WorkspaceDir,
    [ValidateSet('docker', 'podman')][string]$Runtime,
    [string]$ImageRepository,
    [string]$Tag,
    [string]$HomeVolume,
    [ValidateRange(1, 2147483647)][int]$Puid,
    [ValidateRange(1, 2147483647)][int]$Pgid
)

$ErrorActionPreference = 'Stop'
$Repo = 'https://github.com/SquareWaveSystems/squarebox.git'
$ReleasesApi = if ($env:SQUAREBOX_RELEASES_API) { $env:SQUAREBOX_RELEASES_API } else { 'https://api.github.com/repos/SquareWaveSystems/squarebox/releases' }
$ReleaseAssets = if ($env:SQUAREBOX_RELEASE_ASSETS) { $env:SQUAREBOX_RELEASE_ASSETS } else { 'https://github.com/SquareWaveSystems/squarebox/releases/download' }
$ManagedLabel = 'io.squarebox.managed'
$IdentityLabel = 'io.squarebox.install-id'
$UserHome = if ($IsWindows -and $env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$LegacyStarshipBlob = 'fddcbf2d0dfd3b37fbfb645332eb89122078c236'
$LegacyLazygitBlob = '12adb4319fd0624448a20cd98d546e84f6f70c19'
$script:RollbackArmed = $true
$script:RollbackInProgress = $false
$script:CheckoutCreated = $false
$script:RuntimeReady = $false
$script:VolumeCreated = $false
$script:ContainerCreated = $false
$script:ImageAliasMutated = $false
$script:PriorImageAliasId = ''
$script:NewImageAliasId = ''
$script:PriorSourceCommit = ''
$script:CandidateName = ''
$script:RollbackName = ''
$script:OldContainerRenamed = $false
$script:CandidatePromoted = $false
$script:StatePublished = $false
$script:ProfileBackups = @()
$script:ManagedBackupDir = ''
$script:ManagedBackups = @()

function Invoke-InstallRollback {
    if (-not $script:RollbackArmed -or $script:RollbackInProgress) { return }
    $script:RollbackInProgress = $true
    $script:RollbackArmed = $false
    try {
        if ($script:RuntimeReady) {
			if ($script:CandidatePromoted) {
				& $Runtime rename $ContainerName $script:CandidateName 2>$null | Out-Null
				if ($LASTEXITCODE -eq 0) { $script:CandidatePromoted = $false }
				else { Write-Warning "Rollback could not rename '$ContainerName' to '$($script:CandidateName)'." }
			}
			if ($script:OldContainerRenamed) {
				& $Runtime rename $script:RollbackName $ContainerName 2>$null | Out-Null
				if ($LASTEXITCODE -eq 0) { $script:OldContainerRenamed = $false }
				else {
					Write-Warning "Rollback could not restore '$($script:RollbackName)' to '$ContainerName'."
					Write-Warning "Recovery: inspect '$($script:CandidateName)' and '$($script:RollbackName)', then restore the rollback Box to '$ContainerName'."
				}
			}
            if ($script:ContainerCreated) {
                & $Runtime container inspect $script:CandidateName 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $owner = (& $Runtime inspect -f '{{ index .Config.Labels "io.squarebox.install-id" }}' $script:CandidateName 2>$null)
                    if ($LASTEXITCODE -eq 0 -and $owner -and $owner.Trim() -ceq $InstallId) {
                        & $Runtime rm -f $script:CandidateName 2>$null | Out-Null
                    }
                }
            }
            if ($script:VolumeCreated) {
                & $Runtime volume inspect $HomeVolume 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $owner = (& $Runtime volume inspect -f '{{ index .Labels "io.squarebox.install-id" }}' $HomeVolume 2>$null)
                    if ($LASTEXITCODE -eq 0 -and $owner -and $owner.Trim() -ceq $InstallId) {
                        & $Runtime volume rm $HomeVolume 2>$null | Out-Null
                    }
                }
            }
            if ($script:ImageAliasMutated) {
                if ($script:PriorImageAliasId) {
                    & $Runtime tag $script:PriorImageAliasId $ImageAlias 2>$null | Out-Null
                } else {
                    $currentId = (& $Runtime image inspect -f '{{.Id}}' $ImageAlias 2>$null)
                    if ($LASTEXITCODE -eq 0 -and (-not $script:NewImageAliasId -or $currentId.Trim() -ceq $script:NewImageAliasId)) {
                        & $Runtime rmi $ImageAlias 2>$null | Out-Null
                    }
                }
            }
        }
    } catch {
        Write-Warning "Install rollback could not clean every runtime resource: $($_.Exception.Message)"
    }
    if (-not $script:StatePublished -and $script:PriorSourceCommit -and -not $script:CheckoutCreated) {
        try {
            & git -C $InstallDir checkout --detach $script:PriorSourceCommit 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git checkout could not restore source $($script:PriorSourceCommit)" }
            & git -C $InstallDir reset --hard $script:PriorSourceCommit 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git reset could not restore source $($script:PriorSourceCommit)" }
        } catch { Write-Warning "Install rollback could not restore source: $($_.Exception.Message)" }
    }
	if (-not $script:StatePublished) {
		try {
			foreach ($profileBackup in $script:ProfileBackups) {
				if ($profileBackup.Existed) { [IO.File]::Copy($profileBackup.Backup, $profileBackup.Path, $true) }
				elseif (Test-Path -LiteralPath $profileBackup.Path) { Remove-Item -Force -LiteralPath $profileBackup.Path }
			}
        } catch { Write-Warning "Install rollback could not restore profiles: $($_.Exception.Message)" }
    }
    if (-not $script:StatePublished -and $script:ManagedBackupDir) {
        try {
            foreach ($backup in $script:ManagedBackups) {
                if ($backup.Existed) {
                    [IO.Directory]::CreateDirectory((Split-Path $backup.Path)) | Out-Null
                    [IO.File]::Copy($backup.Backup, $backup.Path, $true)
                } elseif (Test-Path -LiteralPath $backup.Path -PathType Leaf) {
                    Remove-Item -Force -LiteralPath $backup.Path
                }
            }
        } catch { Write-Warning "Install rollback could not restore managed configuration: $($_.Exception.Message)" }
    }
    foreach ($profileBackup in $script:ProfileBackups) {
        Remove-Item -Force -LiteralPath $profileBackup.Backup -ErrorAction SilentlyContinue
    }
    if ($script:ManagedBackupDir) { Remove-Item -Recurse -Force -LiteralPath $script:ManagedBackupDir -ErrorAction SilentlyContinue }
    if ($StateTemp) { Remove-Item -Force -LiteralPath $StateTemp -ErrorAction SilentlyContinue }
    try {
        if ($script:CheckoutCreated -and $InstallDir -and $StateFile -and -not (Test-Path -LiteralPath $StateFile)) {
            Remove-Item -Recurse -Force -LiteralPath $InstallDir -ErrorAction Stop
        }
    } catch {
        Write-Warning "Install rollback could not remove the incomplete checkout: $($_.Exception.Message)"
    }
}

function Abort([string]$Message) {
    Invoke-InstallRollback
    Write-Host "Error: $Message" -ForegroundColor Red
    exit 1
}
function Invoke-FailureInjection([string]$Boundary) {
    if ($env:SQUAREBOX_FAIL_AT -ceq $Boundary) { throw "Injected lifecycle failure at '$Boundary'." }
}
trap {
    $failure = $_.Exception.Message
    Invoke-InstallRollback
    Write-Host "Error: $failure" -ForegroundColor Red
    exit 1
}
$StateFields = @(
    'FORMAT', 'INSTALL_ID', 'RUNTIME', 'INSTALL_DIR', 'WORKSPACE_DIR', 'GIT_CONFIG_DIR',
    'HOME_VOLUME', 'CONTAINER_NAME', 'IMAGE_ALIAS', 'IMAGE_REPOSITORY', 'IMAGE_REF',
    'IMAGE_ID', 'IMAGE_DIGEST', 'SOURCE_REF', 'SOURCE_COMMIT', 'RELEASE_TAG',
    'REQUESTED_TAG', 'PUID', 'PGID', 'BUILD', 'EDGE', 'SHELL_INIT', 'SHELL_RC',
    'ORIGIN', 'HOME_VOLUME_ADOPTED'
)
function Test-ReleaseTag([string]$Value) {
    return $Value.Length -le 128 -and $Value -cmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$'
}
function Test-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $null -ne $item -and [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Test-StatePath([string]$Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value -match '[\x00-\x1f\x7f]' -or -not [IO.Path]::IsPathFullyQualified($Value)) { return $false }
    $pathTail = if ($IsWindows -and $Value.StartsWith('\\', [StringComparison]::Ordinal)) { $Value.Substring(2) } else { $Value }
    if ($pathTail -match '[\\/]{2,}') { return $false }
    try { $full = [IO.Path]::GetFullPath($Value) } catch { return $false }
    return $Value -ceq $full
}
function Test-SamePath([string]$Left, [string]$Right) {
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals([IO.Path]::GetFullPath($Left), [IO.Path]::GetFullPath($Right), $comparison)
}
function Test-StateId([string]$Value) {
    $parsed = 0L
    return $Value -cmatch '^[0-9]{1,10}$' -and [long]::TryParse($Value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 2147483647
}
function Assert-InstallState([hashtable]$State, [string]$Path, [string]$ExpectedInstallDir) {
    if ($State.FORMAT -ne '1' -or $State.INSTALL_ID -cnotmatch '^[A-Za-z0-9._-]{8,128}$') { Abort "Invalid Install identity: $Path" }
    if ($State.RUNTIME -cnotin @('docker', 'podman')) { Abort "Invalid Install identity: $Path (invalid RUNTIME)" }
    foreach ($name in @('INSTALL_DIR', 'WORKSPACE_DIR', 'GIT_CONFIG_DIR', 'SHELL_INIT', 'SHELL_RC')) {
        if (-not (Test-StatePath $State[$name])) { Abort "Invalid Install identity: $Path (invalid $name path)" }
    }
    if (-not (Test-SamePath $State.INSTALL_DIR $ExpectedInstallDir)) { Abort "Invalid Install identity: $Path (INSTALL_DIR mismatch)" }
    $installRoot = [IO.Path]::GetPathRoot($State.INSTALL_DIR)
    $workspaceRoot = [IO.Path]::GetPathRoot($State.WORKSPACE_DIR)
    if ((Test-SamePath $State.INSTALL_DIR $installRoot) -or (Test-SamePath $State.INSTALL_DIR $UserHome)) {
        Abort "Invalid Install identity: $Path (unsafe INSTALL_DIR)"
    }
    if ((Test-SamePath $State.WORKSPACE_DIR $workspaceRoot) -or (Test-SamePath $State.WORKSPACE_DIR $State.INSTALL_DIR) -or (Test-SamePath $State.WORKSPACE_DIR $UserHome)) {
        Abort "Invalid Install identity: $Path (unsafe WORKSPACE_DIR)"
    }
    if (-not (Test-SamePath $State.GIT_CONFIG_DIR ([IO.Path]::Combine($State.INSTALL_DIR, '.squarebox', 'identity', 'git')))) {
        Abort "Invalid Install identity: $Path (GIT_CONFIG_DIR is outside managed identity state)"
    }
    if (-not (Test-SamePath $State.SHELL_INIT $PROFILE.CurrentUserAllHosts) -or -not (Test-SamePath $State.SHELL_RC $PROFILE.CurrentUserAllHosts)) {
        Abort "Invalid Install identity: $Path (unexpected PowerShell profile path)"
    }
    if ($State.HOME_VOLUME -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' -or
        $State.CONTAINER_NAME -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        Abort "Invalid Install identity: $Path (invalid runtime resource name)"
    }
    if ($State.IMAGE_ALIAS -cnotmatch '^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$' -or
        $State.IMAGE_REPOSITORY -cnotmatch '^[a-z0-9][a-z0-9._/-]*$' -or
        $State.IMAGE_ID -cnotmatch '^(sha256:)?[0-9a-f]{64}$') {
        Abort "Invalid Install identity: $Path (invalid image identity)"
    }
    if ($State.IMAGE_DIGEST -and $State.IMAGE_DIGEST -cnotmatch '^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$') {
        Abort "Invalid Install identity: $Path (invalid IMAGE_DIGEST)"
    }
    if ($State.SOURCE_COMMIT -cnotmatch '^[0-9a-f]{40}$' -or -not (Test-StateId $State.PUID) -or -not (Test-StateId $State.PGID)) {
        Abort "Invalid Install identity: $Path (invalid source or host identity)"
    }
    if ($State.BUILD -notin @('0', '1') -or $State.EDGE -notin @('0', '1') -or $State.HOME_VOLUME_ADOPTED -notin @('0', '1') -or
        ($State.EDGE -eq '1' -and $State.BUILD -ne '1')) {
        Abort "Invalid Install identity: $Path (BUILD, EDGE, and HOME_VOLUME_ADOPTED must be 0 or 1)"
    }
    if ($State.ORIGIN -cne $Repo) { Abort "Invalid Install identity: $Path (noncanonical ORIGIN)" }
    if ($State.EDGE -eq '1') {
        if ($State.RELEASE_TAG -or $State.REQUESTED_TAG -or $State.SOURCE_REF -cne 'refs/remotes/origin/main') {
            Abort "Invalid Install identity: $Path (inconsistent edge source identity)"
        }
    } else {
        if (-not (Test-ReleaseTag $State.RELEASE_TAG) -or $State.SOURCE_REF -cne $State.RELEASE_TAG) {
            Abort "Invalid Install identity: $Path (invalid Release identity)"
        }
        if ($State.REQUESTED_TAG -and $State.REQUESTED_TAG -cne 'latest' -and
            (-not (Test-ReleaseTag $State.REQUESTED_TAG) -or $State.REQUESTED_TAG -cne $State.RELEASE_TAG)) {
            Abort "Invalid Install identity: $Path (invalid REQUESTED_TAG)"
        }
    }
    if ($State.BUILD -eq '1') {
        if ($State.IMAGE_REF -cne $State.IMAGE_ALIAS) { Abort "Invalid Install identity: $Path (built IMAGE_REF must equal IMAGE_ALIAS)" }
    } elseif ($State.RELEASE_TAG -cmatch '^v1\.0\.0(-rc.*)?$') {
        if ($State.IMAGE_REF -cne "$($State.IMAGE_REPOSITORY):$($State.RELEASE_TAG)" -or -not $State.IMAGE_DIGEST -or
            -not $State.IMAGE_DIGEST.StartsWith("$($State.IMAGE_REPOSITORY)@sha256:", [StringComparison]::Ordinal)) {
            Abort "Invalid Install identity: $Path (invalid legacy image identity)"
        }
    } elseif (-not $State.IMAGE_DIGEST -or $State.IMAGE_REF -cne $State.IMAGE_DIGEST -or
        -not $State.IMAGE_REF.StartsWith("$($State.IMAGE_REPOSITORY)@sha256:", [StringComparison]::Ordinal)) {
        Abort "Invalid Install identity: $Path (release image identities do not match)"
    }
}
function Read-InstallState([string]$Path, [string]$ExpectedInstallDir) {
    $state = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $at = $line.IndexOf('=')
        if ($at -lt 1) { Abort "Malformed Install identity: $Path" }
        $key = $line.Substring(0, $at)
        if ($StateFields -cnotcontains $key) { Abort "Unknown Install identity field '$key': $Path" }
        if ($state.ContainsKey($key)) { Abort "Duplicate Install identity field '$key': $Path" }
        $value = $line.Substring($at + 1)
        if ($value -match "[`r`n]") { Abort "Malformed Install identity: $Path" }
        $state.Add($key, $value)
    }
    foreach ($key in $StateFields) {
        if (-not $state.ContainsKey($key)) { Abort "Missing Install identity field '$key': $Path" }
    }
    Assert-InstallState $state $Path $ExpectedInstallDir
    return $state
}
if ($env:SQUAREBOX_LIFECYCLE_FUNCTIONS_ONLY -eq '1') { return }
function Test-Origin([string]$Origin) {
    return @(
        'https://github.com/SquareWaveSystems/squarebox',
        'https://github.com/SquareWaveSystems/squarebox.git',
        'git@github.com:SquareWaveSystems/squarebox.git',
        'ssh://git@github.com/SquareWaveSystems/squarebox.git'
    ) -ccontains $Origin
}
function Get-BoundedJson([string]$Uri, [int]$MaximumBytes) {
    $response = Invoke-WebRequest -Uri $Uri -Headers @{ Accept = 'application/vnd.github+json' } `
        -MaximumRetryCount 3 -RetryIntervalSec 1 -TimeoutSec 30
    $content = [string]$response.Content
    if ([Text.Encoding]::UTF8.GetByteCount($content) -gt $MaximumBytes) {
        throw "HTTP response exceeded the $MaximumBytes-byte lifecycle metadata limit."
    }
    return $content | ConvertFrom-Json
}

# An installed script can find a custom identity without the caller repeating
# the original environment on every rebuild.
if (-not $InstallDir) {
    if ($env:SQUAREBOX_DIR) { $InstallDir = $env:SQUAREBOX_DIR }
    elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot '.squarebox\install-state'))) { $InstallDir = $PSScriptRoot }
    else { $InstallDir = Join-Path $UserHome 'squarebox' }
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$StateFile = Join-Path $InstallDir '.squarebox\install-state'
if ((Test-ReparsePoint (Join-Path $InstallDir '.squarebox')) -or (Test-ReparsePoint $StateFile)) {
    Abort 'Install identity state must not be reached through a reparse point or symlink.'
}
$State = $null
if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
    $State = Read-InstallState $StateFile $InstallDir
}

if (-not $WorkspaceDir) {
    if ($env:SQUAREBOX_WORKSPACE) { $WorkspaceDir = $env:SQUAREBOX_WORKSPACE }
    elseif ($State) { $WorkspaceDir = $State.WORKSPACE_DIR }
    else { $WorkspaceDir = Join-Path $InstallDir 'workspace' }
}
$WorkspaceDir = [IO.Path]::GetFullPath($WorkspaceDir)
$GitConfigDir = if ($State) { $State.GIT_CONFIG_DIR } else { [IO.Path]::Combine($InstallDir, '.squarebox', 'identity', 'git') }
$ImageRepository = if ($ImageRepository) { $ImageRepository } elseif ($env:SQUAREBOX_IMAGE) { $env:SQUAREBOX_IMAGE } elseif ($State) { $State.IMAGE_REPOSITORY } else { 'ghcr.io/squarewavesystems/squarebox' }
$RequestedTag = if ($Tag) { $Tag } elseif ($env:SQUAREBOX_TAG) { $env:SQUAREBOX_TAG } elseif ($State) { $State.REQUESTED_TAG } else { '' }
$HomeVolume = if ($HomeVolume) { $HomeVolume } elseif ($env:SQUAREBOX_HOME_VOLUME) { $env:SQUAREBOX_HOME_VOLUME } elseif ($State) { $State.HOME_VOLUME } else { 'squarebox-home' }
$ContainerName = if ($State) { $State.CONTAINER_NAME } else { 'squarebox' }
$ImageAlias = if ($State) { $State.IMAGE_ALIAS } else { 'squarebox' }
$InstallId = if ($State) { $State.INSTALL_ID } else { [guid]::NewGuid().ToString() }
if ($State -and $HomeVolume -cne $State.HOME_VOLUME) { Abort 'Cannot change the recorded Managed-home name during rebuild; uninstall this identity first.' }
if (-not $PSBoundParameters.ContainsKey('Edge') -and $State -and $State.EDGE -eq '1') { $Edge = $true }
if (-not $PSBoundParameters.ContainsKey('Build') -and $State -and $State.BUILD -eq '1') { $Build = $true }
if ($env:SQUAREBOX_EDGE -eq '1') { $Edge = $true }
if ($env:SQUAREBOX_BUILD -eq '1') { $Build = $true }
if ($Edge) { $Build = $true }
$DefaultPuid = 1000; $DefaultPgid = 1000
if ($IsLinux) {
    $hostUid = [int](& id -u); $hostGid = [int](& id -g)
    if ($hostUid -gt 0) { $DefaultPuid = $hostUid }
    if ($hostGid -gt 0) { $DefaultPgid = $hostGid }
}
$Puid = if ($Puid) { $Puid } elseif ($env:PUID) { [int]$env:PUID } elseif ($State) { [int]$State.PUID } else { $DefaultPuid }
$Pgid = if ($Pgid) { $Pgid } elseif ($env:PGID) { [int]$env:PGID } elseif ($State) { [int]$State.PGID } else { $DefaultPgid }
if ($Puid -lt 1 -or $Pgid -lt 1) { Abort 'PUID and PGID must be positive integers.' }
foreach ($path in @($InstallDir, $WorkspaceDir, $GitConfigDir)) {
    if (-not (Test-StatePath $path)) { Abort "Lifecycle paths must be absolute and normalized (got '$path')." }
}
if ((Test-SamePath $InstallDir ([IO.Path]::GetPathRoot($InstallDir))) -or (Test-SamePath $InstallDir $UserHome)) { Abort "Unsafe install path '$InstallDir'." }
if ((Test-SamePath $WorkspaceDir ([IO.Path]::GetPathRoot($WorkspaceDir))) -or (Test-SamePath $WorkspaceDir $InstallDir) -or (Test-SamePath $WorkspaceDir $UserHome)) {
    Abort "Unsafe Workspace path '$WorkspaceDir'."
}
if (-not (Test-SamePath $GitConfigDir ([IO.Path]::Combine($InstallDir, '.squarebox', 'identity', 'git')))) { Abort 'Private Git identity path escaped managed state.' }
if ($HomeVolume -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' -or $ContainerName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' -or
    $ImageAlias -cnotmatch '^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$' -or
    $ImageRepository -cnotmatch '^[a-z0-9][a-z0-9._/-]*$') { Abort 'Invalid runtime resource or image name.' }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Abort 'Git is not installed.' }
if (Test-Path $InstallDir) {
    if (-not (Test-Path (Join-Path $InstallDir '.git'))) { Abort "$InstallDir exists but is not a Git checkout." }
    $origin = (& git -C $InstallDir remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Origin $origin)) { Abort "Unexpected checkout origin '$origin'; refusing reset." }
    if (-not $State -and -not $Adopt) { Abort 'Existing checkout has no Install identity; verify it, then use -Adopt.' }
    $priorCommit = (& git -C $InstallDir rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $priorCommit -and $priorCommit.Trim() -cmatch '^[0-9a-f]{40}$') {
        $script:PriorSourceCommit = $priorCommit.Trim()
    }
    Write-Host 'Updating managed checkout...'
    & git -C $InstallDir fetch --force origin '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/*:refs/tags/*'
    if ($LASTEXITCODE -ne 0) { Abort 'git fetch failed.' }
} else {
    Write-Host 'Cloning squarebox...'
    $script:CheckoutCreated = $true
    & git clone -- $Repo $InstallDir
    if ($LASTEXITCODE -ne 0) { Abort 'git clone failed.' }
}

$LegacyRelease = $false
$Manifest = $null
if ($Edge) {
    $ReleaseTag = ''
    $SourceRef = 'refs/remotes/origin/main'
    Write-Host 'Using origin/main (edge)...'
    & git -C $InstallDir checkout --detach $SourceRef
    if ($LASTEXITCODE -ne 0) { Abort 'Unable to check out origin/main.' }
    & git -C $InstallDir reset --hard $SourceRef
    if ($LASTEXITCODE -ne 0) { Abort 'Unable to reset the managed checkout to origin/main.' }
} else {
    try {
        $releaseUri = if ($RequestedTag -and $RequestedTag -cne 'latest') {
            if (-not (Test-ReleaseTag $RequestedTag)) { Abort "Invalid release tag '$RequestedTag'." }
            "$ReleasesApi/tags/$RequestedTag"
        } else { "$ReleasesApi/latest" }
        $Release = Get-BoundedJson $releaseUri 1048576
        $ReleaseTag = [string]$Release.tag_name
    } catch { Abort "Unable to resolve a published Release: $($_.Exception.Message)" }
    if (-not (Test-ReleaseTag $ReleaseTag)) { Abort "Invalid published Release tag '$ReleaseTag'." }
    if ($RequestedTag -and $RequestedTag -cne 'latest' -and $ReleaseTag -cne $RequestedTag) {
        Abort 'Published Release metadata returned an unexpected tag.'
    }
    try {
        $Manifest = Get-BoundedJson "$ReleaseAssets/$ReleaseTag/release.json" 65536
    } catch {
        if ($ReleaseTag -cmatch '^v1\.0\.0(-rc.*)?$') {
            Write-Warning "$ReleaseTag predates release.json; using the explicit legacy v1.0 compatibility path."
            $LegacyRelease = $true
        } else { Abort "Published Release $ReleaseTag has no verifiable release.json." }
    }
    if (-not $LegacyRelease) {
        if ($Manifest.schema -ne 1 -or $Manifest.version -cne $ReleaseTag -or $Manifest.source_ref -cne $ReleaseTag -or
            $Manifest.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $Manifest.image_repository -cnotmatch '^[a-z0-9][a-z0-9._/-]*$' -or
            $Manifest.image_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $Manifest.image_ref -cne "$($Manifest.image_repository)@$($Manifest.image_digest)") {
            Abort "release.json for $ReleaseTag failed identity validation."
        }
    }
    $checkoutRef = "refs/tags/$ReleaseTag"
    & git -C $InstallDir rev-parse --verify "$checkoutRef`^{commit}" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Abort "Published Release $ReleaseTag is absent from the trusted origin." }
    Write-Host "Using published Release $ReleaseTag..."
    & git -C $InstallDir checkout --detach $checkoutRef
    if ($LASTEXITCODE -ne 0) { Abort "Unable to check out $ReleaseTag." }
    & git -C $InstallDir reset --hard $checkoutRef
    if ($LASTEXITCODE -ne 0) { Abort "Unable to reset the managed checkout to $ReleaseTag." }
    $SourceRef = if ($Manifest) { [string]$Manifest.source_ref } else { $ReleaseTag }
}
$SourceCommit = (& git -C $InstallDir rev-parse HEAD).Trim()
if ($Manifest -and $SourceCommit -cne $Manifest.source_sha) { Abort 'Checked-out source does not match release.json.' }
Invoke-FailureInjection 'checkout'

if (-not $Runtime) {
    if ($env:SQUAREBOX_RUNTIME) { $Runtime = $env:SQUAREBOX_RUNTIME }
    elseif ($State) { $Runtime = $State.RUNTIME }
}
if ($State -and $Runtime -cne $State.RUNTIME) { Abort 'Cannot move an Install identity between runtimes during rebuild; uninstall this identity first.' }
if ($Runtime -and $Runtime -cnotin @('docker', 'podman')) { Abort "Invalid runtime '$Runtime'." }
if (-not $Runtime) {
    $hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
    $hasPodman = [bool](Get-Command podman -ErrorAction SilentlyContinue)
    if ($hasDocker -and $hasPodman) {
        if ([Console]::IsInputRedirected) { $Runtime = 'docker' }
        else {
            $choice = Read-Host 'Runtime [docker/podman] (docker)'
            $Runtime = if ($choice -eq 'podman') { 'podman' } else { 'docker' }
        }
    } elseif ($hasDocker) { $Runtime = 'docker' }
    elseif ($hasPodman) { $Runtime = 'podman' }
    else { Abort 'Neither Docker nor Podman is installed.' }
}
if (-not (Get-Command $Runtime -ErrorAction SilentlyContinue)) { Abort "Recorded runtime '$Runtime' is not installed." }
& $Runtime info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Abort "$Runtime is installed but unreachable (machine stopped or permission denied)." }
$script:RuntimeReady = $true
$RootlessPodman = $false
if ($Runtime -ceq 'podman') {
    $rootless = (& $Runtime info --format '{{.Host.Security.Rootless}}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $rootless -or $rootless.Trim() -cnotin @('true', 'false')) {
        Abort 'Unable to determine whether Podman is rootless; refusing an ambiguous user mapping.'
    }
    $RootlessPodman = $rootless.Trim() -ceq 'true'
    if ($RootlessPodman -and ($Puid -ne $DefaultPuid -or $Pgid -ne $DefaultPgid)) {
        Abort "Rootless Podman maps the invoking host identity to image user dev; use PUID=$DefaultPuid and PGID=$DefaultPgid, or a rootful runtime for explicit remapping."
    }
}

function Get-ResourceOwner([ValidateSet('container', 'volume')][string]$Kind, [string]$Name) {
    if ($Kind -ceq 'container') {
        $value = (& $Runtime inspect -f '{{ index .Config.Labels "io.squarebox.install-id" }}' $Name 2>$null)
    } else {
        $value = (& $Runtime volume inspect -f '{{ index .Labels "io.squarebox.install-id" }}' $Name 2>$null)
    }
    if ($LASTEXITCODE -ne 0) { Abort "Unable to verify ownership label for $Kind '$Name'." }
    if ($value) { $value = $value.Trim() }
    if ($value -cin @('<no value>', '<nil>')) { return '' }
    return [string]$value
}

# RepoDigests is an unordered collection. Select the exact Candidate reference
# when one is required; element zero is not stable across Docker and Podman.
function Select-ImageRepoDigest([object[]]$RepoDigests, [string]$Expected = '') {
    $valid = @($RepoDigests | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -cmatch '^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$' })
    if ($Expected) {
        return [string]($valid | Where-Object { $_ -ceq $Expected } | Select-Object -First 1)
    }
    return [string]($valid | Select-Object -First 1)
}

$existingAliasId = (& $Runtime image inspect -f '{{.Id}}' $ImageAlias 2>$null)
if ($LASTEXITCODE -eq 0 -and $existingAliasId) {
    $script:PriorImageAliasId = $existingAliasId.Trim()
    if (-not $State -or $existingAliasId.Trim() -cne $State.IMAGE_ID) {
        if (-not $Adopt) { Abort "Image alias '$ImageAlias' is not owned by this Install identity." }
    }
}

if ($Build) {
    $ImageRef = $ImageAlias
    $version = if ($ReleaseTag) { $ReleaseTag } else { $SourceCommit.Substring(0, 12) }
    Write-Host "Building Candidate image from $SourceCommit..."
    & $Runtime build --label "$ManagedLabel=true" --label "$IdentityLabel=$InstallId" --build-arg "SQUAREBOX_VERSION=$version" -t $ImageAlias $InstallDir
    if ($LASTEXITCODE -ne 0) { Abort "$Runtime build failed." }
    $script:ImageAliasMutated = $true
} else {
    if ($Manifest) {
        if ($ImageRepository -cne $Manifest.image_repository) { Abort 'SQUAREBOX_IMAGE differs from release.json.' }
        $ImageRef = [string]$Manifest.image_ref
    } else { $ImageRef = "${ImageRepository}:$ReleaseTag" }
    Write-Host "Pulling Candidate image $ImageRef..."
    & $Runtime pull $ImageRef
    if ($LASTEXITCODE -ne 0) { Abort "$Runtime pull failed." }
    & $Runtime tag $ImageRef $ImageAlias
    if ($LASTEXITCODE -ne 0) { Abort 'Unable to create the managed image alias.' }
    $script:ImageAliasMutated = $true
}
$ImageId = (& $Runtime image inspect -f '{{.Id}}' $ImageAlias).Trim()
if ($LASTEXITCODE -ne 0) { Abort 'Unable to inspect the Candidate image.' }
$script:NewImageAliasId = $ImageId
Invoke-FailureInjection 'image-alias'
$repoDigestOutput = @()
if (-not $Build) {
    $repoDigestOutput = @(& $Runtime image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' $ImageRef 2>$null)
    if ($LASTEXITCODE -ne 0) { $repoDigestOutput = @() }
}
$expectedDigest = ''
if ($Manifest -and -not $Build) {
    $expectedDigest = [string]$Manifest.image_ref
} elseif (-not $Build -and $State -and $State.RELEASE_TAG -ceq $ReleaseTag) {
    $expectedDigest = [string]$State.IMAGE_DIGEST
}
$ImageDigest = Select-ImageRepoDigest $repoDigestOutput $expectedDigest
if ($Manifest -and -not $Build -and $ImageDigest -cne [string]$Manifest.image_ref) {
    Abort 'Pulled image does not expose the exact release.json digest.'
}
if (-not $Build -and -not $Manifest -and -not $ImageDigest) {
    Abort 'Pulled legacy image exposes no acceptable repository digest.'
}
if (-not $Build -and $State -and $State.RELEASE_TAG -ceq $ReleaseTag -and $State.IMAGE_DIGEST -and $State.IMAGE_DIGEST -cne $ImageDigest) {
    Abort "Immutable image identity changed for $ReleaseTag."
}

$HomeVolumeAdopted = if ($State) { $State.HOME_VOLUME_ADOPTED -eq '1' } else { $false }
& $Runtime volume inspect $HomeVolume 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    $owner = Get-ResourceOwner volume $HomeVolume
    if ($owner -cne $InstallId) {
        # Persisted adopted-home authority permits an ordinary rebuild; purge
        # retains its independent -Force requirement in uninstall.ps1.
        if (-not $owner -and ($Adopt -or ($State -and $State.HOME_VOLUME_ADOPTED -eq '1'))) {
            $HomeVolumeAdopted = $true
            if (-not $State -or $State.HOME_VOLUME_ADOPTED -ne '1') {
                Write-Warning "Adopting unlabeled Managed home '$HomeVolume'; purge will require -Force."
            }
        } else { Abort "Volume '$HomeVolume' is not owned by this Install identity." }
    }
} else {
    & $Runtime volume create --label "$ManagedLabel=true" --label "$IdentityLabel=$InstallId" $HomeVolume | Out-Null
    if ($LASTEXITCODE -ne 0) { Abort "Unable to create Managed home '$HomeVolume'." }
    $script:VolumeCreated = $true
    $HomeVolumeAdopted = $false
    Invoke-FailureInjection 'managed-home-create'
}

& $Runtime container inspect $ContainerName 2>$null | Out-Null
$HadContainer = $LASTEXITCODE -eq 0
if ($HadContainer) {
    $owner = Get-ResourceOwner container $ContainerName
    if ($owner -cne $InstallId -and -not (-not $owner -and $Adopt)) { Abort "Box '$ContainerName' is not owned by this Install identity." }
}
$suffix = ($InstallId -replace '[^A-Za-z0-9_.-]', '-').Substring(0, [Math]::Min(12, $InstallId.Length))
$prefix = $ContainerName.Substring(0, [Math]::Min(96, $ContainerName.Length))
$script:CandidateName = "$prefix-candidate-$suffix"
$script:RollbackName = "$prefix-rollback-$suffix"
foreach ($transactionName in @($script:CandidateName, $script:RollbackName)) {
    & $Runtime container inspect $transactionName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Abort "Lifecycle transaction Box '$transactionName' already exists; inspect and remove or rename it before retrying." }
}
$script:ManagedBackupDir = Join-Path ([IO.Path]::GetTempPath()) "squarebox-managed-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($script:ManagedBackupDir) | Out-Null
$managedPaths = @(
    (Join-Path $GitConfigDir 'config'),
    (Join-Path $InstallDir '.config\starship.toml'),
    (Join-Path $InstallDir '.config\lazygit\config.yml'),
    (Join-Path $InstallDir '.squarebox\managed-config\starship.toml.blob'),
    (Join-Path $InstallDir '.squarebox\managed-config\lazygit-config.yml.blob')
)
for ($index = 0; $index -lt $managedPaths.Count; $index++) {
    $path = $managedPaths[$index]
    $existed = Test-Path -LiteralPath $path -PathType Leaf
    $backup = Join-Path $script:ManagedBackupDir ([string]$index)
    if ($existed) { [IO.File]::Copy($path, $backup, $true) }
    $script:ManagedBackups += [pscustomobject]@{ Path = $path; Backup = $backup; Existed = $existed }
}

# Copy only Git identity values into private install state; never mount the
# host's real global configuration or credential helpers.
function Ensure-ManagedDirectory([string]$Path, [string]$Description) {
    if (Test-ReparsePoint $Path) { Abort "$Description must not be a reparse point or symlink: $Path" }
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Container)) {
        Abort "$Description is not a directory: $Path"
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}
function Get-ManagedBlob([string]$Path) {
    $blob = (& git -C $InstallDir hash-object -- $Path 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $blob -or $blob.Trim() -cnotmatch '^[0-9a-f]{40}$') { Abort "Unable to identify managed config: $Path" }
    return $blob.Trim()
}
function Write-CandidateLazygitDefault([string]$CandidateScript, [string]$Destination) {
    if ((Test-ReparsePoint $CandidateScript) -or -not (Test-Path -LiteralPath $CandidateScript -PathType Leaf)) {
        Abort "Candidate installer is not a regular file: $CandidateScript"
    }
    $lines = [IO.File]::ReadAllLines($CandidateScript)
    $begin = @(); $end = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -ceq '# squarebox-lazygit-default-begin') { $begin += $index }
        if ($lines[$index] -ceq '# squarebox-lazygit-default-end') { $end += $index }
    }
    if ($begin.Count -ne 1 -or $end.Count -ne 1 -or $end[0] -le $begin[0] + 1) { Abort 'Candidate installer has no unique lazygit default.' }
    $content = [Collections.Generic.List[string]]::new()
    for ($index = $begin[0] + 1; $index -lt $end[0]; $index++) {
        if (-not $lines[$index].StartsWith('# ', [StringComparison]::Ordinal)) { Abort 'Candidate lazygit default is malformed.' }
        $content.Add($lines[$index].Substring(2))
    }
    [IO.File]::WriteAllText($Destination, ($content -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}
function Write-BlobTracker([string]$Path, [string]$Blob) {
    if (Test-ReparsePoint $Path) { throw "Managed-config tracker must not be a reparse point or symlink: $Path" }
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Managed-config tracker is not a file: $Path" }
    $temp = Join-Path (Split-Path $Path) ".tracker.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temp, "$Blob`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -Force -LiteralPath $temp }
    }
}
function Update-ManagedFile([string]$Source, [string]$Destination, [string]$Tracker, [string[]]$LegacyBlobs = @()) {
    if ((Test-ReparsePoint $Source) -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { Abort "Managed-config source is not a regular file: $Source" }
    if (Test-ReparsePoint $Destination) { Abort "Managed-config destination must not be a reparse point or symlink: $Destination" }
    if ((Test-Path -LiteralPath $Destination) -and -not (Test-Path -LiteralPath $Destination -PathType Leaf)) { Abort "Managed-config destination is not a regular file: $Destination" }
    if (Test-ReparsePoint $Tracker) { Abort "Managed-config tracker must not be a reparse point or symlink: $Tracker" }
    if ((Test-Path -LiteralPath $Tracker) -and -not (Test-Path -LiteralPath $Tracker -PathType Leaf)) { Abort "Managed-config tracker is not a file: $Tracker" }
    $sourceBlob = Get-ManagedBlob $Source
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $currentBlob = Get-ManagedBlob $Destination
        if (Test-Path -LiteralPath $Tracker -PathType Leaf) {
            $trackerLines = [IO.File]::ReadAllLines($Tracker)
            if ($trackerLines.Count -ne 1 -or $trackerLines[0] -cnotmatch '^[0-9a-f]{40}$') { Abort "Invalid managed-config tracker: $Tracker" }
            $recordedBlob = $trackerLines[0]
        } elseif ($LegacyBlobs.Count -gt 0 -and $LegacyBlobs -ccontains $currentBlob) {
            $recordedBlob = $currentBlob
        } else {
            Write-Warning "Preserving untracked user config at $Destination."
            return
        }
        if ($currentBlob -cne $recordedBlob) {
            Write-Warning "Preserving user-modified config at $Destination."
            return
        }
    }
    $temp = Join-Path (Split-Path $Destination) ".squarebox-config.$PID.$([guid]::NewGuid().ToString('N'))"
    $backup = Join-Path (Split-Path $Destination) ".squarebox-config-backup.$PID.$([guid]::NewGuid().ToString('N'))"
    $hadDestination = Test-Path -LiteralPath $Destination -PathType Leaf
    try {
        [IO.File]::Copy($Source, $temp, $true)
        if ($hadDestination) { [IO.File]::Copy($Destination, $backup, $true) }
        [IO.File]::Move($temp, $Destination, $true)
        try {
            Write-BlobTracker $Tracker $sourceBlob
        } catch {
            if ($hadDestination) { [IO.File]::Move($backup, $Destination, $true) }
            elseif (Test-Path -LiteralPath $Destination) { Remove-Item -Force -LiteralPath $Destination }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -Force -LiteralPath $temp }
        if (Test-Path -LiteralPath $backup) { Remove-Item -Force -LiteralPath $backup }
    }
}
$StateDir = Join-Path $InstallDir '.squarebox'
$IdentityDir = Join-Path $StateDir 'identity'
$ManagedConfigDir = Join-Path $StateDir 'managed-config'
$ConfigDir = Join-Path $InstallDir '.config'
$LazygitDir = Join-Path $ConfigDir 'lazygit'
Ensure-ManagedDirectory $StateDir 'Managed state directory'
Ensure-ManagedDirectory $IdentityDir 'Managed identity directory'
Ensure-ManagedDirectory $GitConfigDir 'Managed Git identity directory'
Ensure-ManagedDirectory $ManagedConfigDir 'Managed-config tracker directory'
Ensure-ManagedDirectory $ConfigDir 'Managed config directory'
Ensure-ManagedDirectory $LazygitDir 'Managed lazygit directory'
if (-not $IsWindows) {
    & chmod 700 $StateDir $IdentityDir $GitConfigDir
    if ($LASTEXITCODE -ne 0) { Abort 'Unable to secure private Install-identity directories.' }
}
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { New-Item -ItemType Directory -Path $WorkspaceDir | Out-Null }
$GitConfigFile = Join-Path $GitConfigDir 'config'
if (Test-ReparsePoint $GitConfigFile) { Abort "Managed Git identity must not be a reparse point or symlink: $GitConfigFile" }
$existingName = (& git config --file $GitConfigFile user.name 2>$null)
$existingEmail = (& git config --file $GitConfigFile user.email 2>$null)
$hostName = (& git config --global user.name 2>$null)
$hostEmail = (& git config --global user.email 2>$null)
if ($env:SQUAREBOX_GIT_NAME) { $hostName = $env:SQUAREBOX_GIT_NAME }
if ($env:SQUAREBOX_GIT_EMAIL) { $hostEmail = $env:SQUAREBOX_GIT_EMAIL }
if (-not $hostName) { $hostName = $existingName }
if (-not $hostEmail) { $hostEmail = $existingEmail }
$GitConfigTemp = Join-Path $GitConfigDir ".git-config.$([guid]::NewGuid().ToString('N'))"
try {
    [IO.File]::WriteAllText($GitConfigTemp, '', [Text.UTF8Encoding]::new($false))
    if ($hostName) {
        & git config --file $GitConfigTemp user.name $hostName
        if ($LASTEXITCODE -ne 0) { Abort 'Unable to write the private Git user name.' }
    }
    if ($hostEmail) {
        & git config --file $GitConfigTemp user.email $hostEmail
        if ($LASTEXITCODE -ne 0) { Abort 'Unable to write the private Git email.' }
    }
    if (-not $IsWindows) {
        & chmod 600 $GitConfigTemp
        if ($LASTEXITCODE -ne 0) { Abort 'Unable to secure the private Git identity.' }
    }
    [IO.File]::Move($GitConfigTemp, $GitConfigFile, $true)
} finally {
    if (Test-Path -LiteralPath $GitConfigTemp) { Remove-Item -Force -LiteralPath $GitConfigTemp }
}

$StarshipDest = Join-Path $ConfigDir 'starship.toml'
$PriorStarshipBlobs = @()
if ($State) {
    $priorBlob = (& git -C $InstallDir rev-parse "$($State.SOURCE_COMMIT):starship.toml" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $priorBlob -and $priorBlob.Trim() -cmatch '^[0-9a-f]{40}$') { $PriorStarshipBlobs = @($priorBlob.Trim()) }
} elseif ($Adopt) {
    $PriorStarshipBlobs = @($LegacyStarshipBlob)
}
Update-ManagedFile (Join-Path $InstallDir 'starship.toml') $StarshipDest (Join-Path $ManagedConfigDir 'starship.toml.blob') $PriorStarshipBlobs

$LazygitConfig = Join-Path $LazygitDir 'config.yml'
$LazygitDefault = Join-Path $ManagedConfigDir ".lazygit-default.$PID"
try {
    Write-CandidateLazygitDefault (Join-Path $InstallDir 'install.sh') $LazygitDefault
    # Blob identity of the v1.0 generated default after repository EOL rules.
    $LegacyLazygitBlobs = if ($State -or $Adopt) { @($LegacyLazygitBlob) } else { @() }
    Update-ManagedFile $LazygitDefault $LazygitConfig (Join-Path $ManagedConfigDir 'lazygit-config.yml.blob') $LegacyLazygitBlobs
    Invoke-FailureInjection 'managed-config'
} finally {
    if (Test-Path -LiteralPath $LazygitDefault) { Remove-Item -Force -LiteralPath $LazygitDefault }
}
$BashrcPath = Join-Path $InstallDir 'dotfiles\bashrc'
if (-not (Test-Path -LiteralPath $BashrcPath -PathType Leaf)) { Abort 'Selected source lacks dotfiles/bashrc.' }

$SeedDir = Join-Path $WorkspaceDir '.squarebox'
$SeedSections = [Collections.Generic.List[string]]::new()
$SeededFiles = [Collections.Generic.List[string]]::new()
$script:SeedDirReady = $false
$SelectionStateFiles = @('ai-tool', 'editors', 'editor-default', 'nvim-lazyvim', 'nvim-lazyvim-sha', 'tuis', 'multiplexer', 'sdks', 'shell')
function Initialize-SeedDirectory {
    if (Test-ReparsePoint $SeedDir) { Abort "Selection state directory must not be a reparse point or symlink: $SeedDir" }
    if ((Test-Path -LiteralPath $SeedDir) -and -not (Test-Path -LiteralPath $SeedDir -PathType Container)) {
        Abort "Selection state path is not a directory: $SeedDir"
    }
    if (-not (Test-Path -LiteralPath $SeedDir)) { New-Item -ItemType Directory -Path $SeedDir | Out-Null }
    if ((Test-ReparsePoint $SeedDir) -or -not (Test-Path -LiteralPath $SeedDir -PathType Container)) {
        Abort "Unable to create a safe Selection state directory: $SeedDir"
    }
    foreach ($name in $SelectionStateFiles) {
        $path = Join-Path $SeedDir $name
        if (Test-ReparsePoint $path) { Abort "Selection state file must not be a reparse point or symlink: $path" }
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Abort "Selection state path is not a regular file: $path"
        }
    }
    $script:SeedDirReady = $true
}
function Add-Seed([string]$File, [string]$Value, [string]$Section) {
    if ([string]::IsNullOrEmpty($Value)) { return }
    if (-not $script:SeedDirReady) { Initialize-SeedDirectory }
    $path = Join-Path $SeedDir $File
    if (-not (Test-Path $path)) {
        Set-Content -LiteralPath $path -Value $Value
        $SeededFiles.Add($path)
    }
    $SeedSections.Add($Section)
}
Add-Seed 'ai-tool' $env:SQUAREBOX_AI 'ai'
Add-Seed 'sdks' $env:SQUAREBOX_SDKS 'sdks'
Add-Seed 'editors' $env:SQUAREBOX_EDITORS 'editors'
Add-Seed 'tuis' $env:SQUAREBOX_TUIS 'tuis'
Add-Seed 'multiplexer' $env:SQUAREBOX_MULTIPLEXERS 'multiplexers'

$RuntimeOptions = @(
    '--label', "$ManagedLabel=true", '--label', "$IdentityLabel=$InstallId",
    '--cap-drop=ALL', '--cap-add=CHOWN', '--cap-add=DAC_OVERRIDE', '--cap-add=FOWNER',
    '--cap-add=SETUID', '--cap-add=SETGID', '--cap-add=KILL', '--pids-limit=4096',
    '-e', "PUID=$Puid", '-e', "PGID=$Pgid"
)
$BindSuffix = ''; $ReadOnlyBindSuffix = ':ro'
if ($Runtime -ceq 'podman') {
    $RuntimeOptions += @('--security-opt', 'label=disable')
    if ($RootlessPodman) {
        $RuntimeOptions += '--userns=keep-id:uid=1000,gid=1000'
    }
}
$RuntimeVolumes = @(
    '-v', "${WorkspaceDir}:/workspace$BindSuffix",
    '-v', "${HomeVolume}:/home/dev",
    '-v', "${BashrcPath}:/home/dev/.bashrc$ReadOnlyBindSuffix",
    '-v', "${GitConfigDir}:/home/dev/.config/git$BindSuffix",
    '-v', "${StarshipDest}:/home/dev/.config/starship.toml$BindSuffix",
    '-v', "${LazygitDir}:/home/dev/.config/lazygit$BindSuffix"
)
$SshDir = Join-Path $UserHome '.ssh'
if (Test-Path $SshDir) { $RuntimeVolumes += @('-v', "${SshDir}:/home/dev/.ssh$ReadOnlyBindSuffix") }

Write-Host 'Creating Candidate Box...'
& $Runtime create -it --name $script:CandidateName @RuntimeOptions @RuntimeVolumes $ImageAlias | Out-Null
if ($LASTEXITCODE -ne 0) { Abort "Unable to create Candidate Box '$($script:CandidateName)'." }
$script:ContainerCreated = $true
Invoke-FailureInjection 'candidate-create'

$ProfilePath = $PROFILE.CurrentUserAllHosts
$ShellInit = $ProfilePath
$stateValues = @(
    $InstallDir, $WorkspaceDir, $GitConfigDir, $HomeVolume, $ContainerName,
    $ImageAlias, $ImageRepository, $ImageRef, $ImageId, $ImageDigest,
    $SourceRef, $SourceCommit, $ReleaseTag, $RequestedTag, $ProfilePath
)
if (@($stateValues | Where-Object { $_ -match "[`r`n]" }).Count -gt 0) { Abort 'Install identity values may not contain newlines.' }
$StateDir = Split-Path $StateFile
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$stateLines = @(
    'FORMAT=1', "INSTALL_ID=$InstallId", "RUNTIME=$Runtime", "INSTALL_DIR=$InstallDir",
    "WORKSPACE_DIR=$WorkspaceDir", "GIT_CONFIG_DIR=$GitConfigDir", "HOME_VOLUME=$HomeVolume",
    "CONTAINER_NAME=$ContainerName", "IMAGE_ALIAS=$ImageAlias", "IMAGE_REPOSITORY=$ImageRepository",
    "IMAGE_REF=$ImageRef", "IMAGE_ID=$ImageId", "IMAGE_DIGEST=$ImageDigest",
    "SOURCE_REF=$SourceRef", "SOURCE_COMMIT=$SourceCommit", "RELEASE_TAG=$ReleaseTag",
    "REQUESTED_TAG=$RequestedTag", "PUID=$Puid", "PGID=$Pgid",
    "BUILD=$([int][bool]$Build)", "EDGE=$([int][bool]$Edge)",
    "SHELL_INIT=$ShellInit", "SHELL_RC=$ProfilePath", "ORIGIN=$Repo",
    "HOME_VOLUME_ADOPTED=$([int]$HomeVolumeAdopted)"
)
$StateTemp = Join-Path $StateDir ".install-state.$([guid]::NewGuid().ToString('N'))"
try {
    [IO.File]::WriteAllLines($StateTemp, $stateLines, [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        & chmod 600 $StateTemp
        if ($LASTEXITCODE -ne 0) { Abort 'Unable to secure the Install identity state.' }
    }
    [void](Read-InstallState $StateTemp $InstallDir)
} catch {
    if (Test-Path -LiteralPath $StateTemp) { Remove-Item -Force -LiteralPath $StateTemp }
    throw
}

$ProfileDir = Split-Path $ProfilePath
if (-not (Test-Path $ProfileDir)) { New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null }
function Test-SquareboxProfileBlock([string]$Path) {
    if (Test-ReparsePoint $Path) { Abort "PowerShell profile must not be a reparse point or symlink: $Path" }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Abort "PowerShell profile is not a regular file: $Path" }
    $inside = $false; $blocks = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -ceq '# >>> squarebox >>>') {
            if ($inside -or $blocks -gt 0) { Abort "Malformed squarebox marker block in $Path; the profile was preserved." }
            $inside = $true; $blocks++; continue
        }
        if ($line -ceq '# <<< squarebox <<<') {
            if (-not $inside) { Abort "Malformed squarebox marker block in $Path; the profile was preserved." }
            $inside = $false; continue
        }
    }
    if ($inside) { Abort "Malformed squarebox marker block in $Path; the profile was preserved." }
    return $blocks -eq 1
}
function Remove-SquareboxProfileBlock([string]$Path) {
    if (-not (Test-SquareboxProfileBlock $Path)) { return }
    $filtered = [Collections.Generic.List[string]]::new(); $inside = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -ceq '# >>> squarebox >>>') { $inside = $true; continue }
        if ($line -ceq '# <<< squarebox <<<') { $inside = $false; continue }
        if (-not $inside) { $filtered.Add($line) }
    }
    $temp = Join-Path (Split-Path $Path) ".squarebox-profile.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllLines($temp, $filtered, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -Force -LiteralPath $temp }
    }
}
function Add-SquareboxProfileBlock([string]$Path, [string]$Block) {
    if (Test-ReparsePoint $Path) { Abort "PowerShell profile must not be a reparse point or symlink: $Path" }
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Abort "PowerShell profile is not a regular file: $Path"
    }
    $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { '' }
    if ($existing -and -not ($existing.EndsWith("`n", [StringComparison]::Ordinal))) { $existing += [Environment]::NewLine }
    $temp = Join-Path (Split-Path $Path) ".squarebox-profile.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temp, $existing + $Block.TrimEnd([char[]]"`r`n") + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -Force -LiteralPath $temp }
    }
}
# v1.0 wrote the adapter to the current-host profile. Remove it there before
# installing the portable all-hosts adapter so stale definitions cannot win.
$ProfilePaths = @($ProfilePath, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
foreach ($path in $ProfilePaths) {
    $existed = Test-Path -LiteralPath $path -PathType Leaf
    $backup = Join-Path ([IO.Path]::GetTempPath()) "squarebox-profile-$([guid]::NewGuid().ToString('N'))"
    if ($existed) { [IO.File]::Copy($path, $backup, $true) }
    $script:ProfileBackups += [pscustomobject]@{ Path = $path; Backup = $backup; Existed = $existed }
}
foreach ($path in $ProfilePaths) {
    $hasBlock = Test-SquareboxProfileBlock $path
    if ($hasBlock) {
        if ($hasBlock -and $State -and -not ([IO.File]::ReadAllLines($path) -ccontains "# squarebox-install-id=$InstallId")) {
            Abort "Existing PowerShell adapter '$path' is not owned by this Install identity."
        }
        if ($hasBlock -and -not $State -and -not $Adopt) {
            Abort "Existing PowerShell adapter '$path' has no Install identity; review it, then use -Adopt."
        }
    }
}
foreach ($path in $ProfilePaths) { Remove-SquareboxProfileBlock $path }
$profileBlock = @'
# >>> squarebox >>>
# Managed by squarebox using the recorded Install identity.
# squarebox-install-id=__INSTALL_ID__
function sqrbx {
    if ($args.Count -gt 0 -and $args[0] -eq 'uninstall') {
        $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
        & '__INSTALL__\uninstall.ps1' @rest
        return
    }
    $owner = (& __RUNTIME__ inspect -f '{{ index .Config.Labels "io.squarebox.install-id" }}' '__CONTAINER__' 2>$null)
    if (-not $owner -or $owner.Trim() -cne '__INSTALL_ID__') { throw 'squarebox Install identity mismatch; refusing to start.' }
    $running = (& __RUNTIME__ inspect -f '{{.State.Running}}' '__CONTAINER__' 2>$null)
    if ($running -and $running.Trim() -ceq 'true') { & __RUNTIME__ stop '__CONTAINER__' | Out-Null }
    & __RUNTIME__ start -ai '__CONTAINER__'
    if ($LASTEXITCODE -ne 0) { throw 'squarebox failed to start.' }
}
function squarebox { sqrbx @args }
function sqrbx-rebuild { & '__INSTALL__\install.ps1' @args }
function squarebox-rebuild { sqrbx-rebuild @args }
function sqrbx-uninstall { & '__INSTALL__\uninstall.ps1' @args }
function squarebox-uninstall { sqrbx-uninstall @args }
# <<< squarebox <<<
'@
$profileValues = @{
    INSTALL = $InstallDir.Replace("'", "''")
    RUNTIME = $Runtime
    CONTAINER = $ContainerName
    INSTALL_ID = $InstallId
}
# Regex replacement scans the template once. Sequential String.Replace calls
# would corrupt an otherwise valid path containing text such as __RUNTIME__.
$profileBlock = [regex]::Replace($profileBlock, '__(INSTALL|RUNTIME|CONTAINER|INSTALL_ID)__', {
    param($match)
    return [string]$profileValues[$match.Groups[1].Value]
})
try { [void][scriptblock]::Create($profileBlock) }
catch { Abort "Generated PowerShell profile failed to parse after interpolation: $($_.Exception.Message)" }
Add-SquareboxProfileBlock $ProfilePath $profileBlock
Write-Host "Installed shell integration -> $ProfilePath"
Invoke-FailureInjection 'host-profile'

Write-Host 'Validating Candidate Box...'
& $Runtime start $script:CandidateName | Out-Null
if ($LASTEXITCODE -ne 0) { Abort 'Unable to start the Candidate Box.' }
$candidateRunning = (& $Runtime inspect -f '{{.State.Running}}' $script:CandidateName 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $candidateRunning -or $candidateRunning.Trim() -cne 'true') { Abort 'Candidate Box exited during validation.' }
Invoke-FailureInjection 'candidate-start'

if ($SeedSections.Count -gt 0) {
    Write-Host "Provisioning requested Selection on the Candidate Box ($($SeedSections -join ', '))..."
    & $Runtime exec -u dev -e HOME=/home/dev $script:CandidateName /usr/local/lib/squarebox/setup.sh --rerun @SeedSections
    $provisionExit = $LASTEXITCODE
    if ($provisionExit -ne 0) {
		& $Runtime stop $script:CandidateName 2>$null | Out-Null
        Abort 'Requested provisioning failed; the prior Box remains available.'
    }
    Invoke-FailureInjection 'provision'
}
& $Runtime stop $script:CandidateName | Out-Null
if ($LASTEXITCODE -ne 0) { Abort 'Unable to stop the validated Candidate Box.' }

if ($HadContainer) {
    Write-Host 'Promoting Candidate Box...'
    & $Runtime rename $ContainerName $script:RollbackName
    if ($LASTEXITCODE -ne 0) { Abort 'Unable to preserve the prior Box for rollback.' }
    $script:OldContainerRenamed = $true
    Invoke-FailureInjection 'old-box-preserved'
}
& $Runtime rename $script:CandidateName $ContainerName
if ($LASTEXITCODE -ne 0) { Abort 'Unable to promote the Candidate Box.' }
$script:CandidatePromoted = $true
Invoke-FailureInjection 'candidate-promoted'
Invoke-FailureInjection 'state-publish'
[IO.File]::Move($StateTemp, $StateFile, $true)
$script:StatePublished = $true
$script:RollbackArmed = $false
if ($HadContainer) {
    & $Runtime rm -f $script:RollbackName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Committed successfully; remove stale prior Box with: $Runtime rm -f '$($script:RollbackName)'" }
}
foreach ($profileBackup in $script:ProfileBackups) {
    if (Test-Path -LiteralPath $profileBackup.Backup) { Remove-Item -Force -LiteralPath $profileBackup.Backup }
}
if ($script:ManagedBackupDir -and (Test-Path -LiteralPath $script:ManagedBackupDir)) { Remove-Item -Recurse -Force -LiteralPath $script:ManagedBackupDir }

Write-Host "Install identity recorded at $StateFile"
if ([Console]::IsInputRedirected) {
    Write-Host "Install complete. Start a new PowerShell session, then run 'squarebox'."
} else {
    & $Runtime start -ai $ContainerName
    if ($LASTEXITCODE -ne 0) { Abort 'Managed Box failed to start.' }
}
