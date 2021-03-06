SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.tables t WHERE t.object_id = OBJECT_ID('PAML.ModelPreset')) BEGIN
	CREATE TABLE PAML.ModelPreset (
		ID int NOT NULL IDENTITY(1,1)
		,Name varchar(50) NOT NULL
		,ShortName varchar(50) NOT NULL
		,[Key] varchar(15) NOT NULL
		,[Rank] int NOT NULL
		,CONSTRAINT PK_PAML_ModelPreset PRIMARY KEY CLUSTERED (ID ASC)
	)

	INSERT INTO PAML.ModelPreset (Name, ShortName, [Key], [Rank])
	VALUES ('Model 0 (Sites)', 'Model 0', 'Model0', 1)
		,('Model 2a rel', 'Model 2a rel', 'Model2a', 2)
		,('Model 8a', 'Model 8a', 'Model8a', 3)
		,('Model 2 (Branch)', 'Branch', 'Branch', 4)
		,('Model 2 Null (Branch Null)', 'Branch Null', 'BranchNull', 5)
		,('Model 2 Alt (Branch-Site)', 'Branch-Site', 'BranchSite', 6)
		,('Model 2 Alt Null (Branch-Site Null)', 'Branch-Site Null', 'BranchSiteNull', 7)
		,('Model 3 (Clade model C)', 'Clade model C', 'CmC', 8)
		,('Model 3 Null (Clade model C Null)', 'Clade model C Null', 'CmCNull', 9)
END
GO
IF EXISTS (SELECT * FROM sys.procedures p WHERE p.object_id = OBJECT_ID('PAML.ModelPreset_List')) BEGIN
	DROP PROCEDURE PAML.ModelPreset_List
END
GO
CREATE PROCEDURE PAML.ModelPreset_List
AS
BEGIN
	SET NOCOUNT ON

	SELECT mp.ID
			,mp.Name
			,mp.ShortName
			,mp.[Key]
			,mp.[Rank]
		FROM PAML.ModelPreset mp
		ORDER BY mp.[Rank]
END
GO
IF NOT EXISTS (SELECT * FROM sys.columns c WHERE c.object_id = OBJECT_ID('PAML.AnalysisConfiguration') AND c.Name = 'ModelPresetID') BEGIN
	ALTER TABLE PAML.AnalysisConfiguration ADD ModelPresetID int
		CONSTRAINT FK_PAML_AnalysisConfiguration_ModelPresetID FOREIGN KEY (ModelPresetID) REFERENCES PAML.ModelPreset (ID)
END
GO
ALTER PROCEDURE [PAML].[AnalysisConfiguration_Edit]
	@TreeID int
	,@Model int
	,@ModelPresetID int
	,@NCatG int
	,@KStart decimal(9,3)
	,@KEnd decimal(9,3)
	,@KInterval decimal(9,3)
	,@KFixed bit
	,@WStart decimal(9,3)
	,@WEnd decimal(9,3)
	,@WInterval decimal(9,3)
	,@WFixed bit
	,@Rank int
	,@StatusID int
	,@NSSites Common.ListInt READONLY
	,@ID int = NULL OUTPUT
AS
BEGIN
	SET NOCOUNT ON

	IF (@ID IS NULL) BEGIN
		INSERT INTO PAML.AnalysisConfiguration (TreeID, Model, ModelPresetID, NCatG
												,KStart, KEnd, KInterval, KFixed
												,WStart, WEnd, WInterval, WFixed
												,[Rank], StatusID)
		VALUES (@TreeID, @Model, @ModelPresetID, @NCatG
				,@KStart, @KEnd, @KInterval, @KFixed
				,@WStart, @WEnd, @WInterval, @WFixed
				,@Rank, @StatusID)

		SET @ID = @@IDENTITY
	END
	ELSE BEGIN
		UPDATE PAML.AnalysisConfiguration
			SET Model = @Model
				,ModelPresetID = @ModelPresetID
				,NCatG = @NCatG
				,KStart = @KStart
				,KEnd = @KEnd
				,KInterval = @KInterval
				,KFixed = @KFixed
				,WStart = @WStart
				,WEnd = @WEnd
				,WInterval = @WInterval
				,WFixed = @WFixed
				,StatusID = @StatusID
			WHERE ID = @ID

		DELETE FROM PAML.AnalysisConfigurationNSSite
			WHERE AnalysisConfigurationID = @ID
	END

	INSERT INTO PAML.AnalysisConfigurationNSSite (AnalysisConfigurationID, NSSite)
	SELECT @ID, ns.Value
		FROM @NSSites ns
END
GO

IF EXISTS (SELECT * FROM sys.objects o WHERE o.object_id = OBJECT_ID('Common.FileNameFromPath')) BEGIN
	DROP FUNCTION Common.FileNameFromPath
END
GO
CREATE FUNCTION Common.FileNameFromPath (@FilePath varchar(250))
RETURNS varchar(250)
AS
BEGIN

	DECLARE @RevFilePath varchar(250) = REVERSE(@FilePath)

	RETURN (SELECT REVERSE(SUBSTRING(@RevFilePath, 0, CHARINDEX('\', @RevFilePath, 0))))

END
GO
ALTER PROCEDURE [Job].[Job_Edit]
	@ID uniqueidentifier = NULL OUTPUT,
	@RecordSetID uniqueidentifier = NULL, -- Not used in an UPDATE
	@SubSetID uniqueidentifier = NULL, -- Not used in an UPDATE
	@TargetID int = NULL, -- Not used in an UPDATE
	@Title varchar(250) = NULL, -- Not used in an UPDATE
	@StatusID int = NULL,
	@StartedAt datetime2(7) = NULL, -- Not used in an UPDATE
	@EndedAt datetime2(7) = NULL,
	@Active bit = NULL
AS
BEGIN
	SET NOCOUNT ON

	IF NOT EXISTS (SELECT * FROM Job.Job j WHERE j.ID = @ID) BEGIN
		IF (@RecordSetID IS NULL AND @SubSetID IS NULL) BEGIN
			RAISERROR('A RecordSet ID or a SubSet ID must be provided', 11, 1)
		END

		SET @ID = NEWID()

		IF (@RecordSetID IS NULL) BEGIN
			SELECT @RecordSetID = sub.RecordSetID
				FROM RecordSet.SubSet sub
				WHERE sub.ID = @SubSetID
		END

		INSERT INTO Job.Job (ID, RecordSetID, SubSetID, TargetID, Title, StartedAt, EndedAt)
		VALUES (@ID, @RecordSetID, @SubSetID, @TargetID, @Title, @StartedAt, @EndedAt)
	END
	ELSE BEGIN
		UPDATE Job.Job
			SET StatusID = ISNULL(@StatusID, StatusID)
				,EndedAt = ISNULL(@EndedAt, EndedAt)
				,Active = ISNULL(@Active, Active)
			WHERE ID = @ID
	END
END
GO
IF EXISTS (SELECT * FROM sys.procedures p WHERE p.object_id = OBJECT_ID('PAML.Job_List')) BEGIN
	DROP PROCEDURE PAML.Job_List
END
GO
CREATE PROCEDURE PAML.Job_List
	@RecordSetID uniqueidentifier
	,@TargetID int
AS
BEGIN
	SET NOCOUNT ON

	SELECT j.ID
			,j.Title
			,j.StartedAt
			,j.EndedAt
			,j.StatusID
			,js.Name AS JobStatusName

			,Common.FileNameFromPath(t.TreeFilePath) AS TreeFileName
			,Common.FileNameFromPath(t.SequencesFilePath) AS SequencesFileName
			,t.Title AS TreeTitle
			,(SELECT COUNT(*)
				FROM PAML.Tree t
				WHERE t.JobID = j.ID) AS TreeFileCount
		
		FROM Job.Job j
		JOIN Job.[Target] jt ON jt.ID = j.TargetID
		JOIN Job.[Status] js ON js.ID = j.StatusID
		JOIN PAML.Tree t ON t.JobID = j.ID
		WHERE j.RecordSetID = @RecordSetID
			AND j.TargetID = @TargetID
			AND t.[Rank] = 1
			AND j.Active = 1
		ORDER BY j.StartedAt DESC
END
GO
ALTER FUNCTION [PAML].[GetNSSitesListForAnalysisConfiguration] (@AnalysisConfigurationID int)
RETURNS varchar(250)
AS
BEGIN
	DECLARE @nssites varchar(250) = ''

	SELECT @nssites += (CASE WHEN @nssites = '' THEN '' ELSE ',' END) + CAST(ns.NSSite AS varchar(5))
		FROM PAML.AnalysisConfigurationNSSite ns
		WHERE ns.AnalysisConfigurationID = @AnalysisConfigurationID
		ORDER BY ns.NSSite

	RETURN @nssites
END
GO
ALTER PROCEDURE [PAML].[Tree_List]
	@JobID uniqueidentifier
AS
BEGIN
	SET NOCOUNT ON

	SELECT t.ID
			,t.TreeFilePath
			,t.SequencesFilePath
			,t.Title
			,t.[Rank]
			,t.ParentID
			,t.StatusID
			,t_st.Name AS TreeStatusName
			,cf.ID AS AnalysisConfigurationID
			,cf.Model
			,cf.ModelPresetID
			,cf.NCatG
			,cf.KStart
			,cf.KEnd
			,cf.KInterval
			,cf.KFixed
			,cf.WStart
			,cf.WEnd
			,cf.WInterval
			,cf.WFixed
			,cf.[Rank]
			,cf.StatusID
			,cf_st.Name AS ConfigurationStatusName
			,PAML.GetNSSitesListForAnalysisConfiguration(cf.ID) AS NSSites
		FROM PAML.Tree t
		JOIN Job.[Status] t_st ON t_st.ID = t.StatusID
		JOIN PAML.AnalysisConfiguration cf ON cf.TreeID = t.ID
		JOIN PAML.ModelPreset mp ON mp.ID = cf.ModelPresetID
		JOIN Job.[Status] cf_st ON cf_st.ID = cf.StatusID
		WHERE t.JobID = @JobID
		ORDER BY (CASE WHEN t.ParentID IS NULL THEN 1 ELSE 0 END), t.[Rank]
END
GO
IF EXISTS (SELECT * FROM sys.procedures p WHERE p.object_id = OBJECT_ID('PAML.Job_ListTopResults')) BEGIN
	DROP PROCEDURE PAML.Job_ListTopResults
END
GO
CREATE PROCEDURE PAML.Job_ListTopResults
	@JobID uniqueidentifier
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @TopResults TABLE (TreeID int, ResultID int);

	WITH AllResults AS (
		SELECT t.ID AS TreeID
				,r.ID AS ResultID
				,ROW_NUMBER() OVER (PARTITION BY t.ID, cf.ModelPresetID, r.NSSite ORDER BY lnL DESC, r.Kappa, r.Omega) AS RowNumber
		FROM PAML.Tree t
		JOIN PAML.Result r ON r.TreeID = t.ID
		JOIN PAML.AnalysisConfiguration cf ON cf.ID = r.AnalysisConfigurationID
		WHERE t.JobID = @JobID
	)

	INSERT INTO @TopResults
	SELECT r.TreeID
			,r.ResultID
		FROM AllResults r
		WHERE r.RowNumber = 1

	SELECT tr.TreeID
			,tr.ResultID
			,r.AnalysisConfigurationID
			,t.Title
			,t.[Rank]
			,mp.[Key] AS ModelPresetKey
			,r.NSSite
			,r.Kappa
			,r.Omega
			,r.np
			,r.lnL
			,CASE mp.[Key]
				WHEN 'Model0' THEN (CASE WHEN r.NSSite = 8 THEN '8b' ELSE CONVERT(varchar(5), r.NSSite) END)
				WHEN 'Model2a' THEN '2a'
				WHEN 'Model8a' THEN '8a'
				WHEN 'BranchNull' THEN '9'
				WHEN 'Branch' THEN '10'
				WHEN 'BranchSiteNull' THEN '11'
				WHEN 'BranchSite' THEN '12'
				WHEN 'CmC' THEN '13'
				WHEN 'CmCNull' THEN '14'
				ELSE CONVERT(varchar(5), mp.[Rank])
				END AS ResultRank
			,r.k
		FROM @TopResults tr
		JOIN PAML.Tree t ON t.ID = tr.TreeID
		JOIN PAML.Result r ON r.ID = tr.ResultID
		JOIN PAML.AnalysisConfiguration cf ON cf.ID = r.AnalysisConfigurationID
		JOIN PAML.ModelPreset mp ON mp.ID = cf.ModelPresetID
		ORDER BY t.[Rank], ResultRank

	SELECT tr.ResultID
			,vt.[Rank] AS TypeRank
			,val.[Rank] AS ValueRank
			,ISNULL(val.SiteClass, '0') AS SiteClass
			,vt.Name AS ValueTypeName
			,vt.[Key] AS ValueTypeKey
			,val.Value
		FROM @TopResults tr
		JOIN PAML.ResultdNdSValue val ON val.ResultID = tr.ResultID
		JOIN PAML.ResultdNdSValueType vt ON vt.ID = val.ValueTypeID
		ORDER BY tr.ResultID, TypeRank, ValueRank, SiteClass

	-- PIVOT
	/*
	SELECT t.Title
			,t.[Rank]
			,r.NSSite
			,r.Kappa
			,r.Omega
			,r.np
			,r.lnL
			,r.k
			,pvt.ValueTypeName
			,pvt.[0], pvt.[1], pvt.[2], pvt.[2a], pvt.[2b]
		FROM TopResults tr
		JOIN PAML.Tree t ON t.ID = tr.TreeID
		JOIN PAML.Result r ON r.ID = tr.ResultID
		JOIN (SELECT * 
				FROM (SELECT tr.ResultID
							,vt.[Rank] AS TypeRank
							,val.[Rank] AS ValueRank
							,ISNULL(val.SiteClass, 0) AS SiteClass
							,vt.Name AS ValueTypeName
							,val.Value
						FROM TopResults tr
						JOIN PAML.ResultdNdSValue val ON val.ResultID = tr.ResultID
						JOIN PAML.ResultdNdSValueType vt ON vt.ID = val.ValueTypeID) p
						PIVOT (MAX(Value) FOR SiteClass IN ([0], [1], [2], [2a], [2b])) pvt) pvt ON pvt.ResultID = r.ID
		ORDER BY t.[Rank], r.NSSite, r.Kappa, r.Omega, pvt.TypeRank, pvt.ValueRank
	*/
END
GO
IF EXISTS (SELECT * FROM sys.procedures p WHERE p.object_id = OBJECT_ID('PAML.Job_ListResultDetails')) BEGIN
	DROP PROCEDURE PAML.Job_ListResultDetails
END
GO
CREATE PROCEDURE PAML.Job_ListResultDetails
	@AnalysisConfigurationID int
AS
BEGIN
	SET NOCOUNT ON;

	SELECT r.ID AS ResultID
			,mp.[Key] AS ModelPresetKey
			,r.NSSite
			,r.Kappa
			,r.Omega
			,r.np
			,r.lnL
			,r.k
		FROM PAML.AnalysisConfiguration cf 
		JOIN PAML.Result r ON r.AnalysisConfigurationID = cf.ID
		JOIN PAML.ModelPreset mp ON mp.ID = cf.ModelPresetID
		WHERE cf.ID = @AnalysisConfigurationID
		ORDER BY r.lnL DESC, r.Kappa, r.Omega

	SELECT r.ID AS ResultID
			,vt.[Rank] AS TypeRank
			,val.[Rank] AS ValueRank
			,ISNULL(val.SiteClass, '0') AS SiteClass
			,vt.Name AS ValueTypeName
			,val.Value
		FROM PAML.Result r
		JOIN PAML.ResultdNdSValue val ON val.ResultID = r.ID
		JOIN PAML.ResultdNdSValueType vt ON vt.ID = val.ValueTypeID
		WHERE r.AnalysisConfigurationID = @AnalysisConfigurationID
		ORDER BY TypeRank, ValueRank, SiteClass
END
GO

GO
UPDATE Common.ApplicationProperty
	SET Value = '1.4.0.1'
	WHERE [Key] = 'DatabaseVersion'
GO