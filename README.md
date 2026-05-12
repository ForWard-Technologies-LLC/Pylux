
![Pylux Logo](pylux-logo.png)

# Pylux

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux-brightgreen)]()
[![PS4 / PS5](https://img.shields.io/badge/PS4%2FPS5-Remote%20Play-informational)]()

**Pylux is a free, open-source PS4 and PS5 Remote Play client for Android, Android TV, iOS, macOS, Windows, Linux, and Steam Deck.** It focuses on app-store installs, Internet Play (no port forwarding needed), automatic console discovery, and a touch-friendly mobile UI — all from one community-maintained codebase.

## Download

| Platform | Link |
|---|---|
| Android / Android TV | [Google Play](https://play.google.com/store/apps/details?id=com.pylux.stream) |
| iPhone / iPad | [App Store](https://apps.apple.com/us/app/pylux-remote-play/id6761292658) |
| macOS | [Mac App Store](https://apps.apple.com/us/app/pylux-remote-play/id6761292658) |
| Windows | [Installer](https://www.dropbox.com/scl/fi/wf9cr349acdwkih0syrva/pylux-windows-installer-latest.exe?rlkey=m2egtuj8z7f5se6405gg09wct&dl=1) · [Portable zip](https://www.dropbox.com/scl/fi/153m9nvy9jluxcjvngmwb/pylux-latest.zip?rlkey=l3bxdp67hu2apfazjs27edxtw&dl=1) |
| Linux / Steam Deck | [AppImage](https://www.dropbox.com/scl/fi/wi8bjilwiklv7fde0b4ea/pylux-latest.AppImage?rlkey=3xne4ltuiq54ogfmng4gq24mp&dl=1) · [Portable zip](https://www.dropbox.com/scl/fi/86rm2424t8jv1h4p2id2b/pylux-latest.zip?rlkey=w69lgzvauq43wpi35wtqac2h0&dl=1) · [Flathub](https://flathub.org/apps/io.github.ForWard_Technologies_LLC.Pylux) |

For full release notes and all downloads see the [Releases page](https://github.com/ForWard-Technologies-LLC/Pylux/releases).

## Screenshots

<p align="center">
  <img src="assets/screenshots/android-phones/01.png" alt="Pylux screenshot 1" width="45%" />
  <img src="assets/screenshots/android-phones/02.png" alt="Pylux screenshot 2" width="45%" />
  <img src="assets/screenshots/android-phones/03.png" alt="Pylux screenshot 3" width="45%" />
  <img src="assets/screenshots/android-phones/04.png" alt="Pylux screenshot 4" width="45%" />
</p>

## Features

- **Internet Play** — connect to your PS4/PS5 from anywhere, no port forwarding or router configuration needed
- **Remote Play** — low-latency streaming of your PlayStation console to any supported device
- **Cross-platform** — Android, Android TV, iOS, iPadOS, macOS, Windows, Linux, Steam Deck
- **App-store installs** — available on Google Play, App Store, and Mac App Store
- **Automatic console discovery and registration**
- **Touch-friendly controls** — mobile-optimized UI for phones and tablets

## Documentation

Full setup guides, configuration, and controller options at **[forward-technologies-llc.github.io/Pylux](https://forward-technologies-llc.github.io/Pylux/)**.

## Contributing

Fork the repo, create a branch, and open a pull request targeting `release/beta`. When merged, CI automatically builds and deploys to all platforms (Google Play, TestFlight, App Store Connect, Dropbox).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow and local development setup.

## What needs work

- **iOS** needs the most work — cleanup, hardening, and refactors are all in scope.
- **Android** is more stable but still benefits from fixes and polish.
- **Desktop (Qt)** is where merge pain with [upstream Chiaki](https://github.com/streetpea/chiaki-ng) shows up most. Prefer adding new code in new files when practical and skip sweeping rewrites that block pulling upstream fixes.
- **Cherry-picks from upstream** are welcome. If you spot something upstream has that Pylux is missing, open an issue or try adding it yourself.

AI-assisted contributions are welcome — just follow good coding standards and fully test your changes before submitting.

## Why Pylux?

I told ChatGPT to name the project and promised I'd actually use the first thing it said. It said Pylux...

## Legal & responsible use

Pylux is intended for use with games and content you own or are licensed to use, on hardware you own, with a valid account or subscription. It does not circumvent copy protection or facilitate piracy.

This project is not endorsed or certified by the console manufacturer. All trademarks belong to their respective owners.

For questions about this project or responsible use, contact [forward.technologies.llc@gmail.com](mailto:forward.technologies.llc@gmail.com).

## Credits

Pylux is built on top of [Chiaki](https://git.sr.ht/~thestr4ng3r/chiaki) and [chiaki-ng](https://github.com/streetpea/chiaki-ng). Special thanks to the original Chiaki development team and the chiaki-ng maintainers for their excellent foundational work. Pylux extends that work with a focus on app-store distribution, mobile and Android TV support, and Internet Play.
