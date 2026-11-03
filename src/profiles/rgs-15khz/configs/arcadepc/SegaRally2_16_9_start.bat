@echo off
mkdir "z:\userdata\saves\windows\Sega Rally 2"
copy /y "z:\userdata\saves\windows\Sega Rally 2\SR2_SAVE.DAT" "C:\SEGA RALLY 2"
start /wait "" ".\SEGA RALLY 2 WIDESCREEN.exe"
copy /y ".\SR2_SAVE.DAT" "z:\userdata\saves\windows\Sega Rally 2"

