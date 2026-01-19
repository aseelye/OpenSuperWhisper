# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libwhisper)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# Some AppleClang versions can still define __ARM_FEATURE_MATMUL_INT8 even when
# the build disables i8mm, which enables codepaths that then fail to compile
# (e.g. vmmlaq_s32 requires i8mm). Force-disable the macro for arm64 builds.
if (APPLE AND CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
    add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)
endif()

add_subdirectory(whisper.cpp)
