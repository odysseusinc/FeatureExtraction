IF OBJECT_ID('tempdb..#groups', 'U') IS NOT NULL
	DROP TABLE #groups;

{@domain_table == 'drug_exposure' | @domain_table == 'drug_era'} ? {
SELECT DISTINCT descendant_concept_id,
  ancestor_concept_id
INTO #groups
FROM @cdm_database_schema.concept_ancestor
INNER JOIN @cdm_database_schema.concept
	ON ancestor_concept_id = concept_id
WHERE vocabulary_id = 'ATC'
	AND LEN(concept_code) IN (1, 3, 4, 5)
	AND concept_id != 0
{@excluded_concept_table != ''} ? {	AND descendant_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {	AND descendant_concept_id IN (SELECT id FROM @included_concept_table)}
{@excluded_concept_table != ''} ? {	AND ancestor_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {	AND ancestor_concept_id IN (SELECT id FROM @included_concept_table)}
;
}

{@domain_table == 'condition_occurrence' | @domain_table == 'condition_era'} ? {
{@hierarchy == "snomed"} ? {
SELECT DISTINCT descendant_concept_id,
  ancestor_concept_id
INTO #groups
FROM @cdm_database_schema.concept_ancestor
INNER JOIN (
	SELECT concept_id
	FROM @cdm_database_schema.concept
	INNER JOIN (
	  SELECT *
	  FROM @cdm_database_schema.concept_ancestor
	  WHERE ancestor_concept_id = 441840 /* SNOMED clinical finding */
	  AND (min_levels_of_separation > 2
		OR descendant_concept_id IN (433736, 433595, 441408, 72404, 192671, 137977, 434621, 437312, 439847, 4171917, 438555, 4299449, 375258, 76784, 40483532, 4145627, 434157, 433778, 258449, 313878)
		) 
	) temp
	  ON concept_id = descendant_concept_id
	WHERE concept_name NOT LIKE '%finding'
		AND concept_name NOT LIKE 'Disorder of%'
		AND concept_name NOT LIKE 'Finding of%'
		AND concept_name NOT LIKE 'Disease of%'
		AND concept_name NOT LIKE 'Injury of%'
		AND concept_name NOT LIKE '%by site'
		AND concept_name NOT LIKE '%by body site'
		AND concept_name NOT LIKE '%by mechanism'
		AND concept_name NOT LIKE '%of body region'
		AND concept_name NOT LIKE '%of anatomical site'
		AND concept_name NOT LIKE '%of specific body structure%'
		AND domain_id = 'Condition'
{@excluded_concept_table != ''} ? {		AND concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {		AND concept_id IN (SELECT id FROM @included_concept_table)}
) valid_groups
	ON ancestor_concept_id = valid_groups.concept_id
WHERE ancestor_concept_id != descendant_concept_id
{@excluded_concept_table != ''} ? {	AND ancestor_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {	AND ancestor_concept_id IN (SELECT id FROM @included_concept_table)}
;
} : { -- hierachy == 'meddra'
SELECT DISTINCT descendant_concept_id,
  ancestor_concept_id
INTO #groups
FROM @cdm_database_schema.concept_ancestor
INNER JOIN (
	SELECT concept_id
	FROM @cdm_database_schema.concept
	WHERE vocabulary_id = 'MedDRA'
		AND concept_class_id != 'SOC'
		AND concept_id NOT IN (36302170, 36303153, 36313966)
{@excluded_concept_table != ''} ? {	AND concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {	AND concept_id IN (SELECT id FROM @included_concept_table)}
	) valid_groups
	ON ancestor_concept_id = valid_groups.concept_id
WHERE ancestor_concept_id != descendant_concept_id
{@excluded_concept_table != ''} ? {		AND descendant_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {		AND descendant_concept_id IN (SELECT id FROM @included_concept_table)}
;
}
}

-- Feature construction
SELECT 
	CAST(ancestor_concept_id AS BIGINT) * 1000 + @analysis_id AS covariate_id,
{@temporal} ? {
    time_id,
}	
{@aggregated} ? {
	COUNT(*) AS sum_value,
	COUNT(*) / (1.0 * (SELECT COUNT(*) FROM @cohort_table {@cohort_definition_id != -1} ? {WHERE cohort_definition_id = @cohort_definition_id})) AS average_value
} : {
	row_id,
	1 AS covariate_value 
}
INTO @covariate_table
FROM (
	SELECT DISTINCT ancestor_concept_id,
{@temporal} ? {
		time_id,
}	
{@aggregated} ? {
		cohort.subject_id,
		cohort.cohort_start_date
} : {
		cohort.@row_id_field AS row_id
}	
	FROM @cohort_table cohort
	INNER JOIN @cdm_database_schema.@domain_table
		ON cohort.subject_id = @domain_table.person_id
	INNER JOIN #groups
		ON @domain_concept_id = descendant_concept_id
{@temporal} ? {
	INNER JOIN #time_period time_period
		ON @domain_start_date <= DATEADD(DAY, time_period.end_day, cohort.cohort_start_date)
		AND @domain_end_date >= DATEADD(DAY, time_period.start_day, cohort.cohort_start_date)
	WHERE drug_concept_id != 0
} : {
	WHERE @domain_start_date <= DATEADD(DAY, @end_day, cohort.cohort_start_date)
		AND @domain_end_date >= DATEADD(DAY, @start_day, cohort.cohort_start_date)
		AND @domain_concept_id != 0
}
{@inpatient} ? {	AND condition_type_concept_id IN (38000183, 38000184, 38000199, 38000200)}
{@included_cov_table != ''} ? {		AND CAST(ancestor_concept_id AS BIGINT) * 1000 + @analysis_id IN (SELECT id FROM @included_cov_table)}
{@cohort_definition_id != -1} ? {		AND cohort.cohort_definition_id = @cohort_definition_id}
) temp
{@aggregated} ? {		
GROUP BY ancestor_concept_id
{@temporal} ? {
    ,time_id
}	
}
;
TRUNCATE TABLE #groups;

DROP TABLE #groups;

-- Reference construction
INSERT INTO #cov_ref (
	covariate_id,
	covariate_name,
	analysis_id,
	concept_id
	)
SELECT covariate_id,
{@temporal} ? {
	CONCAT('@domain_table group: ', concept_id, '-', concept_name) AS covariate_name,
} : {
	CONCAT('@domain_table group during day @start_day through @end_day days relative to index: ', concept_id, '-', concept_name) AS covariate_name,
}
	@analysis_id AS analysis_id,
	concept_id
FROM (
	SELECT DISTINCT covariate_id
	FROM @covariate_table
	) t1
INNER JOIN @cdm_database_schema.concept
	ON concept_id = CAST((covariate_id - @analysis_id) / 1000 AS INT);
	
INSERT INTO #analysis_ref (
	analysis_id,
	analysis_name,
	domain_id,
{!@temporal} ? {
	start_day,
	end_day,
}
	is_binary,
	missing_means_zero
	)
SELECT @analysis_id AS analysis_id,
	'@analysis_name' AS analysis_name,
	'@domain_id' AS domain_id,
{!@temporal} ? {
	@start_day AS start_day,
	@end_day AS end_day,
}
	'Y' AS is_binary,
	NULL AS missing_means_zero;	