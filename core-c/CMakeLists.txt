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
option(CAPGO_FUZZ "Build the libFuzzer targets of fuzz/ (clang, with CAPGO_SHARED=OFF)" OFF)
# address,undefined / thread: sanitizer builds for the test suite (host only).
set(CAPGO_SANITIZE "" CACHE STRING "Sanitizers for the test build, e.g. address,undefined or thread")
# Port in progress: link with unresolved symbols (resolved lazily, missing modules crash only if called).
option(CAPGO_ALLOW_UNDEFINED "Allow undefined symbols in the shared library" OFF)

include(FetchContent)
set(FETCHCONTENT_QUIET ON)
# Each archive is downloaded once into core-c/.deps (shared by every build directory and ABI),
# then verified by SHA-256 before use.
set(CAPGO_DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.deps" CACHE PATH "Download cache of the dependencies")
function(capgo_fetch name url sha256 extension)
  # The extension tells older CMake (3.20+) how to extract the archive.
  set(archive "${CAPGO_DEPS_DIR}/${name}-${sha256}.${extension}")
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
  4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8 tar.bz2)
capgo_fetch(capgo_brotli
  https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz
  816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec tar.gz)
capgo_fetch(capgo_ngtcp2
  https://github.com/ngtcp2/ngtcp2/releases/download/v1.25.0/ngtcp2-1.25.0.tar.xz
  2a34d2484ba17847a5d11965704e9dd0fac4c6d8efc75ffe1ec7de66d8c6b6fb tar.xz)
capgo_fetch(capgo_nghttp3
  https://github.com/ngtcp2/nghttp3/releases/download/v1.18.0/nghttp3-1.18.0.tar.xz
  aad782c23d3f01bd4bb52c8bac7a553b631ef8115fd1612703df6183449fef19 tar.xz)
capgo_fetch(capgo_picotls
  https://github.com/h2o/picotls/archive/112054bc74e6d2be646421a7a134ebdf7ea038f9.tar.gz
  b3c1ed3887146cd290b7593fd5513c83db55251cd86488b8e793176eb3217e43 tar.gz)
FetchContent_MakeAvailable(capgo_mbedtls capgo_brotli capgo_ngtcp2 capgo_nghttp3 capgo_picotls)

# Compile into the same archive so iOS's static library contains every dependency.
set(PACKAGE_VERSION 1.25.0)
set(PACKAGE_VERSION_NUM 0x011900)
configure_file(${capgo_ngtcp2_SOURCE_DIR}/lib/includes/ngtcp2/version.h.in
  ${CMAKE_CURRENT_BINARY_DIR}/quic-include/ngtcp2/version.h @ONLY)
set(PACKAGE_VERSION 1.18.0)
set(PACKAGE_VERSION_NUM 0x011200)
configure_file(${capgo_nghttp3_SOURCE_DIR}/lib/includes/nghttp3/version.h.in
  ${CMAKE_CURRENT_BINARY_DIR}/quic-include/nghttp3/version.h @ONLY)
# The upstream picotls adapter names OpenSSL's picotls algorithms. Use the equivalent
# Mbed TLS algorithms; the adapter otherwise calls the backend-independent picotls API.
file(READ ${capgo_ngtcp2_SOURCE_DIR}/crypto/picotls/picotls.c PICOTLS_ADAPTER)
string(REPLACE "picotls/openssl.h" "picotls/mbedtls.h" PICOTLS_ADAPTER "${PICOTLS_ADAPTER}")
string(REPLACE "ptls_openssl_" "ptls_mbedtls_" PICOTLS_ADAPTER "${PICOTLS_ADAPTER}")
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/picotls-adapter.c "${PICOTLS_ADAPTER}")
# Mbed TLS 3.6 copies PSA output buffers unless exclusive buffers are enabled.
# picotls passes SIZE_MAX as their capacity, which would allocate SIZE_MAX bytes.
# Pass the actual remaining allocation instead (plaintext length plus tag).
file(READ ${capgo_picotls_SOURCE_DIR}/lib/mbedtls.c PICOTLS_MBEDTLS)
string(REPLACE "size_t outlen, taglen;" "size_t outlen, taglen, capacity = ctx->super.algo->tag_size;\n    for (size_t i = 0; i < incnt; i++) capacity += input[i].len;"
  PICOTLS_MBEDTLS "${PICOTLS_MBEDTLS}")
string(REPLACE "dst, SIZE_MAX, &outlen" "dst, capacity - (size_t)(dst - (uint8_t *)output), &outlen"
  PICOTLS_MBEDTLS "${PICOTLS_MBEDTLS}")
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/picotls-mbedtls.c "${PICOTLS_MBEDTLS}")
file(GLOB QUIC_SOURCES ${capgo_ngtcp2_SOURCE_DIR}/lib/*.c ${capgo_nghttp3_SOURCE_DIR}/lib/*.c)
list(APPEND QUIC_SOURCES
  ${capgo_nghttp3_SOURCE_DIR}/lib/sfparse/sfparse.c
  ${capgo_ngtcp2_SOURCE_DIR}/crypto/shared.c
  ${CMAKE_CURRENT_BINARY_DIR}/picotls-adapter.c
  ${capgo_picotls_SOURCE_DIR}/lib/picotls.c
  ${capgo_picotls_SOURCE_DIR}/lib/hpke.c
  ${capgo_picotls_SOURCE_DIR}/lib/pembase64.c
  ${CMAKE_CURRENT_BINARY_DIR}/picotls-mbedtls.c)

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
  add_library(capgo_updater_core SHARED ${CORE_SOURCES} ${MBEDTLS_SOURCES} ${BROTLI_SOURCES} ${QUIC_SOURCES})
else()
  add_library(capgo_updater_core STATIC ${CORE_SOURCES} ${MBEDTLS_SOURCES} ${BROTLI_SOURCES} ${QUIC_SOURCES})
endif()

target_include_directories(capgo_updater_core
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/config
          ${capgo_mbedtls_SOURCE_DIR}/include ${capgo_mbedtls_SOURCE_DIR}/library
          ${capgo_brotli_SOURCE_DIR}/c/include
          ${CMAKE_CURRENT_BINARY_DIR}/quic-include
          ${capgo_ngtcp2_SOURCE_DIR}/lib/includes ${capgo_ngtcp2_SOURCE_DIR}/lib
          ${capgo_ngtcp2_SOURCE_DIR}/crypto/includes ${capgo_ngtcp2_SOURCE_DIR}/crypto
          ${capgo_nghttp3_SOURCE_DIR}/lib/includes ${capgo_nghttp3_SOURCE_DIR}/lib
          ${capgo_picotls_SOURCE_DIR}/include)
target_compile_definitions(capgo_updater_core PRIVATE
  NGTCP2_STATICLIB NGHTTP3_STATICLIB PTLS_HAVE_LOG=0
  HAVE_ARPA_INET_H=1 HAVE_NETINET_IN_H=1 HAVE_UNISTD_H=1 PTLS_OPENSSL_HAVE_CHACHA20_POLY1305=1
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

# Hardening of shipped builds (every source, dependencies included). Costs are measured in
# COMPARISON.md (Crash safety). Sanitizer and fuzzing builds do without: their runtimes check
# more, and _FORTIFY_SOURCE wrappers hide accesses from AddressSanitizer.
option(CAPGO_HARDEN "Stack protector, _FORTIFY_SOURCE=3, zero-initialized locals, RELRO/BIND_NOW" ON)
if(CAPGO_HARDEN AND NOT CAPGO_SANITIZE AND NOT CAPGO_FUZZ)
  # Overflowing a stack buffer aborts; locals start zeroed instead of holding stale data.
  target_compile_options(capgo_updater_core PRIVATE -fstack-protector-strong -ftrivial-auto-var-init=zero)
  # libc bounds checks on memcpy/strlen/snprintf... (__builtin_dynamic_object_size); needs -O.
  target_compile_options(capgo_updater_core PRIVATE
    $<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE> $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=3>)
  if(ANDROID)
    # Already the NDK linker's defaults: kept explicit so a toolchain change cannot drop them.
    target_link_options(capgo_updater_core PRIVATE -Wl,-z,relro,-z,now -Wl,-z,noexecstack)
  endif()
endif()

find_package(ZLIB REQUIRED)
find_package(Threads REQUIRED)
target_link_libraries(capgo_updater_core PRIVATE ZLIB::ZLIB Threads::Threads)
if(ANDROID)
  target_link_libraries(capgo_updater_core PRIVATE log)
endif()

# libFuzzer targets (fuzz/<target>.c, same targets and corpus as core/fuzz): clang only, built
# with -DCAPGO_FUZZ=ON -DCAPGO_SHARED=OFF (scripts/fuzz.sh). Every source, dependencies
# included, gets coverage, AddressSanitizer and UndefinedBehaviorSanitizer (abort on error).
if(CAPGO_FUZZ)
  if(CAPGO_SHARED)
    message(FATAL_ERROR "CAPGO_FUZZ needs -DCAPGO_SHARED=OFF (the harnesses call internal functions)")
  endif()
  set(CAPGO_FUZZ_FLAGS -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=all
      -fno-omit-frame-pointer -g)
  target_compile_options(capgo_updater_core PRIVATE ${CAPGO_FUZZ_FLAGS})
  file(GLOB CAPGO_FUZZ_TARGETS ${CMAKE_CURRENT_SOURCE_DIR}/fuzz/*.c)
  list(FILTER CAPGO_FUZZ_TARGETS EXCLUDE REGEX ".*/fuzz_support\\.c$")
  foreach(source ${CAPGO_FUZZ_TARGETS})
    get_filename_component(name ${source} NAME_WE)
    add_executable(fuzz_${name} ${source} ${CMAKE_CURRENT_SOURCE_DIR}/fuzz/fuzz_support.c)
    target_include_directories(fuzz_${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
      ${CMAKE_CURRENT_SOURCE_DIR}/config ${capgo_mbedtls_SOURCE_DIR}/include ${capgo_brotli_SOURCE_DIR}/c/include)
    target_compile_definitions(fuzz_${name} PRIVATE MBEDTLS_USER_CONFIG_FILE="capgo_mbedtls_config.h"
      _GNU_SOURCE _DARWIN_C_SOURCE _FILE_OFFSET_BITS=64)
    target_compile_options(fuzz_${name} PRIVATE -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all
      -fno-omit-frame-pointer -g -Wall -Wextra)
    target_link_options(fuzz_${name} PRIVATE -fsanitize=fuzzer,address,undefined)
    target_link_libraries(fuzz_${name} PRIVATE capgo_updater_core ZLIB::ZLIB Threads::Threads)
  endforeach()
endif()
