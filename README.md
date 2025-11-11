# BepInEx-Build-N-Copy

Simple helper script to build a .NET mod and copy the resulting DLL(s) into a game's BepInEx/plugins folder.

## Features
- Build a project (dotnet) and copy the main DLL and any additional DLLs listed in `out.txt` to the selected game's `BepInEx/plugins` directory.
- Discover Steam libraries by parsing `libraryfolders.vdf` and list installed games across all libraries for selection.
- Command-line options to specify source/project directory and to directly provide a game path.

## Usage
Run the script from your project folder or specify a source directory.

Basic:
```
./build_n_copy.sh
```

Use a different source/project directory:
```
./build_n_copy.sh -s /path/to/your/project
```

Supply a game path directly (no interactive selection). If you provide the game root the script will append `BepInEx/plugins` when appropriate:
```
./build_n_copy.sh -g "/home/you/.steam/steam/steamapps/common/SomeGame"
```

Show help:
```
./build_n_copy.sh -h
```

## How it works
- The script looks for a `.csproj` in the source directory to determine the project name. If none is found it uses the current directory name.
- It reads `path.txt` (if present) to get the target path. If the path is missing/invalid and `-g` isn't used, it searches for Steam's `libraryfolders.vdf` in common locations (including Flatpak locations).
- The script extracts library locations from `libraryfolders.vdf` (supports both newer `"path"` entries and older numeric entries). It then checks each library's `steamapps/common` folder and lists all installed games so you can pick one.
- After selection the script writes a `path.txt` pointing to the game's `BepInEx/plugins` (using a `$HOME/...` style relative path) and creates the `BepInEx/plugins` directory if necessary.
- Finally it runs `dotnet build --configuration Release`, finds the compiled DLL(s) in `*/bin/Release/*`, and copies them to the selected target.

## Flags
- `-s <source_dir>` — Use `<source_dir>` as the project directory (defaults to current directory).
- `-g <game_path>` — Use `<game_path>` directly as the game install path (bypasses interactive listing). If you give the game root the script appends `BepInEx/plugins`.
- `-h` — Show help.

## Prerequisites
- Bash (script uses Bash features like `mapfile`).
- `dotnet` CLI available in PATH to build the project.
- `grep`, `sed`, `realpath` (most Linux systems have these; if `realpath` is missing you can install `coreutils`).

## Notes and tips
- If your Steam installation is non-standard the script may not find `libraryfolders.vdf`; use `-g` to pass the game path directly.
- The script currently errors if `-g` results in a non-existing `BepInEx/plugins` path — this prevents accidental creation of unintended directories. If you prefer it to auto-create the directory, you can modify the script or ask me to change that behavior.
- The script will copy additional DLLs listed (one per line) in `out.txt` if present.

## Example
Build from another directory and select a game interactively:
```
./build_n_copy.sh -s /home/you/dev/MyMod
```

Build and copy directly to a known install:
```
./build_n_copy.sh -s /home/you/dev/MyMod -g /mnt/games/SomeGame
```