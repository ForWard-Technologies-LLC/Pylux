# Contributing to Pylux

Thanks for your interest in contributing! Pylux is a free, community-built project and all help is welcome.

## Branching and release workflow

| Branch | Purpose |
|---|---|
| `master` | Default branch. Stable code and the starting point for all forks. When deployed, pushes to **production** stores. |
| `release/beta` | Merge target for PRs. Pushes here automatically build and deploy **beta** builds to all platforms. |
| `release/alpha` | Experimental testing branch. No CI is triggered. |

### How to contribute

1. **Fork** the repo on GitHub.
2. Create a feature or fix branch off `master`.
3. Make your changes, commit, and push to your fork.
4. Open a **pull request** targeting `release/beta`.
5. A maintainer reviews and merges. Once merged, CI takes over automatically.
6. For larger changes, opening an issue first is appreciated so we can discuss the approach.
7. Keep PRs focused — one feature or fix per PR when possible.

### What happens after merge

When a PR is merged into `release/beta`, GitHub Actions builds and deploys every platform:

| Platform | What gets built | Where it goes |
|---|---|---|
| Android + Android TV | Signed AAB (all ABIs) | Google Play (beta track) |
| iOS | Signed IPA (arm64) | TestFlight (upload only) |
| macOS | Universal .pkg (arm64 + x86_64) | App Store Connect (upload only) |
| Windows | Portable zip + installer (x86_64) | Dropbox + GitHub Actions artifact |
| Linux | AppImage (x86_64) | Dropbox + GitHub Actions artifact |
| Linux (Flatpak) | Flatpak (x86_64 + aarch64) | Flathub (manifest synced to `flathub/io.github.ForWard_Technologies_LLC.Pylux`) |

When `master` is deployed (currently manual dispatch only):

| Platform | Difference from beta |
|---|---|
| Android + Android TV | Pushed to **production** track instead of beta |
| iOS | Auto-submits for **review** after upload |
| macOS | Auto-submits for **review** after upload |
| Windows / Linux / Flatpak | Same as beta |

All workflows can also be triggered manually from the Actions tab.

## Local development

Each platform has its own build setup. See the relevant directories for details:

- **Android** — `android/` (Gradle + CMake, requires Android SDK/NDK)
- **iOS** — `ios/` (Xcode project + CMake for native libs)
- **macOS App Store** — `macos/` (CMake + Xcode tooling)
- **Desktop (Qt)** — root `CMakeLists.txt` (CMake + Qt 6)
- **Windows** — built via MSYS2 (see `.github/workflows/build-windows.yml`)
- **Linux** — built in a container (see `.github/workflows/build-linux.yml`)
- **Flatpak** — manifest at `scripts/flatpak/io.github.ForWard_Technologies_LLC.Pylux.yml` (see `.github/workflows/deploy-flatpak.yml`)
