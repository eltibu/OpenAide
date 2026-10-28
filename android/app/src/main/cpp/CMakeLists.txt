# Models on the phone: llama.cpp, fetched at a pinned release, plus a small
# JNI bridge (openaide_llm.cpp) that LocalLlm.kt talks to.
cmake_minimum_required(VERSION 3.22.1)

project("openaide_llm" LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED true)

# The CPU code comes in one variant per family of ARM chips (dotprod, i8mm,
# SVE...); the best one for the phone is picked when the app starts. So new
# phones run fast and old ones still run.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_SYSTEM_ARCH "ARM" CACHE STRING "" FORCE)
    set(GGML_CPU_KLEIDIAI ON CACHE BOOL "" FORCE)
    set(GGML_OPENMP ON CACHE BOOL "" FORCE)
else()
    set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
endif()
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
    llama
    GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
    GIT_TAG b11946
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(llama)

add_library(openaide_llm SHARED openaide_llm.cpp)
target_include_directories(openaide_llm PRIVATE
    ${llama_SOURCE_DIR}/common
    ${llama_SOURCE_DIR}/include
    ${llama_SOURCE_DIR}/ggml/include)
target_link_libraries(openaide_llm llama llama-common android log)
