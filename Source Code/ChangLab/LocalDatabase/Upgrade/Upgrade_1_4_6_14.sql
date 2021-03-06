SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM PAML.ModelPreset mp WHERE mp.[Key] = 'CmD') BEGIN
	INSERT INTO PAML.ModelPreset (Name, ShortName, [Key], [Rank])
	VALUES
		('Clade Model D (Alt)', 'Clade Model D (Alt)', 'CmD', 10),
		('Clade Model D (Null)', 'Clade Model D (Null)', 'CmDNull', 11)
END

GO
UPDATE Common.ApplicationProperty
	SET Value = '1.4.6.14'
	WHERE [Key] = 'DatabaseVersion'
GO