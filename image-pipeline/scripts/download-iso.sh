#!/usr/bin/env bash
# Download Windows ISO images from Microsoft.
#
# Uses Microsoft's software download connector API for consumer editions
# (Windows 10/11) and the eval center for Server editions.
# ARM64 ISOs are fetched via the UUP dump API.
#
# Adapted from quickemu/Mido (Elliot Killick, MIT license).
#
# Usage:
#   download-iso.sh [options]
#
# Options:
#   --version VER       Windows version: 10 | 11 | server-2022 | server-2025 (default: 11)
#   --lang LANG         Language (default: "English (United States)")
#   --arch ARCH         Architecture: x86_64 | arm64 (default: auto-detect)
#   --output-dir DIR    Download directory (default: current directory)
#   --list-versions     List available Windows versions
#   --list-langs        List available languages for a version
#   --help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# Defaults
WIN_VERSION="11"
LANG_NAME="English (United States)"
ARCH=""
OUTPUT_DIR="."
LIST_VERSIONS=false
LIST_LANGS=false

USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
MS_DOWNLOAD_PROFILE="606624d44113"

# --- Available versions and languages ---

CONSUMER_VERSIONS=(10 11)
SERVER_VERSIONS=(server-2022 server-2025 server-2019 server-2016)

CONSUMER_LANGUAGES=(
    "Arabic"
    "Brazilian Portuguese"
    "Bulgarian"
    "Chinese (Simplified)"
    "Chinese (Traditional)"
    "Croatian"
    "Czech"
    "Danish"
    "Dutch"
    "English (United States)"
    "English International"
    "Estonian"
    "Finnish"
    "French"
    "French Canadian"
    "German"
    "Greek"
    "Hebrew"
    "Hungarian"
    "Italian"
    "Japanese"
    "Korean"
    "Latvian"
    "Lithuanian"
    "Norwegian"
    "Polish"
    "Portuguese"
    "Romanian"
    "Russian"
    "Serbian Latin"
    "Slovak"
    "Slovenian"
    "Spanish"
    "Spanish (Mexico)"
    "Swedish"
    "Thai"
    "Turkish"
    "Ukrainian"
)

SERVER_LANGUAGES=(
    "English (United States)"
    "Chinese (Simplified)"
    "French"
    "German"
    "Italian"
    "Japanese"
    "Korean"
    "Portuguese (Brazil)"
    "Russian"
    "Spanish"
)

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)       WIN_VERSION="$2"; shift 2 ;;
            --lang)          LANG_NAME="$2"; shift 2 ;;
            --arch)          ARCH="$2"; shift 2 ;;
            --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
            --list-versions) LIST_VERSIONS=true; shift ;;
            --list-langs)    LIST_LANGS=true; shift ;;
            --help)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)               die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$ARCH" ]]; then
        ARCH=$(detect_arch)
    fi
}

# --- List commands ---

do_list_versions() {
    bold "Available Windows versions:"
    echo ""
    echo "  Consumer:"
    for v in "${CONSUMER_VERSIONS[@]}"; do
        echo "    $v"
    done
    echo ""
    echo "  Server (evaluation):"
    for v in "${SERVER_VERSIONS[@]}"; do
        echo "    $v"
    done
    echo ""
    echo "  Architecture support:"
    echo "    x86_64: all versions"
    echo "    arm64:  10, 11 (via UUP dump)"
}

do_list_langs() {
    if [[ "$WIN_VERSION" == server-* ]]; then
        bold "Available languages for $WIN_VERSION:"
        printf '  %s\n' "${SERVER_LANGUAGES[@]}"
    else
        bold "Available languages for Windows $WIN_VERSION:"
        printf '  %s\n' "${CONSUMER_LANGUAGES[@]}"
    fi
}

# --- Consumer Windows download (10/11 x86_64) ---

download_consumer_x86_64() {
    local version="$1"

    require_cmd curl jq uuidgen

    local url="https://www.microsoft.com/en-us/software-download/windows${version}"
    if [[ "$version" == "10" ]]; then
        url="${url}ISO"
    fi

    local session_id
    session_id="$(uuidgen)"

    info "Fetching download page for Windows $version..."
    local page_html
    page_html=$(curl --disable --silent --user-agent "$USER_AGENT" \
        --header "Accept:" --max-filesize 1M --fail \
        --proto =https --tlsv1.2 --http1.1 -- "$url") || \
        die "Failed to fetch download page. Microsoft may have changed the URL."

    # Extract product edition ID
    local product_id
    product_id=$(echo "$page_html" | grep -Eo '<option value="[0-9]+">Windows' | \
        cut -d '"' -f 2 | head -n 1 | tr -cd '0-9' | head -c 16)
    [[ -n "$product_id" ]] || die "Could not find product edition ID on download page"
    info "Product edition ID: $product_id"

    # Permit session
    curl --disable --silent --output /dev/null --user-agent "$USER_AGENT" \
        --header "Accept:" --max-filesize 100K --fail \
        --proto =https --tlsv1.2 --http1.1 -- \
        "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$session_id" || \
        warn "Session permit request failed (may still work)"

    # Get language -> SKU ID mapping
    info "Getting language SKU for: $LANG_NAME"
    local sku_json
    sku_json=$(curl --disable --silent --fail --max-filesize 100K \
        --proto =https --tlsv1.2 --http1.1 \
        "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=${MS_DOWNLOAD_PROFILE}&ProductEditionId=${product_id}&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}") || \
        die "Failed to get SKU information"

    local sku_id
    sku_id=$(echo "$sku_json" | jq -r \
        '.Skus[] | select(.LocalizedLanguage=="'"$LANG_NAME"'" or .Language=="'"$LANG_NAME"'").Id')
    [[ -n "$sku_id" ]] || die "Language '$LANG_NAME' not found. Use --list-langs to see available options."
    info "SKU ID: $sku_id"

    # Get download link
    info "Requesting download link..."
    local link_json
    link_json=$(curl --disable --silent --fail \
        --referer "$url" \
        "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=${MS_DOWNLOAD_PROFILE}&productEditionId=undefined&SKU=${sku_id}&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}") || \
        die "Failed to get download links"

    if echo "$link_json" | grep -q "Sentinel marked this request as rejected"; then
        die "Microsoft blocked the download request based on your IP. Try again later or use a VPN."
    fi

    # Extract the 64-bit ISO link
    local download_url
    download_url=$(echo "$link_json" | jq -r \
        '.ProductDownloadLinks[] | select(.DownloadType=="IsoX64").Uri // empty')

    if [[ -z "$download_url" ]]; then
        # Fallback: try any ISO link
        download_url=$(echo "$link_json" | jq -r \
            '.ProductDownloadLinks[0].Uri // empty')
    fi

    [[ -n "$download_url" ]] || die "No download URL found in Microsoft's response"

    # Download
    local filename="Win${version}_${LANG_NAME// /_}_x86_64.iso"
    filename=$(echo "$filename" | tr -d '()')
    local output_path="$OUTPUT_DIR/$filename"

    info "Downloading: $filename"
    info "URL: ${download_url:0:80}..."
    mkdir -p "$OUTPUT_DIR"

    curl --disable --location --fail --progress-bar \
        --output "$output_path" -- "$download_url" || \
        die "Download failed"

    local size
    size=$(stat -c%s "$output_path" 2>/dev/null || stat -f%z "$output_path" 2>/dev/null || echo "0")
    ok "Downloaded: $output_path ($(human_size "$size"))"
    echo "$output_path"
}

# --- ARM64 consumer Windows via UUP dump ---

# Map display language name to BCP-47 language code
lang_name_to_code() {
    case "$1" in
        "English (United States)") echo "en-us" ;;
        "English International")   echo "en-gb" ;;
        "Chinese (Simplified)")    echo "zh-cn" ;;
        "Chinese (Traditional)")   echo "zh-tw" ;;
        "French")                  echo "fr-fr" ;;
        "German")                  echo "de-de" ;;
        "Italian")                 echo "it-it" ;;
        "Japanese")                echo "ja-jp" ;;
        "Korean")                  echo "ko-kr" ;;
        "Portuguese")              echo "pt-pt" ;;
        "Brazilian Portuguese")    echo "pt-br" ;;
        "Russian")                 echo "ru-ru" ;;
        "Spanish")                 echo "es-es" ;;
        "Spanish (Mexico)")        echo "es-mx" ;;
        "Arabic")                  echo "ar-sa" ;;
        "Bulgarian")               echo "bg-bg" ;;
        "Croatian")                echo "hr-hr" ;;
        "Czech")                   echo "cs-cz" ;;
        "Danish")                  echo "da-dk" ;;
        "Dutch")                   echo "nl-nl" ;;
        "Estonian")                echo "et-ee" ;;
        "Finnish")                 echo "fi-fi" ;;
        "French Canadian")         echo "fr-ca" ;;
        "Greek")                   echo "el-gr" ;;
        "Hebrew")                  echo "he-il" ;;
        "Hungarian")               echo "hu-hu" ;;
        "Latvian")                 echo "lv-lv" ;;
        "Lithuanian")              echo "lt-lt" ;;
        "Norwegian")               echo "nb-no" ;;
        "Polish")                  echo "pl-pl" ;;
        "Romanian")                echo "ro-ro" ;;
        "Serbian Latin")           echo "sr-latn-rs" ;;
        "Slovak")                  echo "sk-sk" ;;
        "Slovenian")               echo "sl-si" ;;
        "Swedish")                 echo "sv-se" ;;
        "Thai")                    echo "th-th" ;;
        "Turkish")                 echo "tr-tr" ;;
        "Ukrainian")               echo "uk-ua" ;;
        *)
            echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
            ;;
    esac
}

uup_find_arm64_build() {
    local version="$1"

    local search_query="windows ${version} arm64"
    local api_url="https://api.uupdump.net/listid.php"

    local builds_json
    builds_json=$(curl --disable --silent --fail \
        "${api_url}?search=${search_query// /+}&sortByDate=1") || \
        die "Failed to query UUP dump API"

    local build_id
    build_id=$(echo "$builds_json" | jq -r \
        '[.response.builds[] | select(.arch=="arm64")] | first | .uuid // empty')

    if [[ -z "$build_id" ]]; then
        die "No ARM64 build found on UUP dump for Windows $version"
    fi

    local build_title
    build_title=$(echo "$builds_json" | jq -r \
        '[.response.builds[] | select(.arch=="arm64")] | first | .title // "unknown"')

    info "Found build: $build_title"
    info "Build ID: $build_id"
    echo "$build_id"
}

uup_get_download_urls() {
    local build_id="$1"
    local lang_code="$2"
    local edition="${3:-professional}"

    local api_url="https://api.uupdump.net/get.php"
    local pkg_json
    pkg_json=$(curl --disable --silent --fail \
        "${api_url}?id=${build_id}&lang=${lang_code}&edition=${edition}") || \
        die "Failed to get package list from UUP dump API"

    # Check for API errors
    local api_error
    api_error=$(echo "$pkg_json" | jq -r '.response.error // empty')
    if [[ -n "$api_error" ]]; then
        die "UUP dump API error: $api_error"
    fi

    echo "$pkg_json"
}

uup_download_files() {
    local pkg_json="$1"
    local download_dir="$2"

    mkdir -p "$download_dir"

    local file_count
    file_count=$(echo "$pkg_json" | jq -r '.response.files | length')
    info "Downloading $file_count UUP files..."

    local downloaded=0
    local failed=0

    # Download each file
    echo "$pkg_json" | jq -r '.response.files | to_entries[] | "\(.key)\t\(.value.url)\t\(.value.sha1)\t\(.value.size)"' | \
    while IFS=$'\t' read -r filename url sha1 size; do
        local dest="$download_dir/$filename"

        # Skip if already downloaded and correct size
        if [[ -f "$dest" ]]; then
            local existing_size
            existing_size=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo "0")
            if [[ "$existing_size" == "$size" ]]; then
                downloaded=$((downloaded + 1))
                continue
            fi
        fi

        info "  [$((downloaded + failed + 1))/$file_count] $filename ($(human_size "$size"))"
        if retry 3 curl --disable --silent --location --fail \
            --output "$dest" -- "$url"; then
            downloaded=$((downloaded + 1))

            # Verify SHA-1 if available
            if [[ -n "$sha1" && "$sha1" != "null" ]] && command -v sha1sum &>/dev/null; then
                local actual_sha1
                actual_sha1=$(sha1sum "$dest" | awk '{print $1}')
                if [[ "$actual_sha1" != "$sha1" ]]; then
                    warn "SHA-1 mismatch for $filename (expected: ${sha1:0:12}..., got: ${actual_sha1:0:12}...)"
                fi
            fi
        else
            err "  Failed to download: $filename"
            failed=$((failed + 1))
        fi
    done

    ok "Downloaded UUP files to $download_dir"
}

uup_convert_to_iso() {
    local download_dir="$1"
    local output_path="$2"
    local edition="${3:-professional}"

    # Check for required tools
    require_cmd cabextract wimlib-imagex

    if ! command -v xorriso &>/dev/null && ! command -v mkisofs &>/dev/null; then
        die "Need xorriso or mkisofs to create ISO"
    fi

    local work_dir
    work_dir=$(mktemp -d "${download_dir}/convert-XXXXXX")

    info "Extracting CAB files..."
    local cab_count=0
    for cab in "$download_dir"/*.cab; do
        [[ -f "$cab" ]] || continue
        cabextract -d "$work_dir" -q "$cab" 2>/dev/null || true
        cab_count=$((cab_count + 1))
    done

    # Extract ESD files (newer UUP format)
    for esd in "$download_dir"/*.esd "$download_dir"/*.ESD; do
        [[ -f "$esd" ]] || continue
        local esd_name
        esd_name=$(basename "$esd")
        info "  Processing: $esd_name"

        # Check if this is the main install ESD
        local image_count
        image_count=$(wimlib-imagex info "$esd" 2>/dev/null | grep -c "^Index:" || echo "0")
        if [[ "$image_count" -gt 1 ]]; then
            # Multi-image ESD — this is the install image
            info "  Found install ESD with $image_count images"

            # Find the edition index
            local target_index=""
            local idx=1
            while [[ $idx -le $image_count ]]; do
                local img_name
                img_name=$(wimlib-imagex info "$esd" "$idx" 2>/dev/null | grep "^Name:" | sed 's/^Name:[[:space:]]*//' || true)
                local img_flags
                img_flags=$(wimlib-imagex info "$esd" "$idx" 2>/dev/null | grep "^Flags:" | sed 's/^Flags:[[:space:]]*//' || true)

                if echo "$img_flags" | grep -qi "$edition"; then
                    target_index=$idx
                    info "  Found edition '$edition' at index $idx: $img_name"
                    break
                fi
                idx=$((idx + 1))
            done

            if [[ -z "$target_index" ]]; then
                # Fall back to last image (usually the most complete edition)
                target_index=$image_count
                warn "  Edition '$edition' not found by flag; using index $target_index"
            fi

            # Export the target edition to install.wim
            info "  Exporting install.wim (this may take several minutes)..."
            wimlib-imagex export "$esd" "$target_index" \
                "$work_dir/sources/install.wim" --compress=LZX 2>/dev/null || \
                die "Failed to export install.wim from ESD"
        else
            # Single-image ESD — likely boot.wim or a component
            if echo "$esd_name" | grep -qi "boot"; then
                mkdir -p "$work_dir/sources"
                wimlib-imagex export "$esd" all \
                    "$work_dir/sources/boot.wim" --compress=LZX 2>/dev/null || true
            fi
        fi
    done

    # Verify we have the essential files
    if [[ ! -f "$work_dir/sources/install.wim" ]]; then
        # Try to find install.wim in extracted CABs
        local found_wim
        found_wim=$(find "$work_dir" -name 'install.wim' -print -quit 2>/dev/null || true)
        if [[ -n "$found_wim" ]]; then
            mkdir -p "$work_dir/sources"
            mv "$found_wim" "$work_dir/sources/install.wim"
        else
            die "Could not produce install.wim from UUP files. The build may require the uup-dump converter tool."
        fi
    fi

    # Create boot structure if missing
    if [[ ! -f "$work_dir/sources/boot.wim" ]]; then
        local found_boot
        found_boot=$(find "$work_dir" -name 'boot.wim' -print -quit 2>/dev/null || true)
        if [[ -n "$found_boot" ]]; then
            mkdir -p "$work_dir/sources"
            mv "$found_boot" "$work_dir/sources/boot.wim"
        fi
    fi

    # Create ISO
    info "Creating ISO image..."
    mkdir -p "$(dirname "$output_path")"

    if command -v xorriso &>/dev/null; then
        xorriso -as mkisofs \
            -iso-level 3 -udf \
            -o "$output_path" "$work_dir" 2>&1 | tail -3
    else
        mkisofs -iso-level 4 -udf \
            -o "$output_path" "$work_dir" 2>&1 | tail -3
    fi

    rm -rf "$work_dir"

    local size
    size=$(stat -c%s "$output_path" 2>/dev/null || stat -f%z "$output_path" 2>/dev/null || echo "0")
    ok "Created ARM64 ISO: $output_path ($(human_size "$size"))"
}

download_consumer_arm64() {
    local version="$1"

    require_cmd curl jq

    info "ARM64 ISOs are not directly available from Microsoft."
    info "Using UUP dump API to find the latest ARM64 build..."

    local build_id
    build_id=$(uup_find_arm64_build "$version")

    local lang_code
    lang_code=$(lang_name_to_code "$LANG_NAME")
    info "Language: $LANG_NAME ($lang_code)"

    # Get package URLs from UUP dump
    local edition="professional"
    info "Edition: $edition"

    local pkg_json
    pkg_json=$(uup_get_download_urls "$build_id" "$lang_code" "$edition")

    local filename="Win${version}_arm64_${lang_code}.iso"
    local output_path="$OUTPUT_DIR/$filename"
    local uup_download_dir="$OUTPUT_DIR/.uup-${build_id}"

    echo ""
    bold "ARM64 ISO Build"
    echo ""

    # Check if we have cabextract + wimlib for local conversion
    local can_convert=true
    for cmd in cabextract wimlib-imagex; do
        if ! command -v "$cmd" &>/dev/null; then
            can_convert=false
            break
        fi
    done

    if [[ "$can_convert" == true ]]; then
        info "Required tools found. Building ISO locally..."
        echo ""

        # Download UUP files
        uup_download_files "$pkg_json" "$uup_download_dir"

        # Convert to ISO
        uup_convert_to_iso "$uup_download_dir" "$output_path" "$edition"

        # Clean up UUP download directory
        rm -rf "$uup_download_dir"

        echo "$output_path"
    else
        # Fallback: provide manual instructions
        local uup_url="https://uupdump.net/selectlang.php?id=${build_id}"

        warn "Missing tools for local ISO build (need: cabextract, wimlib-imagex)"
        echo ""
        info "Install them with:"
        echo "    sudo apt install cabextract wimlib-tools    # Debian/Ubuntu"
        echo "    sudo dnf install cabextract wimlib-utils    # Fedora"
        echo "    sudo pacman -S cabextract wimlib            # Arch"
        echo ""
        info "Then re-run: iwt image download --version $version --arch arm64"
        echo ""
        info "Or download manually:"
        echo ""
        echo "  1. Visit: $uup_url"
        echo "  2. Select language: $LANG_NAME"
        echo "  3. Select edition: Pro"
        echo "  4. Choose 'Download and convert to ISO'"
        echo "  5. Run the downloaded script to build the ISO"
        echo ""
        echo "  Alternatively, on Linux:"
        echo ""
        echo "    git clone https://github.com/uup-dump/converter"
        echo "    cd converter"
        echo "    ./convert.sh wubi ${build_id} ${lang_code} professional"
        echo ""
        info "Once you have the ISO, run:"
        echo "    iwt image build --iso <path-to-iso> --arch arm64"
        echo ""

        echo "$uup_url"
    fi
}

# --- Windows Server evaluation download ---

download_server() {
    local version="$1"

    require_cmd curl

    # Map version to eval center slug
    local eval_slug
    case "$version" in
        server-2025) eval_slug="windows-server-2025" ;;
        server-2022) eval_slug="windows-server-2022" ;;
        server-2019) eval_slug="windows-server-2019" ;;
        server-2016) eval_slug="windows-server-2016" ;;
        *)           die "Unknown server version: $version" ;;
    esac

    local url="https://www.microsoft.com/en-us/evalcenter/download-${eval_slug}"

    info "Fetching eval center page for $version..."
    local page_html
    page_html=$(curl --disable --silent --location --max-filesize 1M --fail \
        --proto =https --tlsv1.2 --http1.1 -- "$url") || \
        die "Failed to fetch eval center page"

    [[ -n "$page_html" ]] || die "Empty response from eval center"

    # Map language to culture code
    local culture=""
    case "$LANG_NAME" in
        "English (United States)") culture="en-us" ;;
        "Chinese (Simplified)")    culture="zh-cn" ;;
        "French")                  culture="fr-fr" ;;
        "German")                  culture="de-de" ;;
        "Italian")                 culture="it-it" ;;
        "Japanese")                culture="ja-jp" ;;
        "Korean")                  culture="ko-kr" ;;
        "Portuguese (Brazil)")     culture="pt-br" ;;
        "Russian")                 culture="ru-ru" ;;
        "Spanish")                 culture="es-es" ;;
        *)                         culture="en-us"
                                   warn "Language '$LANG_NAME' not available for Server; falling back to English" ;;
    esac

    local download_url
    download_url=$(echo "$page_html" | \
        grep -oP 'https://go\.microsoft\.com/fwlink/p/\?LinkID=[0-9]+&clcid=0x[0-9a-f]+&culture='"$culture"'&country=[A-Z]+' | \
        head -1)

    if [[ -z "$download_url" ]]; then
        # Fallback: try to find any ISO link
        download_url=$(echo "$page_html" | \
            grep -oP 'https://go\.microsoft\.com/fwlink/p/\?LinkID=[0-9]+[^"]*' | \
            head -1)
    fi

    if [[ -z "$download_url" ]]; then
        # Second fallback: direct ISO links
        download_url=$(echo "$page_html" | \
            grep -oP 'https://[^"]+\.iso' | \
            grep -i "$culture" | head -1)
    fi

    if [[ -z "$download_url" ]]; then
        die "Could not find download link for $version ($LANG_NAME). The eval center page may have changed."
    fi

    local filename="${eval_slug}_${culture}_${ARCH}.iso"
    local output_path="$OUTPUT_DIR/$filename"

    info "Downloading: $filename"
    mkdir -p "$OUTPUT_DIR"

    curl --disable --location --fail --progress-bar \
        --output "$output_path" -- "$download_url" || \
        die "Download failed"

    local size
    size=$(stat -c%s "$output_path" 2>/dev/null || stat -f%z "$output_path" 2>/dev/null || echo "0")
    ok "Downloaded: $output_path ($(human_size "$size"))"
    echo "$output_path"
}

# --- Main ---

main() {
    parse_args "$@"

    if [[ "$LIST_VERSIONS" == true ]]; then
        do_list_versions
        exit 0
    fi

    if [[ "$LIST_LANGS" == true ]]; then
        do_list_langs
        exit 0
    fi

    echo ""
    bold "IWT ISO Download"
    info "Version:  $WIN_VERSION"
    info "Language: $LANG_NAME"
    info "Arch:     $ARCH"
    info "Output:   $OUTPUT_DIR"
    echo ""

    if [[ "$WIN_VERSION" == server-* ]]; then
        download_server "$WIN_VERSION"
    elif [[ "$ARCH" == "arm64" ]]; then
        download_consumer_arm64 "$WIN_VERSION"
    else
        download_consumer_x86_64 "$WIN_VERSION"
    fi
}

main "$@"
