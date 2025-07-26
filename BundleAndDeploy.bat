@echo off

set /p LUATITLE=<title.txt

node bundle.js
copy /Y "build\%LUATITLE%" "%localappdata%\%LUATITLE%"
exit