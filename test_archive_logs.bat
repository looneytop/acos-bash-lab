@echo off
setlocal EnableExtensions DisableDelayedExpansion

for /f "tokens=2 delims=:" %%C in ('chcp') do set "old_cp=%%C"
if defined old_cp set "old_cp=%old_cp: =%"
if defined old_cp set "old_cp=%old_cp:.=%"
chcp 65001 >nul

rem Windows 10+: cmd.exe и tar.exe. Тесты повторяют test_archive_logs.sh.

set "code=1"
set "setup_err="
set "script=%~1"
if not defined script set "script=%~dp0archive_logs.bat"
for %%I in ("%script%") do set "script=%%~fI"
if not exist "%script%" set "setup_err=Нет скрипта: %script%"
if defined setup_err goto :setup_fail

set "real_tar="
for /f "delims=" %%T in ('where tar 2^>nul') do if not defined real_tar set "real_tar=%%T"
if not defined real_tar set "setup_err=Не найдена команда: tar"
if defined setup_err goto :setup_fail

set "test_root=%TEMP%\archive_logs_tests_%random%%random%"
mkdir "%test_root%" 2>nul || set "setup_err=Не удалось создать временную папку для тестов"
if defined setup_err goto :setup_fail

set "passed=0"
set "failed=0"
for %%T in (test_1_invalid_input test_2_below_threshold test_3_exact_threshold test_4_archive_oldest test_5_command_failures) do call :run_test %%T
rmdir /s /q "%test_root%" 2>nul

echo.
echo Итог: %passed%/5 PASS, %failed% FAIL
set "code=0"
if %failed% gtr 0 set "code=1"
goto :finish

:setup_fail
>&2 echo(%setup_err%

:finish
if defined old_cp chcp %old_cp% >nul
exit /b %code%


rem ---- Запуск теста ----

:run_test
set "test_error="
set "case_root="
call :%~1
if defined test_error goto :run_test_failed
echo PASS: %~1
set /a "passed+=1"
exit /b 0

:run_test_failed
echo FAIL: %~1
echo(  Ошибка теста: %test_error%
if not defined case_root goto :run_test_counted
if not exist "%case_root%\output.txt" goto :run_test_counted
echo   Вывод проверяемого скрипта:
type "%case_root%\output.txt"
:run_test_counted
set /a "failed+=1"
exit /b 0


rem ---- Вспомогательные подпрограммы ----

:prepare
set "case_root=%test_root%\%~1"
set "log_dir=%case_root%\log folder"
set "backup_dir=%case_root%\backup folder"
set "expected_dir=%case_root%\expected"
mkdir "%log_dir%" "%backup_dir%" "%expected_dir%"
exit /b 0

rem Файл нужного размера: сначала быстрый fsutil, а если он недоступен без прав
rem администратора, файл собирается удвоением куска через copy /b.
:make_file
set "mf_path=%~1"
fsutil file createnew "%mf_path%" %~2 >nul 2>&1 && exit /b 0
set /a "mf_left=%~2"
set "mf_chunk=%case_root%\chunk.bin"
set "mf_tmp=%case_root%\chunk_tmp.bin"
set "mf_started="
<nul set /p "=x" > "%mf_chunk%"
:make_file_loop
set /a "mf_bit=mf_left %% 2, mf_left/=2"
if "%mf_bit%"=="1" call :make_file_append
if %mf_left% equ 0 goto :make_file_done
copy /b "%mf_chunk%"+"%mf_chunk%" "%mf_tmp%" >nul && move /y "%mf_tmp%" "%mf_chunk%" >nul
goto :make_file_loop
:make_file_done
del /f /q "%mf_chunk%" >nul 2>&1
if not defined mf_started type nul > "%mf_path%"
if not exist "%mf_path%" set "test_error=не удалось создать файл: %mf_path%"
if defined test_error exit /b 1
exit /b 0

:make_file_append
if defined mf_started goto :make_file_concat
copy /b "%mf_chunk%" "%mf_path%" >nul
set "mf_started=1"
exit /b 0
:make_file_concat
copy /b "%mf_path%"+"%mf_chunk%" "%mf_tmp%" >nul && move /y "%mf_tmp%" "%mf_path%" >nul
exit /b 0

rem Пауза, чтобы время изменения следующего файла было позже.
:wait_tick
ping -n 3 127.0.0.1 >nul
exit /b 0

rem Аргументы передаются через переменную args, чтобы cmd не съел знак % в них.
:run_script
cmd /d /c ""%script%" %args%" > "%case_root%\output.txt" 2>&1
set "rc=%errorlevel%"
exit /b 0

:run_ok
set args="%log_dir%" "%backup_dir%" %~1 %~2
call :run_script
if not "%rc%"=="0" set "test_error=ожидался успешный запуск"
if defined test_error exit /b 1
exit /b 0

:run_bad
call :run_script
if "%rc%"=="0" set "test_error=ожидался ненулевой код завершения: %args%"
if defined test_error exit /b 1
exit /b 0

rem findstr сравнивает байты, поэтому ожидаемая строка пишется в файл в той же UTF-8.
:has_line
>"%case_root%\pattern.txt" echo(%~1
findstr /x /l /g:"%case_root%\pattern.txt" "%case_root%\output.txt" >nul || set "test_error=в выводе нет строки: %~1"
if defined test_error exit /b 1
exit /b 0

:same_file
fc /b "%~1" "%~2" >nul 2>&1 || set "test_error=файлы различаются или отсутствуют: %~1"
if defined test_error exit /b 1
exit /b 0

:count_entries
set "n=0"
for /f "eol=: delims=" %%E in ('dir /b /a "%~1" 2^>nul') do set /a "n+=1"
exit /b 0

:count_archives
set "n=0"
set "archive="
for %%A in ("%backup_dir%\*.tar.gz") do (
    set /a "n+=1"
    set "archive=%%~fA"
)
exit /b 0

rem По заданию во всех тестах папка log должна весить не меньше 0,5 ГБ (512 МиБ).
:assert_min_log_size
set "total=0"
for /f "eol=: delims=" %%N in ('dir /b /a:-d-l "%log_dir%" 2^>nul') do (
    for %%F in ("%log_dir%\%%N") do set /a "total+=%%~zF"
)
if %total% lss 536870912 set "test_error=log весит меньше 0,5 ГБ: %total% байт"
if defined test_error exit /b 1
exit /b 0

:assert_no_archive
call :count_entries "%backup_dir%"
if not "%n%"=="0" set "test_error=в backup не должно быть файлов, найдено: %n%"
if defined test_error exit /b 1
exit /b 0


rem ---- Тесты ----

:test_1_invalid_input
call :prepare invalid
call :make_file "%log_dir%\keep.log" 536870912 || exit /b 1
copy /b /y "%log_dir%\keep.log" "%expected_dir%\keep.log" >nul
call :assert_min_log_size || exit /b 1
set "args="
call :run_bad || exit /b 1
set args="%case_root%\missing" "%backup_dir%" 1024 50
call :run_bad || exit /b 1
set args="%log_dir%" "%case_root%\missing" 1024 50
call :run_bad || exit /b 1
set args="%log_dir%" "%backup_dir%" 0 50
call :run_bad || exit /b 1
set args="%log_dir%" "%backup_dir%" 1.5 50
call :run_bad || exit /b 1
set args="%log_dir%" "%backup_dir%" 1024 101
call :run_bad || exit /b 1
set args="%log_dir%" "%backup_dir%" 1024 50%%
call :run_bad || exit /b 1
set args="%log_dir%" "%backup_dir%" 17592186044416 50
call :run_bad || exit /b 1
set args="%log_dir%" "%log_dir%" 1024 50
call :run_bad || exit /b 1
call :same_file "%log_dir%\keep.log" "%expected_dir%\keep.log" || exit /b 1
call :assert_no_archive || exit /b 1
exit /b 0

:test_2_below_threshold
rem 512 МиБ из 1024 = 50%% при пороге 60%%. Вложенный файл на 200 МиБ дал бы 69%%,
rem поэтому строка с размером доказывает, что вложенные папки и ссылки не учитываются.
call :prepare below
call :make_file "%log_dir%\.small file.log" 536870912 || exit /b 1
copy /b /y "%log_dir%\.small file.log" "%expected_dir%\small.log" >nul
mkdir "%log_dir%\subfolder"
call :make_file "%log_dir%\subfolder\ignored.log" 209715200 || exit /b 1
rem Символьная ссылка в Windows требует прав администратора или режима разработчика.
set "has_link="
mklink "%log_dir%\ignored-link" "%log_dir%\subfolder\ignored.log" >nul 2>&1 && set "has_link=1"
if not defined has_link echo   Символьная ссылка не создана, эта часть проверки пропущена
call :assert_min_log_size || exit /b 1
call :run_ok 1024 60 || exit /b 1
call :has_line "Размер файлов log: 536870912 байт" || exit /b 1
call :has_line "Заполнение: 50%%%%" || exit /b 1
call :has_line "Порог не превышен. Архивация не нужна." || exit /b 1
call :same_file "%log_dir%\.small file.log" "%expected_dir%\small.log" || exit /b 1
if not exist "%log_dir%\subfolder\ignored.log" set "test_error=вложенный файл пропал"
if defined has_link if not exist "%log_dir%\ignored-link" set "test_error=символьная ссылка пропала"
if defined test_error exit /b 1
call :assert_no_archive || exit /b 1
exit /b 0

:test_3_exact_threshold
rem Ровно 512 МиБ из 1024 при пороге 50%%: это ещё не превышение.
call :prepare equal
call :make_file "%log_dir%\exact.log" 536870912 || exit /b 1
copy /b /y "%log_dir%\exact.log" "%expected_dir%\exact.log" >nul
call :assert_min_log_size || exit /b 1
call :run_ok 1024 50 || exit /b 1
call :has_line "Заполнение: 50%%%%" || exit /b 1
call :has_line "Порог не превышен. Архивация не нужна." || exit /b 1
call :same_file "%log_dir%\exact.log" "%expected_dir%\exact.log" || exit /b 1
call :assert_no_archive || exit /b 1
exit /b 0

:test_4_archive_oldest
rem 128 + 128 + 600 = 856 МиБ (83%%) при пороге 60%%: без старого файла 71%%,
rem без двух старых 58%%, поэтому архивируются ровно два самых старых файла.
call :prepare archive
call :make_file "%log_dir%\old file.log" 134217728 || exit /b 1
call :wait_tick
call :make_file "%log_dir%\.middle.log" 134217728 || exit /b 1
call :wait_tick
call :make_file "%log_dir%\-new.log" 629145600 || exit /b 1
copy /b /y "%log_dir%\old file.log" "%expected_dir%\old file.log" >nul
copy /b /y "%log_dir%\.middle.log" "%expected_dir%\.middle.log" >nul
copy /b /y "%log_dir%\-new.log" "%expected_dir%\-new.log" >nul
call :assert_min_log_size || exit /b 1

call :run_ok 1024 60 || exit /b 1
if exist "%log_dir%\old file.log" set "test_error=old file.log не удалён из log"
if exist "%log_dir%\.middle.log" set "test_error=.middle.log не удалён из log"
if defined test_error exit /b 1
call :same_file "%log_dir%\-new.log" "%expected_dir%\-new.log" || exit /b 1
call :count_archives
if not "%n%"=="1" set "test_error=ожидался 1 архив, найдено: %n%"
if defined test_error exit /b 1
mkdir "%case_root%\restored"
"%real_tar%" -xzf "%archive%" -C "%case_root%\restored" || set "test_error=архив не распаковывается"
if defined test_error exit /b 1
call :count_entries "%case_root%\restored"
if not "%n%"=="2" set "test_error=в архиве ожидалось 2 файла, найдено: %n%"
if defined test_error exit /b 1
call :same_file "%case_root%\restored\old file.log" "%expected_dir%\old file.log" || exit /b 1
call :same_file "%case_root%\restored\.middle.log" "%expected_dir%\.middle.log" || exit /b 1
call :has_line "Заархивировано файлов: 2" || exit /b 1
call :has_line "Фактический размер log после архивации: 629145600 байт" || exit /b 1
call :has_line "Фактическое заполнение: 58%%%%" || exit /b 1

rem После архивации в log остаётся 600 МиБ: это всё ещё больше 0,5 ГБ.
call :assert_min_log_size || exit /b 1
call :run_ok 1024 60 || exit /b 1
call :count_archives
if not "%n%"=="1" set "test_error=повторный запуск создал архив, всего архивов: %n%"
if defined test_error exit /b 1
call :same_file "%log_dir%\-new.log" "%expected_dir%\-new.log" || exit /b 1
exit /b 0

:test_5_command_failures
call :prepare failures
call :make_file "%log_dir%\keep.log" 629145600 || exit /b 1
copy /b /y "%log_dir%\keep.log" "%expected_dir%\keep.log" >nul
call :assert_min_log_size || exit /b 1
mkdir "%case_root%\bin"

rem Подменный tar падает на нужном этапе, остальные вызовы передаёт настоящему tar.
> "%case_root%\bin\tar.cmd" (
    echo @echo off
    echo if "%%TEST_FAIL_PHASE%%:%%~1"=="create:-czf" exit /b 2
    echo if "%%TEST_FAIL_PHASE%%:%%~1"=="verify:-tzf" exit /b 2
    echo "%%TEST_REAL_TAR%%" %%*
)

set "TEST_REAL_TAR=%real_tar%"
call :fail_phase create
if not defined test_error call :fail_phase verify
set "TEST_REAL_TAR="
if defined test_error exit /b 1
exit /b 0

:fail_phase
set "old_path=%PATH%"
set "TEST_FAIL_PHASE=%~1"
set "PATH=%case_root%\bin;%old_path%"
set args="%log_dir%" "%backup_dir%" 1024 50
call :run_script
set "PATH=%old_path%"
set "TEST_FAIL_PHASE="
if "%rc%"=="0" set "test_error=ошибка %~1 не привела к ненулевому коду завершения"
if defined test_error exit /b 1
call :same_file "%log_dir%\keep.log" "%expected_dir%\keep.log" || exit /b 1
call :assert_no_archive || exit /b 1
exit /b 0
