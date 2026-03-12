#!/bin/bash

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_colored() {
    echo -e "${1}${2}${NC}"
}

# Function to print a separator
print_separator() {
    echo -e "${CYAN}================================================${NC}"
}

# Usage/help
show_help() {
        cat <<EOF
Usage: $(basename "$0") [-s <source_dir>] [-g <game_path>] [-d <deps_dir>] [-h]

Options:
    -s <source_dir>   Use <source_dir> as the project/source directory (default: current directory)
    -g <game_path>    Directly use <game_path> as the game's install path (bypass interactive listing)
                                        If <game_path> points to a game root, the script will append BepInEx/plugins if needed.
    -d <deps_dir>     Additional directory to search for DLLs listed in out.txt (can be used multiple times)
    -h                Show this help message

If -g is not provided and the path in path.txt is invalid, the script will try to find Steam libraryfolders
and list all installed games across all Steam libraries to let you pick a game.

The script searches for DLLs in out.txt in this order:
  1. Build output (bin/Release/*)
  2. Dependencies folder
  3. deps folder
  4. Custom directories specified with -d
  5. Current directory
EOF
}

# Auto-detect project name from .csproj file
PROJECT_NAME=""
CSPROJ_FILE=""

# Defaults and CLI
SRC_DIR="$(pwd)"
FORCE_GAME_PATH=""
CUSTOM_DEPS_DIRS=()

while getopts ":g:s:d:h" opt; do
    case ${opt} in
        g )
            FORCE_GAME_PATH="$OPTARG"
            ;;
        s )
            SRC_DIR="$OPTARG"
            ;;
        d )
            CUSTOM_DEPS_DIRS+=("$OPTARG")
            ;;
        h )
            show_help
            exit 0
            ;;
        \? )
            print_colored $YELLOW "⚠️  Invalid option: -$OPTARG"
            show_help
            exit 1
            ;;
        : )
            print_colored $YELLOW "⚠️  Option -$OPTARG requires an argument."
            show_help
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

# If a source dir was provided, cd into it for project detection and build
if [ ! -d "$SRC_DIR" ]; then
        print_colored $RED "❌ Source directory does not exist: $SRC_DIR"
        exit 1
fi
cd "$SRC_DIR" || exit 1
print_colored $BLUE "📂 Using source directory: $SRC_DIR"

# Find .csproj file in current directory
for file in *.csproj; do
    if [ -f "$file" ]; then
        CSPROJ_FILE="$file"
        PROJECT_NAME=$(basename "$file" .csproj)
        break
    fi
done

# If no .csproj found, fall back to directory name
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME=$(basename "$(pwd)")
    print_colored $YELLOW "⚠️  No .csproj file found, using directory name: $PROJECT_NAME"
else
    print_colored $BLUE "🔍 Detected project: $PROJECT_NAME (from $CSPROJ_FILE)"
fi

TARGET_PATH=""

# If a forced game path was provided (-g), prefer it and don't do interactive listing
if [ -n "$FORCE_GAME_PATH" ]; then
    # Expand variables like $HOME
    TARGET_PATH=$(eval echo "$FORCE_GAME_PATH")

    # If user provided a game root, append BepInEx/plugins when appropriate
    if [ -d "$TARGET_PATH" ]; then
        if [[ "$(basename "$TARGET_PATH")" != "BepInEx" && "$TARGET_PATH" != *"BepInEx/plugins"* ]]; then
            TARGET_PATH="${TARGET_PATH%/}/BepInEx/plugins"
        fi
    fi

    print_colored $BLUE "📁 Using forced target path: $TARGET_PATH"
    if [ ! -d "$TARGET_PATH" ]; then
        print_colored $RED "❌ Error: Forced target directory does not exist: $TARGET_PATH"
        exit 1
    fi
else
    # Try to read path.txt if present
    if [ -f "path.txt" ]; then
        TARGET_PATH_RAW=$(cat path.txt | tr -d '\n\r')
        TARGET_PATH=$(eval echo "$TARGET_PATH_RAW")
        print_colored $BLUE "📁 Target path from path.txt: $TARGET_PATH"
    fi

    # If target path is missing or invalid, attempt to find Steam libraries and list games across all libraries
    if [ -z "$TARGET_PATH" ] || [ ! -d "$TARGET_PATH" ]; then
        if [ -n "$TARGET_PATH" ]; then
            print_colored $YELLOW "⚠️  Target directory does not exist: $TARGET_PATH"
        else
            print_colored $YELLOW "⚠️  No target path set (path.txt missing or empty)"
        fi

        # Locate libraryfolders.vdf in several typical locations
        POSSIBLE_VDFS=("$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
                      "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
                      "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
                      "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/libraryfolders.vdf")

        VDF_PATH=""
        for p in "${POSSIBLE_VDFS[@]}"; do
            if [ -f "$p" ]; then
                VDF_PATH="$p"
                break
            fi
        done

        if [ -z "$VDF_PATH" ]; then
            print_colored $RED "❌ Could not find Steam libraryfolders.vdf in expected locations"
            print_colored $YELLOW "💡 Please provide a valid path in path.txt or use -g <game_path>"
            exit 1
        fi

        print_colored $YELLOW "🔍 Parsing Steam libraries from: $VDF_PATH"

        # Extract library paths from VDF. Handle multiple VDF formats:
        # - Newer format: entries contain a "path" key
        # - Older format: numeric keys directly map to paths
        LIB_PATHS=()

        # 1) Extract values for "path" entries (common in newer Steam VDF)
        while IFS= read -r p; do
            [ -n "$p" ] && LIB_PATHS+=("$p")
        done < <(grep -Po '"path"\s*"\K[^"]+' "$VDF_PATH" 2>/dev/null || true)

        # 2) Extract numeric-key direct values (older format)
        while IFS= read -r p; do
            [ -n "$p" ] && LIB_PATHS+=("$p")
        done < <(grep -Po '^\s*"[0-9]+"\s*"\K[^\"]+' "$VDF_PATH" 2>/dev/null || true)

        # Deduplicate while preserving order
        if [ ${#LIB_PATHS[@]} -gt 1 ]; then
            declare -A __seen_paths=()
            __unique=()
            for __p in "${LIB_PATHS[@]}"; do
                # Normalize path (strip surrounding whitespace)
                __p_trimmed=$(echo "$__p" | xargs)
                if [ -n "$__p_trimmed" ] && [ -z "${__seen_paths[$__p_trimmed]}" ]; then
                    __seen_paths[$__p_trimmed]=1
                    __unique+=("$__p_trimmed")
                fi
            done
            LIB_PATHS=("${__unique[@]}")
            unset __seen_paths __unique __p __p_trimmed
        fi

        # Fallback to the default local steamapps if none found
        if [ ${#LIB_PATHS[@]} -eq 0 ]; then
            LIB_PATHS=("$HOME/.steam/steam")
        fi

        declare -a GAMES=()
        declare -a GAME_FULL_PATHS=()
        counter=1

        for lib in "${LIB_PATHS[@]}"; do
            # Expand env and strip quotes
            lib=$(eval echo "$lib")
            COMMON_DIR="$lib/steamapps/common"
            if [ -d "$COMMON_DIR" ]; then
                for dir in "$COMMON_DIR"/*; do
                    if [ -d "$dir" ]; then
                        GAME_NAME=$(basename "$dir")
                        GAMES+=("$GAME_NAME")
                        GAME_FULL_PATHS+=("$dir")
                        print_colored $PURPLE "  [$counter] 📂 $GAME_NAME  (in $lib)"
                        ((counter++))
                    fi
                done
            fi
        done

        if [ ${#GAMES[@]} -eq 0 ]; then
            print_colored $RED "❌ No games found in any Steam library's steamapps/common directories"
            print_colored $YELLOW "💡 Please verify Steam installation and game location or use -g <game_path>"
            exit 1
        fi

        print_separator
        print_colored $YELLOW "💡 Select a game to update path.txt, or press Enter to exit:"
        read -p "Enter game number (1-${#GAMES[@]}): " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#GAMES[@]} ]; then
            SELECTED_INDEX=$((selection-1))
            SELECTED_GAME="${GAMES[$SELECTED_INDEX]}"
            SELECTED_FULL_PATH="${GAME_FULL_PATHS[$SELECTED_INDEX]}"
            NEW_PATH="$SELECTED_FULL_PATH/BepInEx/plugins"

            print_colored $GREEN "✅ Selected: $SELECTED_GAME"
            print_colored $BLUE "📝 Updating path.txt with: \$HOME/.../steamapps/common/$SELECTED_GAME/BepInEx/plugins"

            echo "\$HOME/$(realpath --relative-to="$HOME" "$SELECTED_FULL_PATH")/BepInEx/plugins" > path.txt

            if [ ! -d "$NEW_PATH" ]; then
                print_colored $YELLOW "🔧 Creating BepInEx/plugins directory..."
                mkdir -p "$NEW_PATH"
                if [ $? -eq 0 ]; then
                    print_colored $GREEN "✅ Directory created successfully!"
                else
                    print_colored $RED "❌ Failed to create directory!"
                    exit 1
                fi
            fi

            TARGET_PATH="$NEW_PATH"
            print_colored $GREEN "🔄 Continuing with build process using: $TARGET_PATH"
        else
            print_colored $YELLOW "👋 No valid selection made. Exiting..."
            exit 0
        fi
    fi
fi

print_separator
print_colored $YELLOW "🔨 Starting build process..."
print_separator

# Build the project
print_colored $CYAN "⚙️  Building $PROJECT_NAME..."
dotnet build --configuration Release

# Check if build was successful
if [ $? -eq 0 ]; then
    print_colored $GREEN "✅ Build completed successfully!"
else
    print_colored $RED "❌ Build failed!"
    exit 1
fi

print_separator
print_colored $YELLOW "📦 Copying DLLs to target location..."

# Find the built DLL using the detected project name
DLL_PATH=$(find . -name "${PROJECT_NAME}.dll" -path "*/bin/Release/*" | head -1)

if [ -z "$DLL_PATH" ]; then
    print_colored $RED "❌ Error: Could not find ${PROJECT_NAME}.dll in build output!"
    print_colored $YELLOW "🔍 Searching for any .dll files in build output..."
    
    # Try to find any DLL in the build output as fallback
    FALLBACK_DLL=$(find . -name "*.dll" -path "*/bin/Release/*" | grep -v "ref/" | head -1)
    if [ -n "$FALLBACK_DLL" ]; then
        print_colored $YELLOW "⚠️  Found fallback DLL: $FALLBACK_DLL"
        DLL_PATH="$FALLBACK_DLL"
    else
        print_colored $RED "❌ No DLL files found in build output!"
        exit 1
    fi
fi

print_colored $BLUE "📄 Found main DLL: $DLL_PATH"

# Extract the actual DLL name from the path
DLL_NAME=$(basename "$DLL_PATH")

# Copy the main DLL to the target location
cp "$DLL_PATH" "$TARGET_PATH/"

if [ $? -eq 0 ]; then
    print_colored $GREEN "✅ Main DLL ($DLL_NAME) copied successfully to $TARGET_PATH"
    
    # Show file info
    COPIED_FILE="$TARGET_PATH/$DLL_NAME"
    if [ -f "$COPIED_FILE" ]; then
        FILE_SIZE=$(du -h "$COPIED_FILE" | cut -f1)
        FILE_DATE=$(date -r "$COPIED_FILE" "+%Y-%m-%d %H:%M:%S")
        print_colored $PURPLE "📊 Main DLL size: $FILE_SIZE"
        print_colored $PURPLE "🕒 Modified: $FILE_DATE"
    fi
else
    print_colored $RED "❌ Error: Failed to copy main DLL!"
    exit 1
fi

# Check if out.txt exists and copy additional DLLs
if [ -f "out.txt" ]; then
    print_colored $YELLOW "📋 Found out.txt, processing additional DLLs..."
    print_separator
    
    COPIED_COUNT=0
    FAILED_COUNT=0
    
    while IFS= read -r dll_name || [ -n "$dll_name" ]; do
        # Skip empty lines
        if [ -z "$dll_name" ]; then
            continue
        fi
        
        # Remove any whitespace/newlines
        dll_name=$(echo "$dll_name" | tr -d '\n\r' | xargs)
        
        # Skip if empty after trimming
        if [ -z "$dll_name" ]; then
            continue
        fi
        
        print_colored $CYAN "🔍 Searching for: $dll_name"
        
        # Search for DLL in multiple locations (in order of priority)
        ADDITIONAL_DLL_PATH=""
        SOURCE_LOCATION=""
        
        # 1. Check build output first
        ADDITIONAL_DLL_PATH=$(find . -name "$dll_name" -path "*/bin/Release/*" | head -1)
        if [ -n "$ADDITIONAL_DLL_PATH" ]; then
            SOURCE_LOCATION="build output"
        fi
        
        # 2. If not in build output, check Dependencies folder
        if [ -z "$ADDITIONAL_DLL_PATH" ] && [ -d "Dependencies" ]; then
            ADDITIONAL_DLL_PATH=$(find Dependencies -name "$dll_name" -type f | head -1)
            if [ -n "$ADDITIONAL_DLL_PATH" ]; then
                SOURCE_LOCATION="Dependencies folder"
            fi
        fi
        
        # 3. If not in Dependencies, check deps folder
        if [ -z "$ADDITIONAL_DLL_PATH" ] && [ -d "deps" ]; then
            ADDITIONAL_DLL_PATH=$(find deps -name "$dll_name" -type f | head -1)
            if [ -n "$ADDITIONAL_DLL_PATH" ]; then
                SOURCE_LOCATION="deps folder"
            fi
        fi
        
        # 4. Check custom dependency directories specified with -d
        if [ -z "$ADDITIONAL_DLL_PATH" ] && [ ${#CUSTOM_DEPS_DIRS[@]} -gt 0 ]; then
            for custom_dir in "${CUSTOM_DEPS_DIRS[@]}"; do
                if [ -d "$custom_dir" ]; then
                    ADDITIONAL_DLL_PATH=$(find "$custom_dir" -name "$dll_name" -type f | head -1)
                    if [ -n "$ADDITIONAL_DLL_PATH" ]; then
                        SOURCE_LOCATION="custom directory ($custom_dir)"
                        break
                    fi
                fi
            done
        fi
        
        # 5. If still not found, check current directory
        if [ -z "$ADDITIONAL_DLL_PATH" ] && [ -f "$dll_name" ]; then
            ADDITIONAL_DLL_PATH="$dll_name"
            SOURCE_LOCATION="current directory"
        fi
        
        if [ -n "$ADDITIONAL_DLL_PATH" ]; then
            print_colored $BLUE "   ├─ Found in: $SOURCE_LOCATION"
            print_colored $BLUE "   ├─ Path: $ADDITIONAL_DLL_PATH"
            
            cp "$ADDITIONAL_DLL_PATH" "$TARGET_PATH/"
            
            if [ $? -eq 0 ]; then
                print_colored $GREEN "   └─ ✅ Copied successfully!"
                
                # Show file info
                COPIED_ADDITIONAL="$TARGET_PATH/$dll_name"
                if [ -f "$COPIED_ADDITIONAL" ]; then
                    FILE_SIZE=$(du -h "$COPIED_ADDITIONAL" | cut -f1)
                    print_colored $PURPLE "      Size: $FILE_SIZE"
                fi
                ((COPIED_COUNT++))
            else
                print_colored $RED "   └─ ❌ Failed to copy!"
                ((FAILED_COUNT++))
            fi
        else
            print_colored $RED "   └─ ❌ Not found in any search location"
            ((FAILED_COUNT++))
        fi
        echo ""
    done < out.txt
    
    print_separator
    print_colored $CYAN "📊 Summary: $COPIED_COUNT copied, $FAILED_COUNT failed"
else
    print_colored $BLUE "ℹ️  No out.txt found, skipping additional DLLs"
fi

print_separator
print_colored $GREEN "🎉 Build and copy completed successfully!"
print_colored $CYAN "🚀 Ready to test in $PROJECT_NAME!"
print_separator