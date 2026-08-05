[CmdletBinding()]
param(
    [string]$TargetHome,
    [string]$TargetUser,
    [switch]$DebugMode
)

# Force DebugPreference ONLY if explicitly requested via switch or parameter
if ($DebugMode -or $PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

# ==========================================
# Logger Helper Function
# ==========================================
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogFile = Join-Path $ScriptDir "setup_debug.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue

    switch ($Level) {
        'DEBUG'   { Write-Debug $Message }
        'INFO'    { Write-Host "ℹ️  $Message" -ForegroundColor Cyan }
        'WARN'    { Write-Host "⚠️  $Message" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "❌ $Message" -ForegroundColor Red }
        'SUCCESS' { Write-Host "🎉 $Message" -ForegroundColor Green }
    }
}

Write-Log "--------------------------------------------------" -Level 'DEBUG'
Write-Log "Starting SSH Setup Script Execution" -Level 'DEBUG'

# ==========================================
# 1. Capture the REAL logged-in user context
# ==========================================
if (-not $TargetUser) {
    # Determine the desktop user from CIM console session, fallback to $env:USERNAME
    $ConsoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName -split '\\' | Select-Object -Last 1
    if ($ConsoleUser) {
        $TargetUser = $ConsoleUser
    } else {
        $TargetUser = $env:USERNAME
    }
    Write-Log "Queried active desktop user: $TargetUser" -Level 'DEBUG'
}

if (-not $TargetHome) {
    # Make sure we target the user's home profile, not Administrator's profile during elevation
    if ($env:USERNAME -eq $TargetUser -and $env:USERPROFILE) {
        $TargetHome = $env:USERPROFILE
    } else {
        $TargetHome = "C:\Users\$TargetUser"
    }
    Write-Log "Derived home directory: $TargetHome" -Level 'DEBUG'
}

$ScriptPath = $MyInvocation.MyCommand.Path
if (-not $ScriptPath) { $ScriptPath = $PSCommandPath }
if (-not $ScriptPath) { $ScriptPath = Join-Path $ScriptDir "windows-setup.ps1" }
Write-Log "Executing script from path: $ScriptPath" -Level 'DEBUG'

# ==========================================
# Lock ACL Helper Function
# ==========================================
# OpenSSH on Windows requires access restricted to: Owner/TargetUser, SYSTEM, and Administrators.
# Calling SetAccessRuleProtection($true, $false) strips inherited rules, so we explicitly grant
# Full Control to TargetUser, SYSTEM (S-1-5-18), and Administrators (S-1-5-32-544).
function Lock-LocalSshAcl {
    param(
        [string]$Path,
        [string]$User
    )
    
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $Item) { return }

    try {
        $FullPath = $Item.FullName
        $RightsString = if ($Item.PSIsContainer) { "(OI)(CI)F" } else { "F" }

        # Reset inheritance (/inheritance:r) and grant Full Control strictly to TargetUser, SYSTEM, Administrators
        & icacls.exe "$FullPath" /inheritance:r /grant:r "$User`:$RightsString" "NT AUTHORITY\SYSTEM`:$RightsString" "BUILTIN\Administrators`:$RightsString" | Out-Null
        Write-Log "Locked permissions on: $FullPath for user '$User', SYSTEM, Administrators" -Level 'DEBUG'
    } catch {
        Write-Log "Failed setting ACL on ${Path}: $_" -Level 'WARN'
    }
}

# ==========================================
# 2. Execute setup targeting the REAL user
# ==========================================
$OneDriveSSH = $ScriptDir

$TargetSshDir     = Join-Path $TargetHome ".ssh"
$TargetConfigFile = Join-Path $TargetSshDir "config"
$TargetLocalFile  = Join-Path $TargetSshDir "config_local"
$SourceConfigFile = Join-Path $OneDriveSSH "config"

# 2a. Ensure local .ssh directory exists
if (-not (Test-Path $TargetSshDir)) {
    New-Item -ItemType Directory -Path $TargetSshDir -Force | Out-Null
    Write-Log "Created directory: $TargetSshDir" -Level 'INFO'
}

# 2b. Create local override file if missing
if (-not (Test-Path $TargetLocalFile)) {
    New-Item -ItemType File -Path $TargetLocalFile -Force | Out-Null
    Write-Log "Created empty override file: $TargetLocalFile" -Level 'INFO'
}

# Restrict permissions on folder & local physical override file
Lock-LocalSshAcl -Path $TargetSshDir -User $TargetUser
Lock-LocalSshAcl -Path $TargetLocalFile -User $TargetUser

# Restrict permissions on private key files referenced in config
if (Test-Path $SourceConfigFile) {
    Get-Content $SourceConfigFile | Where-Object { $_ -match '^\s*IdentityFile\s+(.+)$' } | ForEach-Object {
        $RawKeyPath = $matches[1].Trim('"').Trim("'")
        $PathWithHome = $RawKeyPath -replace '^~[/\\]', "$TargetHome\"
        $ExpandedPath = [System.Environment]::ExpandEnvironmentVariables($PathWithHome)
        if (Test-Path $ExpandedPath) {
            Lock-LocalSshAcl -Path $ExpandedPath -User $TargetUser
        }
    }
}

# Restrict permissions on any keys in OneDrive Key folder if present
$OneDriveKeyDir = Join-Path (Split-Path -Parent $OneDriveSSH) "Key"
if (Test-Path $OneDriveKeyDir) {
    Get-ChildItem -Path $OneDriveKeyDir -Recurse -Include "*.key","*.pem","id_*" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Lock-LocalSshAcl -Path $_.FullName -User $TargetUser
    }
}

# 2c. Check existing config / symlink status
$ExistingConfig = Get-Item -LiteralPath $TargetConfigFile -Force -ErrorAction SilentlyContinue

$NeedsSymlink = $true
if ($ExistingConfig) {
    if ($ExistingConfig.LinkType -eq 'SymbolicLink') {
        $CurrentTarget = $ExistingConfig.Target
        if ($CurrentTarget -eq $SourceConfigFile) {
            Write-Log "Symbolic link already points to $SourceConfigFile" -Level 'INFO'
            $NeedsSymlink = $false
        } else {
            Write-Log "Existing symbolic link points to '$CurrentTarget'. Removing old link..." -Level 'INFO'
            Remove-Item -LiteralPath $TargetConfigFile -Force
        }
    } else {
        # Regular physical file: back it up
        $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $BackupName = "$TargetConfigFile.bak_$Timestamp"
        Write-Log "Backing up existing physical config file to: $BackupName" -Level 'INFO'
        Move-Item -LiteralPath $TargetConfigFile -Destination $BackupName -Force
        Lock-LocalSshAcl -Path $BackupName -User $TargetUser
    }
}

# 2d. Create the Symbolic Link (Try non-elevated first, elevate if required)
if ($NeedsSymlink) {
    $SymlinkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $TargetConfigFile -Value $SourceConfigFile -Force -ErrorAction Stop | Out-Null
        Write-Log "Symbolic Link created successfully!" -Level 'SUCCESS'
        $SymlinkCreated = $true
    } catch {
        Write-Log "Non-elevated symbolic link creation failed: $_" -Level 'DEBUG'
    }

    if (-not $SymlinkCreated) {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        $IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        if (-not $IsAdmin) {
            Write-Log "Process lacks Administrator privileges. Required for Symbolic Link creation." -Level 'WARN'
            Write-Log "Initiating UAC Elevation prompt..." -Level 'INFO'

            $PowerShellExe = if ($PSVersionTable.PSEdition -eq 'Core') { "pwsh.exe" } else { "powershell.exe" }
            $ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -TargetHome `"$TargetHome`" -TargetUser `"$TargetUser`""
            if ($DebugPreference -eq 'Continue') {
                $ArgumentList += " -DebugMode"
            }

            Write-Log "Elevation command: $PowerShellExe $ArgumentList" -Level 'DEBUG'

            try {
                Start-Process -FilePath $PowerShellExe -ArgumentList $ArgumentList -Verb RunAs -WorkingDirectory $ScriptDir
                Write-Log "Elevated process spawned successfully. Exiting parent process." -Level 'DEBUG'
                Exit
            } catch {
                Write-Log "Failed to elevate process: $($_.Exception.Message)" -Level 'ERROR'
                exit 1
            }
        } else {
            Write-Log "Failed to create Symbolic Link even as Administrator." -Level 'ERROR'
            exit 1
        }
    }
}

Write-Log "Setup finished successfully! OpenSSH permissions verified." -Level 'SUCCESS'

# ==========================================
# Always Pause Window if Debug mode is active
# ==========================================
if ($DebugPreference -eq 'Continue') {
    Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[DEBUG PAUSE] Script execution paused. Press any key to close..." -ForegroundColor Yellow
    
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        Read-Host "Press Enter to exit..."
    }
}