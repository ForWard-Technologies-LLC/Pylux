# AGPL Compliance - Source Code Distribution

## Overview

PSStream (chiaki-ng) is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). This license requires that when distributing binary versions, you must provide access to the corresponding source code.

## How It Works

### 1. Automated Source Code Upload (GitHub Action)

The GitHub Action `.github/workflows/upload-source-code.yml` automatically:
- Creates a complete source code archive when code is pushed
- Uploads it to Dropbox under `/chiaki-ng-sources/`
- Runs on:
  - Manual trigger (`workflow_dispatch`)
  - Push to main/master branches
  - Push to release branches
  - Version tags

### 2. License Files in Binary Distribution

Build scripts use the helper function `add_agpl_compliance()` from `scripts/add-agpl-compliance.sh` to add:
- **`usr/share/licenses/chiaki-ng/COPYING`**: Full AGPL-3.0 license text
- **`usr/share/licenses/chiaki-ng/SOURCE_CODE.txt`**: Notice with link to download source code

Files are placed in `usr/share/licenses/chiaki-ng/` to follow Linux standards while being less prominent to end users.

### 3. Reusable Helper Script

The template `legal/agpl-source-notice.txt` contains the notice text with placeholders that are replaced at build time:
- `__BUILD_DATE__` → Build timestamp
- `__GIT_COMMIT__` → Git commit hash
- `__GIT_BRANCH__` → Git branch name
- `__ARCHITECTURE__` → System architecture

## Setup for GitHub Action

### Required Secrets

Set these in your repository Settings → Secrets and variables → Actions:

- `DROPBOX_REFRESH_TOKEN`
- `DROPBOX_APP_KEY`
- `DROPBOX_APP_SECRET`

### Getting Dropbox OAuth Credentials

1. Go to https://www.dropbox.com/developers/apps
2. Click "Create app"
3. Choose:
   - **API**: Scoped access
   - **Access**: Full Dropbox
   - **Name**: e.g., "chiaki-ng-source-hosting"
4. In the **Permissions** tab, enable:
   - `files.content.write`
   - `files.content.read`
   - `sharing.write`
5. In the **Settings** tab:
   - Note your **App key** and **App secret**
   - Generate an **Access token** (this is the refresh token)

## Using in Build Scripts

To add AGPL compliance to any build script:

```bash
# Source the helper script
source scripts/add-agpl-compliance.sh

# Call the function with your distribution directory
add_agpl_compliance "/path/to/distribution/root"
```

**Example** (as used in `build-appimage.sh`):
```bash
cd ..
source scripts/add-agpl-compliance.sh
add_agpl_compliance "appimage/${PORTABLE_DIR}"
cd appimage
```

This will automatically:
- Create `usr/share/licenses/chiaki-ng/` directory
- Copy `COPYING` license file
- Generate `SOURCE_CODE.txt` with build information

## Updating the Source Code Link

After running the GitHub Action, update the URL in `legal/agpl-source-notice.txt`:

1. Check the Dropbox folder `/chiaki-ng-sources/` for the uploaded archive
2. Get the shared link for the folder or specific file
3. Update line 10 in `legal/agpl-source-notice.txt` with the actual URL

Example:
```
    https://www.dropbox.com/scl/fo/abc123xyz/chiaki-ng-sources?dl=0&rlkey=abc123
```

Since this is a template file, updating it once will apply to all future builds.

## Manual Source Distribution (Alternative)

If you prefer not to use Dropbox, you can:

1. Manually create source archives when releasing binaries
2. Upload to GitHub Releases, your own server, or any public hosting
3. Update the URL in `scripts/build-appimage.sh` line 131

## AGPL Compliance Requirements

✅ **What we do:**
- Include full license text (COPYING)
- Provide written offer to source code (SOURCE_CODE.txt)
- Make source available via public download link
- Include all source needed to build the software

✅ **AGPL Section 6(d) compliance:**
> "Convey the object code by offering access from a designated place...
> and offer equivalent access to the Corresponding Source in the same way"

This means providing a download link in the binary distribution is sufficient.

## Important Notes

### Source Retention
- Keep source archives available as long as you distribute the binary
- AGPL doesn't specify a duration, but 3+ years is recommended

### What's Included in Source Archive
- All source code files
- Build scripts and configuration
- Third-party dependencies (submodules)
- Documentation
- Excludes: build artifacts, binaries, .git history

### Modified Versions
If you modify and distribute the software:
1. Include your modifications in the source archive
2. Add prominent notices of your changes
3. Update the source code link in SOURCE_CODE.txt
4. Maintain the same AGPL license

## Verification

After building, check that the files exist in the distribution:
```bash
ls PSStream/usr/share/licenses/chiaki-ng/COPYING        # License file exists
ls PSStream/usr/share/licenses/chiaki-ng/SOURCE_CODE.txt # Source info exists
cat PSStream/usr/share/licenses/chiaki-ng/SOURCE_CODE.txt # URL is correct
```

The files are intentionally placed in a standard but less prominent location (`usr/share/licenses/`) to comply with AGPL while not being immediately visible to end users.

## References

- AGPL-3.0 License: https://www.gnu.org/licenses/agpl-3.0.html
- GPL FAQ: https://www.gnu.org/licenses/gpl-faq.html
- Full license text: See `COPYING` in repository root

