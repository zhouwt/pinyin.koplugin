@echo off
setlocal enabledelayedexpansion

REM Build a release zip for pinyin.koplugin.
REM The zip filename includes the version/tag, but the top-level folder inside
REM the zip is always exactly "pinyin.koplugin", so KOReader can load it directly.

set "ROOT=%~dp0.."
set "DIST=%ROOT%\dist"
set "ZIPNAME=pinyin.koplugin"

if "%~1"=="" (
    set "TAG=v1.1"
) else (
    set "TAG=%~1"
)

if exist "%DIST%" rmdir /S /Q "%DIST%"
mkdir "%DIST%\pinyin.koplugin"

xcopy /E /I /Y "%ROOT%\assets"       "%DIST%\pinyin.koplugin\assets"
copy /Y "%ROOT%\config.lua"          "%DIST%\pinyin.koplugin\config.lua"
copy /Y "%ROOT%\LICENSE"             "%DIST%\pinyin.koplugin\LICENSE"
copy /Y "%ROOT%\main.lua"            "%DIST%\pinyin.koplugin\main.lua"
copy /Y "%ROOT%\pinyin_data.lua"     "%DIST%\pinyin.koplugin\pinyin_data.lua"
copy /Y "%ROOT%\README.md"           "%DIST%\pinyin.koplugin\README.md"
copy /Y "%ROOT%\_meta.lua"           "%DIST%\pinyin.koplugin\_meta.lua"

powershell -NoProfile -Command "Compress-Archive -Path '%DIST%\pinyin.koplugin' -DestinationPath '%DIST%\%ZIPNAME%-%TAG%.zip' -Force"

echo.
echo Created: %DIST%\%ZIPNAME%-%TAG%.zip
echo.
pause
