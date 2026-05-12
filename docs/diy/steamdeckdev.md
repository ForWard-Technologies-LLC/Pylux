# Developing Pylux updates on Steam Deck

This is for contributors that want to make/test updates to the codebase without building a new flatpak each time.

!!! Info "Adding Dependencies"

    If you want to add new dependencies that aren't already included in the flatpak modules or SDK, then you will need to create a new flatpak build adding that module or install the module locally and it to your PATH. However, this would only be needed in rare circumstances.

## Setup Environment

1. Install flatpak with debug extension and/or build a new one with any added dependencies following [Building the Flatpak Yourself](buildit.md){target="_blank" rel="noopener"}

    ``` bash
    flatpak install --user --include-debug -y https://raw.githubusercontent.com/ForWard-Technologies-LLC/Pylux/main/scripts/flatpak/io.github.ForWard_Technologies_LLC.Pylux-devel.flatpakref
    ```

    !!! Info "Creating local flatpak builds"

        If you want to create flatpak builds from local files, you can do this by changing the manifest sources from:

        ``` bash
        sources:
        - type: git
          url: https://github.com/ForWard-Technologies-LLC/Pylux.git
          branch: main
        ```

        to:

        ``` bash
        sources:
        - type: dir
          path: path-to-Pylux-git
        ```

2. Copy config file from Pylux

    ``` bash
    cp ~/.var/app/io.github.ForWard_Technologies_LLC.Pylux/config/Chiaki/Chiaki.conf ~/.var/app/io.github.ForWard_Technologies_LLC.Pylux-devel/config/Chiaki/Chiaki.conf 
    ```

3. Install the SDK

    ``` bash
    flatpak install --user org.kde.Sdk//6.8
    ```

4. Install the `Debug` extensions for the SDK

    ``` bash
    flatpak install --user org.kde.Sdk.Debug//6.8
    ```

5. Clone the project onto your Steam Deck with:

    === "HTTPS"

        ``` bash
        git clone --recurse-submodules https://github.com/ForWard-Technologies-LLC/Pylux.git
        ```

    === "SSH"

        ``` bash
        git clone --recurse-submodules git@github.com:ForWard-Technologies-LLC/Pylux.git
        ```

    === "GitHub cli"

        ``` bash
        gh repo clone ForWard-Technologies-LLC/Pylux
        ```

    !!! Question "What if I'm testing changes from my branch?"

        Clone that branch or pull it into the git repo cloned above

## Creating and Debugging Builds without New Flatpak Build

1. Enter the development version of the flatpak with the Pylux source code mounted with:

    ``` bash
    flatpak run --command=bash --devel io.github.ForWard_Technologies_LLC.Pylux-devel
    ```

2. Create a build using cmake as per usual

    === "Debug build"

        1. Change into the git directory for your cloned project
        2. Make a directory for your debug build

            ``` bash
            mkdir Debug
            ```
            
        3. Change into debug directory

            ``` bash
            cd Debug
            ```

        4. Create build files with cmake

            ``` bash
            cmake -DCMAKE_BUILD_TYPE=Debug ..
            ```
        
        5. Build Pylux

            ``` bash
            make
            ```

    === "Release build"

        1. Change into the git directory you mounted
        2. Make a directory for your debug build

            ``` bash
            mkdir Release
            ```
        3. Change into debug directory

            ``` bash
            cd Release
            ```

        4. Create build files with cmake

            ``` bash
            cmake -DCMAKE_BUILD_TYPE=Release ..
            ```
        
        5. Build Pylux

            ``` bash
            make
            ```

3. Run build as usual from executables (using gdb for debugging Debug build)

    === "Debug"

        From `Debug` directory using gdb:

        ``` bash
        gdb ./gui/chiaki
        ```

    === "Release"

        From `Release` directory:

        ``` bash
        ./gui/chiaki
        ```

    !!! Note "Set vaapi to none"
        
        When running chiaki from within the flatpak like this please set vaapi to none as otherwise the video won't work. This is fine since you are just running Chiaki like this for development tests only so worse performance isn't a big concern.

4. Make edits to the source code to implement your changes

    !!! Tip "Editing code on Steam Deck"

        Personally, I use vscode which you can install as a flatpak from Discover. You can open your chiaki code directory using vscode from your Steam Deck desktop and save changes. Then, these changes which will be reflected in your flatpak (since you mounted the chiaki code directory to your flatpak in the steps above) when you do a new build in your flatpak environment. The process would be similar with other code editors installed on your Steam Deck.

5. After making changes to the source code, simply rebuild with make as per usual

## Debug Coredump From a flatpak

1. Get process from coredump

    1. Run coredumpctl

        ``` bash
        coredumpctl
        ```

    2. Get pid for your application from list

2. Open gdb session for your flatpak with the given pid
    
    ``` bash
    flatpak-coredumpctl -m given_pid flatpak_name
    ```

    ???+ Example "Example given pid 4822 and flatpak name `io.github.ForWard_Technologies_LLC.Pylux-devel`"

        ``` bash
        flatpak-coredumpctl -m 4822 io.github.ForWard_Technologies_LLC.Pylux-devel
        ```

3. Use gdb commands as per usual such as `bt full`

    For a comprehensive guide on gdb commands see [Debugging with GDB](https://www.eecs.umich.edu/courses/eecs373/readings/Debugger.pdf){target="_blank" rel="noopener"}
