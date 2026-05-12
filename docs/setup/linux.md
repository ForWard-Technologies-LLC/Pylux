# PS4 and PS5 Remote Play on Linux with Pylux

Pylux provides PS4 and PS5 Remote Play for Linux as a Flatpak (on Flathub), AppImage, and portable zip.

## Download

[View Linux Releases](https://github.com/ForWard-Technologies-LLC/Pylux/releases){ .md-button .md-button--primary target="_blank" rel="noopener" }

=== "Flatpak"
    Available on Flathub:

    ```bash
    flatpak install -y io.github.ForWard_Technologies_LLC.Pylux
    ```

    Or search for `Pylux` in the GNOME Software or Discover store.

=== "AppImage"
    Download from the [Releases page](https://github.com/ForWard-Technologies-LLC/Pylux/releases){ target="_blank" rel="noopener" }, make executable, and run:

    ```bash
    chmod +x pylux-latest.AppImage
    ./pylux-latest.AppImage
    ```

=== "Portable zip"
    Download from the [Releases page](https://github.com/ForWard-Technologies-LLC/Pylux/releases){ target="_blank" rel="noopener" }, unzip, and run `launch.sh`.

## Setup

1. Install Pylux using one of the options above (see [Installation](installation.md) for detailed steps)
2. Follow the [Setup Overview](index.md) to register your PS4 or PS5 console
3. Configure [Remote Connection](remoteconnection.md) to connect over the internet (Internet Play)

## Features on Linux

- Internet Play — connect to your console from anywhere without port forwarding
- Automatic console discovery on your local network
- Flatpak on Flathub for easy install and updates
- Steam Deck support — see the [Steam Deck guide](steam-deck.md) for Game Mode integration
