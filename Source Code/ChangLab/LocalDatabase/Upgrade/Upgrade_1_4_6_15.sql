SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [Job].[BlastN_ListAnnotationGenesForJob]
	@JobID uniqueidentifier
AS
BEGIN
	SET NOCOUNT ON

	SELECT qry.*
			,sbj.ID AS SubjectID
			,sbj.SourceID AS SubjectSourceID
			,sbj.[Definition] AS SubjectDefinition
			,sbj.GenBankID AS SubjectGenBankID
			,sbj.LastUpdatedAt AS SubjectLastUpdatedAt
			,sbj.SequenceIdentityMatchPercentage
		FROM Job.Gene j
		JOIN Gene.Gene qry ON qry.ID = j.GeneID

		LEFT OUTER JOIN (
				SELECT al.QueryID
						,sbj.ID
						,sbj.SourceID
						,sbj.[Definition]
						,sbj.GenBankID
						,sbj.LastUpdatedAt
						,CONVERT(int, AVG(ROUND((CONVERT(float, al_ex.IdentitiesCount) / CONVERT(float, al_ex.AlignmentLength)), 2) * 100.0)) AS SequenceIdentityMatchPercentage
					FROM Gene.Gene sbj
					JOIN BlastN.Alignment al ON al.SubjectID = sbj.ID AND al.[Rank] = 0 -- Return just the top match
					JOIN BlastN.AlignmentExon al_ex ON al_ex.AlignmentID = al.ID
					JOIN NCBI.BlastNAlignment ncbi ON ncbi.AlignmentID = al.ID
					JOIN NCBI.Request req ON req.ID = ncbi.RequestID
					WHERE req.JobID = @JobID
					GROUP BY al.QueryID, sbj.ID, sbj.SourceID, sbj.[Definition], sbj.GenBankID, sbj.LastUpdatedAt
			) sbj ON sbj.QueryID = qry.ID

		WHERE j.JobID = @JobID
			AND j.DirectionID = 1

END
GO

ALTER PROCEDURE [RecordSet].[RecordSet_Export]
	@RecordSetID uniqueidentifier = NULL
	,@SelectedSubSetIDs Common.ListUniqueIdentifier READONLY
	,@SelectedGeneIDs Common.ListUniqueIdentifier READONLY
	,@SelectedResultIDs Common.ListInt READONLY
	,@SourceSubSetID_ForSelectedRecords uniqueidentifier = NULL
	,@IncludeJobHistory_TargetIDs Common.ListInt READONLY
	,@GeneOptions_IncludeAlignedSequences bit = 1
	,@GeneOptions_IncludeGeneSequenceAnnotations bit = 1
	,@CompileDocument bit = 0
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @SubSetIDs Common.ListUniqueIdentifier
	DECLARE @GeneIDs TABLE (GeneID uniqueidentifier)
	DECLARE @ResultIDs TABLE (ResultID int)
	
	IF EXISTS (SELECT * FROM @SelectedSubSetIDs) BEGIN
		INSERT INTO @SubSetIDs SELECT Value FROM @SelectedSubSetIDs

		-- To start, get all of the Gene.Gene records that are directly being exported; in other words, everything that's linked in RecordSet.SubSet_Gene
		-- for the subsets that the user selected within the current RecordSet.
		INSERT INTO @GeneIDs
		SELECT DISTINCT g.ID
			FROM Gene.Gene g
			JOIN RecordSet.SubSetGene sg ON sg.GeneID = g.ID
			JOIN @SubSetIDs s_id ON s_id.Value = sg.SubSetID
			WHERE g.Active = 1	
		
		-- Get all of the PAML.Result records that are directly being exported.
		INSERT INTO @ResultIDs
		SELECT r.ID
			FROM PAML.Result r
			JOIN PAML.SubSetResult sr ON sr.ResultID = r.ID
			JOIN @SubSetIDs s_id ON s_id.Value = sr.SubSetID
	END
	ELSE IF EXISTS (SELECT * FROM @SelectedGeneIDs) BEGIN
		-- The user is exporting a data file of specific gene records, not exporting a recordset's worth of data.
		INSERT INTO @GeneIDs
		SELECT sg.Value FROM @SelectedGeneIDs sg

		-- We use this as a convenience for the Import logic; the RecordSet-SubSet-Gene block will be generated for just this one subset and the
		-- import logic can leverage it to assign the Gene.Gene records it just created to the target subset ID specified by the user.
		INSERT INTO @SubSetIDs
		SELECT @SourceSubSetID_ForSelectedRecords
	END
	ELSE IF EXISTS (SELECT * FROM @SelectedResultIDs) BEGIN
		-- The user is exporting a data file of specific PAML results, not exporting a recordset's worth of data.
		INSERT INTO @ResultIDs
		SELECT sr.Value FROM @SelectedResultIDs sr

		-- We use this as a convenience for the Import logic; the RecordSet-PAML-Result/SubSetIDs block will be generated for just this one subset
		-- and theimport logic can leverage it to assign the PAML.Result records it just created to the target subset ID specified by the user.
		INSERT INTO @SubSetIDs
		SELECT @SourceSubSetID_ForSelectedRecords
	END

	IF (@GeneOptions_IncludeAlignedSequences = 1) BEGIN
		-- We also need all of the Gene.Gene records that are aligned with the directly selected sequences.	 These are not restricted by 
		-- RecordSet/SubSet because the app doesn't restrict them that way when you view aligned sequences on frmGeneDetails.
		-- At the moment we're not including Query sequences for which our directly selected sequences were aligned as Subject sequences.
		INSERT INTO @GeneIDs
		SELECT DISTINCT sg.ID
			FROM BlastN.Alignment al
			JOIN @GeneIDs g_id ON g_id.GeneID = al.QueryID
			JOIN Gene.Gene sg ON sg.ID = al.SubjectID
			WHERE sg.Active = 1
				AND NOT EXISTS (SELECT * FROM @GeneIDs ex WHERE ex.GeneID = sg.ID)
	END
	
	DECLARE @JobIDs TABLE (JobID uniqueidentifier)
	-- Build out the list of jobs to include
	IF EXISTS (SELECT * FROM @IncludeJobHistory_TargetIDs) BEGIN
		IF EXISTS (SELECT *
						FROM @IncludeJobHistory_TargetIDs t_id
						JOIN Job.[Target] t ON t.ID = t_id.Value
						WHERE t.[Key] IN ('BLASTN_NCBI', 'PRANK', 'MUSCLE', 'PhyML')) BEGIN
			INSERT INTO @JobIDs
			SELECT j.ID
				FROM Job.Job j
				JOIN @IncludeJobHistory_TargetIDs t ON t.Value = j.TargetID
				WHERE j.Active = 1
					AND EXISTS (SELECT *
									FROM Job.Gene jg
									JOIN @GeneIDs g_id ON g_id.GeneID = jg.GeneID
									WHERE jg.JobID = j.ID
										AND jg.DirectionID = 1)
		END

		IF EXISTS (SELECT *
						FROM @IncludeJobHistory_TargetIDs t_id
						JOIN Job.[Target] t ON t.ID = t_id.Value
						WHERE t.[Key] IN ('CodeML')) BEGIN
			INSERT INTO @JobIDs
			SELECT j.ID
				FROM Job.Job j
				JOIN @IncludeJobHistory_TargetIDs t ON t.Value = j.TargetID
				WHERE j.Active = 1
					AND EXISTS (SELECT *
									FROM PAML.SubSetResult sr
									JOIN @ResultIDs r_id ON r_id.ResultID = sr.ResultID
									JOIN PAML.Result r ON r.ID = r_id.ResultID
									JOIN PAML.Tree t ON t.ID = r.TreeID
									WHERE t.JobID = j.ID
										AND r.Active = 1)
		END
	END

	DECLARE @Output TABLE (ID int identity(1,1), Data xml)
	
	-- Export some properties of the source database; this becomes the "header" for the data file.
	INSERT INTO @Output (Data)
	SELECT (SELECT [Properties].Value AS [DatabaseVersion]
					FROM Common.ApplicationProperty [Properties]
					WHERE [Properties].[Key] = 'DatabaseVersion'
					FOR XML AUTO, ELEMENTS)
	
	IF EXISTS (SELECT * FROM @SelectedSubSetIDs) BEGIN
		-- This is only necessary if the user is exporting a recordset.
		INSERT INTO @Output (Data)
		SELECT (SELECT [RecordSet].*
						,[Properties].[Key]
						,[Properties].Value
					FROM RecordSet.RecordSet [RecordSet]
					LEFT OUTER JOIN RecordSet.ApplicationProperty [Properties] ON [Properties].RecordSetID = [RecordSet].ID
					WHERE [RecordSet].ID = @RecordSetID
					FOR XML AUTO, ELEMENTS)
		UNION ALL 
		SELECT (SELECT [SubSet].ID
						,[SubSet].Name
						,[SubSet].DataTypeID
						,[SubSet].LastOpenedAt
						,[SubSet].[Open]
						,[SubSet].DisplayIndex
					FROM RecordSet.RecordSet [RecordSet]
					JOIN RecordSet.SubSet [SubSet] ON [SubSet].RecordSetID = [RecordSet].ID
					JOIN @SubSetIDs s_id ON s_id.Value = [SubSet].ID
					ORDER BY [SubSet].Name
					FOR XML AUTO, ROOT ('RecordSet-SubSet'))
	END

	-- Export the Genes, nucleotide sequence data and annotations, and their SubSet assignments
	INSERT INTO @Output (Data)
	SELECT (SELECT [Gene].ID
					,[Gene].Name
					,[Gene].[Definition]
					,[Gene].SourceID
					,[Gene].GenBankID
					,[Gene].Locus
					,[Gene].Accession
					,[Gene].Organism
					,[Gene].Taxonomy
					,[Gene].Nucleotides
					,[Gene].SequenceTypeID
					,[Gene].[Description]
					,[Gene].LastUpdatedAt
					,[Gene].LastUpdateSourceID
				FROM Gene.Gene [Gene]
				JOIN @GeneIDs g ON g.GeneID = [Gene].ID
				ORDER BY ID
				FOR XML AUTO, ELEMENTS, ROOT ('RecordSet-Gene'))
	UNION ALL
	SELECT (SELECT [Sequence].*
				FROM Gene.NucleotideSequence [Sequence]
				JOIN @GeneIDs g ON g.GeneID = [Sequence].GeneID
				ORDER BY g.GeneID
				FOR XML AUTO, ELEMENTS, ROOT ('RecordSet-Gene-Sequence'))
	UNION ALL
	SELECT (SELECT [SubSet].ID
					,[Gene].GeneID
					,[Gene].ModifiedAt
				FROM RecordSet.SubSet [SubSet]
				JOIN RecordSet.SubSetGene [Gene] ON [Gene].SubSetID = [SubSet].ID
				JOIN @SubSetIDs s_id ON s_id.Value = [SubSet].ID
				JOIN @GeneIDs g ON g.GeneID = [Gene].GeneID
				ORDER BY [SubSet].ID
				FOR XML AUTO, ROOT ('RecordSet-SubSet-Gene'))
	
	IF (@GeneOptions_IncludeGeneSequenceAnnotations = 1) BEGIN
		INSERT INTO @Output (Data)
		SELECT (SELECT [Gene].GeneID
						,[Feature].ID
						,[Feature].[Rank]
						,[Feature].FeatureKeyID
						,[Feature].GeneQualifier
						,[Feature].GeneIDQualifier
						,[Feature-Interval].ID
						,[Feature-Interval].Start
						,[Feature-Interval].[End]
						,[Feature-Interval].IsComplement
						,[Feature-Interval].StartModifier
						,[Feature-Interval].EndModifier
						,[Feature-Interval].Accession
					FROM Gene.Feature [Feature]
					JOIN Gene.FeatureInterval [Feature-Interval] ON [Feature-Interval].FeatureID = [Feature].ID
					JOIN @GeneIDs [Gene] ON [Gene].GeneID = [Feature].GeneID
					ORDER BY [Gene].GeneID, [Feature].ID, [Feature-Interval].ID
					FOR XML AUTO, ROOT ('RecordSet-Gene-Feature'))
	END

	IF EXISTS (SELECT * FROM @IncludeJobHistory_TargetIDs) BEGIN
		INSERT INTO @Output (Data)
		SELECT (SELECT [Job].ID
						,[Job].TargetID
						,[Job].StartedAt
						,[Job].EndedAt
						,[Job].StatusID
						,[Job].SubSetID
						,[Job].Title
						,CAST('<Encoded>' + Common.ConvertXMLToBase64([Job].AdditionalProperties) + '</Encoded>' AS xml) AS AdditionalProperties
						,CAST(('<Output>' + Common.ConvertToBase64(CONVERT(nvarchar(MAX), [Output].OutputText)) + '</Output>') AS xml) AS OutputText
					FROM Job.Job [Job]
					LEFT OUTER JOIN Job.OutputText [Output] ON [Output].JobID = [Job].ID
					JOIN @JobIDs j_id ON j_id.JobID = [Job].ID
					ORDER BY [Job].ID
					FOR XML AUTO, ROOT ('RecordSet-Job'))
		UNION ALL
		SELECT (SELECT [Job].ID
						,[Exception].ID
						,[Exception].RequestID
						,[Exception].ParentID
						,[Exception].ExceptionAt
						,[Exception].ExceptionType
						,Common.ConvertToBase64(CONVERT(nvarchar(MAX), [Exception].[Message])) AS [Message]
						,Common.ConvertToBase64(CONVERT(nvarchar(MAX), [Exception].[Source])) AS [Source]
						,Common.ConvertToBase64(CONVERT(nvarchar(MAX), [Exception].StackTrace)) AS StackTrace
					FROM Job.Job [Job]
					JOIN Job.Exception [Exception] ON [Exception].JobID = [Job].ID
					JOIN @JobIDs j_id ON j_id.JobID = [Job].ID
					ORDER BY [Job].ID, [Exception].ID
					FOR XML AUTO, ROOT ('RecordSet-Job-Exception'))
		UNION ALL
		SELECT (SELECT [Job].ID
						,[Gene].GeneID
						,[Gene].DirectionID
					FROM Job.Gene [Gene]
					JOIN Job.Job [Job] ON [Job].ID = [Gene].JobID
					JOIN @JobIDs j_id ON j_id.JobID = [Job].ID
					ORDER BY [Job].ID, [Gene].GeneID
					FOR XML AUTO, ROOT ('RecordSet-Job-Gene'))
		UNION ALL
		SELECT (SELECT [Request].ID
						,[Request].RequestID
						,[Request].JobID
						,[Request].StartTime
						,[Request].EndTime
						,[Request].LastStatus
						,[Request].LastUpdatedAt
						,[Request].TargetDatabase
						,[Request].[Algorithm]
						,CASE WHEN ISNULL([Request].StatusInformation, '') = '' THEN NULL
							ELSE CAST(('<Text>' + [Request].StatusInformation + '</Text>') AS xml) 
							END AS StatusInformation
						,CAST(('<IDs>' + NCBI.ConcatenateBlastNAlignments([Request].ID) + '</IDs>') AS xml) AS BlastNAlignments
						,[Request-Gene].GeneID
						,[Request-Gene].StatusID
					FROM NCBI.Request [Request]
					JOIN @JobIDs j_id ON j_id.JobID = [Request].JobID
					JOIN NCBI.Gene [Request-Gene] ON [Request-Gene].RequestID = [Request].ID
					ORDER BY [Request].ID, [Request-Gene].GeneID
					FOR XML AUTO, ROOT ('RecordSet-NCBI-Request'))
		UNION ALL
		SELECT (SELECT DISTINCT [Alignment].*
						,[Alignment-Exon].OrientationID
						,[Alignment-Exon].BitScore
						,[Alignment-Exon].AlignmentLength
						,[Alignment-Exon].IdentitiesCount
						,[Alignment-Exon].Gaps
						,[Alignment-Exon].QueryRangeStart
						,[Alignment-Exon].QueryRangeEnd
						,[Alignment-Exon].SubjectRangeStart
						,[Alignment-Exon].SubjectRangeEnd
					FROM BlastN.Alignment [Alignment]
					JOIN BlastN.AlignmentExon [Alignment-Exon] ON [Alignment-Exon].AlignmentID = [Alignment].ID
					JOIN NCBI.BlastNAlignment n_al ON n_al.AlignmentID = [Alignment].ID
					JOIN NCBI.Request req ON req.ID = n_al.RequestID
					JOIN @JobIDs j_id ON j_id.JobID = req.JobID
					JOIN Gene.Gene qry ON qry.ID = Alignment.QueryID
					JOIN Gene.Gene sbj ON sbj.ID = Alignment.SubjectID
					WHERE qry.Active = 1
						AND sbj.Active = 1
					ORDER BY [Alignment].ID
					FOR XML AUTO, ROOT ('RecordSet-BLASTN-Alignment'))
		--UNION ALL
		--SELECT (SELECT [Request].ID
		--				,[Alignment].AlignmentID
		--				--,(SELECT [Alignment].AlignmentID
		--				--		FROM NCBI.BlastNAlignment [Alignment] 
		--				--		WHERE [Alignment].RequestID = [Request].ID
		--				--		FOR XML PATH(''), TYPE) AS "Alignments"
		--			FROM NCBI.Request [Request]
		--			JOIN NCBI.BlastNAlignment [Alignment] ON [Alignment].RequestID = [Request].ID
		--			JOIN @JobIDs j_id ON j_id.JobID = [Request].JobID
		--			WHERE EXISTS (SELECT * FROM NCBI.BlastNAlignment ex WHERE ex.RequestID = [Request].ID)
		--			FOR XML AUTO, ROOT ('RecordSet-Request-Alignment'))
		UNION ALL
		SELECT (SELECT [Tree].ID
						,[Tree].JobID
						,[Tree].TreeFilePath
						,[Tree].SequencesFilePath
						,[Tree].[Rank]
						,[Tree].StatusID
						,[Tree].Title
						,[Tree].SequenceCount
						,[Tree].SequenceLength
						,CAST('<Encoded>' + Common.ConvertXMLToBase64([Tree].ControlConfiguration) + '</Encoded>' AS xml) AS ControlConfiguration

						,[Config].ID
						,[Config].Model
						,[Config].NCatG
						,CONVERT(varchar(10), [Config].KStart) + '|' + CONVERT(varchar(10), ISNULL([Config].KEnd, [Config].KStart)) + '|' + CONVERT(varchar(10), [Config].KInterval) + '|' + CONVERT(varchar(1), [Config].KFixed) AS K
						,CONVERT(varchar(10), [Config].WStart) + '|' + CONVERT(varchar(10), ISNULL([Config].WEnd, [Config].WStart)) + '|' + CONVERT(varchar(10), [Config].WInterval) + '|' + CONVERT(varchar(1), [Config].WFixed) AS W
						,[Config].[Rank]
						,[Config].StatusID
						,[Config].ModelPresetID
						,PAML.GetNSSitesListForAnalysisConfiguration([Config].ID) AS NSSites
					FROM PAML.Tree [Tree]
					JOIN PAML.AnalysisConfiguration [Config] ON [Config].TreeID = [Tree].ID
					JOIN @JobIDs j_id ON j_id.JobID = [Tree].JobID
					ORDER BY [Tree].ID, [Config].ID
					FOR XML AUTO, ROOT ('RecordSet-PAML-Tree'))
		UNION ALL
		SELECT (SELECT [Result].ID
						,[Result].TreeID
						,[Result].AnalysisConfigurationID
						,[Result].NSSite
						,[Result].Kappa
						,[Result].Omega
						,[Result].np
						,[Result].lnL
						,[Result].k
						,[Result].Duration
						,[Result].CompletedAt
						,CONVERT(xml,
							(SELECT ssr.SubSetID AS ID
								FROM PAML.SubSetResult ssr
								JOIN @SubSetIDs sub ON sub.Value = ssr.SubSetID
								WHERE ssr.ResultID = [Result].ID
								FOR XML RAW)
							) AS SubSetIDs
						,[Value].ID
						,[Value].SiteClass
						,[Value].ValueTypeID
						,[Value].[Rank]
						,[Value].Value
					FROM PAML.Result [Result]
					JOIN PAML.ResultdNdSValue [Value] ON [Value].ResultID = [Result].ID
					JOIN PAML.SubSetResult [SubSetResult] ON [SubSetResult].ResultID = [Result].ID
					JOIN PAML.Tree [Tree] ON [Tree].ID = [Result].TreeID
					JOIN @ResultIDs r_id ON r_id.ResultID = [Result].ID
					WHERE [Result].Active = 1
					ORDER BY [Result].ID, [Value].ID
					FOR XML AUTO, ROOT ('RecordSet-PAML-Result'))
		UNION ALL
		SELECT (SELECT [Output].ID
						,[Output].TreeID
						,[Output].AnalysisConfigurationID
						,[Output].Kappa
						,[Output].Omega
						,[Output].StatusID
						,[Output].ProcessDirectory
						,Common.ConvertToBase64(CONVERT(nvarchar(MAX), [Output].OutputData)) AS OutputData
						,Common.ConvertToBase64(CONVERT(nvarchar(MAX), [Output].ErrorData)) AS ErrorData
					FROM PAML.ProcessOutput [Output]
					JOIN PAML.Tree [Tree] ON [Tree].ID = [Output].TreeID
					JOIN @JobIDs j_id ON j_id.JobID = [Tree].JobID
					ORDER BY [Output].ID
					FOR XML AUTO, ROOT ('RecordSet-PAML-Process'))
		UNION ALL
		SELECT (SELECT [Exception].ExceptionID
						,[Exception].ProcessOutputID
					FROM PAML.ProcessException [Exception]
					JOIN PAML.ProcessOutput o ON o.ID = [Exception].ProcessOutputID
					JOIN PAML.Tree t ON t.ID = o.TreeID
					JOIN @JobIDs j_id ON j_id.JobID = t.JobID
					FOR XML AUTO, ROOT ('RecordSet-PAML-Exception'))
	END

	IF (@CompileDocument = 1) BEGIN
		DECLARE @final xml = '<Pilgrimage />'
				,@fragment xml
		DECLARE @count int = (SELECT COUNT(*) FROM @Output)
		DECLARE @current int = 1

		WHILE @current <= @count BEGIN
			SELECT @fragment = Data
				FROM @Output
				WHERE ID = @current

			SET @final.modify('insert sql:variable("@fragment") into (/Pilgrimage)[1] ')           
	
			SET @current += 1;
		END 
	
		SELECT @final;
	END
	ELSE BEGIN
		SELECT *
			FROM @Output
			ORDER BY ID
	END
END
GO
ALTER PROCEDURE [RecordSet].[Import_RecordSet]
	@JobID uniqueidentifier
	,@x xml
	,@RecordSetName varchar(200)
	,@RecordSetID uniqueidentifier OUTPUT
	,@SubSetsXML xml OUTPUT
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @ProgressMessage varchar(1000)

	SET @RecordSetID = NEWID()
	INSERT INTO RecordSet.RecordSet (ID, Name, CreatedAt, LastOpenedAt, ModifiedAt, Active)
	SELECT @RecordSetID
			,@RecordSetName
			,SYSDATETIME()
			,rs.value('(LastOpenedAt)[1]', 'datetime2(7)')
			,rs.value('(ModifiedAt)[1]', 'datetime2(7)')
			,1
		FROM @x.nodes('(/Pilgrimage/RecordSet)') AS RecordSet(rs)

	IF ((SELECT @x.exist('(/Pilgrimage/RecordSet/Properties/Key)')) = 1) BEGIN
		INSERT INTO RecordSet.ApplicationProperty (RecordSetID, [Key], Value)
		SELECT @RecordSetID
				,kv.value('(Key)[1]', 'varchar(30)')
				,kv.value('(Value)[1]', 'varchar(MAX)')
			FROM @x.nodes('(/Pilgrimage/RecordSet/Properties)') AS Properties(KV)
	END

	SET @ProgressMessage = 'Created recordset ' + @RecordSetName
	EXEC Job.Import_DataFile_Progress_Add @JobID, @ProgressMessage

	DECLARE @SubSetIDs Common.HashtableUniqueIdentifier
	INSERT INTO @SubSetIDs
	SELECT sub.value('(@ID)[1]', 'uniqueidentifier'), NEWID()
		FROM @x.nodes('(/Pilgrimage/RecordSet-SubSet/SubSet)') AS SubSets(Sub)
	SET @SubSetsXML = Common.ConvertHashtableUniqueIdentifierToXML(@SubSetIDs)

	INSERT INTO RecordSet.SubSet (ID, RecordSetID, Name, [Open], DisplayIndex, DataTypeID)
	SELECT id.Value
			,@RecordSetID
			,sub.value('(@Name)[1]', 'varchar(100)')
			,sub.value('(@Open)[1]', 'bit')
			,sub.value('(@DisplayIndex)[1]', 'int')
			,sub.value('(@DataTypeID)[1]', 'int')
		FROM @x.nodes('(/Pilgrimage/RecordSet-SubSet/SubSet)') AS SubSets(Sub)
		JOIN @SubSetIDs id ON id.[Key] = sub.value('(@ID)[1]', 'uniqueidentifier')

	SET @ProgressMessage = 'Created ' + CAST((SELECT COUNT(*) FROM @SubSetIDs) AS varchar(10)) + ' subsets'
	EXEC Job.Import_DataFile_Progress_Add @JobID, @ProgressMessage
END
GO

GO
UPDATE Common.ApplicationProperty
	SET Value = '1.4.6.15'
	WHERE [Key] = 'DatabaseVersion'
GO