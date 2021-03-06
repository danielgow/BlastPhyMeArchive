SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [RecordSet].[RecordSet_Destroy]
	@RecordSetID uniqueidentifier
AS
BEGIN
	-- This procedure is used for debug purposes only; deleting a recordset in the app simply sets the Active flag to 0.
	SET NOCOUNT ON

	BEGIN TRANSACTION
	BEGIN TRY
		DELETE sg
			FROM RecordSet.SubSetGene sg
			JOIN RecordSet.SubSet sub ON sub.ID = sg.SubSetID
			WHERE sub.RecordSetID = @RecordSetID

		-- Capture the genes that belong to this recordset; if they don't exist in any other recordset they can be deleted from Gene.Gene.
		DECLARE @Genes TABLE (ID uniqueidentifier)
		INSERT INTO @Genes
		SELECT g.GeneID
			FROM RecordSet.Gene g
			WHERE g.RecordSetID = @RecordSetID
		DELETE g
			FROM RecordSet.Gene g
			WHERE g.RecordSetID = @RecordSetID

		-- Same idea as with Genes
		DECLARE @Alignments TABLE (ID int)
		INSERT INTO @Alignments
		SELECT DISTINCT n_al.AlignmentID
			FROM NCBI.BlastNAlignment n_al
			JOIN NCBI.Request req ON req.ID = n_al.RequestID
			JOIN Job.Job j ON j.ID = req.JobID
			WHERE j.RecordSetID = @RecordSetID
		-- Pick up the subject genes
		INSERT INTO @Genes
		SELECT DISTINCT al.SubjectID
			FROM BlastN.Alignment al 
			JOIN NCBI.BlastNAlignment n_al ON n_al.AlignmentID = al.ID
			JOIN NCBI.Request req ON req.ID = n_al.RequestID
			JOIN Job.Job j ON j.ID = req.JobID
			WHERE j.RecordSetID = @RecordSetID

		DELETE n_al
			FROM NCBI.BlastNAlignment n_al
			JOIN @Alignments al ON al.ID = n_al.AlignmentID
		DELETE ex
			FROM BlastN.AlignmentExon ex
			JOIN BlastN.Alignment al ON al.ID = ex.AlignmentID
			JOIN @Alignments n_al ON n_al.ID = al.ID
			WHERE NOT EXISTS (SELECT * -- Don't delete if it's aligned via a different recordset's request.
								FROM NCBI.BlastNAlignment existing
								WHERE existing.AlignmentID = al.ID)
		DELETE al
			FROM BlastN.Alignment al 
			JOIN @Alignments n_al ON n_al.ID = al.ID
			WHERE NOT EXISTS (SELECT *
								FROM NCBI.BlastNAlignment existing
								WHERE existing.AlignmentID = al.ID)
		DELETE g
			FROM NCBI.Gene g
			JOIN NCBI.Request req ON req.ID = g.RequestID
			JOIN Job.Job j ON j.ID = req.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE req
			FROM NCBI.Request req
			JOIN Job.Job j ON j.ID = req.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE g
			FROM Job.Gene g
			JOIN Job.Job j ON j.ID = g.JobID
			WHERE j.RecordSetID = @RecordSetID

		DELETE pe
			FROM PAML.ProcessException pe
			JOIN PAML.ProcessOutput po ON po.ID = pe.ProcessOutputID
			JOIN PAML.Tree t ON t.ID = po.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE po
			FROM PAML.ProcessOutput po
			JOIN PAML.Tree t ON t.ID = po.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID

		DELETE sr
			FROM PAML.SubSetResult sr
			JOIN PAML.Result r ON r.ID = sr.ResultID
			JOIN PAML.Tree t ON t.ID = r.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE v
			FROM PAML.ResultdNdSValue v
			JOIN PAML.Result r ON r.ID = v.ResultID
			JOIN PAML.Tree t ON t.ID = r.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE r
			FROM PAML.Result r
			JOIN PAML.Tree t ON t.ID = r.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID

		DELETE ns
			FROM PAML.AnalysisConfigurationNSSite ns
			JOIN PAML.AnalysisConfiguration c ON c.ID = ns.AnalysisConfigurationID
			JOIN PAML.Tree t ON t.ID = c.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE c
			FROM PAML.AnalysisConfiguration c
			JOIN PAML.Tree t ON t.ID = c.TreeID
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE t
			FROM PAML.Tree t
			JOIN Job.Job j ON j.ID = t.JobID
			WHERE j.RecordSetID = @RecordSetID
			
		DELETE ag
			FROM Gene.AlignedGeneSource ag
			JOIN Job.Job j ON j.ID = ag.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE ot
			FROM Job.OutputText ot
			JOIN Job.Job j ON j.ID = ot.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE je
			FROM Job.Exception je
			JOIN Job.Job j ON j.ID = je.JobID
			WHERE j.RecordSetID = @RecordSetID
		DELETE j
			FROM Job.Job j
			WHERE j.RecordSetID = @RecordSetID
		
		DELETE sub
			FROM RecordSet.SubSet sub
			WHERE sub.RecordSetID = @RecordSetID
		DELETE ap
			FROM RecordSet.ApplicationProperty ap
			WHERE ap.RecordSetID = @RecordSetID
		DELETE rs
			FROM RecordSet.RecordSet rs
			WHERE rs.ID = @RecordSetID

		-- Narrow @Genes down to just the orphaned gene sequences
		DELETE id
			FROM @Genes id
			WHERE EXISTS (SELECT * FROM RecordSet.Gene rs_g WHERE rs_g.GeneID = id.ID)
				OR EXISTS (SELECT * FROM BlastN.Alignment al WHERE (al.SubjectID = id.ID OR al.QueryID = id.ID))

		-- Delete the orphaned records
		DELETE fi
			FROM Gene.FeatureInterval fi
			JOIN Gene.Feature f ON f.ID = fi.FeatureID
			JOIN @Genes id ON id.ID = f.GeneID
		DELETE f
			FROM Gene.Feature f
			JOIN @Genes id ON id.ID = f.GeneID
		DELETE seq
			FROM Gene.NucleotideSequence seq
			JOIN @Genes id ON id.ID = seq.GeneID
		DELETE g -- Remove any orphaned gene sequences
			FROM Gene.GeneHistory g
			JOIN @Genes id ON id.ID = g.ID
		DELETE g
			FROM Gene.Gene g
			JOIN @Genes id ON id.ID = g.ID

		COMMIT TRANSACTION
	END TRY
	BEGIN CATCH
		ROLLBACK TRANSACTION
		
		EXEC Common.ThrowException
	END CATCH
END
GO
ALTER PROCEDURE Job.BlastN_ListRequests
	@JobID uniqueidentifier
AS
BEGIN
	SET NOCOUNT ON
	
	DECLARE @History TABLE (ID int, RequestID varchar(20), StartTime datetime2(7), EndTime datetime2(7)
								,LastStatus varchar(8), StatusInformation varchar(MAX)
								,TargetDatabase varchar(250), [Algorithm] varchar(20), GeneCount int, [Rank] int);
	WITH RequestGenes AS (
		SELECT req.ID AS RequestID
				,COUNT(*) AS GeneCount
			FROM NCBI.Request req
			JOIN NCBI.Gene ng ON ng.RequestID = req.ID
			WHERE req.JobID = @JobID
			GROUP BY req.ID
	)

	INSERT INTO @History
	SELECT req.ID
			,req.RequestID
			,req.StartTime
			,req.EndTime AS EndTime
			,req.LastStatus
			,ISNULL(req.StatusInformation, '')
			,req.TargetDatabase
			,req.[Algorithm]
			,rg.GeneCount
			,(0 - ROW_NUMBER() OVER (ORDER BY req.ID DESC)) AS [Rank]
		FROM NCBI.Request req
		JOIN RequestGenes rg ON rg.RequestID = req.ID
		WHERE req.JobID = @JobID;

	-- Theoretically there shouldn't be any of these, because all batches will at least get associated with a shell Request, but if some critical
	-- error failed out of the Job then there might be some that didn't get tagged.
	DECLARE @GenesWithoutARequest TABLE (GeneID uniqueidentifier)
	INSERT INTO @GenesWithoutARequest
	SELECT jg.GeneID
		FROM Job.Gene jg
		JOIN Job.GeneDirection dir ON dir.ID = jg.DirectionID
		WHERE jg.JobID = @JobID
			AND dir.[Key] = 'Input' 
			AND NOT EXISTS (SELECT *
								FROM NCBI.Request req
								JOIN NCBI.Gene ng ON ng.RequestID = req.ID
								WHERE req.JobID = @JobID
									AND ng.GeneID = jg.GeneID)
	
	IF EXISTS (SELECT * FROM @GenesWithoutARequest) BEGIN
		-- We only want to show the unsubmitted row if there were any genes not submitted.
		INSERT INTO @History
		SELECT '0'
				,'Not Processed'
				,NULL
				,NULL
				,CASE WHEN EXISTS (SELECT * FROM Job.Exception ex WHERE ex.JobID = @JobID AND ex.RequestID IS NULL)
					  THEN 'Error' -- Again, this is picking up on the idea of a critical error failing out of the job.
					  ELSE ''
					  END -- LastStatus
				,''
				,''
				,''
				,COUNT(*) -- GeneCount
				,0
			FROM @GenesWithoutARequest
	END
	
	SELECT * 
		FROM @History h
		ORDER BY h.[Rank]
END
GO

GO
UPDATE Common.ApplicationProperty
	SET Value = '1.4.6.4'
	WHERE [Key] = 'DatabaseVersion'
GO