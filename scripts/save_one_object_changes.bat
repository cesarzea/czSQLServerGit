@echo off
REM ============================================================================
REM  save_one_object_changes.bat  <database> <schema> <object> ["login"]
REM  Regenerates the script of ONE object and commits it to Git, authored
REM  by the SQL Server login that made the change (if given).
REM  Invoked asynchronously (Service Broker + xp_cmdshell) by the procedure
REM  czSqlGit.dbo.RegisterChange every time the DDL trigger of a database
REM  detects a schema change.
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
SET AUTHOR_DOMAIN=example.com
SET LOG=save_one_object_changes.log
REM ----------------------------------------------------------------------------

cd /d %REPO_DIR%

if not exist %REPO_DIR%\%1 mkdir %1

echo ---------------------------------------- Start >> %LOG%
date /t >> %LOG%
time /t >> %LOG%
echo Save object changes %1: %2.%3 by %~4 >> %LOG%

del .\%1\%2.%3.*.sql /Q

call %MSSQL_SCRIPTER% -S %SQL_SERVER% -U %SQL_USER% -P %SQL_PASSWORD% -d %1 --exclude-headers --file-per-object --file-path .\%1 --include-objects %2.%3

call %GIT% config user.email "%GIT_USER_EMAIL%"
call %GIT% config user.name "%GIT_USER_NAME%"

REM Commit as the login that made the change; fall back to the service identity
SET AUTHOR=
if not "%~4"=="" SET AUTHOR=--author="%~4 <%~4@%AUTHOR_DOMAIN%>"

call %GIT% add *.sql >> %LOG%
call %GIT% commit %AUTHOR% -m "%1: %2.%3" >> %LOG%

time /t >> %LOG%
echo ---------------------------------------- End >> %LOG%
