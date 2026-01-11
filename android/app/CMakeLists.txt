
cmake_minimum_required(VERSION 3.13)

set(CMAKE_CXX_STANDARD 14)

# Fix for 16 KB page size compatibility (required for Android devices with 16 KB pages)
# With NDK r28+ and ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON set in build.gradle,
# the linker should automatically align LOAD segments to 16 KB boundaries.
# We only add explicit flags if not already present from NDK defaults.
# Note: Manual flags might interfere with NDK's automatic alignment, so we check first.
if(ANDROID)
    # NDK r28+ with ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON should handle this automatically
    # Only add flags if they're not already present (to avoid duplicates)
    string(REGEX MATCH "max-page-size" _has_max_page_size "${CMAKE_SHARED_LINKER_FLAGS}")
    if(NOT _has_max_page_size)
        # Append flag (don't use CACHE/FORCE to avoid overriding NDK defaults)
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
    endif()
    string(REGEX MATCH "max-page-size" _has_max_page_size_exe "${CMAKE_EXE_LINKER_FLAGS}")
    if(NOT _has_max_page_size_exe)
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
    endif()
    unset(_has_max_page_size)
    unset(_has_max_page_size_exe)
endif()

add_library(chiaki-jni SHARED
        src/main/cpp/chiaki-jni.c
        src/main/cpp/log.h
        src/main/cpp/log.c
        src/main/cpp/video-decoder.h
        src/main/cpp/video-decoder.c
        src/main/cpp/audio-decoder.h
        src/main/cpp/audio-decoder.c
        src/main/cpp/audio-output.h
        src/main/cpp/audio-output.cpp
        src/main/cpp/circular-fifo.hpp)

# Apply 16 KB page size alignment fix to chiaki-jni library
# With NDK r28+ and ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON, this should be automatic,
# but we explicitly set it on the target to ensure it's applied
if(ANDROID)
    # Explicitly set alignment on the target to ensure it's not missed
    target_link_options(chiaki-jni PRIVATE "-Wl,-z,max-page-size=16384")
endif()

target_link_libraries(chiaki-jni chiaki-lib)

find_library(ANDROID_LIB_LOG log)
find_library(ANDROID_LIB_MEDIANDK mediandk)
find_library(ANDROID_LIB_ANDROID android)
target_link_libraries(chiaki-jni "${ANDROID_LIB_LOG}" "${ANDROID_LIB_MEDIANDK}" "${ANDROID_LIB_ANDROID}")

add_subdirectory(src/main/cpp/oboe)
target_link_libraries(chiaki-jni oboe)