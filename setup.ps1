$ErrorActionPreference = "Stop"

# Needed by older Windows PowerShell versions for HTTPS.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallRoot = Join-Path $env:LOCALAPPDATA "DevTools"
$W64Root     = Join-Path $InstallRoot "w64devkit"
$VSCodeRoot  = Join-Path $InstallRoot "VSCode"

$TempRoot = Join-Path $env:TEMP "cpp-dev-setup"

Write-Host "Installing development environment to:"
Write-Host "  $InstallRoot"
Write-Host ""

# ---------------------------------------------------------------------------
# Check architecture
# ---------------------------------------------------------------------------

$isX64 =
    $env:PROCESSOR_ARCHITECTURE -eq "AMD64" -or
    $env:PROCESSOR_ARCHITEW6432 -eq "AMD64"

if (-not $isX64) {
    throw "This script currently expects 64-bit x86 Windows."
}

# ---------------------------------------------------------------------------
# Prepare directories
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

if (Test-Path $TempRoot) {
    Remove-Item $TempRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

# ---------------------------------------------------------------------------
# Download latest w64devkit
# ---------------------------------------------------------------------------

Write-Host "[1/6] Finding latest w64devkit release..."

$headers = @{
    "User-Agent" = "cpp-dev-setup"
}

$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/skeeto/w64devkit/releases/latest" `
    -Headers $headers

$asset = $release.assets |
    Where-Object {
        $_.name -match '^w64devkit-x64-.*\.7z\.exe$'
    } |
    Select-Object -First 1

if (-not $asset) {
    throw "Could not find the x64 w64devkit archive in the latest release."
}

Write-Host "      Version: $($release.tag_name)"

$W64Archive = Join-Path $TempRoot $asset.name

Write-Host "[2/6] Downloading w64devkit..."

Invoke-WebRequest `
    -Uri $asset.browser_download_url `
    -OutFile $W64Archive

# ---------------------------------------------------------------------------
# Extract w64devkit
# ---------------------------------------------------------------------------

Write-Host "[3/6] Extracting w64devkit..."

$W64Extract = Join-Path $TempRoot "w64devkit-extract"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $W64Extract |
    Out-Null

# w64devkit is distributed as a self-extracting 7-Zip archive.
$extractArgument = '-o"{0}"' -f $W64Extract

$process = Start-Process `
    -FilePath $W64Archive `
    -ArgumentList "-y", $extractArgument `
    -Wait `
    -PassThru

if ($process.ExitCode -ne 0) {
    throw "w64devkit extraction failed with exit code $($process.ExitCode)."
}

# Find g++.exe rather than depending on the exact archive directory layout.
$gpp = Get-ChildItem `
    -Path $W64Extract `
    -Filter "g++.exe" `
    -Recurse `
    -File |
    Where-Object {
        $_.Directory.Name -eq "bin"
    } |
    Select-Object -First 1

if (-not $gpp) {
    throw "Extraction completed, but g++.exe could not be found."
}

$extractedW64Root = Split-Path $gpp.Directory.FullName -Parent

if (Test-Path $W64Root) {
    Remove-Item $W64Root -Recurse -Force
}

Move-Item $extractedW64Root $W64Root

$W64Bin = Join-Path $W64Root "bin"

# ---------------------------------------------------------------------------
# Download VS Code ZIP
# ---------------------------------------------------------------------------

Write-Host "[4/6] Downloading latest Visual Studio Code..."

$VSCodeZip = Join-Path $TempRoot "vscode.zip"

Invoke-WebRequest `
    -Uri "https://update.code.visualstudio.com/latest/win32-x64-archive/stable" `
    -OutFile $VSCodeZip

# ---------------------------------------------------------------------------
# Extract VS Code
# ---------------------------------------------------------------------------

Write-Host "[5/6] Installing Visual Studio Code..."

if (Test-Path $VSCodeRoot) {
    Remove-Item $VSCodeRoot -Recurse -Force
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $VSCodeRoot |
    Out-Null

Expand-Archive `
    -Path $VSCodeZip `
    -DestinationPath $VSCodeRoot `
    -Force

$CodeExe = Get-ChildItem `
    -Path $VSCodeRoot `
    -Filter "Code.exe" `
    -Recurse `
    -File |
    Select-Object -First 1

if (-not $CodeExe) {
    throw "VS Code was extracted, but Code.exe could not be found."
}

$CodeRoot  = $CodeExe.Directory.FullName
$VSCodeBin = Join-Path $CodeRoot "bin"

# ---------------------------------------------------------------------------
# Configure user PATH
# ---------------------------------------------------------------------------

Write-Host "[6/6] Configuring user PATH..."

$userPath = [Environment]::GetEnvironmentVariable(
    "Path",
    "User"
)

$pathEntries = @()

if ($userPath) {
    $pathEntries = @(
        $userPath.Split(";") |
        Where-Object {
            $_ -ne ""
        }
    )
}

foreach ($directory in @($W64Bin, $VSCodeBin)) {

    # Compare paths case-insensitively.
    $alreadyExists = $false

    foreach ($existingPath in $pathEntries) {
        if ($existingPath.TrimEnd("\") -ieq $directory.TrimEnd("\")) {
            $alreadyExists = $true
            break
        }
    }

    if (-not $alreadyExists) {
        $pathEntries += $directory
    }
}

$newUserPath = $pathEntries -join ";"

[Environment]::SetEnvironmentVariable(
    "Path",
    $newUserPath,
    "User"
)

# Update PATH in this PowerShell process as well.
# This lets the verification and extension installation below work immediately.
$env:Path = "$W64Bin;$VSCodeBin;$env:Path"

# ---------------------------------------------------------------------------
# Create VS Code shortcuts
# ---------------------------------------------------------------------------

Write-Host "Creating Visual Studio Code shortcuts..."

try {
    $Shell = New-Object -ComObject WScript.Shell

    # -----------------------------------------------------------------------
    # Desktop shortcut
    # -----------------------------------------------------------------------

    $Desktop = [Environment]::GetFolderPath("Desktop")

    $DesktopShortcutPath = Join-Path `
        $Desktop `
        "Visual Studio Code.lnk"

    $DesktopShortcut = $Shell.CreateShortcut(
        $DesktopShortcutPath
    )

    $DesktopShortcut.TargetPath = $CodeExe.FullName
    $DesktopShortcut.WorkingDirectory = $CodeRoot
    $DesktopShortcut.IconLocation = "$($CodeExe.FullName),0"

    $DesktopShortcut.Save()

    Write-Host "Created Desktop shortcut:"
    Write-Host "  $DesktopShortcutPath"

    # -----------------------------------------------------------------------
    # Start Menu shortcut
    # -----------------------------------------------------------------------

    $Programs = [Environment]::GetFolderPath("Programs")

    $StartShortcutPath = Join-Path `
        $Programs `
        "Visual Studio Code.lnk"

    $StartShortcut = $Shell.CreateShortcut(
        $StartShortcutPath
    )

    $StartShortcut.TargetPath = $CodeExe.FullName
    $StartShortcut.WorkingDirectory = $CodeRoot
    $StartShortcut.IconLocation = "$($CodeExe.FullName),0"

    $StartShortcut.Save()

    Write-Host "Created Start Menu shortcut:"
    Write-Host "  $StartShortcutPath"
}
catch {
    Write-Warning "Could not create VS Code shortcuts: $_"
}

# ---------------------------------------------------------------------------
# Install Microsoft's C/C++ VS Code extension
# ---------------------------------------------------------------------------

$CodeCmd = Join-Path $VSCodeBin "code.cmd"

if (Test-Path $CodeCmd) {

    Write-Host ""
    Write-Host "Installing Microsoft C/C++ extension..."

    & $CodeCmd `
        --install-extension ms-vscode.cpptools `
        --force

    if ($LASTEXITCODE -ne 0) {
        Write-Warning `
            "C/C++ extension installation failed. VS Code itself is still usable."
    }
}
else {
    Write-Warning `
        "Could not find code.cmd, so the C/C++ extension was not installed."
}

# ---------------------------------------------------------------------------
# Verify GCC
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Testing compiler..."
Write-Host ""

$GppExe = Join-Path $W64Bin "g++.exe"

& $GppExe --version

if ($LASTEXITCODE -ne 0) {
    throw "g++ verification failed."
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

Remove-Item `
    $TempRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host "Setup complete."
Write-Host ""
Write-Host "w64devkit:"
Write-Host "  $W64Root"
Write-Host ""
Write-Host "Visual Studio Code:"
Write-Host "  $CodeRoot"
Write-Host ""
Write-Host "Shortcuts created:"
Write-Host "  - Desktop"
Write-Host "  - Start Menu"
Write-Host ""
Write-Host "To pin VS Code to the taskbar:"
Write-Host "  1. Open Start"
Write-Host "  2. Search for Visual Studio Code"
Write-Host "  3. Right-click it"
Write-Host "  4. Select 'Pin to taskbar'"
Write-Host ""
Write-Host "Once VS Code is open, create a new terminal and run:"
Write-Host ""
Write-Host "  g++ --version"
Write-Host ""
Write-Host "Example compile command:"
Write-Host ""
Write-Host '  g++ -std=c++23 main.cpp -o main.exe'
Write-Host '  .\main.exe'
Write-Host ""
Write-Host "============================================================"
