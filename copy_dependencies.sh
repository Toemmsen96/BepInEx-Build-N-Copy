#!/bin/bash

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_colored() {
    echo -e "${1}${2}${NC}"
}

print_separator() {
    echo -e "${CYAN}================================================${NC}"
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [-s <source_dir>] [-g <game_path>] [-o <output_dir>] [-h]

Reads deps.txt and copies each listed DLL from the game's directory into the
local Dependencies or deps folder (whichever exists) in <source_dir>.

Options:
    -s <source_dir>   Directory containing deps.txt (default: current directory)
    -g <game_path>    Directly use <game_path> as the game's install path (bypass interactive listing)
    -o <output_dir>   Override the output directory (bypasses auto-detection of Dependencies/deps)
    -h                Show this help message

If -g is not provided and path.txt is missing or invalid, the script will try to
find Steam library folders and list installed games to let you pick one.

deps.txt format: one DLL filename per line (e.g. SomeMod.dll), # for comments.

The script searches for each DLL recursively under the game's root directory.
EOF
}

SRC_DIR="$(pwd)"
FORCE_GAME_PATH=""
OVERRIDE_OUTPUT=""

while getopts ":s:g:o:h" opt; do
    case ${opt} in
        s ) SRC_DIR="$OPTARG" ;;
        g ) FORCE_GAME_PATH="$OPTARG" ;;
        o ) OVERRIDE_OUTPUT="$OPTARG" ;;
        h ) show_help; exit 0 ;;
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
shift $((OPTIND - 1))

if [ ! -d "$SRC_DIR" ]; then
    print_colored $RED "❌ Source directory does not exist: $SRC_DIR"
    exit 1
fi
cd "$SRC_DIR" || exit 1
print_colored $BLUE "📂 Using source directory: $SRC_DIR"

# ── Resolve game root (same logic as build_n_copy.sh) ────────────────────────
GAME_ROOT=""

if [ -n "$FORCE_GAME_PATH" ]; then
    GAME_ROOT=$(eval echo "$FORCE_GAME_PATH")
    print_colored $BLUE "📁 Using forced game path: $GAME_ROOT"
    if [ ! -d "$GAME_ROOT" ]; then
        print_colored $RED "❌ Forced game path does not exist: $GAME_ROOT"
        exit 1
    fi
else
    if [ -f "path.txt" ]; then
        RAW=$(cat path.txt | tr -d '\n\r')
        STORED_PATH=$(eval echo "$RAW")
        # Strip trailing BepInEx/plugins to get game root
        GAME_ROOT="${STORED_PATH%/BepInEx/plugins}"
        GAME_ROOT="${GAME_ROOT%/BepInEx}"
        print_colored $BLUE "📁 Game path from path.txt: $GAME_ROOT"
    fi

    if [ -z "$GAME_ROOT" ] || [ ! -d "$GAME_ROOT" ]; then
        if [ -n "$GAME_ROOT" ]; then
            print_colored $YELLOW "⚠️  Game directory does not exist: $GAME_ROOT"
        else
            print_colored $YELLOW "⚠️  No game path set (path.txt missing or empty)"
        fi

        POSSIBLE_VDFS=(
            "$HOME/.steam/steam/steamapps/libraryfolders.vdf"
            "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
            "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/libraryfolders.vdf"
        )

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

        LIB_PATHS=()
        while IFS= read -r p; do
            [ -n "$p" ] && LIB_PATHS+=("$p")
        done < <(grep -Po '"path"\s*"\K[^"]+' "$VDF_PATH" 2>/dev/null || true)
        while IFS= read -r p; do
            [ -n "$p" ] && LIB_PATHS+=("$p")
        done < <(grep -Po '^\s*"[0-9]+"\s*"\K[^\"]+' "$VDF_PATH" 2>/dev/null || true)

        if [ ${#LIB_PATHS[@]} -gt 1 ]; then
            declare -A __seen=()
            __unique=()
            for __p in "${LIB_PATHS[@]}"; do
                __pt=$(echo "$__p" | xargs)
                if [ -n "$__pt" ] && [ -z "${__seen[$__pt]}" ]; then
                    __seen[$__pt]=1
                    __unique+=("$__pt")
                fi
            done
            LIB_PATHS=("${__unique[@]}")
            unset __seen __unique __p __pt
        fi

        [ ${#LIB_PATHS[@]} -eq 0 ] && LIB_PATHS=("$HOME/.steam/steam")

        declare -a GAMES=()
        declare -a GAME_FULL_PATHS=()
        counter=1

        for lib in "${LIB_PATHS[@]}"; do
            lib=$(eval echo "$lib")
            COMMON_DIR="$lib/steamapps/common"
            if [ -d "$COMMON_DIR" ]; then
                for dir in "$COMMON_DIR"/*; do
                    if [ -d "$dir" ]; then
                        GAMES+=("$(basename "$dir")")
                        GAME_FULL_PATHS+=("$dir")
                        print_colored $PURPLE "  [$counter] 📂 $(basename "$dir")  (in $lib)"
                        ((counter++))
                    fi
                done
            fi
        done

        if [ ${#GAMES[@]} -eq 0 ]; then
            print_colored $RED "❌ No games found in any Steam library"
            print_colored $YELLOW "💡 Use -g <game_path> to specify the game directory directly"
            exit 1
        fi

        print_separator
        print_colored $YELLOW "💡 Select a game, or press Enter to exit:"
        read -p "Enter game number (1-${#GAMES[@]}): " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#GAMES[@]} ]; then
            SELECTED_INDEX=$((selection - 1))
            GAME_ROOT="${GAME_FULL_PATHS[$SELECTED_INDEX]}"
            print_colored $GREEN "✅ Selected: ${GAMES[$SELECTED_INDEX]}"
        else
            print_colored $YELLOW "👋 No valid selection made. Exiting..."
            exit 0
        fi
    fi
fi

print_colored $BLUE "🎮 Game root: $GAME_ROOT"

# ── Resolve local output directory (Dependencies or deps) ────────────────────
if [ -n "$OVERRIDE_OUTPUT" ]; then
    OUTPUT_DIR="$OVERRIDE_OUTPUT"
    print_colored $BLUE "📁 Using override output directory: $OUTPUT_DIR"
elif [ -d "Dependencies" ]; then
    OUTPUT_DIR="Dependencies"
    print_colored $BLUE "📁 Using existing Dependencies directory as output"
elif [ -d "deps" ]; then
    OUTPUT_DIR="deps"
    print_colored $BLUE "📁 Using existing deps directory as output"
else
    print_colored $RED "❌ No Dependencies or deps directory found in: $SRC_DIR"
    print_colored $YELLOW "💡 Create one of those directories first, or use -o to specify an output directory"
    exit 1
fi

if [ ! -d "$OUTPUT_DIR" ]; then
    print_colored $YELLOW "🔧 Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR" || { print_colored $RED "❌ Failed to create $OUTPUT_DIR"; exit 1; }
fi

# ── deps.txt ─────────────────────────────────────────────────────────────────
if [ ! -f "deps.txt" ]; then
    print_colored $RED "❌ deps.txt not found in: $SRC_DIR"
    print_colored $YELLOW "💡 Create a deps.txt with one DLL filename per line"
    exit 1
fi

print_separator
print_colored $YELLOW "📋 Processing deps.txt..."
print_separator

COPIED_COUNT=0
FAILED_COUNT=0

while IFS= read -r dll_name || [ -n "$dll_name" ]; do
    if [ -z "$dll_name" ]; then continue; fi
    dll_name=$(echo "$dll_name" | tr -d '\n\r' | xargs)
    if [ -z "$dll_name" ] || [[ "$dll_name" == \#* ]]; then continue; fi

    print_colored $CYAN "🔍 Searching for: $dll_name"

    FOUND_PATH=$(find "$GAME_ROOT" -name "$dll_name" -type f | head -1)

    if [ -n "$FOUND_PATH" ]; then
        print_colored $BLUE "   ├─ Found: $FOUND_PATH"

        cp "$FOUND_PATH" "$OUTPUT_DIR/"

        if [ $? -eq 0 ]; then
            print_colored $GREEN "   └─ ✅ Copied successfully!"
            COPIED_FILE="$OUTPUT_DIR/$dll_name"
            if [ -f "$COPIED_FILE" ]; then
                FILE_SIZE=$(du -h "$COPIED_FILE" | cut -f1)
                print_colored $PURPLE "      Size: $FILE_SIZE"
            fi
            ((COPIED_COUNT++))
        else
            print_colored $RED "   └─ ❌ Failed to copy!"
            ((FAILED_COUNT++))
        fi
    else
        print_colored $RED "   └─ ❌ Not found under game directory"
        ((FAILED_COUNT++))
    fi
    echo ""
done < deps.txt

print_separator
print_colored $CYAN "📊 Summary: $COPIED_COUNT copied, $FAILED_COUNT failed"
print_colored $BLUE "📁 Output directory: $OUTPUT_DIR"
print_separator

if [ $FAILED_COUNT -gt 0 ]; then
    print_colored $YELLOW "⚠️  Some DLLs could not be found. Check that they exist under: $GAME_ROOT"
    exit 1
fi

print_colored $GREEN "🎉 All dependencies copied successfully!"
print_separator
