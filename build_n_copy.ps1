#Requires -Version 5.1
param(
    [string]$s = "",
    [string]$g = "",
    [string[]]$d = @(),
    [switch]$h
)

function Write-Colored($color, $msg) { Write-Host $msg -ForegroundColor $color }
function Write-Sep() { Write-Host "================================================" -ForegroundColor Cyan }

if ($h) {
    Write-Host "Usage: .\build_n_copy.ps1 [-s <source_dir>] [-g <game_path>] [-d <deps_dir>] [-h]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "    -s <source_dir>   Use <source_dir> as the project/source directory (default: current directory)"
    Write-Host "    -g <game_path>    Directly use <game_path> as the game's install path (bypass interactive listing)"
    Write-Host "                      If <game_path> points to a game root, BepInEx\plugins will be appended if needed."
    Write-Host "    -d <deps_dir>     Additional directory to search for DLLs listed in out.txt"
    Write-Host "    -h                Show this help message"
    Write-Host ""
    Write-Host "The script searches for DLLs in out.txt in this order:"
    Write-Host "  1. Build output (bin\Release\*)"
    Write-Host "  2. Dependencies folder"
    Write-Host "  3. deps folder"
    Write-Host "  4. Custom directories specified with -d"
    Write-Host "  5. Current directory"
    exit 0
}

$SrcDir = if ($s) { $s } else { (Get-Location).Path }

if (-not (Test-Path $SrcDir -PathType Container)) {
    Write-Colored Red "ERROR: Source directory does not exist: $SrcDir"
    exit 1
}

Set-Location $SrcDir
Write-Colored Cyan "INFO: Using source directory: $SrcDir"

$CsprojFile = Get-ChildItem -Filter "*.csproj" | Select-Object -First 1
$ProjectName = if ($CsprojFile) {
    Write-Colored Cyan "INFO: Detected project: $($CsprojFile.BaseName) (from $($CsprojFile.Name))"
    $CsprojFile.BaseName
} else {
    $dirName = Split-Path -Leaf $SrcDir
    Write-Colored Yellow "WARN: No .csproj file found, using directory name: $dirName"
    $dirName
}

$TargetPath = ""

if ($g) {
    $TargetPath = [System.Environment]::ExpandEnvironmentVariables($g)

    if (Test-Path $TargetPath -PathType Container) {
        $leaf = Split-Path -Leaf $TargetPath
        if ($leaf -ne "BepInEx" -and $TargetPath -notmatch "BepInEx[/\\]plugins") {
            $TargetPath = Join-Path $TargetPath "BepInEx\plugins"
        }
    }

    Write-Colored Cyan "INFO: Using forced target path: $TargetPath"
    if (-not (Test-Path $TargetPath -PathType Container)) {
        Write-Colored Red "ERROR: Forced target directory does not exist: $TargetPath"
        exit 1
    }
} else {
    if (Test-Path "path.txt") {
        $raw = (Get-Content "path.txt" -Raw).Trim()
        $TargetPath = [System.Environment]::ExpandEnvironmentVariables($raw)
        Write-Colored Cyan "INFO: Target path from path.txt: $TargetPath"
    }

    if (-not $TargetPath -or -not (Test-Path $TargetPath -PathType Container)) {
        if ($TargetPath) {
            Write-Colored Yellow "WARN: Target directory does not exist: $TargetPath"
        } else {
            Write-Colored Yellow "WARN: No target path set (path.txt missing or empty)"
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
            Write-Colored Red "ERROR: No games found in any Steam library's steamapps\common directories"
            Write-Colored Yellow "TIP: Please verify Steam installation and game location or use -g <game_path>"
            exit 1
        }

        Write-Sep
        Write-Colored Yellow "Select a game to update path.txt, or press Enter to exit:"
        $selection = Read-Host "Enter game number (1-$($Games.Count))"

        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $Games.Count) {
            $idx = [int]$selection - 1
            $selectedGame = $Games[$idx]
            $selectedFullPath = $GamePaths[$idx]
            $newPath = Join-Path $selectedFullPath "BepInEx\plugins"

            Write-Colored Green "Selected: $selectedGame"
            Write-Colored Cyan "Updating path.txt with: $newPath"
            Set-Content "path.txt" $newPath -Encoding UTF8

            if (-not (Test-Path $newPath -PathType Container)) {
                Write-Colored Yellow "Creating BepInEx\plugins directory..."
                try {
                    New-Item -ItemType Directory -Force $newPath | Out-Null
                    Write-Colored Green "Directory created successfully!"
                } catch {
                    Write-Colored Red "ERROR: Failed to create directory: $_"
                    exit 1
                }
            }

            $TargetPath = $newPath
            Write-Colored Green "Continuing with build process using: $TargetPath"
        } else {
            Write-Colored Yellow "No valid selection made. Exiting..."
            exit 0
        }
    }
}

Write-Sep
Write-Colored Yellow "Starting build process..."
Write-Sep

Write-Colored Cyan "Building $ProjectName..."
dotnet build --configuration Release
if ($LASTEXITCODE -ne 0) {
    Write-Colored Red "ERROR: Build failed!"
    exit 1
}
Write-Colored Green "Build completed successfully!"

Write-Sep
Write-Colored Yellow "Copying DLLs to target location..."

$DllPath = Get-ChildItem -Recurse -Filter "${ProjectName}.dll" |
    Where-Object { $_.FullName -match "\\bin\\Release\\" } |
    Select-Object -First 1

if (-not $DllPath) {
    Write-Colored Red "ERROR: Could not find ${ProjectName}.dll in build output!"
    Write-Colored Yellow "Searching for any .dll files in build output..."
    $DllPath = Get-ChildItem -Recurse -Filter "*.dll" |
        Where-Object { $_.FullName -match "\\bin\\Release\\" -and $_.FullName -notmatch "\\ref\\" } |
        Select-Object -First 1
    if ($DllPath) {
        Write-Colored Yellow "WARN: Found fallback DLL: $($DllPath.FullName)"
    } else {
        Write-Colored Red "ERROR: No DLL files found in build output!"
        exit 1
    }
}

Write-Colored Cyan "Found main DLL: $($DllPath.FullName)"
Copy-Item $DllPath.FullName -Destination $TargetPath -Force
Write-Colored Green "Main DLL ($($DllPath.Name)) copied successfully to $TargetPath"

$copiedFile = Join-Path $TargetPath $DllPath.Name
if (Test-Path $copiedFile) {
    $info = Get-Item $copiedFile
    Write-Colored Magenta "Size: $([math]::Round($info.Length / 1KB, 1)) KB"
    Write-Colored Magenta "Modified: $($info.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}

if (Test-Path "out.txt") {
    Write-Colored Yellow "Found out.txt, processing additional DLLs..."
    Write-Sep

    $CopiedCount = 0
    $FailedCount = 0

    foreach ($line in Get-Content "out.txt") {
        $dllName = $line.Trim()
        if (-not $dllName) { continue }

        Write-Colored Cyan "Searching for: $dllName"

        $foundPath = ""
        $sourceLocation = ""

        $found = Get-ChildItem -Recurse -Filter $dllName |
            Where-Object { $_.FullName -match "\\bin\\Release\\" } |
            Select-Object -First 1
        if ($found) { $foundPath = $found.FullName; $sourceLocation = "build output" }

        if (-not $foundPath -and (Test-Path "Dependencies" -PathType Container)) {
            $found = Get-ChildItem "Dependencies" -Recurse -Filter $dllName | Select-Object -First 1
            if ($found) { $foundPath = $found.FullName; $sourceLocation = "Dependencies folder" }
        }

        if (-not $foundPath -and (Test-Path "deps" -PathType Container)) {
            $found = Get-ChildItem "deps" -Recurse -Filter $dllName | Select-Object -First 1
            if ($found) { $foundPath = $found.FullName; $sourceLocation = "deps folder" }
        }

        if (-not $foundPath) {
            foreach ($customDir in $d) {
                if (Test-Path $customDir -PathType Container) {
                    $found = Get-ChildItem $customDir -Recurse -Filter $dllName | Select-Object -First 1
                    if ($found) { $foundPath = $found.FullName; $sourceLocation = "custom directory ($customDir)"; break }
                }
            }
        }

        if (-not $foundPath -and (Test-Path $dllName)) {
            $foundPath = (Resolve-Path $dllName).Path
            $sourceLocation = "current directory"
        }

        if ($foundPath) {
            Write-Colored Cyan "   Found in: $sourceLocation"
            Write-Colored Cyan "   Path: $foundPath"
            try {
                Copy-Item $foundPath -Destination $TargetPath -Force
                Write-Colored Green "   Copied successfully!"
                $copiedInfo = Get-Item (Join-Path $TargetPath $dllName) -ErrorAction SilentlyContinue
                if ($copiedInfo) {
                    Write-Colored Magenta "   Size: $([math]::Round($copiedInfo.Length / 1KB, 1)) KB"
                }
                $CopiedCount++
            } catch {
                Write-Colored Red "   ERROR: Failed to copy: $_"
                $FailedCount++
            }
        } else {
            Write-Colored Red "   Not found in any search location"
            $FailedCount++
        }
        Write-Host ""
    }

    Write-Sep
    Write-Colored Cyan "Summary: $CopiedCount copied, $FailedCount failed"
} else {
    Write-Colored Cyan "No out.txt found, skipping additional DLLs"
}

Write-Sep
Write-Colored Green "Build and copy completed successfully!"
Write-Colored Cyan "Ready to test in $ProjectName!"
Write-Sep
