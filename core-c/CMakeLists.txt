# Capgo updater core, C implementation of include/capgo_updater_core.h.
#
#   cmake -S core-c -B core-c/build -DCMAKE_BUILD_TYPE=Release [-DCAPGO_TEST_SUPPORT=ON] [-DCAPGO_JNI=ON]
#
# Dependencies are fetched at configure time (pinned by SHA-256): Mbed TLS (TLS client,
# AES, SHA-256, RSA big numbers) and the Brotli decoder. zlib comes from the platform
# (Android NDK, Apple SDKs, Linux).
cmake_minimum_required(VERSION 3.20)
project(capgo_updater_core_c C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(CAPGO_TEST_SUPPORT "Build the test.* operations used by core/tests" OFF)
option(CAPGO_JNI "Build the JNI entry points (Android, JVM unit tests)" OFF)
option(CAPGO_SHARED "Build a shared library (static otherwise)" ON)
# address,undefined / thread: sanitizer builds for the test suite (host only).
set(CAPGO_SANITIZE "" CACHE STRING "Sanitizers for the test build, e.g. address,undefined or thread")
# Port in progress: link with unresolved symbols (resolved lazily, missing modules crash only if called).
option(CAPGO_ALLOW_UNDEFINED "Allow undefined symbols in the shared library" OFF)

include(FetchContent)
set(FETCHCONTENT_QUIET ON)
# Each archive is downloaded once into core-c/.deps (shared by every build directory and ABI),
# then verified by SHA-256 before use.
set(CAPGO_DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.deps" CACHE PATH "Download cache of the dependencies")
function(capgo_fetch name url sha256)
  set(archive "${CAPGO_DEPS_DIR}/${name}-${sha256}")
  if(NOT EXISTS "${archive}")
    foreach(attempt RANGE 1 3)
      file(DOWNLOAD "${url}" "${archive}.part" EXPECTED_HASH SHA256=${sha256} STATUS status TLS_VERIFY ON)
      list(GET status 0 code)
      if(code EQUAL 0)
        file(RENAME "${archive}.part" "${archive}")
        break()
      endif()
      file(REMOVE "${archive}.part")
      message(WARNING "Download of ${url} failed (attempt ${attempt}): ${status}")
    endforeach()
    if(NOT EXISTS "${archive}")
      message(FATAL_ERROR "Could not download ${url}")
    endif()
  endif()
  FetchContent_Declare(${name}
    URL "${archive}"
    URL_HASH SHA256=${sha256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR not-a-cmake-project)
endfunction()
capgo_fetch(capgo_mbedtls
  https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2
  4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8)
capgo_fetch(capgo_brotli
  https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz
  816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec)
FetchContent_MakeAvailable(capgo_mbedtls capgo_brotli)

file(GLOB MBEDTLS_SOURCES ${capgo_mbedtls_SOURCE_DIR}/library/*.c)
file(GLOB BROTLI_SOURCES ${capgo_brotli_SOURCE_DIR}/c/common/*.c ${capgo_brotli_SOURCE_DIR}/c/dec/*.c)
file(GLOB_RECURSE CORE_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/*.c)
if(NOT CAPGO_JNI)
  list(FILTER CORE_SOURCES EXCLUDE REGEX ".*/jni\\.c$")
endif()
if(NOT CAPGO_TEST_SUPPORT)
  list(FILTER CORE_SOURCES EXCLUDE REGEX ".*/testing[^/]*\\.c$")
endif()

if(CAPGO_SHARED)
  add_library(capgo_updater_core SHARED ${CORE_SOURCES} ${MBEDTLS_SOURCES} ${BROTLI_SOURCES})
else()
  add_library(capgo_updater_core STATIC ${CORE_SOURCES} ${MBEDTLS_SOURCES} ${BROTLI_SOURCES})
endif()

target_include_directories(capgo_updater_core
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/config
          ${capgo_mbedtls_SOURCE_DIR}/include ${capgo_mbedtls_SOURCE_DIR}/library
          ${capgo_brotli_SOURCE_DIR}/c/include)
target_compile_definitions(capgo_updater_core PRIVATE
  MBEDTLS_USER_CONFIG_FILE="capgo_mbedtls_config.h"
  _GNU_SOURCE _DARWIN_C_SOURCE _FILE_OFFSET_BITS=64)
if(CAPGO_TEST_SUPPORT)
  target_compile_definitions(capgo_updater_core PRIVATE CAPGO_TEST_SUPPORT=1)
endif()
if(CAPGO_JNI)
  target_compile_definitions(capgo_updater_core PRIVATE CAPGO_JNI=1)
  if(NOT ANDROID)
    find_package(JNI REQUIRED)
    target_include_directories(capgo_updater_core PRIVATE ${JNI_INCLUDE_DIRS})
  endif()
endif()

# Only the C ABI (and JNI) is exported.
set_target_properties(capgo_updater_core PROPERTIES C_VISIBILITY_PRESET hidden)
target_compile_options(capgo_updater_core PRIVATE -ffunction-sections -fdata-sections)
set_source_files_properties(${CORE_SOURCES} PROPERTIES COMPILE_OPTIONS
  "-Wall;-Wextra;-Wno-unused-parameter;-Wno-missing-field-initializers")
if(CAPGO_ALLOW_UNDEFINED)
  if(APPLE)
    target_link_options(capgo_updater_core PRIVATE -Wl,-undefined,dynamic_lookup)
  endif()
endif()
if(APPLE)
  target_link_options(capgo_updater_core PRIVATE -Wl,-dead_strip)
else()
  target_link_options(capgo_updater_core PRIVATE -Wl,--gc-sections)
endif()

if(CAPGO_SANITIZE)
  target_compile_options(capgo_updater_core PRIVATE -fsanitize=${CAPGO_SANITIZE} -fno-omit-frame-pointer -g)
  target_link_options(capgo_updater_core PRIVATE -fsanitize=${CAPGO_SANITIZE})
endif()

find_package(ZLIB REQUIRED)
find_package(Threads REQUIRED)
target_link_libraries(capgo_updater_core PRIVATE ZLIB::ZLIB Threads::Threads)
if(ANDROID)
  target_link_libraries(capgo_updater_core PRIVATE log)
endif()
