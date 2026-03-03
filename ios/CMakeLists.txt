# iOS build for Chiaki library
# Invokes the parent project with CHIAKI_ENABLE_IOS=ON to build lib only.
# Use with ios.toolchain.cmake (from ios-cmake) via -DCMAKE_TOOLCHAIN_FILE.
#
# Example:
#   cmake -S . -B build-iphoneos -DCMAKE_TOOLCHAIN_FILE=ios.toolchain.cmake \
#         -DPLATFORM=OS64 -DCHIAKI_ENABLE_IOS=ON

cmake_minimum_required(VERSION 3.10)
project(chiaki-ios LANGUAGES C CXX)

# Force iOS options before including parent (they must be set before parent's option() calls)
set(CHIAKI_ENABLE_IOS ON CACHE BOOL "Enable iOS build" FORCE)

# Include parent project - it will only add lib (and third-party) when CHIAKI_ENABLE_IOS is ON
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/.. ${CMAKE_CURRENT_BINARY_DIR}/parent)

# chiaki-lib target is now available; no need to add anything else
# The build will produce libchiaki.a in the lib/ subdir of the build folder
