# Archive to AppImage Converter GitHub Action

[![GitHub Super-Linter](https://github.com/statuses/clean)](https://github.com/marketplace/actions/archive-to-appimage-converter)

A highly robust, smart, and flexible GitHub Action to download precompiled application archives (`.tar.xz`, `.tar.gz`, `.zip`, `.rar`, `.7z`, etc.) and convert them into fully functional, standalone **Linux AppImages**—completely FUSE-free.

---

## Features

- 📦 **Multi-Format Extraction**: Auto-detects and extracts `.zip`, `.tar.xz`, `.tar.gz`, `.tar.bz2`, `.rar`, `.7z`, and more.
- 🧠 **Smart Auto-Detection**: Heuristically finds the main executable using desktop entry parsing, binary/slug pattern matching, and file signatures.
- ⚡ **FUSE-free Packaging**: Bypasses FUSE mount requirements in GitHub VM runners by using containerized extraction methods.
- ⚙️ **Smart Error Handling**: Logs archive file structures upon failure, suggests manual configurations, and interprets `appimagetool` output.
- 🏗️ **Architecture-Aware**: Automatically detects whether binaries are compiled for `x86_64`, `aarch64`, `armhf`, or `i686`, setting up the proper AppImage metadata.
- 🎨 **Auto-Icon Generation**: Resolves icons from the archive, pulls external URLs, or creates a beautiful, minimalist vector SVG icon fallback.

---

## Action Inputs

| Input | Description | Required | Default |
| :--- | :--- | :---: | :--- |
| `urls` | Comma- or newline-separated list of download URLs for your archives. | **Yes** | N/A |
| `app_name` | Name of the application. Auto-detected from URL filename if empty. | No | `""` |
| `executable_path` | Relative path to the binary inside the archive (e.g. `bin/myapp`). | No | `""` (auto-detected) |
| `icon_url` | URL to a custom icon (`.png` or `.svg`) to bundle into the AppImage. | No | `""` (fallback/autodetect) |
| `fail_fast` | Terminate the action immediately on any single failure when converting multiple URLs. | No | `false` |

---

## Action Outputs

| Output | Description |
| :--- | :--- |
| `appimages_dir` | Absolute path to the directory containing all generated `.AppImage` files. |

---

## Quick Start (Workflow Usage)

To convert precompiled archives and upload the resulting AppImages as artifacts, use this step in your workflow:

```yaml
name: Package AppImage

on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Convert Archive to AppImage
        id: converter
        uses: quirky-pythagoras/archive-to-appimage@v1
        with:
          urls: 'https://github.com/muesli/duf/releases/download/v0.8.1/duf_0.8.1_linux_amd64.tar.gz'
          app_name: 'Duf'

      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: my-appimage
          path: ${{ steps.converter.outputs.appimages_dir }}/*.AppImage
```

---

## Run Manually in This Repo

This repository includes a preconfigured manual conversion workflow. 

1. Go to the **Actions** tab of your repository.
2. Select the **Convert Archives to AppImage** workflow in the sidebar.
3. Click **Run workflow**.
4. Paste one or more archive URLs.
5. Retrieve the compiled `.AppImage` files directly from the run summary under **Artifacts**.

---

## Smart Heuristics & Error Handling

### How Auto-Detection Works
1. **Desktop Entry Check**: Searches for existing `.desktop` files in the archive to find the mapped binary path (`Exec` value).
2. **Name Matching**: Searches for ELF binaries/scripts matching the application name or slug (case-insensitive).
3. **Location Search**: Searches for any compiled ELF binary in `bin/` or the root folder.
4. **Shell Script Check**: Searches for executable entrypoint shell/Python scripts.

### Smart Error Diagnostics
If packaging or extraction fails:
- Connection and HTTP status codes are checked and logged for download errors.
- If the binary is missing, the action lists the extracted folder structure up to 3 levels deep and prints recommendations (e.g. suggesting you specify the `executable_path` input).
- Direct appimagetool stderr outputs are captured and parsed to provide actionable tips for fixing `.desktop` and configuration issues.

---

## License

This project is licensed under the [MIT License](LICENSE).
