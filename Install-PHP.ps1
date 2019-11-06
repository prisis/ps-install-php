Param(
  [string]$Version,
  [switch]$Highest,
  [switch]$Lowest,
  [switch]$ThreadSafe,
  [string]$Arch = "x86",
  [string]$InstallPath = "C:\tools\php",
  [switch]$Debug,
  [array]$Extensions
)
if ($Debug) {
    Write-Output $PSVersionTable
}

Add-Type -assembly "System.IO.Compression.FileSystem"

$Arch = $Arch.ToUpper()
$ArchVersions = "X86", "X64"

if (!$ArchVersions.Contains($Arch)) {
    throw "The arch value must be x86 or x64. Got: $Arch"
}
if ($Highest -and $Lowest) {
    throw "You cannot specify both the highest and lowest version"
}
if (!$Version -and ($Highest -or $Lowest)) {
    throw "If you don't specify a version you cannot specify high or low. The most current is assumed."
}

if ($Version) {
    $Version = New-Object -TypeName System.Version($Version)

    if (($Highest -or $Lowest) -and $Version.Build -ne $null) {
       throw "To Select the highest or lowest version you must not specify an exact version." 
    }

    if (!($Highest -or $Lowest) -and [int]$Version.Build -eq $null) {
       throw "If you don't select the highest or lowest version, you must specify an exact version." 
    }
}

$VC = @{
    "VC14_X86" = "https://download.microsoft.com/download/9/3/F/93FCF1E7-E6A4-478B-96E7-D4B285925B00/vc_redist.x86.exe"
    "VC14_X64" = "https://download.microsoft.com/download/9/3/F/93FCF1E7-E6A4-478B-96E7-D4B285925B00/vc_redist.x64.exe"
    "VC15_X86" = "https://download.microsoft.com/download/6/A/A/6AA4EDFF-645B-48C5-81CC-ED5963AEAD48/vc_redist.x86.exe"
    "VC15_X64" = "https://download.microsoft.com/download/6/A/A/6AA4EDFF-645B-48C5-81CC-ED5963AEAD48/vc_redist.x64.exe"
}

Write-Output "Checking for downloadable PHP versions..."

$AllVersions = @()
foreach ($url in @("https://windows.php.net/downloads/releases/", "https://windows.php.net/downloads/releases/archives/", "https://windows.php.net/downloads/qa/")) {
    if ($Debug) {
        Write-Output "Searching in $url";
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $Page = Invoke-WebRequest -URI $url -Method GET -TimeoutSec 5

    $Page.Links | Where-Object { $_.innerText -match "^php-((\d{1,}\.\d{1,}\.\d{1,})|(\d{1,}\.\d{1,}\.\d{1,})([A-Z]+[0-9]+))-(nts-)?.*(VC\d\d?)-(x\d\d).zip" } | ForEach-Object {
        $php = @{}
        
        $absoluteUri = [Uri]::new([Uri]$url, $_.href).AbsoluteUri

        if ($Debug) {
            Write-Output "Found php $absoluteUri";
        }

        $php['version'] = New-Object -TypeName System.Version($Matches[3])
        $php['vc'] = ($Matches[6] + '_' + $Matches[7]).ToUpper()
        $php['arch'] = $Matches[7].ToUpper()
        $php['url'] = $absoluteUri
        $php['ts'] = ![bool]$Matches[5]

        $AllVersions += $php
    }
}

$Filtered = $AllVersions | Where-Object { [string]$_.ts -eq $ThreadSafe -and $_.arch -eq $Arch }
if ($Version -and $Highest) {
    $ToInstall = $Filtered | Where-Object { [string]$_.version -match [string]$Version } | Sort-Object -Descending { $_.version } | Select-Object -First 1
} elseif ($Version -and $Lowest) {
    $ToInstall = $Filtered | Where-Object { [string]$_.version -match [string]$Version } | Sort-Object { $_.version } | Select-Object -First 1
} elseif ($Version) {
    $ToInstall = $Filtered | Where-Object { [string]$_.version -eq [string]$Version } | Select-Object -First 1
} else {
    $ToInstall = $Filtered | Sort-Object -Descending { $_.version } | Select-Object -First 1
}

if (!$ToInstall) {
    throw "Unable to find an installable version of $Arch PHP $Version, check that the version specified is correct."
}

$PhpZipFileName = [Uri]::new([Uri]$ToInstall.url).Segments[-1]
$DownloadFilePath = ($InstallPath + '\' + $PhpZipFileName)

$VcFileName = [Uri]::new([Uri]$VC[$ToInstall.vc]).Segments[-1]
$VcDownloadFilePath = ($InstallPath + '\' + $VcFileName)

New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

Write-Output ("Downloading PHP " + $ToInstall.version + " $Arch...")
try {
    Invoke-WebRequest $ToInstall.url -OutFile $DownloadFilePath -ErrorAction Stop
} catch {
    throw ("Unable to download PHP from: " + $ToInstall.url)
}

Write-Output ("Downloading " + $ToInstall.vc + " redistributable...")
try {
    Invoke-WebRequest $VC[$ToInstall.vc] -OutFile $VcDownloadFilePath -ErrorAction Stop
} catch {
    throw ("Unable to download " + $ToInstall.vc + "  from: " + $VC[$ToInstall.vc])
}

Write-Output ("Installing " + $ToInstall.vc + " redistributable...")

$process = (Start-Process -FilePath $VcDownloadFilePath -ArgumentList "/q /norestart")

if ($process.ExitCode) {
  Write-Output "Errorcode: " $process.ExitCode
}

if (-not $?) {
    throw ("Unable to install " + $ToInstall.vc)
}
Remove-Item $VcDownloadFilePath -Force -ErrorAction SilentlyContinue | Out-Null

Write-Output ("Extracting PHP " + $ToInstall.version + " $Arch to: " + $InstallPath)
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($DownloadFilePath, $InstallPath)
} catch {
    $ErrorMessage = $_.Exception.Message

    throw "Unable to extract PHP from ZIP with the error message " + $ErrorMessage
}

Remove-Item $DownloadFilePath -Force -ErrorAction SilentlyContinue | Out-Null

Rename-Item "$InstallPath\php.ini-development" -NewName "php.ini" -ErrorAction Stop
$PhpIni = "$InstallPath\php.ini"

'date.timezone="UTC"' | Out-File $PhpIni -Append -Encoding utf8
'extension_dir=ext' | Out-File $PhpIni -Append -Encoding utf8

foreach ($extension in $Extensions) {
    if ($ToInstall.version -ge "7.2.0") {
        "extension=php_$extension" | Out-File $PhpIni -Append -Encoding utf8
    } else {
        "extension=php_$extension.dll" | Out-File $PhpIni -Append -Encoding utf8
    }
}

try {
    $Reg = "Registry::HKLM\System\CurrentControlSet\Control\Session Manager\Environment"
    $OldPath = (Get-ItemProperty -Path $Reg -Name PATH).Path

    if (($OldPath -split ';') -notcontains $InstallPath){
        Set-ItemProperty -Path $Reg -Name PATH –Value ($OldPath + ’;’ + $InstallPath)
    }
} catch {
    Write-Warning "Unable to add PHP to path. You may have to add it manually: $InstallPath"
}
