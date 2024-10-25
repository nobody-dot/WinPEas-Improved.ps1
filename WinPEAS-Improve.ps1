<#
.SYNOPSIS
  PowerShell adaptation of WinPEAS.exe / WinPeas.bat
.DESCRIPTION
  For the legal enumeration of Windows-based computers that you either own or are approved to run this script on
.EXAMPLE
  # Default - normal operation with username/password audit in drives/registry
  .\winPeas.ps1

  # Include Excel files in search: .xls, .xlsx, .xlsm
  .\winPeas.ps1 -Excel

  # Full audit - normal operation with APIs / Keys / Tokens
  ## This will produce false positives ##
  .\winPeas.ps1 -FullCheck

  # Add Time stamps to each command
  .\winPeas.ps1 -TimeStamp

.NOTES
  Version:                    1.4
  PEASS-ng Original Author:    PEASS-ng
  winPEAS.ps1 Author:          @RandolphConley
  Improvements By:             [Your Name]
  Creation Date:               10/4/2022
  Last Updated:                [Today's Date]
  Website:                     https://github.com/peass-ng/PEASS-ng

  TESTED: PowerShell 5, 7
  UNTESTED: PowerShell 3, 4
  NOT FULLY COMPATIBLE: PowerShell 2 or lower
#>

######################## FUNCTIONS ########################

[CmdletBinding()]
param (
    [switch]$TimeStamp,
    [switch]$FullCheck,
    [switch]$Excel
)

# Function to gather KB from all patches installed
function Get-HotFixID {
    param (
        [string]$Title
    )
    # Match on KB or if patch does not have a KB, return end result
    if ($Title -match 'KB(\d{4,6})') {
        return $Matches[0]
    } else {
        return $Title
    }
}

function Start-ACLCheck {
    param (
        [string]$Target,
        [string]$ServiceName
    )
    # Gather ACL of object
    if (-not [string]::IsNullOrEmpty($Target) -and (Test-Path $Target)) {
        try {
            $ACLObject = Get-Acl $Target -ErrorAction Stop
        } catch {
            return
        }

        # If Found, Evaluate Permissions
        if ($ACLObject) {
            $Identity = @("$env:COMPUTERNAME\$env:USERNAME")
            $WhoAmI = whoami.exe /groups /fo csv | Select-Object -Skip 2 | ConvertFrom-Csv -Header 'GroupName' | Select-Object -ExpandProperty 'GroupName'
            $Identity += $WhoAmI
            $IdentityFound = $false

            foreach ($id in $Identity) {
                $Permissions = $ACLObject.Access | Where-Object { $_.IdentityReference -like $id }
                foreach ($Permission in $Permissions) {
                    $UserPermission = ""
                    if ($Permission.FileSystemRights -match 'FullControl|Write|Modify' -or $Permission.RegistryRights -eq 'FullControl') {
                        $UserPermission = $Permission.FileSystemRights
                        $IdentityFound = $true
                        if ($ServiceName) {
                            Write-Host "$ServiceName found with permissions issue:" -ForegroundColor Red
                        }
                        Write-Host -ForegroundColor Red "Identity $($Permission.IdentityReference) has '$UserPermission' perms for $Target"
                    }
                }
            }

            # Recursive check if Identity not found
            if (-not $IdentityFound -and ($Target -ne (Split-Path $Target -Parent))) {
                Start-ACLCheck -Target (Split-Path $Target -Parent) -ServiceName $ServiceName
            }
        }
    }
}

function UnquotedServicePathCheck {
    Write-Host "Fetching the list of services, this may take a while..."
    $services = Get-CimInstance -ClassName Win32_Service | Where-Object {
        $_.PathName -notmatch '"' -and
        $_.PathName -notmatch ':\Windows\' -and
        ($_.StartMode -eq "Auto" -or $_.StartMode -eq "Manual") -and
        ($_.State -eq "Running" -or $_.State -eq "Stopped")
    }

    if ($services.Count -lt 1) {
        Write-Host "No unquoted service paths were found"
    } else {
        foreach ($service in $services) {
            Write-Host "Unquoted Service Path found!" -ForegroundColor Red
            Write-Host "Name: $($service.Name)"
            Write-Host "PathName: $($service.PathName)"
            Write-Host "StartName: $($service.StartName)"
            Write-Host "StartMode: $($service.StartMode)"
            Write-Host "Running: $($service.State)"
        }
    }
}

function TimeElapsed {
    Write-Host "Time Running: $($stopwatch.Elapsed.Minutes):$($stopwatch.Elapsed.Seconds)"
}

function Get-ClipBoardText {
    try {
        Add-Type -AssemblyName PresentationCore
        $text = [Windows.Clipboard]::GetText()
        if ($text) {
            Write-Host ""
            if ($TimeStamp) { TimeElapsed }
            Write-Host -ForegroundColor Blue "=========|| Clipboard text found:"
            Write-Host $text
        }
    } catch {
        Write-Host "Failed to access clipboard" -ForegroundColor Yellow
    }
}

function Search-Excel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$SearchText
    )
    $Excel = New-Object -ComObject Excel.Application
    $Workbook = $Excel.Workbooks.Open($Source)
    try {
        foreach ($Worksheet in $Workbook.Sheets) {
            $Found = $Worksheet.Cells.Find($SearchText)
            if ($Found) {
                $BeginAddress = $Found.Address($false, $false)
                do {
                    Write-Host "Pattern: '$SearchText' found in $Source" -ForegroundColor Blue
                    [PSCustomObject]@{
                        WorkSheet = $Worksheet.Name
                        Column    = $Found.Column
                        Row       = $Found.Row
                        TextMatch = $Found.Text
                        Address   = $Found.Address($false, $false)
                    }
                    $Found = $Worksheet.Cells.FindNext($Found)
                } while ($Found -and $Found.Address($false, $false) -ne $BeginAddress)
            }
        }
    } finally {
        $Workbook.Close($false)
        $Excel.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Excel) | Out-Null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Write-Color {
    param (
        [String[]]$Text,
        [ConsoleColor[]]$Color
    )
    for ($i = 0; $i -lt $Text.Length; $i++) {
        Write-Host $Text[$i] -ForegroundColor $Color[$i] -NoNewline
    }
    Write-Host
}

######################## VARIABLES ########################

# Regular expression patterns for sensitive data
$regexSearch = @{}

if ($FullCheck) {
    $Excel = $true
}

# Drives to search
$Drives = Get-PSDrive -PSProvider FileSystem

# File extensions to search
$fileExtensions = @("*.xml", "*.txt", "*.conf", "*.config", "*.cfg", "*.ini", "*.y*ml", "*.log", "*.bak")

if ($Excel) {
    $fileExtensions += @("*.xls", "*.xlsx", "*.xlsm")
}

######################## INTRODUCTION ########################

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ($FullCheck) {
    Write-Host "**Full Check Enabled. This will significantly increase false positives in registry/folder checks for usernames/passwords.**"
}

######################## SYSTEM INFORMATION ########################

Write-Host ""
if ($TimeStamp) { TimeElapsed }
Write-Host "====================================|| SYSTEM INFORMATION ||===================================="
Write-Host "The following information is curated. To get a full list of system information, run the cmdlet Get-ComputerInfo"

# System Info
systeminfo.exe

# Hotfixes installed
Write-Host ""
if ($TimeStamp) { TimeElapsed }
Write-Host -ForegroundColor Blue "=========|| WINDOWS HOTFIXES"
Write-Host "=| Check if Windows is vulnerable with Watson https://github.com/rasta-mouse/Watson" -ForegroundColor Yellow
$Hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending
$Hotfixes | Format-Table -AutoSize

######################## SUMMARY ########################

Write-Host ""
if ($TimeStamp) { TimeElapsed }
$stopwatch.Stop()
Write-Host "Script execution completed in $($stopwatch.Elapsed.ToString())"
