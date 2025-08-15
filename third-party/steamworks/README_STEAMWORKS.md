# Steamworks SDK Setup

This directory contains the Steamworks SDK integration for chiaki-ng.

## Installation

1. Download the Steamworks SDK from the Steamworks Partner site
2. Extract the SDK and place the contents in `steamworks_sdk/` directory inside this folder

The directory structure should look like:
```
third-party/steamworks/
├── CMakeLists.txt
├── README_STEAMWORKS.md
└── steamworks_sdk/
    ├── public/
    │   └── steam/
    │       └── steam_api.h
    └── redistributable_bin/
        ├── linux64/
        │   └── libsteam_api.so
        ├── osx/
        │   └── libsteam_api.dylib
        └── win64/
            ├── steam_api64.dll
            └── steam_api64.lib
```

## Usage

The Steamworks integration is controlled by the `CHIAKI_ENABLE_STEAMWORKS` CMake option:

```bash
cmake -DCHIAKI_ENABLE_STEAMWORKS=ON ...
```

When enabled, this creates a `steamworks` CMake target that can be linked like any other library.



