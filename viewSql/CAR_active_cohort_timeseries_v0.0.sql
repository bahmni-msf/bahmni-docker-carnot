-- The first CTE build the frame for patients entering and exiting the cohort. This frame is based on MNT VIH TB form with visit types of 'Inclusion' and 'Sortie'. For each patient, the query takes all initial visit dates and matches the discharge visit date occuring after the initial visit. If a patient has multiple initial visits and discharge visits, the match happens sequentially based on the date of visit (e.g. the first initial visit is matched to the first discharge, and so on). If the patient does not have a discharge visit, then the discharge information is empty until completed. 
WITH inclusion AS (
	SELECT 
		patient_id, encounter_id AS encounter_id_inclusion, lieu_de_visite AS lieu_de_visite_inclusion, date AS date_inclusion, DENSE_RANK () OVER (PARTITION BY patient_id ORDER BY date) AS inclusion_visit_order, LEAD (date) OVER (PARTITION BY patient_id ORDER BY date) AS date_inclusion_suivi
	FROM mnt_vih_tb WHERE type_de_visite = 'Inclusion'),
cohorte AS (
	SELECT
		i.patient_id, i.encounter_id_inclusion, i.lieu_de_visite_inclusion, i.date_inclusion, CASE WHEN i.inclusion_visit_order > 1 THEN 'Oui' END readmission, d.encounter_id AS encounter_id_sortie, CASE WHEN d.date_de_sortie IS NOT NULL THEN d.date_de_sortie WHEN d.date_de_sortie IS NULL THEN d.date ELSE NULL END AS date_de_sortie, d.statut_de_sortie AS statut_de_sortie
	FROM inclusion i
	LEFT JOIN (SELECT patient_id, date, encounter_id, date_de_sortie, statut_de_sortie FROM mnt_vih_tb WHERE type_de_visite = 'Sortie') d 
		ON i.patient_id = d.patient_id AND d.date >= i.date_inclusion AND (d.date < i.date_inclusion_suivi OR i.date_inclusion_suivi IS NULL)),
-- The following CTEs create the active patient calculation by counting each day the cumulative admissions and exits from the cohort.
range_values AS (
	SELECT 
		date_trunc('day',min(c.date_inclusion)) AS minval,
		date_trunc('day',max(CURRENT_DATE)) AS maxval
	FROM cohorte c),
day_range AS (
	SELECT 
		generate_series(minval,maxval,'1 day'::interval) as day
	FROM range_values),   
daily_admissions AS (
	SELECT 
		date_trunc('day', c.date_inclusion) AS day,
		count(*) AS patients
	FROM cohorte c
	GROUP BY 1),
daily_exits AS (
	SELECT
		date_trunc('day',c.date_de_sortie) AS day,
		count(*) AS patients
	FROM cohorte c
	GROUP BY 1),
daily_cohorte_active AS (
	SELECT 
		dr.day as reporting_day,
		SUM(da.patients) over (order by dr.day asc rows between unbounded preceding and current row) AS cumulative_admissions,
		CASE
		    WHEN SUM(de.patients) over (order by dr.day asc rows between unbounded preceding and current row) IS NULL
		    THEN 0
		    ELSE SUM(de.patients) over (order by dr.day asc rows between unbounded preceding and current row) 
		END AS cumulative_exits,  
		CASE
		    WHEN SUM(de.patients) over (order by dr.day asc rows between unbounded preceding and current row) IS NULL 
			THEN SUM(da.patients) over (order by dr.day asc rows between unbounded preceding and current row)
		    ELSE (SUM(da.patients) over (order by dr.day asc rows between unbounded preceding and current row)-
				SUM(de.patients) over (order by dr.day asc rows between unbounded preceding and current row)) 
		END AS cohorte_active,
		CASE 
			WHEN date(dr.day)::date = (date_trunc('MONTH', dr.day) + INTERVAL '1 MONTH - 1 day')::date THEN 1
		END AS last_day_of_month
	FROM day_range dr
	LEFT OUTER JOIN daily_admissions da ON dr.day = da.day
	LEFT OUTER JOIN daily_exits de ON dr.day = de.day)
-- Main query --
SELECT 
	dap.reporting_day::date,
	dap.cohorte_active
FROM daily_cohorte_active dap
WHERE dap.last_day_of_month = 1 and dap.reporting_day > date_trunc('MONTH', CURRENT_DATE) - INTERVAL '1 year'
GROUP BY dap.reporting_day, dap.cohorte_active;