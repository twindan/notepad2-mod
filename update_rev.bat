@ECHO OFF
SETLOCAL

PUSHD "%~dp0" || EXIT /B 1

IF EXIST "build.user.bat" CALL "build.user.bat"

python.exe "%~dp0version.py"
SET "VERSION_EXIT_CODE=%ERRORLEVEL%"

POPD
ENDLOCAL & EXIT /B %VERSION_EXIT_CODE%
