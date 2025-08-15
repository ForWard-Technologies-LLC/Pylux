cmake_minimum_required(VERSION 3.14)

project(steamworks LANGUAGES CXX)

# Steamworks SDK is an external prebuilt library, not built from source
# This CMakeLists.txt creates an IMPORTED target to handle it consistently

# Define the Steamworks SDK path relative to this CMakeLists.txt
set(STEAMWORKS_SDK_PATH "${CMAKE_CURRENT_SOURCE_DIR}/steamworks_sdk")

# Check if the SDK exists
if(NOT EXISTS "${STEAMWORKS_SDK_PATH}/public/steam/steam_api.h")
    message(FATAL_ERROR "Steamworks SDK not found at ${STEAMWORKS_SDK_PATH}. Please follow the instructions in ${CMAKE_CURRENT_SOURCE_DIR}/README_STEAMWORKS.md")
endif()

# Create an INTERFACE library target (better for header-only or external libs)
add_library(steamworks INTERFACE)

# Set the include directories for the target
target_include_directories(steamworks INTERFACE "${STEAMWORKS_SDK_PATH}/public")

# Link the appropriate Steamworks library based on platform
if(WIN32)
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
        target_link_libraries(steamworks INTERFACE "${STEAMWORKS_SDK_PATH}/redistributable_bin/win64/steam_api64.lib")
        set(STEAMWORKS_LIBRARY_FILE "steam_api64.dll")
        set(STEAMWORKS_IMPLIB_FILE "steam_api64.lib")
    else()
        target_link_libraries(steamworks INTERFACE "${STEAMWORKS_SDK_PATH}/redistributable_bin/steam_api.lib")
        set(STEAMWORKS_LIBRARY_FILE "steam_api.dll")
        set(STEAMWORKS_IMPLIB_FILE "steam_api.lib")
    endif()
elseif(APPLE)
    target_link_libraries(steamworks INTERFACE "${STEAMWORKS_SDK_PATH}/redistributable_bin/osx/libsteam_api.dylib")
    set(STEAMWORKS_LIBRARY_FILE "libsteam_api.dylib")
else() # Linux
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
        target_link_libraries(steamworks INTERFACE "${STEAMWORKS_SDK_PATH}/redistributable_bin/linux64/libsteam_api.so")
        set(STEAMWORKS_LIBRARY_FILE "libsteam_api.so")
    else()
        target_link_libraries(steamworks INTERFACE "${STEAMWORKS_SDK_PATH}/redistributable_bin/linux32/libsteam_api.so")
        set(STEAMWORKS_LIBRARY_FILE "libsteam_api.so")
    endif()
endif()

# Install the library alongside the application (similar to cpp-steam-tools pattern)
if(WIN32)
    install(FILES "${STEAMWORKS_SDK_PATH}/redistributable_bin/win64/${STEAMWORKS_LIBRARY_FILE}"
        DESTINATION bin)
    if(STEAMWORKS_IMPLIB_FILE)
        install(FILES "${STEAMWORKS_SDK_PATH}/redistributable_bin/win64/${STEAMWORKS_IMPLIB_FILE}"
            DESTINATION lib)
    endif()
elseif(APPLE)
    install(FILES "${STEAMWORKS_SDK_PATH}/redistributable_bin/osx/${STEAMWORKS_LIBRARY_FILE}"
        DESTINATION lib)
else() # Linux
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
        install(FILES "${STEAMWORKS_SDK_PATH}/redistributable_bin/linux64/${STEAMWORKS_LIBRARY_FILE}"
            DESTINATION lib)
    else()
        install(FILES "${STEAMWORKS_SDK_PATH}/redistributable_bin/linux32/${STEAMWORKS_LIBRARY_FILE}"
            DESTINATION lib)
    endif()
endif()

message(STATUS "Steamworks SDK found and configured as IMPORTED target")
