@echo off
rem =====================================================================
rem ewelevate.cmd - run a command as NT AUTHORITY\SYSTEM.
rem
rem The worker normally runs as `docker`, which in this image is already an
rem Administrator with a full High-IL token (UAC is disabled), so most jobs
rem need nothing special. This helper is the escape hatch for the few things
rem that require SYSTEM itself (e.g. SeDebugPrivilege, or service/driver ops
rem that must not land in an interactive session).
rem
rem   ewelevate.cmd "cmd /c some-command > C:\path\out.txt 2>&1"
rem   ewelevate.cmd someprogram.exe arg1 arg2
rem
rem NOTE: output must go to a file or a service - a SYSTEM process has no
rem console to print to.
rem
rem Implementation: write a wrapper .cmd holding the command line, run it via a
rem one-shot SYSTEM scheduled task, and wait for a sentinel the wrapper drops.
rem Delayed expansion is used so redirection characters in the command are
rem written literally rather than being consumed by this script's echo.
rem =====================================================================
setlocal enabledelayedexpansion
if "%~1"=="" (
  echo usage: ewelevate.cmd "command line" 1>&2
  exit /b 2
)

set "TAG=%RANDOM%%RANDOM%%RANDOM%"
set "WRAP=%TEMP%\ewelevate_%TAG%.cmd"
set "DONE=%TEMP%\ewelevate_%TAG%.done"
set "TASK=EWElevate_%TAG%"

rem Join all args verbatim into the wrapper line, preserving inner quotes.
set "CMD=%~1"
shift
:join
if "%~1"=="" goto joined
set "CMD=!CMD! %~1"
shift
goto join
:joined

> "%WRAP%" echo @echo off
>>"%WRAP%" echo !CMD!
>>"%WRAP%" echo ^> "%DONE%" echo done

schtasks /create /tn "%TASK%" /tr "%WRAP%" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f >nul
if errorlevel 1 ( echo ewelevate: create failed 1>&2 & del "%WRAP%" 2>nul & exit /b 1 )

schtasks /run /tn "%TASK%" >nul
if errorlevel 1 ( schtasks /delete /tn "%TASK%" /f >nul 2>&1 & del "%WRAP%" 2>nul & echo ewelevate: run failed 1>&2 & exit /b 1 )

for /l %%i in (1,1,120) do (
  if exist "%DONE%" goto finished
  ping -n 2 127.0.0.1 >nul
)
echo ewelevate: timed out waiting for SYSTEM command 1>&2

:finished
schtasks /delete /tn "%TASK%" /f >nul 2>&1
del "%DONE%" 2>nul
del "%WRAP%" 2>nul
exit /b 0
