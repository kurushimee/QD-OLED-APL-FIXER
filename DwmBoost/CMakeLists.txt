cmake_minimum_required(VERSION 3.21)
project(DwmBoost CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")   # /MT: no VC runtime dependency inside dwm.exe

if(NOT MSVC)
    message(FATAL_ERROR "DwmBoost builds with MSVC only.")
endif()

add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

# --- MinHook (vendored, BSD-2) ---
add_library(minhook STATIC
    third_party/minhook/src/buffer.c
    third_party/minhook/src/hook.c
    third_party/minhook/src/trampoline.c
    third_party/minhook/src/hde/hde32.c
    third_party/minhook/src/hde/hde64.c)
target_include_directories(minhook PUBLIC third_party/minhook/include)

# --- Shader bytecode: regenerate boost_bytecode.h from boost.hlsl with the SDK fxc ---
find_program(FXC_EXE fxc HINTS
    "$ENV{WindowsSdkVerBinPath}x64"
    "C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64")
if(NOT FXC_EXE)
    message(FATAL_ERROR "fxc.exe not found; set it in PATH or install the Windows 10 SDK.")
endif()

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_SOURCE_DIR}/hook/boost_bytecode.h
    COMMAND ${CMAKE_COMMAND} -E env FXC=${FXC_EXE} cmd /c "${CMAKE_CURRENT_SOURCE_DIR}/hook/compile_shaders.cmd"
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/hook/boost.hlsl
            ${CMAKE_CURRENT_SOURCE_DIR}/../Shaders/PanelModel_27M2N6500.fxh
            ${CMAKE_CURRENT_SOURCE_DIR}/hook/compile_shaders.cmd
    COMMENT "Compiling boost.hlsl -> boost_bytecode.h")
add_custom_target(boost_bytecode DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/hook/boost_bytecode.h)

# --- Hook DLL ---
add_library(DwmBoostHook SHARED
    hook/dllmain.cpp
    hook/locate.cpp
    hook/flip_disable.cpp
    hook/present_hook.cpp
    hook/pipeline.cpp)
add_dependencies(DwmBoostHook boost_bytecode)
target_link_libraries(DwmBoostHook PRIVATE minhook d3d11 dxgi d3dcompiler)
set_target_properties(DwmBoostHook PROPERTIES OUTPUT_NAME "DwmBoostHook")

# --- Verify renderer: the hook's pipeline on a saved HDR frame ---
add_executable(RenderFrame
    verify/render_frame.cpp
    hook/pipeline.cpp)
add_dependencies(RenderFrame boost_bytecode)
target_include_directories(RenderFrame PRIVATE hook)
target_link_libraries(RenderFrame PRIVATE d3d11 windowscodecs ole32)

# --- Tray host ---
add_executable(DwmBoost WIN32
    app/main.cpp
    app/DwmBoost.rc
    app/app.manifest)
target_link_libraries(DwmBoost PRIVATE user32 shell32 dwmapi advapi32 gdi32)
# The app.manifest carries the UAC trustInfo; stop the linker synthesizing a conflicting one.
target_link_options(DwmBoost PRIVATE "/MANIFESTUAC:NO")
set_target_properties(DwmBoost PROPERTIES OUTPUT_NAME "DwmBoost")

# Put both next to each other so the host finds the DLL beside itself.
set_target_properties(DwmBoostHook DwmBoost RenderFrame PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
