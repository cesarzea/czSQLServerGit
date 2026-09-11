@echo off
REM ============================================================================
REM  czSqlGit - Automatic Git version control for SQL Server schemas
REM  https://github.com/cesarzea/czSqlGit
REM
REM  Copyright (c) 2020-2026 Cesar Zea - https://www.cesarzea.com
REM  Licensed under the MIT License. See LICENSE.
REM ============================================================================

REM ============================================================================
REM  save_changes.bat
REM  Scripts every object of the listed databases, copies any other code to
REM  be versioned and commits to Git.
REM  It regenerates ALL scripts and commits whatever differs, so it picks up
REM  what the trigger does not capture (external files, databases without
REM  the trigger, uncovered events). Run it by hand the first time, then
REM  from the Windows Task Scheduler.
REM ============================================================================

REM ---- Configuration ---------------------------------------------------------
SET REPO_DIR=C:\czSqlGit
SET SQL_SERVER=127.0.0.1
SET SQL_USER=czsqlgit
SET SQL_PASSWORD=<password>
REM Full path to mssql-scripter.bat if the Python Scripts folder is not in PATH
SET MSSQL_SCRIPTER=mssql-scripter
SET GIT="C:\Program Files\Git\cmd\git.exe"
SET GIT_USER_NAME=czSqlGit
SET GIT_USER_EMAIL=czsqlgit@example.com
SET LOG=save_changes.log
REM ----------------------------------------------------------------------------

cd /d %REPO_DIR%

echo ============================================================ >> %LOG%
date /t >> %LOG%
time /t >> %LOG%

REM One block per database to be versioned
del .\AdventureWorks\*.* /Q
call %MSSQL_SCRIPTER% -S %SQL_SERVER% -U %SQL_USER% -P %SQL_PASSWORD% -d AdventureWorks --exclude-headers --file-per-object --file-path .\AdventureWorks

del .\Northwind\*.* /Q
call %MSSQL_SCRIPTER% -S %SQL_SERVER% -U %SQL_USER% -P %SQL_PASSWORD% -d Northwind --exclude-headers --file-per-object --file-path .\Northwind

REM Any other files to be versioned (optional)
xcopy C:\ETL\*.py  .\ETL /s /y
xcopy C:\ETL\*.bat .\ETL /s /y

call %GIT% config user.email "%GIT_USER_EMAIL%"
call %GIT% config user.name "%GIT_USER_NAME%"

call %GIT% add .\ETL\* >> %LOG%
call %GIT% add *.sql >> %LOG%
call %GIT% commit -m "Full refresh" >> %LOG%

time /t >> %LOG%
