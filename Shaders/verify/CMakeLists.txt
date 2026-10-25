cmake_minimum_required(VERSION 3.24)
project(EffectVerify CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT MSVC)
    message(FATAL_ERROR "RenderEffect builds with MSVC only.")
endif()

add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

include(FetchContent)

# --- ReShade 6.8.0's effect compiler, the runtime the shaders run under ---
# SOURCE_SUBDIR points at a folder without a CMakeLists.txt so only the sources get fetched.
FetchContent_Declare(reshade
    URL https://github.com/crosire/reshade/archive/18deaa52de0c425a78b329e9cb3c497281cd00ec.tar.gz
    URL_HASH SHA256=582184d6b278ed670a7b6811b5cb99541e3cf1de996998b8b9fed0de9991ef76
    SOURCE_SUBDIR source)
FetchContent_MakeAvailable(reshade)

# --- ReShade.fxh from reshade-shaders, the copy ReShade's installer puts next to the shaders ---
set(RESHADE_FXH_DIR ${CMAKE_BINARY_DIR}/reshade-shaders)
file(DOWNLOAD
    https://raw.githubusercontent.com/crosire/reshade-shaders/ee30868391d4ad103db60489820102d8fd40e3c1/Shaders/ReShade.fxh
    ${RESHADE_FXH_DIR}/ReShade.fxh
    EXPECTED_HASH MD5=47282a1a2afe26b488fddf25ef18ff9e)

# --- Effect runner: a ReShade effect on a saved HDR frame ---
set(RESHADEFX_SOURCE ${reshade_SOURCE_DIR}/source)
add_executable(RenderEffect
    render_effect.cpp
    ${RESHADEFX_SOURCE}/effect_codegen_dxbc.cpp
    ${RESHADEFX_SOURCE}/effect_expression.cpp
    ${RESHADEFX_SOURCE}/effect_lexer.cpp
    ${RESHADEFX_SOURCE}/effect_parser_exp.cpp
    ${RESHADEFX_SOURCE}/effect_parser_stmt.cpp
    ${RESHADEFX_SOURCE}/effect_preprocessor.cpp
    ${RESHADEFX_SOURCE}/effect_symbol_table.cpp)
target_include_directories(RenderEffect PRIVATE ${RESHADEFX_SOURCE})
target_compile_definitions(RenderEffect PRIVATE RESHADE_FXH_DIR=L"${RESHADE_FXH_DIR}")
target_compile_options(RenderEffect PRIVATE /utf-8 /Zc:char8_t-)
target_link_libraries(RenderEffect PRIVATE d3d11 d3dcompiler windowscodecs ole32)
set_target_properties(RenderEffect PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
