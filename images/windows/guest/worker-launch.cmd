@echo off
rem =====================================================================
rem EasyWorker Windows guest launcher  (v1.5.0: docker user + elevation)
rem
rem Started by the `EasyWorker` scheduled task, which runs as `Docker` in
rem the interactive session (UAC is disabled in this image and Docker is an
rem Administrator, so this process already holds a full High-IL admin token
rem - jobs therefore need no UAC/elevation dance at all).
rem
rem Responsibilities:
rem   1. fetch the pod-provided WORKER_TOKEN from http://host.lan:8090/token
rem   2. start easyworker.exe as the current (docker) user, writing its log
rem      somewhere a job can read.
rem =====================================================================
setlocal enabledelayedexpansion

set "EWROOT=C:\Users\Docker"
set "BIN=%EWROOT%\easyworker.exe"
set "EWWS=%EWROOT%\ewws"
set "LOG=%EWWS%\easyworker.log"

if not exist "%EWWS%" mkdir "%EWWS%"

rem --- 1. token (pre-authorization). Empty -> normal claim flow. --------
set "WORKER_TOKEN="
set /a N=0
:try
for /f "usebackq delims=" %%i in (`curl.exe -s -m 2 http://host.lan:8090/token 2^>nul`) do set "WORKER_TOKEN=%%i"
if defined WORKER_TOKEN goto have
set /a N+=1
if !N! lss 10 (ping -n 2 127.0.0.1 >nul & goto try)

:have
rem --- 2. run the worker in this (docker) session -----------------------
>>"%LOG%" echo [%DATE% %TIME%] launcher: starting worker as %USERNAME%
"%BIN%" -addr 0.0.0.0:48080 -workspace "%EWWS%" -db "%EWWS%\jobs.db" >>"%LOG%" 2>&1

endlocal
