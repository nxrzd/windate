#requires -RunAsAdministrator

<#
.SYNOPSIS
    Verbose, interactive Windows Update installer.

.DESCRIPTION
    Searches Windows Update and displays:

        Required Updates
        Optional Updates
        Drivers

    Required updates are selected by default.

    Use -Include-Optional to also select optional updates
    and drivers.

    Use -Auto-Reboot to automatically restart Windows when
    a reboot is required by this update operation.

    Existing pending reboots do NOT automatically trigger
    a reboot before searching for updates.

.PARAMETER Include_Optional
    Includes optional updates and driver updates.

.PARAMETER Auto_Reboot
    Automatically restarts Windows when the update operation
    requires a reboot.

.EXAMPLES

    Required updates only:
        .\Windows_Update_2.1.ps1

    Required + optional + drivers:
        .\Windows_Update_2.1.ps1 -Include-Optional

    Required + optional + drivers + automatic reboot:
        .\Windows_Update_2.1.ps1 -Include-Optional -Auto-Reboot

.EXIT CODES

    0     Success
    1     Not Administrator
    2     Windows Update initialization failure
    3     Windows Update search failure
    10    User cancelled
    20    Download operation failure
    21    No selected updates downloaded successfully
    30    Installation operation failure
    40    One or more updates failed or could not be downloaded
    3010  Success, reboot required
#>

[CmdletBinding()]
param(
    [switch]$Include_Optional,

    [switch]$Auto_Reboot
)

$ErrorActionPreference = "Stop"

# ============================================================
# DISPLAY FUNCTIONS
# ============================================================

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] " `
        -NoNewline `
        -ForegroundColor DarkGray

    Write-Host $Message -ForegroundColor Cyan
}

function Write-Info {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "    $Message" -ForegroundColor Gray
}

function Write-Success {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "    $Message" -ForegroundColor Green
}

function Write-WarningMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "    $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "    $Message" -ForegroundColor Red
}

function Write-UpdateEntry {
    param(
        [Parameter(Mandatory)]
        $Update
    )

    $kb = Get-KB $Update
    $size = Get-SizeMB $Update

    Write-Host "  ● " `
        -NoNewline `
        -ForegroundColor Yellow

    if ($kb) {
        Write-Host "$kb " `
            -NoNewline `
            -ForegroundColor Yellow
    }

    Write-Host $Update.Title -ForegroundColor White

    if ($size -gt 0) {
        Write-Host "      Size: $size MB" `
            -ForegroundColor DarkGray
    }
}

# ============================================================
# UPDATE HELPERS
# ============================================================

function Get-KB {
    param(
        [Parameter(Mandatory)]
        $Update
    )

    try {
        if ($null -ne $Update.KBArticleIDs -and
            $Update.KBArticleIDs.Count -gt 0) {

            return "KB$($Update.KBArticleIDs.Item(0))"
        }
    }
    catch {
        # Some updates do not expose KBArticleIDs.
    }

    return ""
}

function Get-SizeMB {
    param(
        [Parameter(Mandatory)]
        $Update
    )

    try {
        if ($Update.MaxDownloadSize -gt 0) {

            return [math]::Round(
                $Update.MaxDownloadSize / 1MB,
                1
            )
        }
    }
    catch {
        # Some updates do not expose download size.
    }

    return 0
}

function Test-DriverUpdate {
    param(
        [Parameter(Mandatory)]
        $Update
    )

    try {
        # Windows Update Agent:
        # 1 = Software
        # 2 = Driver

        return ([int]$Update.Type -eq 2)
    }
    catch {
        return $false
    }
}

function Test-OptionalUpdate {
    param(
        [Parameter(Mandatory)]
        $Update
    )

    # BrowseOnly is the primary WUA indication that an update
    # is not normally offered as an automatic/required update.

    try {
        if ([bool]$Update.BrowseOnly) {
            return $true
        }
    }
    catch {
    }

    return $false
}

function Get-UpdateType {
    param(
        [Parameter(Mandatory)]
        $Update
    )

    # Drivers are classified separately before optional status.

    if (Test-DriverUpdate $Update) {
        return "Driver"
    }

    if (Test-OptionalUpdate $Update) {
        return "Optional"
    }

    return "Required"
}

# ============================================================
# REBOOT DETECTION
# ============================================================

function Test-PendingReboot {

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    foreach ($path in $paths) {

        if (Test-Path $path) {
            return $true
        }
    }

    return $false
}

# ============================================================
# AUTOMATIC REBOOT
# ============================================================

function Start-UpdateReboot {

    Write-Host ""

    Write-WarningMessage `
        "Windows needs to restart to finish applying updates."

    if (-not $Auto_Reboot) {

        Write-WarningMessage `
            "Automatic reboot is disabled."

        Write-WarningMessage `
            "Restart Windows manually when convenient."

        return $false
    }

    Write-Host ""

    for ($seconds = 15; $seconds -gt 0; $seconds--) {

        Write-Host `
            "`r    Restarting in $seconds seconds... " `
            -NoNewline `
            -ForegroundColor Yellow

        Start-Sleep -Seconds 1
    }

    Write-Host ""
    Write-Host ""

    Write-WarningMessage "Restarting computer..."

    Restart-Computer -Force

    return $true
}

# ============================================================
# HEADER
# ============================================================

Clear-Host

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host "                  WINDOWS UPDATE" `
    -ForegroundColor Cyan

Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host ""

Write-Info "Computer : $env:COMPUTERNAME"
Write-Info "Started  : $(Get-Date)"

if ($Include_Optional) {

    Write-Info "Optional : Included"
}
else {

    Write-Info "Optional : Not selected"
}

if ($Auto_Reboot) {

    Write-Info "Reboot   : Automatic when required"
}
else {

    Write-Info "Reboot   : Manual"
}

# ============================================================
# ADMIN CHECK
# ============================================================

Write-Step "Checking administrator privileges..."

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object Security.Principal.WindowsPrincipal(
    $identity
)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {

    Write-Failure `
        "This script must be run as Administrator."

    exit 1
}

Write-Success `
    "Administrator privileges confirmed."

# ============================================================
# EXISTING REBOOT CHECK
# ============================================================

Write-Step "Checking for a pending reboot..."

$existingPendingReboot = Test-PendingReboot

if ($existingPendingReboot) {

    Write-WarningMessage `
        "Windows currently reports a pending reboot."

    Write-WarningMessage `
        "The script will not automatically reboot at this stage."

    if ($Auto_Reboot) {

        Write-Info `
            "Automatic reboot will only occur if the current update operation requires it."
    }
}
else {

    Write-Success "No pending reboot detected."
}

# ============================================================
# WINDOWS UPDATE SESSION
# ============================================================

Write-Step "Connecting to Windows Update..."

try {

    $session = New-Object -ComObject Microsoft.Update.Session

    $session.ClientApplicationID = `
        "PowerShell Windows Updater"

    $searcher = $session.CreateUpdateSearcher()

    $searcher.Online = $true
}
catch {

    Write-Failure `
        "Could not initialize Windows Update."

    Write-Failure $_.Exception.Message

    exit 2
}

Write-Success `
    "Windows Update Agent initialized."

# ============================================================
# SEARCH
# ============================================================

Write-Step "Searching Windows Update..."

Write-Info "Online search: enabled"
Write-Info "Hidden updates: excluded"
Write-Info "Installed updates: excluded"

Write-Host ""

$searchStart = Get-Date

try {

    $searchResult = $searcher.Search(
        "IsInstalled=0 and IsHidden=0"
    )
}
catch {

    Write-Failure `
        "Windows Update search failed."

    Write-Failure $_.Exception.Message

    exit 3
}

$searchSeconds = [math]::Round(
    ((Get-Date) - $searchStart).TotalSeconds,
    1
)

$allUpdates = $searchResult.Updates

Write-Success "Search completed."

Write-Info `
    "Search time: $searchSeconds seconds"

Write-Info `
    "Updates found: $($allUpdates.Count)"

# ============================================================
# CATEGORIZE UPDATES
# ============================================================

Write-Step "Categorizing updates..."

$requiredUpdates = `
    New-Object -ComObject Microsoft.Update.UpdateColl

$optionalUpdates = `
    New-Object -ComObject Microsoft.Update.UpdateColl

$driverUpdates = `
    New-Object -ComObject Microsoft.Update.UpdateColl

foreach ($update in $allUpdates) {

    $type = Get-UpdateType $update

    switch ($type) {

        "Driver" {
            [void]$driverUpdates.Add($update)
        }

        "Optional" {
            [void]$optionalUpdates.Add($update)
        }

        default {
            [void]$requiredUpdates.Add($update)
        }
    }
}

Write-Success "Categorization complete."

# ============================================================
# DISPLAY REQUIRED
# ============================================================

Write-Host ""
Write-Host "WINDOWS UPDATE" -ForegroundColor White

Write-Host "------------------------------------------------------------" `
    -ForegroundColor DarkGray

Write-Host ""
Write-Host "Required Updates" -ForegroundColor Cyan

if ($requiredUpdates.Count -eq 0) {

    Write-Host "  None" -ForegroundColor DarkGray
}
else {

    for (
        $i = 0;
        $i -lt $requiredUpdates.Count;
        $i++
    ) {

        $update = $requiredUpdates.Item($i)

        Write-UpdateEntry $update
    }
}

# ============================================================
# DISPLAY OPTIONAL
# ============================================================

Write-Host ""
Write-Host "Optional Updates" -ForegroundColor Cyan

if ($optionalUpdates.Count -eq 0) {

    Write-Host "  None" -ForegroundColor DarkGray
}
else {

    for (
        $i = 0;
        $i -lt $optionalUpdates.Count;
        $i++
    ) {

        $update = $optionalUpdates.Item($i)

        Write-UpdateEntry $update
    }
}

# ============================================================
# DISPLAY DRIVERS
# ============================================================

Write-Host ""
Write-Host "Drivers" -ForegroundColor Cyan

if ($driverUpdates.Count -eq 0) {

    Write-Host "  None" -ForegroundColor DarkGray
}
else {

    for (
        $i = 0;
        $i -lt $driverUpdates.Count;
        $i++
    ) {

        $update = $driverUpdates.Item($i)

        Write-UpdateEntry $update
    }
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "Available Updates:" -ForegroundColor Cyan

Write-Host "  Required:         $($requiredUpdates.Count)"
Write-Host "  Optional:         $($optionalUpdates.Count)"
Write-Host "  Drivers:          $($driverUpdates.Count)"

# ============================================================
# NOTHING FOUND
# ============================================================

if (
    $requiredUpdates.Count -eq 0 -and
    $optionalUpdates.Count -eq 0 -and
    $driverUpdates.Count -eq 0
) {

    Write-Host ""

    Write-Host `
        "============================================================" `
        -ForegroundColor Green

    Write-Host `
        "                WINDOWS IS UP TO DATE" `
        -ForegroundColor Green

    Write-Host `
        "============================================================" `
        -ForegroundColor Green

    Write-Host ""

    exit 0
}

# ============================================================
# BUILD INSTALLATION LIST
# ============================================================

$updatesToInstall = `
    New-Object -ComObject Microsoft.Update.UpdateColl

# Required updates are always selected.

foreach ($update in $requiredUpdates) {

    [void]$updatesToInstall.Add($update)
}

# Optional updates and drivers require -Include-Optional.

if ($Include_Optional) {

    foreach ($update in $optionalUpdates) {

        [void]$updatesToInstall.Add($update)
    }

    foreach ($update in $driverUpdates) {

        [void]$updatesToInstall.Add($update)
    }
}

Write-Host ""

Write-Host `
    "Selected for installation: $($updatesToInstall.Count)" `
    -ForegroundColor Cyan

if (-not $Include_Optional) {

    Write-Info `
        "Optional updates and drivers are displayed but not selected."

    Write-Info `
        "Use -Include-Optional to install them."
}

# ============================================================
# NOTHING SELECTED
# ============================================================

if ($updatesToInstall.Count -eq 0) {

    Write-Host ""

    Write-WarningMessage `
        "No updates are selected for installation."

    Write-Info `
        "Use -Include-Optional if you want to install optional updates and drivers."

    exit 0
}

# ============================================================
# CONFIRMATION
# ============================================================

Write-Host ""

Write-Host `
    "Install selected updates? [Y/N] " `
    -NoNewline `
    -ForegroundColor Yellow

$answer = Read-Host

if ($answer -notmatch "^[Yy]$") {

    Write-Host ""

    Write-WarningMessage `
        "Installation cancelled by user."

    exit 10
}

# ============================================================
# DOWNLOAD PREPARATION
# ============================================================

Write-Step "Preparing updates..."

$updatesNeedingEula = 0

foreach ($update in $updatesToInstall) {

    try {

        if (-not $update.EulaAccepted) {

            Write-WarningMessage `
                "EULA not yet accepted:"

            Write-Info $update.Title

            Write-Info `
                "Windows Update will handle EULA requirements during installation."

            $updatesNeedingEula++
        }
    }
    catch {
        # Some updates may not expose EulaAccepted.
    }
}

if ($updatesNeedingEula -gt 0) {

    Write-Info `
        "$updatesNeedingEula update(s) report an unaccepted EULA."
}

Write-Success "Updates prepared."

# ============================================================
# DOWNLOAD
# ============================================================

Write-Step "Downloading updates..."

Write-Info `
    "Updates selected: $($updatesToInstall.Count)"

Write-Info `
    "Windows Update is downloading the required files."

$downloader = $session.CreateUpdateDownloader()

$downloader.Updates = $updatesToInstall

$downloadStart = Get-Date

try {

    $downloadResult = $downloader.Download()
}
catch {

    Write-Failure `
        "Download operation failed."

    Write-Failure $_.Exception.Message

    exit 20
}

$downloadSeconds = [math]::Round(
    ((Get-Date) - $downloadStart).TotalSeconds,
    1
)

Write-Success `
    "Download operation completed."

Write-Info `
    "Download time: $downloadSeconds seconds"

Write-Info `
    "Result code: $($downloadResult.ResultCode)"

# ============================================================
# CHECK DOWNLOADS
# ============================================================

Write-Step "Checking downloaded updates..."

$installCollection = `
    New-Object -ComObject Microsoft.Update.UpdateColl

$downloadFailures = 0

foreach ($update in $updatesToInstall) {

    if ($update.IsDownloaded) {

        [void]$installCollection.Add($update)

        Write-Success `
            "Ready: $($update.Title)"
    }
    else {

        Write-Failure `
            "Download failed: $($update.Title)"

        $downloadFailures++
    }
}

Write-Host ""

Write-Info `
    "Ready to install: $($installCollection.Count)"

Write-Info `
    "Download failures: $downloadFailures"

if ($installCollection.Count -eq 0) {

    Write-Failure `
        "No selected updates were successfully downloaded."

    exit 21
}

# ============================================================
# INSTALLATION SETUP
# ============================================================

Write-Step `
    "Checking installation requirements..."

$installer = $session.CreateUpdateInstaller()

$installer.Updates = $installCollection

try {

    if ($installer.RebootRequiredBeforeInstallation) {

        Write-WarningMessage `
            "Windows requires a reboot before installation."

        if ($Auto_Reboot) {

            Write-WarningMessage `
                "Automatic reboot is enabled."

            Write-WarningMessage `
                "Restarting now..."

            Restart-Computer -Force

            exit 3010
        }

        Write-Failure `
            "Installation cannot continue until Windows is restarted."

        Write-WarningMessage `
            "Restart Windows and run this script again."

        exit 3010
    }
}
catch {

    Write-WarningMessage `
        "Could not determine pre-install reboot state."

    Write-WarningMessage `
        "Continuing with installation."
}

# ============================================================
# INSTALL
# ============================================================

Write-Step "Installing Windows Updates..."

Write-Info `
    "Updates to install: $($installCollection.Count)"

Write-Info `
    "This may take several minutes."

$installStart = Get-Date

try {

    $installResult = $installer.Install()
}
catch {

    Write-Failure `
        "Windows Update installation failed."

    Write-Failure $_.Exception.Message

    exit 30
}

$installSeconds = [math]::Round(
    ((Get-Date) - $installStart).TotalSeconds,
    1
)

# ============================================================
# INDIVIDUAL RESULTS
# ============================================================

Write-Step "Installation Results"

$installedSuccessfully = 0
$installedWithErrors = 0
$failed = 0
$unknown = 0

for (
    $i = 0;
    $i -lt $installCollection.Count;
    $i++
) {

    $update = $installCollection.Item($i)

    $result = $installResult.GetUpdateResult($i)

    Write-Host ""

    Write-Host `
        "  [$($i + 1)/$($installCollection.Count)]" `
        -ForegroundColor Yellow

    Write-Host `
        "  $($update.Title)" `
        -ForegroundColor White

    Write-Info `
        "Result code: $($result.ResultCode)"

    Write-Info `
        "HRESULT:     $($result.HResult)"

    switch ([int]$result.ResultCode) {

        # 2 = Succeeded
        2 {

            Write-Success `
                "Installed successfully."

            $installedSuccessfully++
        }

        # 3 = Succeeded with errors
        3 {

            Write-WarningMessage `
                "Installed with errors."

            $installedWithErrors++
        }

        # 4 = Failed
        4 {

            Write-Failure `
                "Installation failed."

            $failed++
        }

        # 5 = Aborted
        5 {

            Write-Failure `
                "Installation aborted."

            $failed++
        }

        default {

            Write-WarningMessage `
                "Unknown installation result."

            $unknown++
        }
    }
}

# ============================================================
# REBOOT STATUS
# ============================================================

Write-Step "Checking final reboot status..."

$rebootRequired = $false

try {

    $rebootRequired = `
        [bool]$installResult.RebootRequired
}
catch {

    $rebootRequired = Test-PendingReboot
}

# Check system state as a fallback.

if (-not $rebootRequired) {

    $rebootRequired = Test-PendingReboot
}

# ============================================================
# FINAL SUMMARY
# ============================================================

Write-Host ""

Write-Host `
    "============================================================" `
    -ForegroundColor Cyan

Write-Host `
    "                    UPDATE SUMMARY" `
    -ForegroundColor Cyan

Write-Host `
    "============================================================" `
    -ForegroundColor Cyan

Write-Host ""

Write-Info `
    "Installation time     : $installSeconds seconds"

Write-Info `
    "Installed successfully: $installedSuccessfully"

Write-Info `
    "Installed with errors : $installedWithErrors"

Write-Info `
    "Failed                : $failed"

Write-Info `
    "Unknown               : $unknown"

Write-Info `
    "Download failures     : $downloadFailures"

if ($existingPendingReboot) {

    Write-Host ""

    Write-WarningMessage `
        "A reboot was already pending before this script ran."
}

if ($rebootRequired) {

    Write-Host ""

    Write-Host `
        "    *** REBOOT REQUIRED ***" `
        -ForegroundColor Yellow

    Write-WarningMessage `
        "Windows must restart to finish applying updates."
}
else {

    Write-Host ""

    Write-Success `
        "No reboot is required."
}

# ============================================================
# FAILURE HANDLING
# ============================================================

if (
    $failed -gt 0 -or
    $downloadFailures -gt 0 -or
    $unknown -gt 0
) {

    Write-Host ""

    Write-Failure `
        "Windows Update completed with errors."

    if ($installedWithErrors -gt 0) {

        Write-WarningMessage `
            "$installedWithErrors update(s) installed with errors."
    }

    if ($rebootRequired -and $Auto_Reboot) {

        Start-UpdateReboot | Out-Null
    }

    exit 40
}

# ============================================================
# INSTALLATION-WITH-ERRORS HANDLING
# ============================================================

if ($installedWithErrors -gt 0) {

    Write-Host ""

    Write-WarningMessage `
        "All selected updates completed, but one or more reported errors."

    if ($rebootRequired) {

        if ($Auto_Reboot) {

            Start-UpdateReboot | Out-Null

            exit 3010
        }

        Write-WarningMessage `
            "Automatic reboot is disabled."

        Write-WarningMessage `
            "Restart Windows manually when convenient."

        exit 3010
    }

    exit 40
}

# ============================================================
# REBOOT HANDLING
# ============================================================

if ($rebootRequired) {

    if ($Auto_Reboot) {

        Start-UpdateReboot | Out-Null

        exit 3010
    }

    Write-Host ""

    Write-WarningMessage `
        "Automatic reboot is disabled."

    Write-WarningMessage `
        "Restart Windows manually when convenient."

    exit 3010
}

# ============================================================
# SUCCESS
# ============================================================

Write-Host ""

Write-Host `
    "============================================================" `
    -ForegroundColor Green

Write-Host `
    "              WINDOWS UPDATE COMPLETE" `
    -ForegroundColor Green

Write-Host `
    "============================================================" `
    -ForegroundColor Green

Write-Host ""

Write-Success `
    "All selected updates completed successfully."

exit 0
