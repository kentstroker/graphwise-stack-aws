@echo off

:: script must be used with setlocal enabledelayedexpansion

:: Set OntoRefine dist directory
set SCRIPT=%~dp0
for %%I in ("%SCRIPT%..") do set "ONTOREFINE_DIST=%%~dpfI"

:: Note that if someone has moved the script manually, this would not work

:: Find java.exe
if exist "%ONTOREFINE_DIST%\..\runtime\" (
    :: Our bundled JDK
    set "JAVA=%ONTOREFINE_DIST%\..\runtime\bin\java.exe"
) else (
    :: Java from JAVA_HOME or path
    if "%JAVA_HOME%" == "" (
        :: If JAVA_HOME isn't set look for java.exe in the PATH
        for %%I in (java.exe) do set "JAVA=%%~$PATH:I"
        if '!JAVA!' == '' (
            echo Could not find any executable java binary. Please install java in your PATH or set JAVA_HOME.
            exit /b 1
        )
    ) else (
        :: Use java.exe from JAVA_HOME
        set "JAVA=%JAVA_HOME%\bin\java.exe"
    )
)

:: Supported Java versions
set SUPPORTED_JAVA_VERSIONS=11 16

set JAVA_VERSION=0
for /f "tokens=3" %%g in ('"%JAVA%" -version 2^>^&1 ^| findstr /i version') do (
    set JAVA_VERSION=%%g
)
set JAVA_VERSION=%JAVA_VERSION:"=%
for /f "delims=.-_ tokens=1-2" %%v in ("%JAVA_VERSION%") do (
    if /I "%%v" EQU "1" (
        set JAVA_VERSION=%%w
    ) else (
        set JAVA_VERSION=%%v
    )
)

set _is_supported=false
for %%v in (%SUPPORTED_JAVA_VERSIONS%) do (
    if /i %JAVA_VERSION% equ %%v (
        set _is_supported=true
    )
    set _last_version=%%v
)

if "%_is_supported%"=="false" (
    set HUMAN_READABLE_JAVA_VERSIONS=
    for %%v in (%SUPPORTED_JAVA_VERSIONS%) do (
        if "!HUMAN_READABLE_JAVA_VERSIONS!"=="" (
            set HUMAN_READABLE_JAVA_VERSIONS=%%v
        ) else (
            if NOT "%_last_version%"=="%%v" (
                set HUMAN_READABLE_JAVA_VERSIONS=!HUMAN_READABLE_JAVA_VERSIONS!, %%v
            ) else (
                set HUMAN_READABLE_JAVA_VERSIONS=!HUMAN_READABLE_JAVA_VERSIONS! or %%v
            )
        )
    )

    echo This OntoRefine distribution requires Java !HUMAN_READABLE_JAVA_VERSIONS! but you have Java !JAVA_VERSION!
    echo Execution will continue in 5 seconds
    timeout 5 /nobreak > nul
)

:: Empty default for version specific options
set JAVA_VERSION_OPTS=

:: Include Java exports for Java 9+
if %JAVA_VERSION% GEQ 9 (
	set JAVA_VERSION_OPTS=%JAVA_VERSION_OPTS% --add-exports jdk.management.agent/jdk.internal.agent=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED
)

:: By default the -XX:MaxDirectMemorySize is limited to the heap size
if NOT "%ONTOREFINE_JAVA_32BIT%" == "true" (
	set JAVA_VERSION_OPTS=%JAVA_VERSION_OPTS% -XX:MaxDirectMemorySize=128G
)

set "ONTOREFINE_CLASSPATH=%ONTOREFINE_DIST%\lib\*"

call "%~dp0\ontorefine.in.cmd" || exit /b 1
