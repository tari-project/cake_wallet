cmake_minimum_required(VERSION 3.10)
project(cw_minotari LANGUAGES C)

if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  message(FATAL_ERROR "Minotari desktop currently supports Linux x86_64 only.")
endif()

set(MINOTARI_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/lib/librust_lib_flutter_rust_wallet.so")
if(NOT EXISTS "${MINOTARI_LIBRARY}")
  message(FATAL_ERROR "Missing Minotari native library. Run bash scripts/linux/build_minotari.sh first.")
endif()

# Flutter's FFI plugin installer copies this into the application's lib/ directory.
set(cw_minotari_bundled_libraries "${MINOTARI_LIBRARY}" PARENT_SCOPE)
