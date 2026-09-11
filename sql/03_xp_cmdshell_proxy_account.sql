------------------------------------------------------------------------
-- OPTIONAL. Only needed if running xp_cmdshell from Service Broker
-- fails with permission errors (visible in the SQL Server event log or
-- in the table czSqlGit.dbo.AsyncExecResults).
--
-- If the credential ##xp_cmdshell_proxy_account## exists, xp_cmdshell
-- uses it as the Windows security context to run under. Use an account
-- with permissions on the repository folder, Git and mssql-scripter.
------------------------------------------------------------------------
USE [master]
GO

-- xp_cmdshell must be enabled on the instance
EXEC sp_configure 'show advanced options', 1
RECONFIGURE
EXEC sp_configure 'xp_cmdshell', 1
RECONFIGURE
GO

CREATE CREDENTIAL ##xp_cmdshell_proxy_account##
WITH IDENTITY = 'DOMAIN\user',
     SECRET   = '<password>'
GO
