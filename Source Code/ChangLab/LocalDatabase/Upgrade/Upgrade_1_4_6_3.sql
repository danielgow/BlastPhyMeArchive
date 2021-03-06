SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
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
					JOIN RecordSet.ApplicationProperty [Properties] ON [Properties].RecordSetID = [RecordSet].ID
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
IF NOT EXISTS (SELECT * FROM sys.columns c WHERE c.name = 'MessageAt' AND c.object_id = OBJECT_ID('Job.Import_DataFile_Progress')) BEGIN
	ALTER TABLE Job.Import_DataFile_Progress ADD MessageAt datetime2(7) NOT NULL CONSTRAINT DF_Job_Import_DataFile_Progress_MessageAt DEFAULT (sysdatetime())
END
GO
ALTER PROCEDURE [Job].[Import_DataFile_Progress_List]
	@JobID uniqueidentifier
	,@LastStep int = 0
AS
BEGIN
	SET NOCOUNT ON

	SELECT p.LastStep
			,p.[Message]
			,p.MessageAt
		FROM Job.Import_DataFile_Progress p
		WHERE p.JobID = @JobID
			AND ((@LastStep = 0) OR (p.LastStep > @LastStep))
		ORDER BY p.LastStep
END
GO
IF EXISTS (SELECT * FROM sys.objects o WHERE o.object_id = OBJECT_ID('Common.StackedSplitString')) BEGIN
	DROP FUNCTION Common.StackedSplitString
END
GO
CREATE FUNCTION Common.StackedSplitString (@List nvarchar(MAX), @Delimiter nvarchar(5))
RETURNS @StackedValues TABLE (Value nvarchar(MAX), Fragment nvarchar(1000), [Index] int)
AS
BEGIN
	DECLARE @Split TABLE (Value nvarchar(MAX), [Index] int, ParentValue nvarchar(MAX), ParentIndex int)
	INSERT INTO @Split
	SELECT t1.Value
			,t1.[Index]
			,t2.Value AS ParentValue
			,t2.[Index] AS ParentIndex
		FROM Common.SplitString(@List, @Delimiter) t1
		LEFT OUTER JOIN Common.SplitString(@List, @Delimiter) t2 ON t2.[Index] <= t1.[Index]

	DECLARE @MaxIndex int = (SELECT MAX([Index]) FROM @Split)
			,@Iterator int = 0
			,@Value nvarchar(MAX)
			,@Fragment nvarchar(1000)

	WHILE (@Iterator < @MaxIndex) BEGIN
		SET @Iterator += 1
		SET @Value = ''

		SELECT TOP 1 @Fragment = s.Value
			FROM @Split s
			WHERE s.[Index] = @Iterator

		SELECT @Value += s.ParentValue + ';'
			FROM @Split s
			WHERE s.[Index] = @Iterator

		SET @Value = SUBSTRING(@Value, 1, LEN(@Value) - 1)

		INSERT INTO @StackedValues
		VALUES (@Value, @Fragment, @Iterator)
	END

	RETURN
END
GO
IF NOT EXISTS (SELECT * FROM sys.columns c WHERE c.name = 'Taxonomy' AND c.object_id = OBJECT_ID('Taxonomy.Taxon')) BEGIN
	ALTER TABLE Taxonomy.Taxon ADD Taxonomy varchar(MAX)	
END
GO
IF EXISTS (SELECT * FROM Taxonomy.Taxon WHERE Taxonomy IS NULL) BEGIN
	SET NOCOUNT ON

	DECLARE @TaxonTableIDs TABLE ([Index] int IDENTITY(1,1), ID int)
	INSERT INTO @TaxonTableIDs (ID) SELECT ID FROM Taxonomy.Taxon WHERE Taxonomy IS NULL

	DECLARE @MaxIndex int = (SELECT MAX([Index]) FROM @TaxonTableIDs)
			,@Iterator int = 0
			,@ConcatenatedTaxa varchar(MAX)
	DECLARE @TaxaIDs Common.ListInt
	DECLARE @TaxaTree TABLE (ID int, Name varchar(200), Hierarchy varchar(4000), ParentID int)
		
	WHILE (@Iterator < @MaxIndex) BEGIN
		SET @Iterator += 1

		DELETE FROM @TaxaIDs
		INSERT INTO @TaxaIDs SELECT ID FROM @TaxonTableIDs WHERE [Index] = @Iterator

		DELETE FROM @TaxaTree
		INSERT INTO @TaxaTree
		EXEC Taxonomy.Taxon_ListTreeView_ForTaxa @TaxaIDs

		IF EXISTS (SELECT * FROM @TaxaTree) BEGIN
			SET @ConcatenatedTaxa = ''
			SELECT @ConcatenatedTaxa += Name +';'
				FROM @TaxaTree
			SET @ConcatenatedTaxa = SUBSTRING(@ConcatenatedTaxa, 1, LEN(@ConcatenatedTaxa) - 1)
		END
		ELSE BEGIN
			SELECT @ConcatenatedTaxa = Name
				FROM Taxonomy.Taxon t
				JOIN @TaxaIDs id ON id.Value = t.ID
		END
		
		UPDATE t
			SET Taxonomy = @ConcatenatedTaxa
			FROM Taxonomy.Taxon t
			JOIN @TaxaIDs id ON id.Value = t.ID
	END
END
GO
ALTER PROCEDURE [Taxonomy].[Taxon_Parse]
	@Taxonomy varchar(MAX),
	@TaxonomyID int OUTPUT
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @Concatenated varchar(MAX)
			,@Taxa varchar(200)
			,@Index int
			,@ParentValue varchar(30)
			,@ParentIndex int
			,@ParentHierarchyID hierarchyid
			,@NewID int
			,@NewHID hierarchyid
			,@TaxonHierarchyID hierarchyid
			,@ErrorMessage nvarchar(MAX) 
	SET @Taxonomy = REPLACE(@Taxonomy, ' ', '')

	DECLARE @TaxaValues TABLE (Concatenated varchar(MAX), Fragment varchar(200), [Index] int, TaxonHierarchyID hierarchyid)
	INSERT INTO @TaxaValues
	SELECT s.Value
			,s.Fragment
			,s.[Index]
			,t.HID
		FROM Common.StackedSplitString(@Taxonomy, ';') s
		LEFT OUTER JOIN Taxonomy.Taxon t ON t.Taxonomy = s.Value

	DECLARE cTax CURSOR FOR SELECT Concatenated, Fragment, [Index], TaxonHierarchyID FROM @TaxaValues
	OPEN cTax
	FETCH NEXT FROM cTax INTO @Concatenated, @Taxa, @Index, @TaxonHierarchyID
	WHILE @@FETCH_STATUS = 0 BEGIN
		BEGIN TRY
			IF (@TaxonHierarchyID IS NULL) BEGIN
				SELECT @ParentHierarchyID = v.TaxonHierarchyID
					FROM @TaxaValues v
					WHERE v.[Index] = (@Index - 1)

				IF (@ParentHierarchyID IS NULL) BEGIN
					-- New root node
					SET @ParentHierarchyID = '/'
				END
				
				-- Add the new node as the max descendant of the parent
				SELECT @NewHID = @ParentHierarchyID.GetDescendant(MAX(t.HID), NULL)
					FROM Taxonomy.Taxon t
					WHERE t.HID.IsDescendantOf(@ParentHierarchyID) = 1
						AND t.HID.GetLevel() = (@ParentHierarchyID.GetLevel() + 1)

				INSERT INTO Taxonomy.Taxon (HID, Name, Taxonomy)
				VALUES (@NewHID, @Taxa, @Concatenated)

				SET @NewID = @@IDENTITY
				SELECT @NewHID = HID FROM Taxonomy.Taxon WHERE ID = @NewID
					
				UPDATE v
					SET TaxonHierarchyID = @NewHID
					FROM @TaxaValues v
					WHERE v.[Index] = @Index
			END
		END TRY
		BEGIN CATCH
			SELECT @ErrorMessage = ERROR_MESSAGE()

			INSERT INTO Taxonomy.ParseError ([Message], Taxonomy, ParentID, ParentValue, ParentIndex, NewValue, NewIndex)
			VALUES (@ErrorMessage, @Taxonomy, @ParentHierarchyID, @ParentValue, @ParentIndex, @Taxa, @Index)
		END CATCH

		FETCH NEXT FROM cTax INTO @Concatenated, @Taxa, @Index, @TaxonHierarchyID
	END
	CLOSE cTax
	DEALLOCATE cTax

	SELECT @TaxonomyID = t.ID
		FROM Taxonomy.Taxon t
		WHERE t.Taxonomy = @Taxonomy
END
GO
ALTER PROCEDURE [RecordSet].[Import_Genes]
	@JobID uniqueidentifier
	,@x xml
	,@RecordSetID uniqueidentifier
	,@SubSetIDs Common.HashtableUniqueIdentifier READONLY
	,@GenesXML xml OUTPUT
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @GeneIDs Common.HashtableUniqueIdentifier
	DECLARE @GeneFeatureIDs Common.HashtableInt
	DECLARE @ProgressMessage varchar(1000)

	DECLARE @GeneTaxonomies TABLE (GeneID uniqueidentifier, Taxonomy varchar(4000), TaxonomyID int)
	INSERT INTO @GeneTaxonomies (GeneID, Taxonomy)
	SELECT g.value('(ID)[1]', 'uniqueidentifier')
			,g.value('(Taxonomy)[1]', 'varchar(4000)') AS Taxonomy
		FROM @x.nodes('(/Pilgrimage/RecordSet-Gene/Gene)') AS Genes(g)

	DECLARE @Taxonomies TABLE ([Index] int IDENTITY(1,1), Taxonomy varchar(4000), TaxonomyID int)
	INSERT INTO @Taxonomies (Taxonomy)
	SELECT DISTINCT Taxonomy FROM @GeneTaxonomies

	DECLARE @TaxonomyIterator int = 0
			,@TaxonomyCount int = (SELECT COUNT(*) FROM @Taxonomies)
			,@Taxonomy varchar(4000)
			,@TaxonomyID int

	WHILE (@TaxonomyIterator < @TaxonomyCount) BEGIN
		SET @TaxonomyIterator = (@TaxonomyIterator + 1)

		SELECT @Taxonomy = t.Taxonomy
			FROM @Taxonomies t
			WHERE [Index] = @TaxonomyIterator

		IF (@Taxonomy IS NOT NULL AND LTRIM(RTRIM(@Taxonomy)) <> SPACE(0)) BEGIN
			EXEC Taxonomy.Taxon_Parse @Taxonomy, @TaxonomyID OUTPUT

			UPDATE @Taxonomies
				SET TaxonomyID = @TaxonomyID
				WHERE [Index] = @TaxonomyIterator
		END
	END

	UPDATE gt
		SET TaxonomyID = t.TaxonomyID
		FROM @GeneTaxonomies gt
		JOIN @Taxonomies t ON t.Taxonomy = gt.Taxonomy

	DECLARE @NCBI_SourceIDs TABLE (SourceID int)
	INSERT INTO @NCBI_SourceIDs SELECT ID FROM Gene.[Source] WHERE [Key] IN ('GenBank', 'BLASTN_NCBI')
	
	MERGE Gene.Gene t
	USING (SELECT g.value('(ID)[1]', 'uniqueidentifier') AS OriginalGeneID 
				,NEWID() AS NewGeneID
				,g.value('(Name)[1]', 'varchar(100)') AS Name
				,g.value('(Definition)[1]', 'varchar(1000)') AS [Definition]
				,g.value('(SourceID)[1]', 'int') AS SourceID
				,g.value('(GenBankID)[1]', 'int') AS GenBankID
				,g.value('(Locus)[1]', 'varchar(100)') AS Locus
				,g.value('(Accession)[1]', 'varchar(20)') AS Accession
				,g.value('(Organism)[1]', 'varchar(250)') AS Organism
				,g.value('(Taxonomy)[1]', 'varchar(4000)') AS Taxonomy
				,tax.TaxonomyID
				,g.value('(Nucleotides)[1]', 'varchar(MAX)') AS Nucleotides
				,g.value('(SequenceTypeID)[1]', 'int') AS SequenceTypeID
				,g.value('(Description)[1]', 'varchar(MAX)') AS [Description]
				,g.value('(LastUpdatedAt)[1]', 'datetime2(7)') AS LastUpdatedAt
				,g.value('(LastUpdateSourceID)[1]', 'int') AS LastUpdateSourceID
			FROM @x.nodes('(/Pilgrimage/RecordSet-Gene/Gene)') AS Genes(g)
			JOIN @GeneTaxonomies tax ON tax.GeneID = g.value('(ID)[1]', 'uniqueidentifier')
			) s
	ON (t.GenBankID = s.GenBankID
			AND (
					t.SourceID IN (2, 3) --SELECT src_ncbi.SourceID FROM @NCBI_SourceIDs src_ncbi)
					AND s.SourceID IN (2, 3)
			)
	)
	WHEN MATCHED AND s.LastUpdatedAt > t.LastUpdatedAt THEN
		UPDATE
			SET Name = s.Name
				,[Definition] = s.[Definition]
				,Locus = s.Locus
				,Accession = s.Accession
				,Organism = s.Organism
				,Taxonomy = s.Taxonomy
				,TaxonomyID = s.TaxonomyID
				,Nucleotides = s.Nucleotides
				,[Description] = s.[Description]
				,LastUpdatedAt = s.LastUpdatedAt
				,LastUpdateSourceID = s.LastUpdateSourceID
	WHEN NOT MATCHED THEN
		INSERT (ID, Name, [Definition], SourceID, GenBankID, Locus, Accession, Organism, Taxonomy, TaxonomyID, Nucleotides, SequenceTypeID, [Description], LastUpdatedAt, LastUpdateSourceID)
		VALUES (s.NewGeneID, s.Name, s.[Definition], s.SourceID, s.GenBankID, s.Locus, s.Accession, s.Organism, s.Taxonomy, s.TaxonomyID, s.Nucleotides, s.SequenceTypeID, s.[Description], s.LastUpdatedAt, s.LastUpdateSourceID)
	OUTPUT s.OriginalGeneID, inserted.ID INTO @GeneIDs;
		
	MERGE Gene.NucleotideSequence t
	USING (SELECT id.Value AS GeneID
				,s.value('(Nucleotides)[1]', 'varchar(MAX)') AS Nucleotides
				,s.value('(Start)[1]', 'int') AS Start
				,s.value('(End)[1]', 'int') AS [End]
			FROM @x.nodes('(/Pilgrimage/RecordSet-Gene-Sequence/Sequence)') AS Seq(s)
			JOIN @GeneIDs id ON id.[Key] = s.value('(GeneID)[1]', 'uniqueidentifier')) s
	ON (t.GeneID = s.GeneID)
	WHEN MATCHED THEN
		UPDATE SET Nucleotides = s.Nucleotides, Start = s.Start, [End] = s.[End]
	WHEN NOT MATCHED THEN
		INSERT (GeneID, Nucleotides, Start, [End])
		VALUES (s.GeneID, s.Nucleotides, s.Start, s.[End]);
		
	SET @ProgressMessage = 'Imported ' + CAST((SELECT COUNT(*) FROM @GeneTaxonomies) AS varchar(10)) + ' gene sequence records'
	EXEC Job.Import_DataFile_Progress_Add @JobID, @ProgressMessage

	-- This DELETE only happens for NCBI-sourced records that were updated in the above MERGE on Gene.Gene.
	-- Deleting the existing features makes things easier on us for merging into Gene.Feature, instead of setting up an UPDATE.
	DELETE fi
		FROM Gene.FeatureInterval fi
		JOIN Gene.Feature f ON f.ID = fi.FeatureID
		JOIN @GeneIDs id ON id.[Key] = f.GeneID
		WHERE id.[Key] = id.Value
	DELETE f
		FROM Gene.Feature f
		JOIN @GeneIDs id ON id.[Key] = f.GeneID
		WHERE id.[Key] = id.Value
	
	MERGE INTO Gene.Feature
	USING (SELECT gene_id.Value AS ReplacementGeneID
					,f.value('(@ID)[1]', 'int') AS OriginalFeatureID
					,f.value('(@Rank)[1]', 'int') AS [Rank]
					,f.value('(@FeatureKeyID)[1]', 'int') AS FeatureKeyID
					,f.value('(@GeneQualifier)[1]', 'varchar(250)') AS GeneQualifier
					,f.value('(@GeneIDQualifier)[1]', 'int') AS GeneIDQualifier
				FROM @x.nodes('(Pilgrimage/RecordSet-Gene-Feature/Gene)') AS Gene(g)
				CROSS APPLY g.nodes('(Feature)') AS Feature(f)
				JOIN @GeneIDs gene_id ON gene_id.[Key] = g.value('(@GeneID)[1]', 'uniqueidentifier')) AS f
	-- This looks weird, but in order to get the OriginalID and the new identity value for the ID column we need the OUTPUT clause, and OUTPUT on INSERT
	-- won't let you get at values in any table other than the INSERTED pseudotable, whereas MERGE is quite happy to involve other tables.
		ON 1 = 0 
	WHEN NOT MATCHED THEN
		INSERT (GeneID, [Rank], FeatureKeyID, GeneQualifier, GeneIDQualifier)
		VALUES (f.ReplacementGeneID, f.[Rank], f.FeatureKeyID, f.GeneQualifier, f.GeneIDQualifier)
	OUTPUT f.OriginalFeatureID, inserted.ID /* Replacement Feature ID */ INTO @GeneFeatureIDs;

	INSERT INTO Gene.FeatureInterval (ID, FeatureID, Start, [End], IsComplement, StartModifier, EndModifier, Accession)
	SELECT fi.value('(@ID)[1]', 'int')
			,feature_id.Value
			,fi.value('(@Start)[1]', 'int')
			,fi.value('(@End)[1]', 'int')
			,fi.value('(@IsComplement)[1]', 'bit')
			,fi.value('(@StartModifier)[1]', 'char(1)')
			,fi.value('(@EndModifier)[1]', 'char(1)')
			,fi.value('(@Accession)[1]', 'varchar(20)')
		FROM @x.nodes('(Pilgrimage/RecordSet-Gene-Feature/Gene/Feature)') AS Feature(f)
		CROSS APPLY f.nodes('(Feature-Interval)') AS FeatureInterval(fi)
		JOIN @GeneFeatureIDs feature_id ON feature_id.[Key] = f.value('(@ID)[1]', 'int')
	
	SET @ProgressMessage = 'Imported ' + CAST((SELECT COUNT(*) FROM @GeneFeatureIDs) AS varchar(10)) + ' annotations for gene sequence records'
	EXEC Job.Import_DataFile_Progress_Add @JobID, @ProgressMessage

	-- Pick up any NCBI-sourced genes that were not updated in the MERGE on Gene.Gene so that we can pop them into the RecordSet and SubSet.
	INSERT INTO @GeneIDs
	SELECT s.value('(ID)[1]', 'uniqueidentifier'), t.ID
		FROM @x.nodes('(/Pilgrimage/RecordSet-Gene/Gene)') AS Genes(s)
		JOIN Gene.Gene t ON t.GenBankID = s.value('(GenBankID)[1]', 'int') 
		WHERE t.SourceID IN (2, 3) 
			AND s.value('(SourceID)[1]', 'int') IN (2, 3) 
			AND s.value('(LastUpdatedAt)[1]', 'datetime2(7)') <= t.LastUpdatedAt
			AND NOT EXISTS (SELECT * FROM @GeneIDs ex WHERE ex.[Key] = s.value('(ID)[1]', 'uniqueidentifier'))

	-- Assign the gene records to the recordset and subsets
	INSERT INTO RecordSet.SubSetGene
	SELECT subset_id.Value
			,gene_id.Value
			,MAX(g.value('(@ModifiedAt)[1]', 'datetime2(7)'))
		FROM @x.nodes('(/Pilgrimage/RecordSet-SubSet-Gene/SubSet)') AS SubSet(s)
		CROSS APPLY s.nodes('(Gene)') AS Gene(g)
		JOIN @SubSetIDs subset_id ON subset_id.[Key] = s.value('(@ID)[1]', 'uniqueidentifier')
		JOIN @GeneIDs gene_id ON gene_id.[Key] = g.value('(@GeneID)[1]', 'uniqueidentifier')
		WHERE NOT EXISTS (SELECT * FROM RecordSet.SubSetGene ex WHERE ex.SubSetID = subset_id.Value AND ex.GeneID = gene_id.Value)
		GROUP BY subset_id.Value, gene_id.Value

	INSERT INTO RecordSet.Gene
	SELECT @RecordSetID
			,gene_id.Value
			,MAX(g.value('(@ModifiedAt)[1]', 'datetime2(7)'))
		FROM @x.nodes('(/Pilgrimage/RecordSet-SubSet-Gene/SubSet)') AS SubSet(s)
		CROSS APPLY s.nodes('(Gene)') AS Gene(g)
		JOIN @SubSetIDs subset_id ON subset_id.[Key] = s.value('(@ID)[1]', 'uniqueidentifier')
		JOIN @GeneIDs gene_id ON gene_id.[Key] = g.value('(@GeneID)[1]', 'uniqueidentifier')
		WHERE NOT EXISTS (SELECT * FROM RecordSet.Gene ex WHERE ex.RecordSetID = @RecordSetID AND ex.GeneID = gene_id.Value)
		GROUP BY gene_id.Value

	DELETE FROM @GeneIDs WHERE [Key] = Value
	SET @GenesXML = Common.ConvertHashtableUniqueIdentifierToXML(@GeneIDs)
END
GO
ALTER PROCEDURE [RecordSet].[Import_DataFile]
	@x xml
	,@RecordSetName varchar(200) = NULL
	,@TargetSubSetID uniqueidentifier = NULL

	,@JobRecordSetID uniqueidentifier
	,@NewRecordSetID uniqueidentifier OUTPUT
	,@JobID uniqueidentifier OUTPUT
	,@ValidateOnly bit = 0
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @JobTargetID int = (SELECT ID FROM Job.[Target] WHERE [Key] = 'Import_DataFile')
			,@JobTitle varchar(250)
			,@JobStatusID int = (SELECT ID FROM Job.[Status] WHERE [Key] = 'Running')
			,@JobStartedAt datetime2(7) = SYSDATETIME()
			,@JobEndedAt datetime2(7)
			,@JobOutputText varchar(MAX);

	IF (@RecordSetName IS NOT NULL) BEGIN
		SET @JobTitle = 'Importing ' + @x.value('(/Pilgrimage/RecordSet/Name)[1]', 'varchar(200)') + ' into ' + @RecordSetName;
	END
	ELSE IF (@TargetSubSetID IS NOT NULL) BEGIN
		SELECT @JobTitle = 'Importing into ' + sub.Name + ' in ' + rs.Name
				,@NewRecordSetID = sub.RecordSetID
			FROM RecordSet.SubSet sub
			JOIN RecordSet.RecordSet rs ON rs.ID = sub.RecordSetID
			WHERE sub.ID = @TargetSubSetID;
	END
	ELSE BEGIN
		RAISERROR ('A new recordset or an existing subset must be specified for importing from a data file.', 18, 1);
	END

	EXEC Job.Job_Edit
		@ID = @JobID OUTPUT, 
		@RecordSetID = @JobRecordSetID,
		@TargetID = @JobTargetID,
		@Title = @JobTitle,
		@StatusID = @JobStatusID,
		@StartedAt = @JobStartedAt;

	SET @JobOutputText = 'Job started at ' + CAST(@JobStartedAt as varchar(50))
	EXEC Job.OutputText_Edit @JobID, @JobOutputText

	BEGIN TRANSACTION
	BEGIN TRY
		DECLARE @SubSetIDs Common.HashtableUniqueIdentifier -- [Key] = Original ID, [Value] = Replacement ID
				,@SubSetsXML xml
				,@GeneIDs Common.HashtableUniqueIdentifier -- [Key] = Original ID, [Value] = Replacement ID
				,@GenesXML xml
				,@JobIDs Common.HashtableUniqueIdentifier -- [Key] = Original ID, [Value] = Replacement ID
				,@JobsXML xml
				,@JobExceptionsIDs Common.HashtableInt -- [Key] = Original ID, [Value] = Replacement ID
				,@JobExceptionsXML xml
	
		IF (@TargetSubSetID IS NULL) BEGIN
			-- Import top-level recordset details and create the subsets
			EXEC RecordSet.Import_RecordSet @JobID, @x, @RecordSetName, @NewRecordSetID OUTPUT, @SubSetsXML OUTPUT
			INSERT INTO @SubSetIDs SELECT * FROM Common.ConvertXMLToHashtableUniqueIdentifier(@SubSetsXML)
		END
		ELSE BEGIN
			INSERT INTO @SubSetIDs
			SELECT TOP 1 s.value('(@ID)[1]', 'uniqueidentifier'), @TargetSubSetID
				FROM @x.nodes('(/Pilgrimage/RecordSet-SubSet-Gene/SubSet)') AS SubSet(s)
			UNION
			SELECT TOP 1 s.value('(@ID)[1]', 'uniqueidentifier'), @TargetSubSetID
				FROM @x.nodes('(Pilgrimage/RecordSet-PAML-Result/Result/SubSetIDs/row)') AS SubSet(s)

			-- This is an import of a data file created from exporting specific records, not a recordset, so we should never have both PAML and Gene records
			-- in the same data file.  Just in case, though...
			
			IF (SELECT COUNT(*) FROM @SubSetIDs) > 1 BEGIN
				RAISERROR ('Data file contains records from multiple subsets and cannot be imported into a single subset.', 18, 1);
			END
		END
	
		-- Import Gene.Gene records, nucleotide sequences, and recordset/subset assignments
		EXEC RecordSet.Import_Genes @JobID, @x, @NewRecordSetID, @SubSetIDs, @GenesXML OUTPUT
		INSERT INTO @GeneIDs SELECT * FROM Common.ConvertXMLToHashtableUniqueIdentifier(@GenesXML)

		-- Import into Job, Job.OutputText, and Job.Genes
		-- PRANK, MUSCLE, and PHYML jobs do not touch any other tables, and thus have no specific stored procedure for importing additional data.
		EXEC RecordSet.Import_Jobs @JobID, @NewRecordSetID, @x, @GeneIDs, @JobsXML OUTPUT
		INSERT INTO @JobIDs SELECT * FROM Common.ConvertXMLToHashtableUniqueIdentifier(@JobsXML)
	
		-- Import BLASTN job history
		EXEC RecordSet.Import_BLASTNHistory @JobID, @NewRecordSetID, @x, @GeneIDs, @JobIDs, @JobExceptionsXML OUTPUT
		INSERT INTO @JobExceptionsIDs SELECT * FROM Common.ConvertXMLToHashtableInt(@JobExceptionsXML)
	
		-- Import PAML job history
		EXEC RecordSet.Import_PAML @JobID, @NewRecordSetID, @x, @SubSetIDs, @JobIDs, @JobExceptionsIDs

		IF (@ValidateOnly = 0) BEGIN
			COMMIT TRANSACTION
		END
		ELSE BEGIN
			ROLLBACK TRANSACTION
		END
		
		SET @JobStatusID = (SELECT ID FROM Job.[Status] WHERE [Key] = 'Completed')
		SET @JobEndedAt = SYSDATETIME()
		EXEC Job.Job_Edit @ID = @JobID, @StatusID = @JobStatusID, @EndedAt = @JobEndedAt
	END TRY
	BEGIN CATCH
		ROLLBACK TRANSACTION

		SET @JobOutputText = 'Import failed: ' + ERROR_MESSAGE()
		EXEC Job.Import_DataFile_Progress_Add @JobID, @JobOutputText

		SET @JobStatusID = (SELECT ID FROM Job.[Status] WHERE [Key] = 'Failed')
		SET @JobEndedAt = SYSDATETIME()
		EXEC Job.Job_Edit @ID = @JobID, @StatusID = @JobStatusID, @EndedAt = @JobEndedAt
		
		EXEC Common.ThrowException 0, @JobID
	END CATCH

	---- Check job status for cancellation.
	--IF (SELECT s.[Key] FROM Job.Job j JOIN Job.[Status] s ON s.ID = j.StatusID WHERE j.ID = @JobID) = 'Cancelled' BEGIN
	--	GOTO cancelled;
	--END

	--cancelled:
	--IF (SELECT s.[Key] FROM Job.Job j JOIN Job.[Status] s ON s.ID = j.StatusID WHERE j.ID = @JobID) = 'Cancelled' BEGIN
	--	SET @JobOutputText = 'Job cancelled at ' + CAST(SYSDATETIME() as varchar(50))
	--	EXEC Job.Import_DataFile_Progress_Add @JobID, @JobOutputText
	--END
END
GO
IF EXISTS (SELECT * FROM sys.procedures p WHERE p.object_id = OBJECT_ID('Taxonomy.RefreshTaxonHierarchy')) BEGIN
	DROP PROCEDURE Taxonomy.RefreshTaxonHierarchy
END
GO
CREATE PROCEDURE Taxonomy.RefreshTaxonHierarchy AS
BEGIN
	SET NOCOUNT ON

	ALTER TABLE Gene.Gene DISABLE TRIGGER Gene_LogHistory

	UPDATE Gene.Gene SET TaxonomyID = NULL
	UPDATE Gene.GeneHistory SET TaxonomyID = NULL
	DELETE FROM Taxonomy.ParseError
	DELETE FROM Taxonomy.Taxon

	DECLARE @Taxonomy varchar(4000)
			,@TaxonomyID int
			,@Iterator int = 0
			,@TaxaCount int

	DECLARE @Taxa TABLE (ID int IDENTITY(1,1), Taxa varchar(4000), TaxonomyID int)

	INSERT INTO @Taxa (Taxa)
	SELECT DISTINCT g.Taxonomy FROM Gene.Gene g WHERE g.Taxonomy IS NOT NULL
	UNION
	SELECT DISTINCT g.Taxonomy FROM Gene.GeneHistory g WHERE g.Taxonomy IS NOT NULL

	SELECT @TaxaCount = COUNT(*) FROM @Taxa
	
	WHILE (@Iterator < @TaxaCount) BEGIN
		SET @Iterator += 1

		SELECT @Taxonomy = Taxa
			FROM @Taxa
			WHERE ID = @Iterator
	
		EXEC Taxonomy.Taxon_Parse @Taxonomy, @TaxonomyID OUTPUT

		UPDATE @Taxa
			SET TaxonomyID = @TaxonomyID
			WHERE ID = @Iterator
	END

	UPDATE g
		SET g.TaxonomyID = t.ID
		FROM Gene.Gene g
		JOIN Taxonomy.Taxon t ON t.Taxonomy = REPLACE(g.Taxonomy, ' ', '')

	UPDATE g
		SET g.TaxonomyID = t.ID
		FROM Gene.GeneHistory g
		JOIN Taxonomy.Taxon t ON t.Taxonomy = REPLACE(g.Taxonomy, ' ', '')

	ALTER TABLE Gene.Gene ENABLE TRIGGER Gene_LogHistory
END
GO

GO
UPDATE ap
	SET Value = LTRIM(RTRIM(REPLACE(ap.Value, '{Coding Sequence Length}', '')))
	FROM Common.ApplicationProperty ap
	WHERE [Key] = 'FASTAHeaderFormatString'
		AND Value LIKE '%{Coding Sequence Length}%'
GO
UPDATE Common.ApplicationProperty
	SET Value = '1.4.6.3'
	WHERE [Key] = 'DatabaseVersion'
GO