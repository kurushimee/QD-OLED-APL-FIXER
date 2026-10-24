@echo off
rem Regenerate boost_bytecode.h from boost.hlsl using the Windows SDK fxc.
rem Invoked by the CMake pre-build step; FXC is passed in, or found on PATH.
setlocal
set SRC=%~dp0boost.hlsl
set OUT=%~dp0boost_bytecode.h
if "%FXC%"=="" set FXC=fxc.exe

set TMP=%TEMP%\dwmboost_fxc
if exist "%TMP%" rmdir /s /q "%TMP%"
mkdir "%TMP%"

call :one CS_SetupAndClearAPLFullFrameRowHistograms      cs_5_0 g_CS_Setup  || exit /b 1
call :one CS_BuildAPLFullFrameRowHistogram               cs_5_0 g_CS_Build  || exit /b 1
call :one CS_ReduceAPLFullFrameRowHistogram              cs_5_0 g_CS_Reduce || exit /b 1
call :one CS_EvaluateSolveAndSmoothAPLFullFrameHistogram cs_5_0 g_CS_Solve  || exit /b 1
call :one PostProcessVS                                  vs_5_0 g_VS_Boost  || exit /b 1
call :one PS_MainPass                                    ps_5_0 g_PS_Boost  || exit /b 1

> "%OUT%" echo // Generated from boost.hlsl by compile_shaders.cmd. Do not edit.
>>"%OUT%" echo #pragma once
type "%TMP%\g_CS_Setup.h"  >> "%OUT%"
type "%TMP%\g_CS_Build.h"  >> "%OUT%"
type "%TMP%\g_CS_Reduce.h" >> "%OUT%"
type "%TMP%\g_CS_Solve.h"  >> "%OUT%"
type "%TMP%\g_VS_Boost.h"  >> "%OUT%"
type "%TMP%\g_PS_Boost.h"  >> "%OUT%"
rmdir /s /q "%TMP%"
echo boost_bytecode.h written
exit /b 0

:one
"%FXC%" /nologo /T %2 /E %1 /O3 /Fh "%TMP%\%3.h" /Vn %3 "%SRC%"
exit /b %errorlevel%
