#!/usr/bin/env bash
set -eo pipefail

# Archive to AppImage Converter Entrypoint Script
# Handles downloading, extracting, detecting binary, formatting AppDir, and packaging with appimagetool.

INPUT_URLS="${INPUT_URLS:-}"
INPUT_APP_NAME="${INPUT_APP_NAME:-}"
INPUT_EXECUTABLE_PATH="${INPUT_EXECUTABLE_PATH:-}"
INPUT_ICON_URL="${INPUT_ICON_URL:-}"
INPUT_FAIL_FAST="${INPUT_FAIL_FAST:-false}"
ACTION_PATH="${ACTION_PATH:-$(pwd)}"

# Create outputs directory
outputs_dir="$(pwd)/appimages_out"
mkdir -p "$outputs_dir"
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "appimages_dir=$outputs_dir" >> "$GITHUB_OUTPUT"
fi

# 1. Install dependencies
echo "::group::Installing extraction tools and dependencies..."
sudo apt-get update -y || true
sudo apt-get install -y p7zip-full unrar xz-utils file binutils curl wget || true
echo "::endgroup::"

# 2. Download and extract appimagetool (FUSE-free version)
echo "::group::Setting up appimagetool..."
cd /tmp
wget -q -O appimagetool-x86_64.AppImage https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool-x86_64.AppImage
./appimagetool-x86_64.AppImage --appimage-extract > /dev/null
APPIMAGETOOL_BIN="/tmp/squashfs-root/AppRun"
cd - > /dev/null
echo "::endgroup::"

# 3. Clean and parse URLs
urls_clean=$(echo "$INPUT_URLS" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d')

success_count=0
failure_count=0
success_list=()
failure_list=()

# Process each URL
while read -r url; do
  [ -z "$url" ] && continue
  echo "============================================="
  echo "Processing URL: $url"
  echo "============================================="

  # Generate base name for the archive
  archive_name=$(basename "$url" | cut -d? -f1)
  if [ -z "$archive_name" ] || [ "$archive_name" = "/" ]; then
    archive_name="archive_$(date +%s)"
  fi

  # A. Download the archive
  echo "Downloading file..."
  download_file="/tmp/downloaded_$archive_name"
  
  # Check connection/download health
  set +e
  http_code=$(curl -sSL -w "%{http_code}" -o "$download_file" "$url")
  curl_exit=$?
  set -e

  if [ "$curl_exit" -ne 0 ] || [ "$http_code" -lt 200 ] || [ "$http_code" -ge 400 ]; then
    echo "::error::Download failed for $url."
    echo "Curl exit code: $curl_exit, HTTP status code: $http_code"
    failure_list+=("$url (Download Failed - HTTP $http_code)")
    ((failure_count++))
    [ "$INPUT_FAIL_FAST" = "true" ] && exit 1
    continue
  fi

  # B. Extract the archive
  extract_dir="/tmp/extracted_$archive_name"
  mkdir -p "$extract_dir"
  
  echo "Detecting MIME type and extracting archive..."
  file_type=$(file -b --mime-type "$download_file" || echo "unknown")
  echo "Detected MIME-type: $file_type"

  extract_success=false

  set +e
  case "$file_type" in
    application/zip|application/x-zip-compressed)
      unzip -q -o "$download_file" -d "$extract_dir" && extract_success=true
      ;;
    application/x-tar|application/x-gzip|application/gzip|application/x-bzip2|application/x-xz|application/x-lzma|application/x-compress|application/x-tar-compressed)
      tar -xf "$download_file" -C "$extract_dir" && extract_success=true
      ;;
    application/x-rar|application/x-rar-compressed)
      if command -v unrar >/dev/null 2>&1; then
        unrar x -o+ -inul "$download_file" "$extract_dir" && extract_success=true
      fi
      if [ "$extract_success" = "false" ]; then
        7z x -y -o"$extract_dir" "$download_file" >/dev/null && extract_success=true
      fi
      ;;
    application/x-7z-compressed)
      7z x -y -o"$extract_dir" "$download_file" >/dev/null && extract_success=true
      ;;
  esac

  # Fallback to extension check if mime-type detection was not decisive
  if [ "$extract_success" = "false" ]; then
    echo "Attempting fallback extraction based on file extension..."
    case "$archive_name" in
      *.zip)
        unzip -q -o "$download_file" -d "$extract_dir" && extract_success=true
        ;;
      *.tar.xz|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar)
        tar -xf "$download_file" -C "$extract_dir" && extract_success=true
        ;;
      *.rar)
        7z x -y -o"$extract_dir" "$download_file" >/dev/null && extract_success=true
        ;;
      *.7z)
        7z x -y -o"$extract_dir" "$download_file" >/dev/null && extract_success=true
        ;;
    esac
  fi

  # Final general fallback try
  if [ "$extract_success" = "false" ]; then
    echo "MIME-type/extension extraction failed. Trying general extraction fallbacks..."
    if 7z x -y -o"$extract_dir" "$download_file" >/dev/null 2>&1; then
      extract_success=true
    elif tar -xf "$download_file" -C "$extract_dir" 2>/dev/null; then
      extract_success=true
    elif unzip -q -o "$download_file" -d "$extract_dir" 2>/dev/null; then
      extract_success=true
    fi
  fi
  set -e

  if [ "$extract_success" = "false" ]; then
    echo "::error::Could not extract archive from $url. The format might be unsupported, or the file is corrupted."
    failure_list+=("$url (Extraction Failed)")
    ((failure_count++))
    rm -f "$download_file"
    [ "$INPUT_FAIL_FAST" = "true" ] && exit 1
    continue
  fi

  # C. Clean up single-folder wrappers (normalize directory)
  # If extraction contains exactly one sub-directory and no other files, step inside
  num_items=$(find "$extract_dir" -maxdepth 1 -mindepth 1 | wc -l)
  if [ "$num_items" -eq 1 ]; then
    single_item=$(find "$extract_dir" -maxdepth 1 -mindepth 1)
    if [ -d "$single_item" ]; then
      app_dir="$single_item"
    else
      app_dir="$extract_dir"
    fi
  else
    app_dir="$extract_dir"
  fi
  echo "Application root folder resolved to: $app_dir"

  # D. Determine App Name & Slug
  total_urls=$(echo "$urls_clean" | wc -l)
  if [ -n "$INPUT_APP_NAME" ]; then
    if [ "$total_urls" -eq 1 ]; then
      app_name="$INPUT_APP_NAME"
    else
      app_name="${INPUT_APP_NAME}_$(echo "$archive_name" | sed -E 's/\.(tar\.(xz|gz|bz2)|tgz|zip|rar|7z)$//I')"
    fi
  else
    app_name=$(echo "$archive_name" | sed -E 's/\.(tar\.(xz|gz|bz2)|tgz|zip|rar|7z)$//I')
  fi
  app_name_slug=$(echo "$app_name" | sed 's/[^a-zA-Z0-9_-]/_/g' | tr '[:upper:]' '[:lower:]')

  # E. Auto-detect main executable
  binary_path=""

  # Heuristic 1: User-specified executable path
  if [ -n "$INPUT_EXECUTABLE_PATH" ]; then
    if [ -f "$app_dir/$INPUT_EXECUTABLE_PATH" ]; then
      binary_path="$app_dir/$INPUT_EXECUTABLE_PATH"
      echo "Using manually specified executable: $binary_path"
    else
      echo "::warning::Manually specified executable_path '$INPUT_EXECUTABLE_PATH' not found at '$app_dir/$INPUT_EXECUTABLE_PATH'."
    fi
  fi

  # Heuristic 2: Look for existing .desktop files and parse Exec key
  if [ -z "$binary_path" ]; then
    desktop_files=$(find "$app_dir" -type f -name "*.desktop")
    if [ -n "$desktop_files" ]; then
      for df in $desktop_files; do
        exec_val=$(grep -m1 "^Exec=" "$df" | cut -d= -f2- | awk '{print $1}')
        if [ -n "$exec_val" ]; then
          # Search for file matching this binary name
          found_bin=$(find "$app_dir" -type f -name "$exec_val" -print -quit)
          if [ -n "$found_bin" ]; then
            binary_path="$found_bin"
            echo "Detected executable via desktop entry ($df): $binary_path"
            break
          fi
        fi
      done
    fi
  fi

  # Heuristic 3: Look for ELF binaries matching the slug/app name
  if [ -z "$binary_path" ]; then
    found_bin=$(find "$app_dir" -type f -name "$app_name_slug" -print -quit)
    if [ -z "$found_bin" ]; then
      found_bin=$(find "$app_dir" -type f -iname "*$app_name_slug*" -print -quit)
    fi
    if [ -n "$found_bin" ]; then
      if file -b "$found_bin" | grep -qE "ELF|executable|script"; then
        binary_path="$found_bin"
        echo "Detected executable matching app name: $binary_path"
      fi
    fi
  fi

  # Heuristic 4: Search for any ELF executable in standard locations (bin/ or root)
  if [ -z "$binary_path" ]; then
    elf_binaries=$(find "$app_dir" -type f -exec sh -c 'file -b "$1" | grep -q "ELF.*executable"' _ {} \; -print)
    if [ -n "$elf_binaries" ]; then
      best_elf=""
      for elf in $elf_binaries; do
        dir_of_elf=$(dirname "$elf")
        if [ "$dir_of_elf" = "$app_dir" ] || [ "$(basename "$dir_of_elf")" = "bin" ]; then
          best_elf="$elf"
          break
        fi
      done
      if [ -z "$best_elf" ]; then
        best_elf=$(echo "$elf_binaries" | head -n 1)
      fi
      binary_path="$best_elf"
      echo "Detected ELF executable: $binary_path"
    fi
  fi

  # Heuristic 5: Search for executable scripts (shell, Python, etc.) at root/bin
  if [ -z "$binary_path" ]; then
    scripts=$(find "$app_dir" -maxdepth 2 -type f -executable -exec sh -c 'file -b "$1" | grep -qE "shell script|Python script"' _ {} \; -print)
    if [ -n "$scripts" ]; then
      binary_path=$(echo "$scripts" | head -n 1)
      echo "Detected executable script: $binary_path"
    fi
  fi

  # SMART ERROR HANDLER: No executable found diagnostics
  if [ -z "$binary_path" ]; then
    echo "::error::Could not auto-detect the main executable in the extracted archive."
    echo "============================================="
    echo "Listing all extracted files to help you debug:"
    find "$app_dir" -maxdepth 3 -not -path '*/.*' | sort
    echo "============================================="
    echo "Troubleshooting suggestions:"
    echo "1. Verify if the archive contains precompiled Linux binaries (not source code)."
    echo "2. Ensure the files inside the archive have executable permissions."
    echo "3. Use the 'executable_path' input parameter to explicitly define the path to the main binary."
    echo "============================================="
    
    failure_list+=("$url (No executable detected)")
    ((failure_count++))
    rm -rf "$extract_dir" "$download_file"
    [ "$INPUT_FAIL_FAST" = "true" ] && exit 1
    continue
  fi

  # F. Detect binary architecture for setting ARCH env variable
  set +e
  binary_info=$(file -b "$binary_path" || echo "unknown")
  set -e
  if echo "$binary_info" | grep -q -E "ARM aarch64|AArch64"; then
    export ARCH="aarch64"
  elif echo "$binary_info" | grep -q "ARM"; then
    export ARCH="armhf"
  elif echo "$binary_info" | grep -q "i386\|i686"; then
    export ARCH="i686"
  else
    export ARCH="x86_64"
  fi
  echo "Configured architecture: $ARCH (extracted from binary type: $binary_info)"

  # G. Build AppDir structure: AppRun, Icon, and Desktop Entry
  # AppRun wrapper
  binary_rel_path=$(realpath --relative-to="$app_dir" "$binary_path")
  cat << EOF > "$app_dir/AppRun"
#!/bin/sh
SELF=\$(dirname "\$(readlink -f "\$0")")
exec "\$SELF/$binary_rel_path" "\$@"
EOF
  chmod +x "$app_dir/AppRun"

  # Icon helper
  icon_found=false
  if [ -n "$INPUT_ICON_URL" ]; then
    icon_ext=$(echo "$INPUT_ICON_URL" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')
    if [ "$icon_ext" != "png" ] && [ "$icon_ext" != "svg" ]; then
      icon_ext="png"
    fi
    echo "Downloading custom icon..."
    set +e
    curl -sSL -f -o "$app_dir/${app_name_slug}.${icon_ext}" "$INPUT_ICON_URL" && icon_found=true
    set -e
  fi

  if [ "$icon_found" = "false" ]; then
    # Look for png/svg in the extracted archive
    img_files=$(find "$app_dir" -type f -name "*.png" -o -name "*.svg" | sort)
    if [ -n "$img_files" ]; then
      best_img=$(echo "$img_files" | head -n 1)
      best_img_ext="${best_img##*.}"
      cp "$best_img" "$app_dir/${app_name_slug}.${best_img_ext}"
      icon_found=true
      echo "Using image found in archive: $best_img"
    fi
  fi

  if [ "$icon_found" = "false" ]; then
    # Generate fallback SVG icon
    echo "Generating generic SVG icon..."
    cat << EOF > "$app_dir/${app_name_slug}.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <circle cx="50" cy="50" r="48" fill="#4A90E2" stroke="#fff" stroke-width="4"/>
  <text x="50" y="58" font-family="sans-serif" font-size="24" font-weight="bold" fill="#fff" text-anchor="middle">${app_name:0:3}</text>
</svg>
EOF
  fi

  # Desktop file helper
  desktop_found=false
  existing_desktop=$(find "$app_dir" -type f -name "*.desktop" -print -quit)
  if [ -n "$existing_desktop" ]; then
    cp "$existing_desktop" "$app_dir/${app_name_slug}.desktop"
    # Update Exec and Icon lines in the copied desktop file to standard values using robust regex
    sed -i -E "s|^[[:space:]]*Exec[[:space:]]*=.*|Exec=AppRun|" "$app_dir/${app_name_slug}.desktop" || true
    sed -i -E "s|^[[:space:]]*Icon[[:space:]]*=.*|Icon=${app_name_slug}|" "$app_dir/${app_name_slug}.desktop" || true
    
    # Clean up deprecated/invalid keys like %k that cause desktop-file-validate to fail
    sed -i "/^Version=/d" "$app_dir/${app_name_slug}.desktop" || true
    
    # Remove all other desktop files at the root of app_dir to prevent appimagetool from getting confused
    find "$app_dir" -maxdepth 1 -name "*.desktop" ! -name "${app_name_slug}.desktop" -delete 2>/dev/null || true
    
    desktop_found=true
    echo "Using and updating desktop file from archive: $existing_desktop"
  fi

  if [ "$desktop_found" = "false" ]; then
    echo "Generating standard desktop entry..."
    cat << EOF > "$app_dir/${app_name_slug}.desktop"
[Desktop Entry]
Type=Application
Name=${app_name}
Exec=AppRun
Icon=${app_name_slug}
Categories=Utility;
Comment=AppImage generated from archive
EOF
  fi

  # H. Package with appimagetool
  output_appimage="$outputs_dir/${app_name_slug}-${ARCH}.AppImage"
  echo "Packaging AppImage..."

  set +e
  err_log="/tmp/appimagetool_err_${app_name_slug}.log"
  "$APPIMAGETOOL_BIN" "$app_dir" "$output_appimage" > /tmp/appimagetool_out.log 2> "$err_log"
  tool_exit=$?
  set -e

  # SMART SELF-HEALING: If packaging failed due to desktop file errors, generate a clean, minimal one and retry!
  if [ "$tool_exit" -ne 0 ] && grep -q -i "desktop" "$err_log" 2>/dev/null; then
    echo "::warning::appimagetool failed due to desktop entry validation. Attempting self-healing fallback by generating a clean, minimal desktop entry..."
    
    # Remove all desktop files at root
    find "$app_dir" -maxdepth 1 -name "*.desktop" -delete 2>/dev/null || true
    
    # Generate minimal, 100% compliant desktop file
    cat << EOF > "$app_dir/${app_name_slug}.desktop"
[Desktop Entry]
Type=Application
Name=${app_name}
Exec=AppRun
Icon=${app_name_slug}
Categories=Utility;
Comment=AppImage generated from archive
EOF
    
    echo "Retrying packaging with minimal desktop entry..."
    set +e
    "$APPIMAGETOOL_BIN" "$app_dir" "$output_appimage" > /tmp/appimagetool_out.log 2> "$err_log"
    tool_exit=$?
    set -e
  fi

  if [ "$tool_exit" -ne 0 ]; then
    echo "::error::appimagetool execution failed!"
    echo "============================================="
    echo "appimagetool Error Output:"
    cat "$err_log"
    echo "============================================="
    
    # SMART ERROR HANDLER: Parse common appimagetool failure reasons
    if grep -q -i "desktop entry" "$err_log" 2>/dev/null; then
      echo "Diagnostic: The desktop file format did not comply with AppImage standards."
    elif grep -q -i "FUSE" "$err_log" 2>/dev/null; then
      echo "Diagnostic: A FUSE mounting failure occurred. Verify FUSE execution bypassing configuration."
    fi
    
    failure_list+=("$url (AppImage Packaging Failed)")
    ((failure_count++))
    rm -rf "$extract_dir" "$download_file"
    [ "$INPUT_FAIL_FAST" = "true" ] && exit 1
    continue
  fi

  if [ -f "$output_appimage" ]; then
    chmod +x "$output_appimage"
    echo "::notice::Successfully created AppImage: $(basename "$output_appimage")"
    success_list+=("$url -> $(basename "$output_appimage")")
    ((success_count++))
  else
    echo "::error::appimagetool finished without errors, but output file is missing!"
    failure_list+=("$url (Output missing)")
    ((failure_count++))
  fi

  # Cleanup temporary directory
  rm -rf "$extract_dir" "$download_file"

done <<< "$urls_clean"

# 4. Generate final summary report
echo "============================================="
echo "               CONVERSION SUMMARY            "
echo "============================================="
echo "Total processed: $((success_count + failure_count))"
echo "Successes:       $success_count"
echo "Failures:        $failure_count"
echo "---------------------------------------------"

if [ ${#success_list[@]} -gt 0 ]; then
  echo "Successfully generated AppImages:"
  for item in "${success_list[@]}"; do
    echo "  - $item"
  done
fi

if [ ${#failure_list[@]} -gt 0 ]; then
  echo "Failed conversions:"
  for item in "${failure_list[@]}"; do
    echo "  - $item"
  done
  echo "============================================="
  exit 1
fi

echo "============================================="
