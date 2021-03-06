SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

UPDATE Common.ThirdPartyComponentReference
	SET Version = '4.8, 4.9a'
			,LastUpdatedAt = '2015-09-11 00:00:00.0000000'
			,LastRetrievedAt = '2016-05-15 09:47:00.0000000'
	WHERE Name = 'PAML'
GO

UPDATE Common.ApplicationProperty
	SET Value = '1.5.0.2'
	WHERE [Key] = 'DatabaseVersion'
GO