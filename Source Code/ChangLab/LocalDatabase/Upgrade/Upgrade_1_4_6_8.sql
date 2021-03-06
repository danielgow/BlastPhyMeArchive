SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [PAML].[Result_Details]
	@ResultID int
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @TreeID int
			,@AnalysisConfigurationID int
			,@NSSite int

	SELECT @TreeID = r.TreeID
			,@AnalysisConfigurationID = r.AnalysisConfigurationID
			,@NSSite = r.NSSite
		FROM PAML.Result r
		WHERE r.ID = @ResultID

	SELECT t.ID AS TreeID
			,t.Title AS TreeTitle
			,t.TreeFilePath
			,t.SequenceCount
			,t.SequenceLength
			,t.SequencesFilePath
			,t.JobID
			,cf.ModelPresetID
			,mp.[Key] AS ModelPresetKey
			,r.NSSite
			,cf.NCatG
			,cf.KStart, cf.KEnd, cf.KInterval, cf.KFixed
			,cf.WStart, cf.WEnd, cf.WInterval, cf.WFixed
		FROM PAML.Result r
		JOIN PAML.Tree t ON t.ID = r.TreeID
		JOIN PAML.AnalysisConfiguration cf ON cf.ID = r.AnalysisConfigurationID
		JOIN PAML.ModelPreset mp ON mp.ID = cf.ModelPresetID
		JOIN Job.Job j ON j.ID = t.JobID
		WHERE r.ID = @ResultID

	SELECT r.ID AS ResultID
			,r.np
			,r.lnL
			,r.k
			,r.Kappa
			,r.Omega
			,ROW_NUMBER() OVER (ORDER BY r.lnL DESC, r.Kappa, r.Omega) AS RowNumber
		FROM PAML.Result r
		WHERE r.TreeID = @TreeID
			AND r.AnalysisConfigurationID = @AnalysisConfigurationID
			AND r.NSSite = @NSSite
			AND r.Active = 1
		ORDER BY RowNumber

	SELECT r.ID AS ResultID
			,vt.[Rank] AS TypeRank
			,val.[Rank] AS ValueRank
			,ISNULL(val.SiteClass, '0') AS SiteClass
			,vt.Name AS ValueTypeName
			,vt.[Key] AS ValueTypeKey
			,val.Value
		FROM PAML.Result r
		JOIN PAML.ResultdNdSValue val ON val.ResultID = r.ID
		JOIN PAML.ResultdNdSValueType vt ON vt.ID = val.ValueTypeID
		WHERE r.TreeID = @TreeID
			AND r.AnalysisConfigurationID = @AnalysisConfigurationID
			AND r.NSSite = @NSSite
			AND r.Active = 1
		ORDER BY r.ID, TypeRank, ValueRank, SiteClass
END
GO

GO
UPDATE Common.ApplicationProperty
	SET Value = '1.4.6.8'
	WHERE [Key] = 'DatabaseVersion'
GO