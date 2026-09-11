------------------------------------------------------------------------
-- czSQLServerGit - Automatic Git version control for SQL Server schemas
-- https://github.com/cesarzea/czSQLServerGit
--
-- Copyright (c) 2020-2026 César Zea - https://www.cesarzea.com
-- Licensed under the MIT License. See LICENSE.
------------------------------------------------------------------------

------------------------------------------------------------------------
-- DDL trigger to be created in EVERY database whose schema changes
-- must be recorded.
--
-- Replace AdventureWorks with the database name.
------------------------------------------------------------------------
USE [AdventureWorks]
GO

CREATE TRIGGER [czSqlGit_SchemaAudit] ON DATABASE
    FOR
    CREATE_PROCEDURE, ALTER_PROCEDURE, DROP_PROCEDURE,
    CREATE_INDEX,     ALTER_INDEX,     DROP_INDEX,
    CREATE_TRIGGER,   ALTER_TRIGGER,   DROP_TRIGGER,
    CREATE_FUNCTION,  ALTER_FUNCTION,  DROP_FUNCTION,
    CREATE_TABLE,     ALTER_TABLE,     DROP_TABLE,
    CREATE_VIEW,      ALTER_VIEW,      DROP_VIEW
AS
BEGIN
    SET NOCOUNT ON

    DECLARE @eventData XML = EVENTDATA()

    DECLARE
        @schemaName NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/SchemaName)[1]', 'nvarchar(255)'),
        @objectName NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(255)')

    DECLARE @objectDefinition NVARCHAR(MAX)
    SELECT @objectDefinition = OBJECT_DEFINITION(OBJECT_ID(QUOTENAME(@schemaName) + '.' + QUOTENAME(@objectName)))

    EXEC [czSqlGit].[dbo].[RegisterChange] @eventData, @objectDefinition

    SET NOCOUNT OFF
END
GO

ENABLE TRIGGER [czSqlGit_SchemaAudit] ON DATABASE
GO

-- To remove it:
-- DROP TRIGGER [czSqlGit_SchemaAudit] ON DATABASE


------------------------------------------------------------------------
-- Quick test: create and drop a procedure to check that the trigger
-- records both events in czSqlGit.dbo.SchemaLog and that two new
-- commits show up in the Git repository.
------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[czSqlGit_Test] AS
    SELECT 1
GO

DROP PROCEDURE [dbo].[czSqlGit_Test]
GO
