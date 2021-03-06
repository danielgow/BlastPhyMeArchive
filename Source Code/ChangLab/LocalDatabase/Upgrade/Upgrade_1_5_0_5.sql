SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

GO
IF EXISTS (SELECT * FROM sys.objects o WHERE o.object_id = OBJECT_ID('PAML.ResultIsInRecordSet')) BEGIN
	EXEC ('DROP FUNCTION PAML.ResultIsInRecordSet')
END
GO
CREATE FUNCTION PAML.ResultIsInRecordSet(@ResultID int, @RecordSetID uniqueidentifier)
	RETURNS bit
AS
BEGIN

	RETURN
		CAST(CASE WHEN EXISTS (SELECT *
									FROM PAML.SubSetResult sr
									JOIN RecordSet.SubSet sub ON sub.ID = sr.SubSetID
									WHERE sub.RecordSetID = @RecordSetID
										AND sr.ResultID = @ResultID)
				THEN 1 ELSE 0 END AS bit)

END
GO
ALTER PROCEDURE [PAML].[Job_ListTopResults]
	@RecordSetID uniqueidentifier
	,@JobID uniqueidentifier = NULL
	,@ResultIDs Common.ListInt READONLY
AS
BEGIN
	SET NOCOUNT ON;
	DECLARE @TopResults TABLE (TreeID int, ResultID int);

	IF EXISTS (SELECT * FROM @ResultIDs) BEGIN
		INSERT INTO @TopResults
		SELECT r.TreeID, r.ID
			FROM @ResultIDs r_id
			JOIN PAML.Result r ON r.ID = r_id.Value
	END
	ELSE BEGIN
		WITH AllResults AS (
			SELECT t.ID AS TreeID
					,r.ID AS ResultID
					,ROW_NUMBER() OVER (PARTITION BY t.ID, cf.ModelPresetID, r.NSSite ORDER BY lnL DESC, r.Kappa, r.Omega) AS RowNumber
			FROM PAML.Tree t
			JOIN PAML.Result r ON r.TreeID = t.ID
			JOIN PAML.AnalysisConfiguration cf ON cf.ID = r.AnalysisConfigurationID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE r.Active = 1
				AND (@RecordSetID IS NULL OR j.RecordSetID = @RecordSetID)
				AND ((@JobID IS NULL AND j.Active = 1)
						OR
					(@JobID IS NOT NULL AND (t.JobID = @JobID)))
		)

		INSERT INTO @TopResults
		SELECT r.TreeID, r.ResultID
			FROM AllResults r
			WHERE r.RowNumber = 1
	END

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
			,r.CompletedAt
			,PAML.ResultIsInRecordSet(tr.ResultID, @RecordSetID) AS InRecordSet
		FROM @TopResults tr
		JOIN PAML.Tree t ON t.ID = tr.TreeID
		JOIN PAML.Result r ON r.ID = tr.ResultID
		JOIN PAML.AnalysisConfiguration cf ON cf.ID = r.AnalysisConfigurationID
		JOIN PAML.ModelPreset mp ON mp.ID = cf.ModelPresetID
		ORDER BY t.Title, ResultRank

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
ALTER PROCEDURE [PAML].[Job_List]
	@RecordSetID uniqueidentifier
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @TargetID int = (SELECT ID FROM Job.[Target] WHERE [Key] = 'CodeML')

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
			,CAST(CASE WHEN EXISTS (SELECT * 
										FROM PAML.Result r
										JOIN PAML.Tree t ON t.ID = r.TreeID
										JOIN PAML.SubSetResult sr ON sr.ResultID = r.ID
										JOIN RecordSet.SubSet sub ON sub.ID = sr.SubSetID 
											WHERE sub.RecordSetID = @RecordSetID 
											AND t.JobID = j.ID) THEN 1 ELSE 0 END AS bit) AS InRecordSet
		
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

GO

UPDATE Common.ApplicationProperty
	SET Value = '1.5.0.5'
	WHERE [Key] = 'DatabaseVersion'
GO