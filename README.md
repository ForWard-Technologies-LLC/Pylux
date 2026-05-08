
![Pylux Logo](pylux-logo.png)

# Pylux

Pylux is a free, community-built, open source hobby project for PlayStation 4 and PlayStation 5 Remote Play. It focuses on maintaining internet remote play while keeping the app simple to install from major app stores.

## Screenshots

<p align="center">
  <img src="assets/screenshots/android-phones/01.png" alt="Pylux screenshot 1" width="45%" />
  <img src="assets/screenshots/android-phones/02.png" alt="Pylux screenshot 2" width="45%" />
  <img src="assets/screenshots/android-phones/03.png" alt="Pylux screenshot 3" width="45%" />
  <img src="assets/screenshots/android-phones/04.png" alt="Pylux screenshot 4" width="45%" />
</p>

## Features

- Internet Play
- Remote play
- Cross-platform builds for straightforward deployment
- Modern UI with touch-friendly controls where it matters
- Automatic console discovery and registration

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

Special thanks to the original Chiaki development team for their excellent work on what became the backbone of this project. This fork builds on their incredible work, aiming to bring internet play to more people through straightforward installs across platforms.
