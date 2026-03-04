
cmake_minimum_required(VERSION 3.10)

project(chiaki)

# Fix for 16 KB page size compatibility (required for Android devices with 16 KB pages)
# This ensures ELF LOAD segments are aligned to 16 KB boundaries for shared libraries
# Note: Static libraries don't need this - they're archived, not linked
# With NDK r28+ and ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON, alignment should be automatic
if(ANDROID)
    # NDK r28+ treats warnings as errors. Disable problematic warnings for external libraries like mbedTLS
    # Use -Wno-error= to make specific warnings non-fatal even if -Werror is present
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-error=documentation -Wno-error=unused-but-set-variable")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-error=documentation -Wno-error=unused-but-set-variable")
    
    # For 16KB alignment: NDK r28+ should handle this automatically with ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
    # However, we explicitly add the flag as a backup to ensure alignment
    # Check if flag is already present (NDK may add it automatically)
    string(REGEX MATCH "max-page-size" _has_max_page_size "${CMAKE_SHARED_LINKER_FLAGS}")
    if(NOT _has_max_page_size)
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
    endif()
    string(REGEX MATCH "max-page-size" _has_max_page_size_exe "${CMAKE_EXE_LINKER_FLAGS}")
    if(NOT _has_max_page_size_exe)
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
    endif()
    unset(_has_max_page_size)
    unset(_has_max_page_size_exe)
endif()

# Like option(), but the value can also be AUTO
macro(tri_option name desc default)
    set("${name}" "${default}" CACHE STRING "${desc}")
    set_property(CACHE "${name}" PROPERTY STRINGS AUTO ON OFF)
endmacro()

option(CHIAKI_ENABLE_TESTS "Enable tests for Chiaki" ON)
option(CHIAKI_ENABLE_CLI "Enable CLI for Chiaki" ON)
option(CHIAKI_ENABLE_GUI "Enable Qt GUI" ON)
option(CHIAKI_ENABLE_ANDROID "Enable Android (Use only as part of the Gradle Project)" OFF)
option(CHIAKI_ENABLE_IOS "Enable iOS build (lib only, use from ios/ folder)" OFF)
option(CHIAKI_ENABLE_BOREALIS "Enable Borealis GUI (For Nintendo Switch or PC)" OFF)
tri_option(CHIAKI_ENABLE_SETSU "Enable libsetsu for touchpad input from controller" AUTO)
tri_option(CHIAKI_ENABLE_STEAMDECK_NATIVE "Enable sdeck for native gyro and haptic feedback from Steam Deck" ON)
option(CHIAKI_LIB_ENABLE_OPUS "Use Opus as part of Chiaki Lib" ON)
tri_option(CHIAKI_ENABLE_SPEEX "Use speex for echo cancelling mic playback" AUTO)
tri_option(CHIAKI_ENABLE_RUDP "Enable Remote Play over Internet" AUTO)
if(CHIAKI_ENABLE_GUI OR CHIAKI_ENABLE_BOREALIS)
	set(CHIAKI_FFMPEG_DEFAULT ON)
else()
	set(CHIAKI_FFMPEG_DEFAULT AUTO)
endif()
tri_option(CHIAKI_ENABLE_FFMPEG_DECODER "Enable FFMPEG video decoder" ${CHIAKI_FFMPEG_DEFAULT})
tri_option(CHIAKI_ENABLE_PI_DECODER "Enable Raspberry Pi-specific video decoder (requires libraspberrypi0 and libraspberrypi-doc)" AUTO)
option(CHIAKI_LIB_ENABLE_MBEDTLS "Use mbedtls instead of OpenSSL as part of Chiaki Lib" OFF)
option(CHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT "Fetch Mbed TLS instead of using system-provided libs" OFF)
option(CHIAKI_LIB_OPENSSL_EXTERNAL_PROJECT "Use OpenSSL as CMake external project" OFF)
option(CHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER "Use SDL Gamecontroller for Input" ON)
option(CHIAKI_CLI_ARGP_STANDALONE "Search for standalone argp lib for CLI" OFF)
option(CHIAKI_ENABLE_STEAM_SHORTCUT "Add ability to create Steam shortcut" ON)
option(CHIAKI_ENABLE_STEAMWORKS "Enable Steamworks SDK integration for Steam overlay" OFF)
tri_option(CHIAKI_USE_SYSTEM_JERASURE "Use system-provided jerasure instead of submodule" AUTO)
tri_option(CHIAKI_USE_SYSTEM_NANOPB "Use system-provided nanopb instead of submodule" AUTO)
tri_option(CHIAKI_USE_SYSTEM_CURL "Use system-provided curl instead of submodule. Has to be built with experimental WebSocket support!" OFF)

set(CHIAKI_VERSION_MAJOR 2)
set(CHIAKI_VERSION_MINOR 10)
set(CHIAKI_VERSION_PATCH 1)
set(CHIAKI_VERSION ${CHIAKI_VERSION_MAJOR}.${CHIAKI_VERSION_MINOR}.${CHIAKI_VERSION_PATCH})

set(CPACK_PACKAGE_NAME "chiaki-ng")
set(CPACK_PACKAGE_DESCRIPTION "Remote Play Client")
set(CPACK_PACKAGE_VERSION_MAJOR ${CHIAKI_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${CHIAKI_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${CHIAKI_VERSION_PATCH})
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DESCRIPTION ${CPACK_PACKAGE_DESCRIPTION})
set(CPACK_DEBIAN_PACKAGE_SECTION "games")
include(CPack)

set(CHIAKI_IS_SWITCH ${NSWITCH})

if(CHIAKI_ENABLE_IOS)
	set(IOS TRUE)
	set(CHIAKI_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
	set(CHIAKI_ENABLE_CLI OFF CACHE BOOL "" FORCE)
	set(CHIAKI_ENABLE_GUI OFF CACHE BOOL "" FORCE)
	set(CHIAKI_ENABLE_BOREALIS OFF CACHE BOOL "" FORCE)
	set(CHIAKI_ENABLE_SETSU OFF CACHE STRING "" FORCE)
	set(CHIAKI_ENABLE_FFMPEG_DECODER OFF CACHE STRING "" FORCE)
	set(CHIAKI_ENABLE_PI_DECODER OFF CACHE STRING "" FORCE)
	set(CHIAKI_ENABLE_STEAMDECK_NATIVE OFF CACHE STRING "" FORCE)
	set(CHIAKI_ENABLE_STEAM_SHORTCUT OFF CACHE BOOL "" FORCE)
	set(CHIAKI_ENABLE_RUDP ON CACHE STRING "" FORCE)
	set(CHIAKI_LIB_ENABLE_MBEDTLS ON CACHE BOOL "" FORCE)
	set(CHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT ON CACHE BOOL "" FORCE)
	message(STATUS "iOS build: lib only, mbedTLS, RUDP enabled")
endif()

if(APPLE)
	if(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
		set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0 CACHE STRING "Minimum OS X deployment version" FORCE)
	else()
		set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0 CACHE STRING "Minimum OS X deployment version" FORCE)
	endif()
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake;${CMAKE_CURRENT_SOURCE_DIR}/setsu/cmake")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake;${CMAKE_CURRENT_SOURCE_DIR}/steamdeck_native/cmake")
set(CMAKE_CXX_STANDARD 11)

if(CHIAKI_IS_SWITCH)
	# force mbedtls as crypto lib
	set(CHIAKI_LIB_ENABLE_MBEDTLS ON)
	add_definitions(-D__SWITCH__)
endif()

if(CHIAKI_USE_SYSTEM_JERASURE)
	if(CHIAKI_USE_SYSTEM_JERASURE STREQUAL AUTO)
		find_package(Jerasure QUIET)
		set(CHIAKI_USE_SYSTEM_JERASURE ${Jerasure_FOUND})
	else()
		find_package(Jerasure REQUIRED)
		set(CHIAKI_USE_SYSTEM_JERASURE ON)
	endif()
endif()

if(CHIAKI_ENABLE_GUI)
	find_package(PkgConfig REQUIRED)
	pkg_check_modules(LIBPLACEBO REQUIRED libplacebo IMPORTED_TARGET)
endif()

if(CHIAKI_USE_SYSTEM_CURL)
	if (CHIAKI_USE_SYSTEM_CURL STREQUAL AUTO)
		find_package(CURL COMPONENTS HTTP HTTPS WS WSS QUIET)
		set(CHIAKI_USE_SYSTEM_CURL ${CURL_FOUND})
	else()
		find_package(CURL REQUIRED COMPONENTS HTTP HTTPS WS WSS)
		set(CHIAKI_USE_SYSTEM_CURL ON)
	endif()
endif()

if(CHIAKI_ENABLE_SPEEX)
	set(SpeexDSP_FOUND FALSE)
	find_package(SpeexDSP QUIET)
	pkg_check_modules(SpeexDSP speexdsp IMPORTED_TARGET)
	if(SpeexDSP_FOUND)
		set(CHIAKI_ENABLE_SPEEX ON)
		message(STATUS "Speex DSP found echo cancelling and noise suppression enabled")
	else()
		set(CHIAKI_ENABLE_SPEEX OFF)
		message(STATUS "Speex DSP not found echo cancelling and noise suppression disabled")
	endif()
endif()

find_package(PythonInterp 3 REQUIRED) # Make sure nanopb doesn't find Python 2.7 because Python 2 should just die.

if(CHIAKI_USE_SYSTEM_NANOPB)
	if(CHIAKI_USE_SYSTEM_NANOPB STREQUAL AUTO)
		find_package(Nanopb QUIET)
		set(CHIAKI_USE_SYSTEM_NANOPB ${Nanopb_FOUND})
	else()
		find_package(Nanopb REQUIRED)
		set(CHIAKI_USE_SYSTEM_NANOPB ON)
	endif()
endif()

add_definitions(-DCHIAKI_VERSION_MAJOR=${CHIAKI_VERSION_MAJOR} -DCHIAKI_VERSION_MINOR=${CHIAKI_VERSION_MINOR} -DCHIAKI_VERSION_PATCH=${CHIAKI_VERSION_PATCH} -DCHIAKI_VERSION=\"${CHIAKI_VERSION}\")

if(CHIAKI_LIB_OPENSSL_EXTERNAL_PROJECT)
	include(OpenSSLExternalProject)
endif()

# mbedTLS must be fetched BEFORE third-party so curl can use it for SSL
if(CHIAKI_LIB_ENABLE_MBEDTLS)
	add_definitions(-DCHIAKI_LIB_ENABLE_MBEDTLS)
	if(CHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT)
		set(FETCHCONTENT_QUIET CACHE BOOL FALSE)
		include(FetchContent)
		set(ENABLE_TESTING CACHE INTERNAL OFF)
		set(ENABLE_PROGRAMS CACHE INTERNAL OFF)
		set(USE_SHARED_MBEDTLS_LIBRARY CACHE INTERNAL OFF)
		# Android/iOS: Disable PSA crypto to avoid crypto_sizes.h generation issues
		# (Switch and other platforms can keep PSA enabled if needed)
		if(ANDROID OR IOS)
			set(MBEDTLS_PSA_CRYPTO_C OFF CACHE BOOL "Disable PSA Crypto API" FORCE)
		endif()
		FetchContent_Declare(
			mbedtls
			GIT_REPOSITORY https://github.com/Mbed-TLS/mbedtls.git
			GIT_TAG 8b3f26a5ac38d4fdccbc5c5366229f3e01dafcc0 # v2.28.0
			GIT_PROGRESS TRUE
		)
		if(ANDROID OR IOS)
			# Android/iOS: Use manual FetchContent approach to inject compiler flags before building mbedTLS
			# Android: NDK r28+ treats documentation warnings as errors
			# iOS: Xcode clang treats -Wunused-but-set-variable as error with mbedTLS's -Werror
			FetchContent_GetProperties(mbedtls)
			if(NOT mbedtls_POPULATED)
				FetchContent_Populate(mbedtls)
				# Set flags that will be used when mbedTLS configures itself
				set(ENABLE_TESTING OFF CACHE BOOL "Enable mbedTLS testing" FORCE)
				set(ENABLE_PROGRAMS OFF CACHE BOOL "Enable mbedTLS programs" FORCE)
				# Override CMAKE_C_FLAGS and CMAKE_CXX_FLAGS for mbedTLS build
				set(CMAKE_C_FLAGS_BACKUP "${CMAKE_C_FLAGS}")
				set(CMAKE_CXX_FLAGS_BACKUP "${CMAKE_CXX_FLAGS}")
				set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-documentation -Wno-unused-but-set-variable -Wno-error=documentation -Wno-error=unused-but-set-variable")
				set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-documentation -Wno-unused-but-set-variable -Wno-error=documentation -Wno-error=unused-but-set-variable")
			endif()
			# Configure mbedTLS as a subdirectory so we can control its build
			add_subdirectory(${mbedtls_SOURCE_DIR} ${mbedtls_BINARY_DIR})
			# Restore original flags
			set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS_BACKUP}")
			set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS_BACKUP}")
		else()
			# Non-Android platforms: Use standard FetchContent approach
			FetchContent_MakeAvailable(mbedtls)
		endif()
	endif()
endif()

# third-party must come after mbedTLS so curl can use mbedTLS for SSL
add_subdirectory(third-party)

if(CHIAKI_ENABLE_STEAM_SHORTCUT)
	message(STATUS "Steam shortcut enabled")
else()
	message(STATUS "Steam shortcut disabled")
endif()

if(CHIAKI_ENABLE_FFMPEG_DECODER)
	find_package(FFMPEG COMPONENTS avcodec avutil avformat)
	if(FFMPEG_FOUND)
		set(CHIAKI_ENABLE_FFMPEG_DECODER ON)
	else()
		if(NOT CHIAKI_ENABLE_FFMPEG_DECODER STREQUAL AUTO)
			message(FATAL_ERROR "CHIAKI_ENABLE_FFMPEG_DECODER is set to ON, but ffmpeg could not be found.")
		endif()
		set(CHIAKI_ENABLE_FFMPEG_DECODER OFF)
	endif()
endif()

if(CHIAKI_ENABLE_FFMPEG_DECODER)
	message(STATUS "FFMPEG Decoder enabled")
else()
	message(STATUS "FFMPEG Decoder disabled")
endif()

if(CHIAKI_ENABLE_PI_DECODER)
	find_package(ILClient)
	if(ILClient_FOUND)
		set(CHIAKI_ENABLE_PI_DECODER ON)
	else()
		if(NOT CHIAKI_ENABLE_PI_DECODER STREQUAL AUTO)
			message(FATAL_ERROR "
CHIAKI_ENABLE_PI_DECODER is set to ON, but its dependencies (ilclient source and libs) could not be resolved.
The Raspberry Pi Decoder is only supported on Raspberry Pi OS and requires libraspberrypi0 and libraspberrypi-doc.")
		endif()
		set(CHIAKI_ENABLE_PI_DECODER OFF)
	endif()
endif()

if(CHIAKI_ENABLE_PI_DECODER)
	message(STATUS "Pi Decoder enabled")
else()
	message(STATUS "Pi Decoder disabled")
endif()

add_subdirectory(lib)

if(CHIAKI_ENABLE_CLI)
	add_subdirectory(cli)
endif()

if(CHIAKI_ENABLE_STEAMDECK_NATIVE AND NOT ANDROID)
	find_package(HIDAPI QUIET)
	find_package(PkgConfig REQUIRED)
	pkg_search_module(FFTW REQUIRED fftw3 IMPORTED_TARGET)
	if(HIDAPI_FOUND AND FFTW_FOUND)
		set(CHIAKI_ENABLE_STEAMDECK_NATIVE ON)
	else()
		if(NOT CHIAKI_ENABLE_STEAMDECK_NATIVE STREQUAL AUTO)
			if(NOT HIDAPI_FOUND AND NOT FFTW_FOUND)
				message(FATAL_ERROR "
				CHIAKI_ENABLE_STEAMDECK_NATIVE is set to ON, but its dependencies (HIDAPI & FFTW3) could not be resolved.")
			endif()
			if(NOT HIDAPI_FOUND)
				message(FATAL_ERROR "
				CHIAKI_ENABLE_STEAMDECK_NATIVE is set to ON, but its dependency (HIDAPI) could not be resolved.")
			endif()
			if(NOT FFTW_FOUND)
				message(FATAL_ERROR "
				CHIAKI_ENABLE_STEAMDECK_NATIVE is set to ON, but its dependency (FFTW3) could not be resolved.")
			endif()
		endif()
		set(CHIAKI_ENABLE_STEAMDECK_NATIVE OFF)
	endif()
	if(CHIAKI_ENABLE_STEAMDECK_NATIVE)
		add_subdirectory(steamdeck_native)
	endif()
endif()

if(CHIAKI_ENABLE_STEAMDECK_NATIVE)
	message(STATUS "Steamdeck native gyro and haptics enabled")
else()
	message(STATUS "Steamdeck native gyro and hatpics disabled")
endif()

if(CHIAKI_ENABLE_GUI)
	find_package(SDL2 MODULE REQUIRED)
endif()

if(CHIAKI_ENABLE_SETSU)
	if(CHIAKI_ENABLE_SETSU STREQUAL AUTO AND SDL2_FOUND AND (SDL2_VERSION_MINOR GREATER 0 OR SDL2_VERSION_PATCH GREATER_EQUAL 14))
		message(STATUS "SDL version ${SDL2_VERSION} is >= 2.0.14, disabling Setsu")
		set(CHIAKI_ENABLE_SETSU OFF)
	else()
		find_package(Udev QUIET)
		find_package(Evdev QUIET)
		if(Udev_FOUND AND Evdev_FOUND)
			set(CHIAKI_ENABLE_SETSU ON)
		else()
			if(NOT CHIAKI_ENABLE_SETSU STREQUAL AUTO)
				message(FATAL_ERROR "
	CHIAKI_ENABLE_SETSU is set to ON, but its dependencies (udev and evdev) could not be resolved.
	Keep in mind that setsu is only supported on Linux!")
			endif()
			set(CHIAKI_ENABLE_SETSU OFF)
		endif()
		if(CHIAKI_ENABLE_SETSU)
			add_subdirectory(setsu)
		endif()
	endif()
endif()

if(CHIAKI_ENABLE_SETSU)
	message(STATUS "Setsu enabled")
else()
	message(STATUS "Setsu disabled")
endif()

if(CHIAKI_ENABLE_GUI)
	add_subdirectory(gui)
endif()

if(CHIAKI_ENABLE_TESTS)
	enable_testing()
	add_subdirectory(test)
endif()

if(CHIAKI_ENABLE_ANDROID)
	add_subdirectory(android/app)
endif()

if(CHIAKI_ENABLE_BOREALIS)
	add_subdirectory(switch)
endif()