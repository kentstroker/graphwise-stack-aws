@echo off

call "%~dp0"\setvars.in.cmd

"%JAVA%" %JAVA_OPTS% %ONTOREFINE_JAVA_OPTS% -Dontorefine.dist="%ONTOREFINE_DIST%" -cp "%ONTOREFINE_CLASSPATH%" com.ontotext.refine.cli.Main %*
