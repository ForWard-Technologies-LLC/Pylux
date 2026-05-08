
find_program(PROTOC protoc)

if(ANDROID)
	# Android: Try Python's grpc_tools.protoc if system protoc not found
	if(NOT PROTOC AND PYTHON_EXECUTABLE)
		execute_process(
			COMMAND "${PYTHON_EXECUTABLE}" -c "import grpc_tools.protoc; print('found')"
			OUTPUT_VARIABLE PYTHON_PROTOC_CHECK
			ERROR_QUIET
			OUTPUT_STRIP_TRAILING_WHITESPACE
		)
		if(PYTHON_PROTOC_CHECK STREQUAL "found")
			set(USE_PYTHON_PROTOC TRUE)
			message(STATUS "Using Python protoc from grpc_tools")
		endif()
	endif()

	if(NOT PROTOC AND NOT USE_PYTHON_PROTOC)
		message(FATAL_ERROR "Could not find protoc (tried system protoc and Python grpc_tools)")
	endif()

	if(USE_PYTHON_PROTOC)
		add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/takion.pb"
				COMMAND "${PYTHON_EXECUTABLE}" -m grpc_tools.protoc "--proto_path=${CMAKE_CURRENT_SOURCE_DIR}" "--descriptor_set_out=${CMAKE_CURRENT_BINARY_DIR}/takion.pb" "${CMAKE_CURRENT_SOURCE_DIR}/takion.proto"
				MAIN_DEPENDENCY "${CMAKE_CURRENT_SOURCE_DIR}/takion.proto")
	else()
		add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/takion.pb"
				COMMAND "${PROTOC}" "-o${CMAKE_CURRENT_BINARY_DIR}/takion.pb" "${CMAKE_CURRENT_SOURCE_DIR}/takion.proto" "-I${CMAKE_CURRENT_SOURCE_DIR}"
				MAIN_DEPENDENCY "${CMAKE_CURRENT_SOURCE_DIR}/takion.proto")
	endif()

	set(GEN_PREFIX "")
else()
	# Non-Android: Original logic - require system protoc
	if(NOT PROTOC)
		message(FATAL_ERROR "Could not find protoc")
	endif()

	add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/takion.pb"
			COMMAND "${PROTOC}" "-o${CMAKE_CURRENT_BINARY_DIR}/takion.pb" "${CMAKE_CURRENT_SOURCE_DIR}/takion.proto" "-I${CMAKE_CURRENT_SOURCE_DIR}"
			MAIN_DEPENDENCY "${CMAKE_CURRENT_SOURCE_DIR}/takion.proto")

	if(UNIX AND IS_ABSOLUTE "${PROTOC}")
		# make sure protoc is in PATH when invoking the generator below, which needs it.
		get_filename_component(PROTOC_PATH "${PROTOC}" DIRECTORY)
		set(GEN_PREFIX "${CMAKE_COMMAND}" -E env "PATH=${PROTOC_PATH}:$ENV{PATH}")
	else()
		set(GEN_PREFIX "")
	endif()
endif()

set(SOURCE_FILES "${CMAKE_CURRENT_BINARY_DIR}/takion.pb.c")
set(HEADER_FILES "${CMAKE_CURRENT_BINARY_DIR}/takion.pb.h")

add_custom_command(OUTPUT ${SOURCE_FILES} ${HEADER_FILES}
		COMMAND ${GEN_PREFIX} "${PYTHON_EXECUTABLE}" "${NANOPB_GENERATOR_PY}" "${CMAKE_CURRENT_BINARY_DIR}/takion.pb"
		MAIN_DEPENDENCY "${CMAKE_CURRENT_BINARY_DIR}/takion.pb")

set(CHIAKI_LIB_PROTO_SOURCE_FILES "${SOURCE_FILES}" PARENT_SCOPE)
set(CHIAKI_LIB_PROTO_HEADER_FILES "${HEADER_FILES}" PARENT_SCOPE)
set(CHIAKI_LIB_PROTO_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}" PARENT_SCOPE)

add_custom_target(chiaki-pb DEPENDS ${SOURCE_FILES} ${HEADER_FILES})
