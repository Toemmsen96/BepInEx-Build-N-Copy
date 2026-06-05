#Requires -Version 5.1
param(
    [string]$s = "",
    [string]$g = "",
    [string]$o = "",
    [switch]$h
)

function Write-Colored($color, $msg) { Write-Host $msg -ForegroundColor $color }
function Write-Sep() { Write-Host "================================================" -ForegroundColor Cyan }

if ($h) {
    Write-Host "Usage: .\copy_dependencies.ps1 [-s <source_dir>] [-g <game_path>] [-o <output_dir>] [-h]"
    Write-Host ""
    Write-Host "Reads deps.txt and copies each listed DLL from the game's directory into the"
    Write-Host "local Dependencies or deps folder (whichever exists) in <source_dir>."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "    -s <source_dir>   Directory containing deps.txt (default: current directory)"
    Write-Host "    -g <game_path>    Directly use <game_path> as the game's install path (bypass interactive listing)"
    Write-Host "    -o <output_dir>   Override the output directory (bypasses auto-detection of Dependencies/deps)"
    Write-Host "    -h                Show this help message"
    Write-Host ""
    Write-Host "If -g is not provided and path.txt is missing or invalid, the script will try to"
    Write-Host "find Steam library folders and list installed games to let you pick one."
    Write-Host ""
    Write-Host "deps.txt format: one DLL filename per line (e.g. SomeMod.dll), # for comments."
    Write-Host ""
    Write-Host "The script searches for each DLL recursively under the game's root directory."
    exit 0
}

$SrcDir = if ($s) { $s } else { (Get-Location).Path }

if (-not (Test-Path $SrcDir -PathType Container)) {
    Write-Colored Red "ERROR: Source directory does not exist: $SrcDir"
    exit 1
}

Set-Location $SrcDir
Write-Colored Cyan "INFO: Using source directory: $SrcDir"

# Resolve game root
$GameRoot = ""

if ($g) {
    $GameRoot = [System.Environment]::ExpandEnvironmentVariables($g)
    Write-Colored Cyan "INFO: Using forced game path: $GameRoot"
    if (-not (Test-Path $GameRoot -PathType Container)) {
        Write-Colored Red "ERROR: Forced game path does not exist: $GameRoot"
        exit 1
    }
} else {
    if (Test-Path "path.txt") {
        $raw = (Get-Content "path.txt" -Raw).Trim()
        $stored = [System.Environment]::ExpandEnvironmentVariables($raw)
        # Strip trailing BepInEx\plugins or BepInEx to get game root
        $GameRoot = $stored -replace '[/\\]BepInEx[/\\]plugins$', '' -replace '[/\\]BepInEx$', ''
        Write-Colored Cyan "INFO: Game path from path.txt: $GameRoot"
    }

    if (-not $GameRoot -or -not (Test-Path $GameRoot -PathType Container)) {
        if ($GameRoot) {
            Write-Colored Yellow "WARN: Game directory does not exist: $GameRoot"
        } else {
            Write-Colored Yellow "WARN: No game path set (path.txt missing or empty)"
        }

        $SteamRoots = @(
            "${env:ProgramFiles(x86)}\Steam",
            "$env:ProgramFiles\Steam",
            "$env:LOCALAPPDATA\Steam"
        )

        $VdfPath = ""
        foreach ($root in $SteamRoots) {
            $candidate = Join-Path $root "steamapps\libraryfolders.vdf"
            if (Test-Path $candidate) { $VdfPath = $candidate; break }
        }

        if (-not $VdfPath) {
            Write-Colored Red "ERROR: Could not find Steam libraryfolders.vdf in expected locations"
            Write-Colored Yellow "TIP: Please provide a valid path in path.txt or use -g <game_path>"
            exit 1
        }

        Write-Colored Yellow "INFO: Parsing Steam libraries from: $VdfPath"

        $vdfContent = Get-Content $VdfPath -Raw
        $LibPaths = [System.Collections.Generic.List[string]]::new()

        foreach ($m in [regex]::Matches($vdfContent, '"path"\s*"([^"]+)"')) {
            $LibPaths.Add($m.Groups[1].Value)
        }
        foreach ($m in [regex]::Matches($vdfContent, '(?m)^\s*"[0-9]+"\s*"([^"]+)"')) {
            $p = $m.Groups[1].Value
            if (-not $LibPaths.Contains($p)) { $LibPaths.Add($p) }
        }

        if ($LibPaths.Count -eq 0) {
            Write-Colored Red "ERROR: No Steam library paths found in VDF"
            Write-Colored Yellow "TIP: Please provide a valid path in path.txt or use -g <game_path>"
            exit 1
        }

        $Games = [System.Collections.Generic.List[string]]::new()
        $GamePaths = [System.Collections.Generic.List[string]]::new()
        $counter = 1

        foreach ($lib in $LibPaths) {
            $lib = [System.Environment]::ExpandEnvironmentVariables($lib.Trim())
            $commonDir = Join-Path $lib "steamapps\common"
            if (Test-Path $commonDir -PathType Container) {
                foreach ($dir in Get-ChildItem $commonDir -Directory) {
                    Write-Colored Magenta "  [$counter] $($dir.Name)  (in $lib)"
                    $Games.Add($dir.Name)
                    $GamePaths.Add($dir.FullName)
                    $counter++
                }
            }
        }

        if ($Games.Count -eq 0) {
            Write-Colored Red "ERROR: No games found in any Steam library"
            Write-Colored Yellow "TIP: Use -g <game_path> to specify the game directory directly"
            exit 1
        }

        Write-Sep
        Write-Colored Yellow "Select a game, or press Enter to exit:"
        $selection = Read-Host "Enter game number (1-$($Games.Count))"

        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $Games.Count) {
            $idx = [int]$selection - 1
            $GameRoot = $GamePaths[$idx]
            Write-Colored Green "Selected: $($Games[$idx])"
        } else {
            Write-Colored Yellow "No valid selection made. Exiting..."
            exit 0
        }
    }
}

Write-Colored Cyan "INFO: Game root: $GameRoot"

# Resolve output directory
$OutputDir = ""

if ($o) {
    $OutputDir = $o
    Write-Colored Cyan "INFO: Using override output directory: $OutputDir"
} elseif (Test-Path "Dependencies" -PathType Container) {
    $OutputDir = "Dependencies"
    Write-Colored Cyan "INFO: Using existing Dependencies directory as output"
} elseif (Test-Path "deps" -PathType Container) {
    $OutputDir = "deps"
    Write-Colored Cyan "INFO: Using existing deps directory as output"
} else {
    Write-Colored Red "ERROR: No Dependencies or deps directory found in: $SrcDir"
    Write-Colored Yellow "TIP: Create one of those directories first, or use -o to specify an output directory"
    exit 1
}

if (-not (Test-Path $OutputDir -PathType Container)) {
    Write-Colored Yellow "INFO: Creating output directory: $OutputDir"
    try {
        New-Item -ItemType Directory -Force $OutputDir | Out-Null
    } catch {
        Write-Colored Red "ERROR: Failed to create $OutputDir : $_"
        exit 1
    }
}

# Process deps.txt
if (-not (Test-Path "deps.txt")) {
    Write-Colored Red "ERROR: deps.txt not found in: $SrcDir"
    Write-Colored Yellow "TIP: Create a deps.txt with one DLL filename per line"
    exit 1
}

Write-Sep
Write-Colored Yellow "Processing deps.txt..."
Write-Sep

$CopiedCount = 0
$FailedCount = 0

foreach ($line in Get-Content "deps.txt") {
    $dllName = $line.Trim()
    if (-not $dllName -or $dllName.StartsWith('#')) { continue }

    Write-Colored Cyan "Searching for: $dllName"

    $found = Get-ChildItem $GameRoot -Recurse -Filter $dllName -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($found) {
        Write-Colored Cyan "   Found: $($found.FullName)"
        try {
            Copy-Item $found.FullName -Destination $OutputDir -Force
            Write-Colored Green "   Copied successfully!"
            $copiedInfo = Get-Item (Join-Path $OutputDir $dllName) -ErrorAction SilentlyContinue
            if ($copiedInfo) {
                Write-Colored Magenta "   Size: $([math]::Round($copiedInfo.Length / 1KB, 1)) KB"
            }
            $CopiedCount++
        } catch {
            Write-Colored Red "   ERROR: Failed to copy: $_"
            $FailedCount++
        }
    } else {
        Write-Colored Red "   Not found under game directory"
        $FailedCount++
    }
    Write-Host ""
}

Write-Sep
Write-Colored Cyan "Summary: $CopiedCount copied, $FailedCount failed"
Write-Colored Cyan "Output directory: $OutputDir"
Write-Sep

if ($FailedCount -gt 0) {
    Write-Colored Yellow "WARN: Some DLLs could not be found. Check that they exist under: $GameRoot"
    exit 1
}

Write-Colored Green "All dependencies copied successfully!"
Write-Sep
