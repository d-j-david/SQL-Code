USE [Database]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- ================================================================================================
-- Author: David David
-- Description: Cleans the specified table by removing text qualifiers, and changing blank strings
--              to nulls. There are other options to further clean & configure the table.
-- Variables: @Table            = Full name of the table to be cleaned
--            @CleanHeaders     = 1 to clean headers into a form that does not require brackets
--            @DetectDataTypes  = 1 to detect and adjust column data types
-- ================================================================================================
ALTER PROCEDURE [dbo].[ConfigureTbl]
	@Table            VARCHAR(255),
	@CleanHeaders     BIT = 1,
	@DetectDataTypes  BIT = 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @DB    VARCHAR(255) = parsename(@Table, 3)
	DECLARE @Tbl   VARCHAR(255) = parsename(@Table, 1)
	DECLARE @Query VARCHAR(max)

	---------------------------------------------------------------------------------------------------
	-- Check if table name is formatted properly
	---------------------------------------------------------------------------------------------------
	IF (SELECT object_id(@Table)) is null
	BEGIN
		PRINT 'ERROR: ' + @Table + ' does not exist.'
		RETURN
	END

	---------------------------------------------------------------------------------------------------
	-- Setup a cursor to select each column of the table
	---------------------------------------------------------------------------------------------------
	DECLARE @Column      VARCHAR(255)
	DECLARE @DataType    VARCHAR(255)
	DECLARE @IndexColumn INT

	SET @Query = 
	'
		SELECT 
			''['' + c.name + '']'' as ColumnName,
			ty.name as DataType,
			CASE WHEN i.column_id is not null THEN 1 ELSE 0 END as IndexColumn
		INTO ##ColumnsTbl
		FROM ' + @DB + '.sys.columns c
		JOIN ' + @DB + '.sys.types ty ON c.user_type_id = ty.user_type_id
		LEFT OUTER JOIN ' + @DB + '.sys.index_columns i ON c.[object_id] = i.[object_id]
													   AND c.column_id = i.column_id
		WHERE c.[object_id] = object_id(''' + @Table + ''')
	'
	EXEC(@Query)

	DECLARE ColumnCsr CURSOR FOR
	SELECT * FROM ##ColumnsTbl

	---------------------------------------------------------------------------------------------------
	-- Clean/Configure table
	---------------------------------------------------------------------------------------------------
	SET @Table = IIF(@Table like 'tempdb..%', right(@Table, len(@Table) - 8), @Table)
	
	OPEN ColumnCsr
	FETCH NEXT FROM ColumnCsr INTO @Column, @DataType, @IndexColumn
	WHILE @@FETCH_STATUS = 0 
	BEGIN
		
		-- Only edit the column if it's not part of an index
		IF @IndexColumn = 0
		BEGIN

			-- Clean the column name
			IF @CleanHeaders = 1
			BEGIN
				
				SET @Query = 'USE ' + @DB + ' EXEC sp_RENAME ''' + @Tbl + '.' + @Column + ''', '

				SET @Column = Analytics.dbo.StartCase(@Column, ' ', 0)
				SET @Column = Analytics.dbo.StartCase(@Column, '-', 0)
				SET @Column = replace(replace(replace(replace(replace(replace(@Column,
								  ' ', ''), '-', ''), '''', ''), '"', ''), '[', ''), ']', '')
				SET @Column = iif(isnumeric(left(@Column, 1)) = 1, 'Col_' + @Column, @Column)

				SET @Query = @Query + '''' +  @Column + ''''
				EXEC(@Query)

				SET @Column = '[' + @Column + ']'
			END

			IF @DataType like '%VARCHAR%'
			BEGIN

				-- Make the column nullable
				SET @Query = 'ALTER TABLE ' + @Table + ' ALTER COLUMN ' + @Column + ' VARCHAR(255) NULL'
				EXEC(@Query)

				-- Remove text qualifiers
				SET @Query =
				'
					UPDATE ' + @Table + '
					SET ' + @Column + ' = substring(' + @Column + ', 2, len(' + @Column + ') - 2)
					WHERE left(' + @Column + ', 1) in ('''''''',''"'')
					  AND right(' + @Column + ', 1) in ('''''''',''"'')
				'
				EXEC(@Query)

				-- Trim
				SET @Query = 'UPDATE ' + @Table + ' SET ' + @Column + ' = rtrim(ltrim(' + @Column + '))'
				EXEC(@Query)

				-- Remove blank strings 
				SET @Query = 'UPDATE ' + @Table + ' SET ' + @Column + ' = null WHERE len(' + @Column + ') < 1'
				EXEC(@Query)

				-- Convert 'NULL' strings to true nulls
				SET @Query = 'UPDATE ' + @Table + ' SET ' + @Column + ' = null WHERE ' + @Column + ' = ''NULL'''
				EXEC(@Query)

				-- Attempt to detect and adjust data type
				IF @DetectDataTypes = 1
				BEGIN
					SET @Query = 
					'
						-- Convert to VARCHAR(255) as a default
						ALTER TABLE ' + @Table + '
						ALTER COLUMN ' + @Column + ' VARCHAR(255)

						IF (SELECT count(*) FROM ' + @Table + ' WHERE ' + @Column + ' is not null) > 0
						BEGIN	

							-- If the column is numeric
							IF (SELECT count(*) FROM ' + @Table + ' WHERE isnumeric(isnull(' + @Column + ',0)) = 0) = 0
							BEGIN

								-- Remove commas
								UPDATE ' + @Table + '
								SET ' + @Column + ' = replace(' + @Column + ', '','', '''')

								-- If there are $ signs, convert to MONEY
								IF (SELECT count(*) FROM ' + @Table + ' WHERE ' + @Column + ' like ''$%'') > 0
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' MONEY
								END

								-- If there are decimals, convert to FLOAT
								ELSE IF (SELECT count(*) FROM ' + @Table + ' WHERE ' + @Column + ' like ''%.%'') > 0
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' FLOAT
								END

								-- If it looks like a zipcode, convert it to CHAR(5)
								ELSE IF	''' + @Column + ''' like ''%Zip%''
								AND (SELECT count(*) FROM ' + @Table + ' WHERE len(' + @Column + ') > 5) = 0
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' CHAR(5)

									UPDATE ' + @Table + '
									SET ' + @Column + ' = right(''00000'' + ' + @Column + ', 5)
								END

								-- if it is too large to be an INT, convert to BIGINT
								ELSE IF	(
									SELECT count(*) 
									FROM ' + @Table + ' 
									WHERE abs(cast(' + @Column + ' as BIGINT)) > 2147483647
								) > 0
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' BIGINT
								END

								-- Else, convert to INT
								ELSE		
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' INT
								END
							END

							-- If the column is a DATE/TIME
							ELSE IF (
								SELECT count(*)
								FROM ' + @Table + '
								WHERE isdate(isnull(' + @Column + ', ''1900-01-01'')) = 0
							) = 0
							BEGIN

								-- If there are colons, convert to DATETIME
								IF (SELECT count(*) FROM ' + @Table + ' WHERE ' + @Column + ' like ''%:%'') > 0
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' DATETIME
								END

								-- Else, convert to DATE
								ELSE
								BEGIN
									ALTER TABLE ' + @Table + '
									ALTER COLUMN ' + @Column + ' DATE
								END
							END

							-- If it can be transformed into a DATE
							ELSE IF	(
								SELECT count(*) 
								FROM ' + @Table + '
								WHERE isnull(' + @Column + ', ''1900-01'') not like ''[0-9][0-9][0-9][0-9]-[0-9][0-9]''
							) = 0
							BEGIN
								UPDATE ' + @Table + '
								SET ' + @Column + ' = ' + @Column + ' + ''-01''

								ALTER TABLE ' + @Table + '
								ALTER COLUMN ' + @Column + ' DATE
							END

							-- If it can be transformed into a DATE in a different way
							ELSE IF	(
								SELECT count(*)
								FROM ' + @Table + '
								WHERE isnull(' + @Column + ', ''Jan-01'') not like ''[A-Z][A-Z][A-Z]-[0-9][0-9]''
							) = 0
							BEGIN	
								UPDATE ' + @Table + '
								SET ' + @Column + ' = ''1-'' + cast(' + @Column + ' as VARCHAR)

								ALTER TABLE ' + @Table + '
								ALTER COLUMN ' + @Column + ' DATE
							END
						END
					'
					EXEC(@Query) 
				END
			END
		END
		FETCH NEXT FROM ColumnCsr INTO @Column, @DataType, @IndexColumn
	END
	CLOSE ColumnCsr
	DEALLOCATE ColumnCsr
	DROP TABLE ##ColumnsTbl
END