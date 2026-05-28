@echo off

:: OPTIONS:
::    -h
::    --help        print command line options
::    --extensions  set Ontotext Refine butterfly module extensions.
::    -Dprop        set Java system property
::    -Xprop        set non-standard Java system property
::
:: CONTROLLING STARTUP:
::
:: You can use these environment variables to control some options:
::
::    ONTOREFINE_JAVA_OPTS      - Sets additional Java options (-D or -X)
::    ONTOREFINE_JAVA_32BIT     - Configures (if set to true) OntoRefine to run on 32bit Java
::    ONTOREFINE_MIN_MEM        - Sets the Java minimum heap size (-Xms option).
::    ONTOREFINE_MAX_MEM        - Sets the Java maximum heap size (-Xmx option).
::    ONTOREFINE_HEAP_SIZE      - Sets the Java minimum and maximum heap size (-Xms and -Xmx option).
::                         Overrides both ONTOREFINE_MIN_MEM and ONTOREFINE_MAX_MEM.
::                         Recommended if you need to specify the heap size.
::    ONTOREFINE_HEAP_NEWSIZE   - Sets the initial and maximum heap size for the young generation (-Xmn option).
::    ONTOREFINE_GC_LOG         - Enables (if set to true) the logging of Java garbage collection.
::                         The log will be written to gc-<pid>.log in the distribution directory,
::                         unless ONTOREFINE_GC_LOG_FILE is set to a custom file.
::    ONTOREFINE_GC_LOG_FILE    - Specifies a custom file for GC logging.


setlocal enabledelayedexpansion

call "%~dp0"\setvars.in.cmd || exit /b 1

:: Stores each argument into two 1-based arrays, argArray and nextArgArray, where nextArgArray is shifted to the left.
:: Each argument is stripped of any surrounding double quotes.
set argCount=0
for %%x in (%*) do (
    set /A argCount+=1
    set "argArray[!argCount!]=%%~x"
    if !argCount! gtr 1 (
        set /A argCount2=argCount-1
        set "nextArgArray[!argCount2!]=%%~x"
    )
)

set _mainClass=OntoRefine
set _cmdLine=

set _skipNext=
for /L %%i in (1,1,%argCount%) do (
    set "_arg=!argArray[%%i]!"
    set "_nextArg=!nextArgArray[%%i]!"

    if "!_skipNext!" == "yes" (
        :: Skip this argument as it was appended to previous argument
        set _skipNext=
    ) else (
        if "!_arg!" == "-h" (
            call :Usage
            exit /b 1
        )
        if "!_arg!" == "--help" (
            call :Usage
            exit /b 1
        )

        set _minusDorX=
        if "!_arg:~0,2!" == "-D" (
            set _minusDorX=yes
        ) else if "!_arg:~0,2!" == "-X" (
            set _minusDorX=yes
        )

        if "!_minusDorX!" == "yes" (
            :: Handle the case where -Dfoo=bar or -Xfoo=bar is mangled by cmd.exe into two parameters "-Dfoo" and "bar"
            if %%i lss %argCount% (
                if "!_nextArg:~0,1!" neq "-" (
                    set "_arg=!_arg!=!_nextArg!"
                    set _skipNext=yes
                )
            )
        ) else if "!_arg!" == "--extensions" (
           set _arg="-Dbutterfly.modules.path=!_nextArg!"
           set _skipNext=yes
        ) else (
            call :ErrorAndUsage "Invalid parameter: !_arg!"
            exit /b 1
        )

        if "!_arg!" neq "" (
            set "_cmdLine=!_cmdLine! ^"!_arg!^""
        )
    )
)

set _mainClass=com.ontotext.ontorefine.!_mainClass!

"%JAVA%" %JAVA_OPTS% %ONTOREFINE_JAVA_OPTS% -Dontorefine.dist="%ONTOREFINE_DIST%" -cp "%ONTOREFINE_CLASSPATH%" !_cmdLine! !_mainClass! < nul
goto :eof

:Usage
    echo Usage: ontorefine [-h] [-Dprop] [-Xprop]
    echo Start OntoRefine.
    echo     -h
    echo     --help        print command line options
    echo     --extensions  set Ontotext Refine butterfly module extensions.
    echo     -Dprop        set Java system property
    echo     -Xprop        set non-standard Java system property
    echo:
    echo Note: to pass a double quote as part of an argument, surround the entire argument
    echo in double quotes and escape the double quote with another double quote, e.g.:
    echo:
    echo     "-Dmy.property=value-with-""-in-it" will set the property my.property to value-with-^"-in-it
    exit /b

:ErrorAndUsage
    echo %~1
    echo:
    call :Usage
    exit /b
