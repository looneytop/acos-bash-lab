@echo off
setlocal EnableExtensions DisableDelayedExpansion

for /f "tokens=2 delims=:" %%C in ('chcp') do set "old_cp=%%C"
if defined old_cp set "old_cp=%old_cp: =%"
if defined old_cp set "old_cp=%old_cp:.=%"
chcp 65001 >nul

rem Windows 10+: cmd.exe и tar.exe (входит в Windows 10 1803 и новее).
rem Отложенное раскрытие выключено, чтобы имена файлов с ! и ^ не портились.

set "code=0"
set "err="
set "list_file="
set "names_file="

if "%~4"=="" goto :usage
if not "%~5"=="" goto :usage

set "log_dir=%~1"
set "backup_dir=%~2"
set "limit_mib=%~3"
set "threshold=%~4"

if not exist "%log_dir%\" set "err=папка log не существует: %log_dir%"
if defined err goto :fail
if not exist "%backup_dir%\" set "err=папка backup не существует: %backup_dir%"
if defined err goto :fail
echo(%limit_mib%| findstr /r /x "[1-9][0-9]*" >nul || set "err=лимит должен быть положительным целым числом МиБ"
if defined err goto :fail
echo(%threshold%| findstr /r /x /c:"100" /c:"[0-9]" /c:"[1-9][0-9]" >nul || set "err=порог должен быть целым числом от 0 до 100"
if defined err goto :fail

rem Арифметика cmd 32-битная, поэтому лимит ограничен 1000000 МиБ.
if not "%limit_mib:~7%"=="" set "err=лимит слишком велик для расчёта в cmd"
if defined err goto :fail
if %limit_mib% gtr 1000000 set "err=лимит слишком велик для расчёта в cmd"
if defined err goto :fail

for %%I in ("%log_dir%") do set "log_dir=%%~fI"
for %%I in ("%backup_dir%") do set "backup_dir=%%~fI"
if "%log_dir:~-1%"=="\" set "log_dir=%log_dir:~0,-1%"
if "%backup_dir:~-1%"=="\" set "backup_dir=%backup_dir:~0,-1%"

call :is_inside "%backup_dir%" "%log_dir%"
if "%inside%"=="1" set "err=log и backup должны быть отдельными папками без вложения друг в друга"
if defined err goto :fail
call :is_inside "%log_dir%" "%backup_dir%"
if "%inside%"=="1" set "err=log и backup должны быть отдельными папками без вложения друг в друга"
if defined err goto :fail

call :can_write "%log_dir%" || set "err=нет прав для работы с log"
if defined err goto :fail
call :can_write "%backup_dir%" || set "err=нет прав для записи в backup"
if defined err goto :fail
where tar >nul 2>&1 || set "err=не найдена команда tar"
if defined err goto :fail

call :count_size || set "err=не удалось подсчитать размер log: файл больше 999999999 байт или суммарный размер слишком велик"
if defined err goto :fail

call :format_bytes %size_m% %size_r%
call :percent %size_m% %size_r%

echo(Папка с логами: %log_dir%
echo(Папка для архивов: %backup_dir%
echo(Лимит: %limit_mib% МиБ
echo(Порог: %threshold%%%
echo(Размер файлов log: %bytes% байт
echo(Заполнение: %pct%%%

call :check_over %size_m% %size_r%
if defined over goto :select
echo Порог не превышен. Архивация не нужна.
goto :finish

:select
echo Порог превышен. Нужно выбрать старые файлы.

set "list_file=%TEMP%\archive_logs_list_%random%%random%.txt"
set "names_file=%TEMP%\archive_logs_names_%random%%random%.txt"
2>nul (type nul > "%list_file%") || set "err=не удалось создать временный список"
if defined err goto :fail
2>nul (type nul > "%names_file%") || set "err=не удалось создать временный список"
if defined err goto :fail

rem Размер хранится как МиБ + остаток в байтах, чтобы не переполнить 32-битные числа.
set "rem_m=%size_m%"
set "rem_r=%size_r%"
set "count=0"

rem dir /o:d сортирует от старых файлов к новым; /a:-d-l исключает папки и ссылки.
for /f "eol=: delims=" %%N in ('dir /b /a:-d-l /o:d /t:w "%log_dir%" 2^>nul') do (
    call :check_over %%rem_m%% %%rem_r%%
    if defined over (
        for %%F in ("%log_dir%\%%N") do call :sub_rem %%~zF
        >>"%list_file%" echo(./%%N
        >>"%names_file%" echo(%%N
        set /a "count+=1"
    )
)

call :check_over %rem_m% %rem_r%
if "%count%"=="0" set "err=не удалось выбрать достаточно файлов для достижения порога"
if defined over set "err=не удалось выбрать достаточно файлов для достижения порога"
if defined err goto :fail

call :format_bytes %rem_m% %rem_r%
echo(Нужно архивировать файлов: %count%
echo(Расчётный размер log после их удаления: %bytes% байт
for /f "usebackq eol=: delims=" %%N in ("%names_file%") do echo(Выбран: %log_dir%\%%N

rem Случайный суффикс и проверка exist не дают перезаписать существующий архив.
call :timestamp
:new_archive
set "archive_path=%backup_dir%\logs_%stamp%_%random%%random%.tar.gz"
if exist "%archive_path%" goto :new_archive
2>nul (type nul > "%archive_path%") || set "err=не удалось создать файл архива"
if defined err goto :fail

rem Префикс ./ в списке не даёт tar принять имена на - за параметры.
call tar -czf "%archive_path%" -C "%log_dir%" -T "%list_file%"
if errorlevel 1 (
    del /f /q "%archive_path%" >nul 2>&1
    set "err=не удалось создать архив; оригиналы сохранены"
    goto :fail
)

call tar -tzf "%archive_path%" >nul
if errorlevel 1 (
    del /f /q "%archive_path%" >nul 2>&1
    set "err=архив не прошёл проверку; оригиналы сохранены"
    goto :fail
)

echo(Архив создан и проверен: %archive_path%

set "del_err="
for /f "usebackq eol=: delims=" %%N in ("%names_file%") do (
    del /f /q /a "%log_dir%\%%N" >nul 2>&1
    if exist "%log_dir%\%%N" set "del_err=%%N"
)
if defined del_err set "err=не удалось удалить файл: %log_dir%\%del_err%; его копия есть в архиве"
if defined err goto :fail

call :count_size || set "err=не удалось подсчитать размер log после архивации"
if defined err goto :fail
call :format_bytes %size_m% %size_r%
call :percent %size_m% %size_r%
echo(Фактический размер log после архивации: %bytes% байт
echo(Фактическое заполнение: %pct%%%
echo(Заархивировано файлов: %count%

call :check_over %size_m% %size_r%
if defined over set "err=после архивации порог всё ещё превышен: возможно, файлы менялись во время работы"
if defined err goto :fail
goto :finish

:usage
>&2 echo(Использование: %~nx0 ПАПКА_LOG ПАПКА_BACKUP ЛИМИТ_В_МиБ ПОРОГ_В_ПРОЦЕНТАХ
set "code=1"
goto :finish

:fail
>&2 echo(Ошибка: %err%
set "code=1"

:finish
if defined list_file if exist "%list_file%" del /f /q "%list_file%" >nul 2>&1
if defined names_file if exist "%names_file%" del /f /q "%names_file%" >nul 2>&1
if defined old_cp chcp %old_cp% >nul
exit /b %code%


rem ---- Подпрограммы ----

rem Считает размер обычных файлов log в size_m (МиБ) и size_r (остаток в байтах).
:count_size
set "size_m=0"
set "size_r=0"
set "size_err="
for /f "eol=: delims=" %%N in ('dir /b /a:-d-l "%log_dir%" 2^>nul') do (
    for %%F in ("%log_dir%\%%N") do call :add_size %%~zF || set "size_err=1"
)
if defined size_err exit /b 1
exit /b 0

:add_size
set "n=%~1"
if not defined n exit /b 1
if not "%n:~9%"=="" exit /b 1
set /a "size_m+=n/1048576, size_r+=n%%1048576"
if %size_r% geq 1048576 set /a "size_m+=1, size_r-=1048576"
if %size_m% gtr 20000000 exit /b 1
exit /b 0

:sub_rem
set /a "rem_m-=%~1/1048576, rem_r-=%~1%%1048576"
if %rem_r% lss 0 set /a "rem_m-=1, rem_r+=1048576"
exit /b 0

rem over задан, если (МиБ*1048576 + байты) * 100 > лимит * порог * 1048576.
:check_over
set /a "co_a=%~1*100+(%~2*100)/1048576, co_r=(%~2*100)%%1048576, co_l=limit_mib*threshold"
set "over="
if %co_a% gtr %co_l% set "over=1"
if %co_a% equ %co_l% if %co_r% gtr 0 set "over=1"
exit /b 0

rem Целочисленный процент с отбрасыванием дробной части, как в Bash.
:percent
set /a "pct=(%~1*100+(%~2*100)/1048576)/limit_mib"
exit /b 0

rem Переводит МиБ + остаток в десятичную строку bytes через разряды по 10000.
:format_bytes
set /a "fb_lo=%~1%%10000, fb_hi=%~1/10000"
set /a "d0=fb_lo*8576+%~2, d1=fb_lo*104+fb_hi*8576, d2=fb_hi*104, d3=0"
set /a "d1+=d0/10000, d0%%=10000"
set /a "d2+=d1/10000, d1%%=10000"
set /a "d3+=d2/10000, d2%%=10000"
set /a "d3+=10000, d2+=10000, d1+=10000, d0+=10000"
set "bytes=%d3:~1%%d2:~1%%d1:~1%%d0:~1%"
:format_bytes_strip
if "%bytes:~1%"=="" exit /b 0
if not "%bytes:~0,1%"=="0" exit /b 0
set "bytes=%bytes:~1%"
goto :format_bytes_strip

rem inside=1, если первая папка совпадает со второй или лежит внутри неё.
:is_inside
set "inside=0"
set "child=%~1\"
set "parent=%~2\"
setlocal EnableDelayedExpansion
call :strlen parent
set "head=!child:~0,%len%!"
if /i "!head!"=="!parent!" (endlocal & set "inside=1") else endlocal
exit /b 0

:strlen
set "sl=!%~1!#"
set "len=0"
for %%P in (4096 2048 1024 512 256 128 64 32 16 8 4 2 1) do (
    if not "!sl:~%%P,1!"=="" (set /a "len+=%%P" & set "sl=!sl:~%%P!")
)
exit /b 0

rem Пробный файл удаляется сразу после проверки и ничего не оставляет в папке.
:can_write
set "probe=%~1\.archive_logs_probe_%random%%random%"
2>nul (type nul > "%probe%") || exit /b 1
del /f /q /a "%probe%" >nul 2>&1
exit /b 0

:timestamp
set "stamp="
for /f "delims=" %%T in ('powershell -NoProfile -NonInteractive -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>nul') do set "stamp=%%T"
if not defined stamp set "stamp=%random%"
exit /b 0
