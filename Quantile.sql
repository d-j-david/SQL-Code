USE [Database]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================================================================================
-- Author: David David
-- Description: Quantiles the specified table with respect to the specified field, and inserts a new quantile 
--              field into that table. 
--
-- Variables: @Table        = Table containing the field to be evaluated for quantiles
--            @Field        = Field to quantile (usually a TRx field)
--            @Level        = ID field for each observation to quantile (PrimaryKey, Zip Code, etc) 
--            @Base         = Base for the quantiling (10 for decile, 3 for tercile, etc)
--            @Type         = 1, Quantile observations (make buckets with equal number of observations)
--                          = 2, Quantile values (make buckets with approx. equal total volume)
--            @IncludeZeros = 1, Observations with value of zero included in quantiling
--                          = 0, Observations with value of zero put into separate '0' quantile
--            @Reproducible = 1, Each run will contain the same observations in each quantile
--                            0, Each run may contain different observations in each quantile, due to multiple
--                               observations sharing the same value
-- =============================================================================================================
ALTER PROCEDURE [dbo].[Quantile]
	@Table VARCHAR(255),
	@Field VARCHAR(255),
	@Level VARCHAR(255) = 'UniverseID',
	@Base  INT          = 10,
	@Type  INT          = 1,
	@IncludeZeros BIT   = 0,
	@Reproducible BIT   = 1
AS
BEGIN
	SET NOCOUNT ON;

	---------------------------------------------------------------------------------------------------
	-- Make Table for Quantiling
	---------------------------------------------------------------------------------------------------
	IF object_ID('tempdb..#SetupTbl') is not null DROP TABLE #SetupTbl
	CREATE TABLE #SetupTbl(LevelID VARCHAR(255), Field DECIMAL(38,10), Quantile INT)

	EXEC
	('
		INSERT INTO #SetupTbl(LevelID, Field)
		SELECT ' + @Level + ', sum(isnull(' + @Field + ',0))
		FROM ' + @Table + '
		WHERE ' + @Level + ' is not null
		GROUP BY ' + @Level
	)

	---------------------------------------------------------------------------------------------------
	-- Calculate the quantiles
	---------------------------------------------------------------------------------------------------
	IF object_ID('tempdb..#QuantileTbl') is not null DROP TABLE #QuantileTbl
	CREATE TABLE #QuantileTbl(LevelID VARCHAR(255), Field DECIMAL(38,10), Quantile INT)
	
	-- If Type 1, quantile the observations
	-- If Type 2, quantile the values
	IF @Type = 1
	BEGIN
		INSERT INTO #QuantileTbl
		SELECT 
			LevelID, 
			Field, 
			ntile(@Base) 
			OVER (
				ORDER BY Field, iif(@Reproducible = 1, LevelID, cast(newid() as VARCHAR(255)))
			) as Quantile
		FROM #SetupTbl
		WHERE Field >= (@IncludeZeros + 1) % 2
		GROUP BY LevelID, Field	
	END
	ELSE IF @Type = 2
	BEGIN
		DECLARE @Denominator DECIMAL(38,10) = (SELECT sum(isnull(Field,0)) FROM #SetupTbl) / @Base

		INSERT INTO #QuantileTbl
		SELECT 
			LevelID, 
			Field, 
			ceiling(
				sum(Field) 
				OVER (
					ORDER BY Field, iif(@Reproducible = 1, LevelID, cast(newid() as VARCHAR(255)))
				) / @Denominator
			) as Quantile
		FROM #SetupTbl
		WHERE Field >= (@IncludeZeros + 1) % 2
		GROUP BY LevelID, Field	

		UPDATE #QuantileTbl
		SET Quantile = 1
		WHERE Quantile = 0
	END
	ELSE
	BEGIN
		PRINT 'ERROR: Type not recognized.'
		RETURN
	END

	---------------------------------------------------------------------------------------------------
	-- Create Quantile Field in table
	---------------------------------------------------------------------------------------------------
	DECLARE @Query VARCHAR(max)

	-- Determine name of the field -------------------------------------
	SET @Field = @Field + '_Quantile' + cast(@Base as VARCHAR))

	-- Create field and update with quantile ---------------------------
	IF COL_LENGTH(@Table, @Field) IS NULL
		EXEC('ALTER TABLE ' + @Table + ' ADD ' + @Field + ' INT')
	ELSE
	BEGIN
		PRINT 'ERROR: ' + @Field + ' already exists in ' + @Table + '.'
		RETURN
	END

	EXEC
	('
		UPDATE ' + @Table + '
		SET ' + @Field + ' = b.Quantile
		FROM ' + @Table + ' a
		JOIN #QuantileTbl b ON a.' + @Level + ' = b.LevelID

		UPDATE ' + @Table + '
		SET ' + @Field + ' = 0
		WHERE ' + @Field + ' is null
		  AND ' + @Level + ' is not null
	')
END