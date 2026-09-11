------------------------------------------------------------------------
-- czSQLServerGit - Automatic Git version control for SQL Server schemas
-- https://github.com/cesarzea/czSQLServerGit
--
-- Copyright (c) 2020-2026 César Zea - https://www.cesarzea.com
-- Licensed under the MIT License. See LICENSE.
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Utility database that records every schema change the moment it happens
-- and sends it asynchronously (Service Broker) to Git.
--
-- Run under the 'sa' security context so that 'sa' owns the database.
------------------------------------------------------------------------

IF DB_ID('czSQLServerGit') IS NULL
    CREATE DATABASE [czSQLServerGit]
GO

ALTER DATABASE [czSQLServerGit] SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE
GO

USE [czSQLServerGit]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

------------------------------------------------------------------------
-- Table dbo.AsyncExecResults
-- One row per asynchronous call sent to Service Broker: command,
-- execution times and error, if any.
------------------------------------------------------------------------
CREATE TABLE [dbo].[AsyncExecResults](
   [Token]        [uniqueidentifier] NOT NULL,
   [TaskToken]    [uniqueidentifier] NULL,
   [SubmitTime]   [datetime]         NOT NULL,
   [Command]      [nvarchar](max)    NULL,
   [StartTime]    [datetime]         NULL,
   [FinishTime]   [datetime]         NULL,
   [ErrorNumber]  [int]              NULL,
   [ErrorMessage] [nvarchar](max)    NULL,
   [Result]       [nvarchar](max)    NULL,
 CONSTRAINT [PK_AsyncExecResults] PRIMARY KEY CLUSTERED ([Token] ASC)
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

------------------------------------------------------------------------
-- Table dbo.SchemaLog
-- One row per schema change made in any of the monitored databases.
------------------------------------------------------------------------
CREATE TABLE [dbo].[SchemaLog](
   [Id]               [int] IDENTITY(1,1) NOT NULL,
   [UserName]         [nvarchar](255)  NULL,
   [EventType]        [nvarchar](255)  NULL,
   [DatabaseName]     [nvarchar](255)  NULL,
   [SchemaName]       [nvarchar](255)  NULL,
   [ObjectName]       [nvarchar](255)  NULL,
   [ObjectType]       [nvarchar](255)  NULL,
   [CreatedAt]        [datetime]       NULL,
   [ObjectDefinition] [nvarchar](max)  NULL,
   [Command]          [nvarchar](max)  NULL,
   [EventData]        [xml]            NULL,
   [GitCommand]       [nvarchar](max)  NULL,
 CONSTRAINT [PK_SchemaLog] PRIMARY KEY CLUSTERED ([Id] ASC)
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

------------------------------------------------------------------------
-- Service Broker queue (activation is configured below, once the
-- activation procedure exists)
------------------------------------------------------------------------
CREATE QUEUE [dbo].[AsyncExecQueue]
    WITH STATUS = ON, RETENTION = OFF, POISON_MESSAGE_HANDLING (STATUS = ON)
    ON [PRIMARY]
GO

------------------------------------------------------------------------
-- Procedure dbo.AsyncExecActivated
-- Queue activation procedure: receives a message, executes the command
-- it carries and records the outcome in AsyncExecResults.
------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[AsyncExecActivated]
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @h UNIQUEIDENTIFIER
    , @messageTypeName SYSNAME
    , @messageBody VARBINARY(MAX)
    , @xmlBody XML
    , @procedureName NVARCHAR(MAX)
    , @startTime DATETIME
    , @finishTime DATETIME
    , @execErrorNumber INT
    , @execErrorMessage NVARCHAR(MAX)
    , @execErrorProcedureLine INT
    , @execErrorProcedure NVARCHAR(MAX)
    , @xactState SMALLINT
    , @token UNIQUEIDENTIFIER;

  BEGIN TRY
    RECEIVE TOP (1)
      @h = [conversation_handle]
      , @messageTypeName = [message_type_name]
      , @messageBody = [message_body]
      FROM [AsyncExecQueue];

    IF (@h IS NOT NULL)
      BEGIN
        IF (@messageTypeName = N'DEFAULT')
          BEGIN
            -- The DEFAULT message type is a procedure invocation.
            -- Extract the name of the procedure from the message body.
            SELECT @xmlBody = CAST(@messageBody AS XML);
            SELECT @procedureName = @xmlBody.value('(//procedure/name)[1]', 'nvarchar(max)');

            SELECT @startTime = GETDATE();
            SELECT @token = [conversation_id] FROM sys.conversation_endpoints WHERE [conversation_handle] = @h;
            IF (@token IS NULL)
              BEGIN
                RAISERROR (N'Internal consistency error: conversation not found', 16, 20);
              END

            UPDATE [AsyncExecResults]
            SET [StartTime] = @startTime
            WHERE [Token] = @token;

            BEGIN TRY
              EXEC (@procedureName);
            END TRY
            BEGIN CATCH
              SELECT @execErrorNumber = ERROR_NUMBER(), @execErrorMessage = ERROR_MESSAGE(), @xactState = XACT_STATE(), @execErrorProcedureLine = ERROR_LINE(), @execErrorProcedure = ERROR_PROCEDURE();

              IF (@xactState = -1)
                BEGIN
                  RAISERROR (N'Unrecoverable error in procedure %s: %i: %s', 16, 10,
                    @procedureName, @execErrorNumber, @execErrorMessage);
                END
              ELSE
                IF (@xactState = 1)
                  BEGIN
                    PRINT 'Error AsyncExecActivated = 1'
                  END
            END CATCH

            SELECT @finishTime = GETDATE();

            UPDATE [AsyncExecResults]
            SET [StartTime]    = @startTime,
                [FinishTime]   = @finishTime,
                [ErrorNumber]  = @execErrorNumber,
                [ErrorMessage] = CASE WHEN @execErrorNumber IS NULL THEN NULL ELSE COALESCE(@execErrorMessage, '') + ' at line ' + COALESCE(CAST(@execErrorProcedureLine AS VARCHAR(10)), '') END
            WHERE [Token] = @token;
            IF (0 = @@ROWCOUNT)
              BEGIN
                RAISERROR (N'Internal consistency error: token not found', 16, 30);
              END
            END CONVERSATION @h;
          END
        ELSE
          IF (@messageTypeName = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog')
            BEGIN
              END CONVERSATION @h;
            END
          ELSE
            IF (@messageTypeName = N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
              BEGIN
                DECLARE @errorNumber INT
                  , @errorMessage NVARCHAR(2048);
                SELECT @xmlBody = CAST(@messageBody AS XML);
                WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
                SELECT @errorNumber = @xmlBody.value('(/Error/Code)[1]', 'INT'), @errorMessage = @xmlBody.value('(/Error/Description)[1]', 'NVARCHAR(MAX)');
                -- Update the request with the received error
                SELECT @token = [conversation_id] FROM sys.conversation_endpoints WHERE [conversation_handle] = @h;
                UPDATE [AsyncExecResults]
                SET [ErrorNumber]  = @errorNumber,
                    [ErrorMessage] = @errorMessage
                WHERE [Token] = @token;
                END CONVERSATION @h;
              END
            ELSE
              BEGIN
                RAISERROR (N'Received unexpected message type: %s', 16, 50, @messageTypeName);
              END
      END
  END TRY
  BEGIN CATCH
    DECLARE @error INT
      , @message NVARCHAR(2048);
    SELECT @error = ERROR_NUMBER(), @message = ERROR_MESSAGE(), @xactState = XACT_STATE();
    RAISERROR (N'Error: %i, %s', 1, 60, @error, @message) WITH LOG;
  END CATCH
END
GO

------------------------------------------------------------------------
-- Procedure dbo.AsyncExecInvoke
-- Sends the command to the Service Broker queue and records it in
-- AsyncExecResults. Returns the call identifier in @token.
------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[AsyncExecInvoke]
    @procedureName NVARCHAR(MAX),
    @taskToken UNIQUEIDENTIFIER,
    @token UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    IF (@taskToken IS NULL)
        SET @taskToken = NEWID()

    DECLARE @h UNIQUEIDENTIFIER, @xmlBody XML;

    BEGIN TRY
        BEGIN DIALOG CONVERSATION @h FROM SERVICE [AsyncExecService] TO SERVICE N'AsyncExecService', 'current database' WITH ENCRYPTION = OFF;

        SELECT @token = [conversation_id]
        FROM sys.conversation_endpoints
        WHERE [conversation_handle] = @h;

        SELECT @xmlBody =
               (
                   SELECT @procedureName AS [name]
                   FOR XML PATH ('procedure'), TYPE
               );

        SEND ON CONVERSATION @h(@xmlBody);

        INSERT INTO [AsyncExecResults] ([Token], [TaskToken], [Command], [SubmitTime])
        VALUES (@token, @taskToken, @procedureName, GETUTCDATE());
    END TRY
    BEGIN CATCH
        DECLARE @error INT, @message NVARCHAR(2048), @xactState SMALLINT;

        SELECT @error = ERROR_NUMBER(),
               @message = ERROR_MESSAGE(),
               @xactState = XACT_STATE();
        IF @xactState = -1
            ROLLBACK;

        RAISERROR (N'Error: %i, %s', 16, 1, @error, @message);
    END CATCH;
END;
GO

------------------------------------------------------------------------
-- Procedure dbo.RegisterChange
-- Called by the DDL trigger of every monitored database.
-- Records the change in SchemaLog and queues the Git update.
------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[RegisterChange]
    @eventData XML,
    @objectDefinition NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON

    DECLARE
        @userName     NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/LoginName)[1]', 'nvarchar(255)'),
        @eventType    NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/EventType)[1]', 'nvarchar(255)'),
        @databaseName NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/DatabaseName)[1]', 'nvarchar(255)'),
        @schemaName   NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/SchemaName)[1]', 'nvarchar(255)'),
        @objectName   NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(255)'),
        @objectType   NVARCHAR(255) = @eventData.value('(/EVENT_INSTANCE/ObjectType)[1]', 'nvarchar(255)'),
        @command      NVARCHAR(MAX) = @eventData.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'nvarchar(MAX)'),
        @createdAt    DATETIME      = GETDATE()

    -- Exclude changes made by specific logins (ETL, replication, BI processes...)
    -- IF @userName IN ('etl_service', 'replication_user') RETURN

    -- Command that regenerates the object script and commits it to Git as the
    -- login that made the change. Adjust the path if the repository is not in C:\czSQLServerGit
    DECLARE @gitCommand NVARCHAR(MAX)
    SET @gitCommand = 'EXEC master..xp_cmdshell ''C:\czSQLServerGit\save_one_object_changes.bat ' + @databaseName + ' ' + @schemaName + ' ' + @objectName + ' "' + @userName + '"'''

    INSERT INTO [SchemaLog] ([UserName], [EventType], [DatabaseName], [SchemaName], [ObjectName], [ObjectType], [CreatedAt], [ObjectDefinition], [Command], [EventData], [GitCommand])
    VALUES (@userName, @eventType, @databaseName, @schemaName, @objectName, @objectType, @createdAt, @objectDefinition, @command, @eventData, @gitCommand)

    EXEC [AsyncExecInvoke] @gitCommand, NULL, NULL

    SET NOCOUNT OFF
END
GO

------------------------------------------------------------------------
-- Queue activation (a single reader: Git calls run one after another,
-- never concurrently) and Service Broker service
------------------------------------------------------------------------
ALTER QUEUE [dbo].[AsyncExecQueue]
    WITH ACTIVATION ( STATUS = ON, PROCEDURE_NAME = [dbo].[AsyncExecActivated], MAX_QUEUE_READERS = 1, EXECUTE AS OWNER )
GO

CREATE SERVICE [AsyncExecService] ON QUEUE [dbo].[AsyncExecQueue] ([DEFAULT])
GO
