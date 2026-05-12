# Installing Pylux

=== "Android / Android TV"

    Install directly from the Play Store:

    [Get it on Google Play](https://play.google.com/store/apps/details?id=com.pylux.stream){ target="_blank" rel="noopener" }

    Works on phones, tablets, and Android TV devices.

=== "iOS / iPadOS"

    Install from the App Store:

    [Download on the App Store](https://apps.apple.com/us/app/pylux-remote-play/id6761292658){ target="_blank" rel="noopener" }

=== "macOS"

    Install from the Mac App Store:

    [Download on the Mac App Store](https://apps.apple.com/us/app/pylux-remote-play/id6761292658){ target="_blank" rel="noopener" }

=== "Windows"

    Download from the [Releases page](https://github.com/ForWard-Technologies-LLC/Pylux/releases){ target="_blank" rel="noopener" }:

    - **Installer** — recommended for most users
    - **Portable zip** — unzip and run, no install required

=== "Linux / Steam Deck"

    !!! Tip "Copying from and Pasting into Konsole Windows"

        You can copy from and paste into `konsole` windows with ++ctrl+shift+c++ (copy) and ++ctrl+shift+v++ (paste) instead of the normal ++ctrl+c++ (copy) and ++ctrl+v++ (paste) shortcuts.

    === "Flatpak (Recommended)"

        === "Using the Discover Store"

            1. Open the Discover store

                ![Open Discover](images/OpenDiscover.png)

            2. Search for `Pylux` in the search bar

            3. Click Install

        === "Using the `konsole`"

            1. Run the following command in the `konsole`

                ```
                flatpak install -y io.github.ForWard_Technologies_LLC.Pylux
                ```

        !!! Note "About the Pylux Flatpak"

            The above instructions are for the official Pylux flatpak on Flathub.

            You can also build the flatpak yourself by following the instructions in [Building the Flatpak Yourself](../diy/buildit.md){ target="_blank" rel="noopener" }.

    === "AppImage"

        1. Download the AppImage from the [Releases page](https://github.com/ForWard-Technologies-LLC/Pylux/releases){ target="_blank" rel="noopener" }

        2. Make it executable and run it:

            ```bash
            chmod +x pylux-latest.AppImage
            ./pylux-latest.AppImage
            ```

            !!! Tip "Steam Deck / Steam"
                Set `APPIMAGE_EXTRACT_AND_RUN=1` if Steam misbehaves with the AppImage.

    === "Portable zip"

        1. Download the portable zip from the [Releases page](https://github.com/ForWard-Technologies-LLC/Pylux/releases){ target="_blank" rel="noopener" }

        2. Unzip and run `launch.sh` (sets up bundled libs and OpenSSL fallback automatically)
