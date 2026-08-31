# tvOS build for Chiaki library
# Invokes the parent project with CHIAKI_ENABLE_IOS=ON to build lib only.
# Use with ios.toolchain.cmake (from ios-cmake) via -DCMAKE_TOOLCHAIN_FILE.
#
# Example:
#   cmake -S . -B build-appletvos -DCMAKE_TOOLCHAIN_FILE=ios.toolchain.cmake \
#         -DPLATFORM=TVOS -DCHIAKI_ENABLE_IOS=ON

cmake_minimum_required(VERSION 3.10)
project(chiaki-tvos LANGUAGES C CXX)

# The leetal ios-cmake toolchain sets IOS=ON for PLATFORM=TVOS, so existing
# if(IOS) gates in lib/ and third-party/ apply. Reuse CHIAKI_ENABLE_IOS.
set(CHIAKI_ENABLE_IOS ON CACHE BOOL "Enable iOS/tvOS embedded Apple build" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/.. ${CMAKE_CURRENT_BINARY_DIR}/parent)
