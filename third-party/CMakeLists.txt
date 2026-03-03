
if(NOT CHIAKI_USE_SYSTEM_NANOPB)
	##################
	# nanopb
	##################

	add_definitions(-DPB_C99_STATIC_ASSERT) # Fix PB_STATIC_ASSERT on msvc without using C11 for now
	add_subdirectory(nanopb EXCLUDE_FROM_ALL)
	set(NANOPB_GENERATOR_PY "${CMAKE_CURRENT_SOURCE_DIR}/nanopb/generator/nanopb_generator.py" PARENT_SCOPE)
	add_library(nanopb INTERFACE)
	target_link_libraries(nanopb INTERFACE protobuf-nanopb-static)
	target_include_directories(nanopb INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/nanopb")
	target_compile_definitions(nanopb INTERFACE -DPB_C99_STATIC_ASSERT) # see above
	add_library(Nanopb::nanopb ALIAS nanopb)
endif()

if(NOT CHIAKI_USE_SYSTEM_JERASURE)
	##################
	# gf-complete
	##################

	set(GF_COMPLETE_SOURCE
			gf-complete/src/gf.c
			gf-complete/src/gf_wgen.c
			gf-complete/src/gf_w4.c
			gf-complete/src/gf_w8.c
			gf-complete/src/gf_w16.c
			gf-complete/src/gf_w32.c
			gf-complete/src/gf_w64.c
			gf-complete/src/gf_w128.c
			gf-complete/src/gf_rand.c
			gf-complete/src/gf_general.c
			gf-complete/src/gf_cpu.c)

	# TODO: support NEON

	add_library(gf_complete STATIC ${GF_COMPLETE_SOURCE})
	target_include_directories(gf_complete PUBLIC gf-complete/include)

	##################
	# jerasure
	##################

	set(JERASURE_SOURCE
			jerasure/src/galois.c
			jerasure/src/jerasure.c
			jerasure/src/reed_sol.c
			jerasure/src/cauchy.c
			jerasure/src/liberation.c)

	add_library(jerasure STATIC ${JERASURE_SOURCE})
	target_include_directories(jerasure PUBLIC jerasure/include)
	target_link_libraries(jerasure gf_complete)

	add_library(Jerasure::Jerasure ALIAS jerasure)
endif()

if (NOT CHIAKI_IS_SWITCH) 
	if(NOT CHIAKI_USE_SYSTEM_CURL) 
		##################
		# libcurl (with experimental WebSocket support enabled)
		##################
		set(BUILD_EXE OFF)
		set(BUILD_SHARED_LIBS OFF)
		set(BUILD_STATIC_LIBS ON)
		set(CURL_DISABLE_INSTALL ON)
		set(HTTP_ONLY ON)
		set(ENABLE_WEBSOCKETS ON)
		if(IOS)
			# iOS: Use Apple's native Secure Transport for curl SSL.
			# This uses the iOS system trust store (managed by Apple, auto-updated via
			# iOS security patches). No bundled CA cert file needed.
			# Note: chiaki-lib still uses mbedTLS for its own crypto (AES/SHA), which
			# is completely separate from curl's SSL backend.
			set(CURL_USE_SECTRANSP ON CACHE BOOL "Use Secure Transport for curl on iOS" FORCE)
			set(CURL_USE_LIBSSH2 OFF CACHE BOOL "Disable libssh2" FORCE)
		elseif(ANDROID AND CHIAKI_LIB_ENABLE_MBEDTLS)
			# Android: Use mbedTLS for curl SSL (no native SSL API available from C).
			# Requires CA cert bundle set via CHIAKI_CA_BUNDLE env var at runtime.
			set(CURL_USE_MBEDTLS ON CACHE BOOL "Use mbedTLS for curl" FORCE)
			set(CURL_USE_LIBSSH2 OFF CACHE BOOL "Disable libssh2" FORCE)
			# mbedTLS was fetched via FetchContent in root CMakeLists.txt before this
			# Set include/library paths for curl to find mbedTLS
			if(mbedtls_SOURCE_DIR AND mbedtls_BINARY_DIR)
				set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include" CACHE PATH "mbedTLS include directory" FORCE)
				set(MBEDTLS_LIBRARY "${mbedtls_BINARY_DIR}/library/libmbedtls.a" CACHE FILEPATH "mbedtls library" FORCE)
				set(MBEDX509_LIBRARY "${mbedtls_BINARY_DIR}/library/libmbedx509.a" CACHE FILEPATH "mbedx509 library" FORCE)
				set(MBEDCRYPTO_LIBRARY "${mbedtls_BINARY_DIR}/library/libmbedcrypto.a" CACHE FILEPATH "mbedcrypto library" FORCE)
			endif()
		elseif(WIN32)
			set(USE_SSLEAY ON)
			set(CURL_USE_SCHANNEL ON)
		endif()
		find_package(PkgConfig QUIET)
		if (PKG_CONFIG_FOUND)
			pkg_check_modules(PkgLibIdn2 IMPORTED_TARGET GLOBAL libidn2)
		endif ()

		if (PkgLibIdn2_FOUND)
			set(LIBIDN2_INCLUDE_DIR ${PkgLibIdn2_INCLUDE_DIRS} CACHE FILEPATH "libidn2 include path")
			set(LIBIDN2_LIBRARIES ${PkgLibIdn2_LIBRARIES} CACHE STRING "libidn2 libraries")
			set(LIBIDN2_VERSION ${PkgLibIdn2_VERSION})
			add_library(Libidn2::Libidn2 ALIAS PkgConfig::PkgLibIdn2)
			set(Libidn2_FOUND ON)
		endif()
		add_subdirectory(curl)
		# Exported library is CURL::libcurl_static
	endif()
endif()

if(CHIAKI_ENABLE_STEAM_SHORTCUT)
	add_subdirectory(cpp-steam-tools)
endif()

if(CHIAKI_ENABLE_STEAMWORKS)
	add_subdirectory(steamworks)
endif()

if(ANDROID OR IOS)
	##################
	# json-c for Android/iOS (using FetchContent for proper build integration)
	# Always built since RUDP is always enabled for mobile
	##################
	include(FetchContent)
	
	# Configure json-c build options before fetching
	set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
	set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
	set(BUILD_APPS OFF CACHE BOOL "" FORCE)
	set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
	set(DISABLE_WERROR ON CACHE BOOL "" FORCE)
	
	FetchContent_Declare(
		jsonc
		GIT_REPOSITORY https://github.com/json-c/json-c.git
		GIT_TAG json-c-0.17-20230812
		GIT_SHALLOW TRUE
		SOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/_deps/json-c  # Name it json-c so includes work
	)
	FetchContent_MakeAvailable(jsonc)
	
	# Export include directory for chiaki-lib to use
	# The source is now in _deps/json-c, so parent dir allows #include <json-c/...>
	set(JSONC_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/_deps" CACHE PATH "json-c include directory" FORCE)
	
	##################
	# miniupnpc for Android (using FetchContent for proper build integration)
	##################
	# Configure miniupnpc build options before fetching
	set(UPNPC_BUILD_STATIC ON CACHE BOOL "" FORCE)
	set(UPNPC_BUILD_SHARED OFF CACHE BOOL "" FORCE)
	set(UPNPC_BUILD_TESTS OFF CACHE BOOL "" FORCE)
	set(UPNPC_BUILD_SAMPLE OFF CACHE BOOL "" FORCE)
	set(UPNPC_NO_INSTALL ON CACHE BOOL "" FORCE)
	
	FetchContent_Declare(
		miniupnp
		GIT_REPOSITORY https://github.com/miniupnp/miniupnp.git
		GIT_TAG miniupnpc_2_2_8
		GIT_SHALLOW TRUE
		SOURCE_SUBDIR miniupnpc
	)
	FetchContent_MakeAvailable(miniupnp)
	
	# Export include directory - miniupnpc headers are in miniupnpc/include/
	# The repo structure is miniupnp/miniupnpc/include/miniupnpc.h (NOT include/miniupnpc/miniupnpc.h)
	# Code uses #include <miniupnpc/miniupnpc.h>
	# The libminiupnpc-static target sets BUILD_INTERFACE to include/ which has miniupnpc.h directly
	# So we need a directory where 'miniupnpc' folder contains the headers
	# Solution: Create a wrapper directory structure at configure time
	# After FetchContent_MakeAvailable, miniupnp_SOURCE_DIR points to the repo root
	# With SOURCE_SUBDIR=miniupnpc, the actual miniupnpc source is at miniupnp_SOURCE_DIR/miniupnpc
	set(MINIUPNPC_WRAPPER_DIR "${CMAKE_CURRENT_BINARY_DIR}/miniupnpc-include-wrapper")
	file(MAKE_DIRECTORY "${MINIUPNPC_WRAPPER_DIR}/miniupnpc")
	# Copy headers to wrapper - headers are at miniupnp_SOURCE_DIR/miniupnpc/include/
	set(MINIUPNPC_SRC_INCLUDE "${miniupnp_SOURCE_DIR}/miniupnpc/include")
	file(GLOB MINIUPNPC_HEADERS "${MINIUPNPC_SRC_INCLUDE}/*.h")
	message(STATUS "miniupnp_SOURCE_DIR: ${miniupnp_SOURCE_DIR}")
	message(STATUS "Looking for headers in: ${MINIUPNPC_SRC_INCLUDE}")
	message(STATUS "Found miniupnpc headers: ${MINIUPNPC_HEADERS}")
	foreach(HEADER ${MINIUPNPC_HEADERS})
		get_filename_component(HEADER_NAME ${HEADER} NAME)
		configure_file(${HEADER} "${MINIUPNPC_WRAPPER_DIR}/miniupnpc/${HEADER_NAME}" COPYONLY)
	endforeach()
	# Also copy generated header from build dir (created during build, not configure)
	# We'll handle this in lib/CMakeLists.txt by also including the build dir
	set(MINIUPNPC_INCLUDE_DIR "${MINIUPNPC_WRAPPER_DIR}" CACHE PATH "miniupnpc include directory" FORCE)
	set(MINIUPNPC_BUILD_DIR "${miniupnp_BINARY_DIR}" CACHE PATH "miniupnpc build directory" FORCE)
	
	##################
	# opus for Android (using FetchContent for proper build integration)
	# Required for PSCloud audio decoding (unitized Opus format)
	##################
	# Configure opus build options before fetching
	set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
	set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
	set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
	set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
	set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
	
	FetchContent_Declare(
		opus
		GIT_REPOSITORY https://github.com/xiph/opus.git
		GIT_TAG v1.5.2
		GIT_SHALLOW TRUE
	)
	FetchContent_MakeAvailable(opus)
	
	# Create a wrapper include directory so #include <opus/opus.h> works
	# Opus headers are in opus_SOURCE_DIR/include/*.h
	# We need them accessible as opus/*.h
	set(OPUS_WRAPPER_DIR "${CMAKE_CURRENT_BINARY_DIR}/opus-include-wrapper")
	file(MAKE_DIRECTORY "${OPUS_WRAPPER_DIR}/opus")
	file(GLOB OPUS_HEADERS "${opus_SOURCE_DIR}/include/*.h")
	foreach(HEADER ${OPUS_HEADERS})
		get_filename_component(HEADER_NAME ${HEADER} NAME)
		configure_file(${HEADER} "${OPUS_WRAPPER_DIR}/opus/${HEADER_NAME}" COPYONLY)
	endforeach()
	
	# Create an alias target matching what find_package(Opus) would create
	# The opus library target is already created by opus's CMakeLists.txt
	set(Opus_INCLUDE_DIRS "${OPUS_WRAPPER_DIR}" CACHE PATH "opus include directory" FORCE)
	set(Opus_LIBRARIES opus CACHE STRING "opus libraries" FORCE)
	add_library(Opus::opus ALIAS opus)
endif()
