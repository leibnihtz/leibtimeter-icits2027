-- Congelamiento de cifras para el paper ICITS 2027 (spec_icits_freeze.md). SOLO LECTURA.
-- Ejecutar en el droplet:
--   docker exec -i leibtimeter_db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
--     < /root/production_stats_v2_1_queries.sql > /root/production_stats_v2_1_out.txt 2>&1
--
-- Diferencias con el esquema supuesto en el spec:
--   * Responses."StudentId" (no "StudentProfileId"); la tabla de alumnos es "Students".
--   * La oferta de curso se identifica por ("Code","Term"); desde el 2026-09-29 los códigos
--     ya no llevan sufijo V2 (se filtran ambos por si acaso).
--   * "Evaluable" = definición de LearningAnalytics.cs:
--     formato ∈ {SingleChoice, MultipleChoice, TrueFalse} ∧ HasCorrectAnswer ∧ IsCorrect no nulo.
--   * RT = SubmittedAt − OpenedAt (reloj del servidor); se descartan nulos y negativos.
--   * Corte: Sessions."StartedAt" < 2026-09-26 00:00 hora de Lima (UTC−5).

SET client_encoding = 'UTF8';
\pset pager off
\set corte '2026-09-26 00:00:00-05'
BEGIN;
SET LOCAL timezone = 'UTC';

-- Vistas temporales (se descartan con el ROLLBACK final).
CREATE TEMP VIEW ses AS
SELECT s."Id", s."StartedAt", s."EndedAt", s."Status",
       c."Id" AS curso_id, c."Code" AS curso, c."Term" AS semestre,
       (c."Code" IN ('070165','070185','070165V2','070185V2'))            AS curso_main,
       (c."Code" IN ('070165','070185','070165V2','070185V2')
        AND s."StartedAt" < :'corte'::timestamptz)                        AS en_main,
       (c."Code" IN ('030591','070247'))                                  AS en_piloto
FROM "Sessions" s JOIN "Courses" c ON c."Id" = s."CourseId";

CREATE TEMP VIEW resp AS
SELECT r."Id", r."StudentId", r."QuestionId", r."SubmittedAt",
       ses."Id" AS "SessionId", ses.curso, ses.semestre, ses.curso_main, ses.en_main, ses.en_piloto,
       q."QuestionType" AS tipo, q."ConceptTag" AS concepto,
       q."Topic" AS tema, q."LearningOutcome" AS logro,
       (q."QuestionType" IN ('SingleChoice','MultipleChoice','TrueFalse')
        AND q."HasCorrectAnswer" AND r."IsCorrect" IS NOT NULL) AS evaluable,
       r."IsCorrect" AS correcta,
       CASE WHEN qr."OpenedAt" IS NOT NULL AND r."SubmittedAt" >= qr."OpenedAt"
            THEN EXTRACT(EPOCH FROM r."SubmittedAt" - qr."OpenedAt") END AS rt
FROM "Responses" r
JOIN "SessionQuestionRuns" qr ON qr."Id" = r."SessionQuestionRunId"
JOIN "Questions" q ON q."Id" = r."QuestionId"
JOIN ses ON ses."Id" = qr."SessionId";

SET LOCAL transaction_read_only = on;

\echo '=== 0a. Tipos de columnas de fecha ==='
SELECT table_name, column_name, data_type FROM information_schema.columns
WHERE (table_name, column_name) IN (('Sessions','StartedAt'),('Sessions','EndedAt'),
      ('SessionQuestionRuns','OpenedAt'),('Responses','SubmittedAt'),('Questions','UpdatedAt'),('Students','CreatedAt'))
ORDER BY 1, 2;

\echo '=== 0b. Cursos (todas las ofertas) ==='
SELECT c."Code", c."Term", left(c."Name", 45) AS nombre,
       count(DISTINCT s."Id")                                             AS sesiones,
       count(DISTINCT s."Id") FILTER (WHERE s."StartedAt" < :'corte'::timestamptz) AS sesiones_antes_corte,
       (min(s."StartedAt") AT TIME ZONE 'America/Lima')::date             AS primera_lima,
       (max(s."StartedAt") AT TIME ZONE 'America/Lima')::date             AS ultima_lima
FROM "Courses" c LEFT JOIN "Sessions" s ON s."CourseId" = c."Id"
GROUP BY c."Id", c."Code", c."Term", c."Name" ORDER BY c."Term", c."Code";

-- ───────────────────────────── BLOQUE A ─────────────────────────────

\echo '=== A1. Totales del dataset principal ==='
SELECT
  (SELECT count(DISTINCT (curso, semestre)) FROM ses WHERE en_main)        AS course_offerings,
  (SELECT count(*) FROM ses WHERE en_main)                                 AS sessions,
  (SELECT count(*) FROM ses WHERE en_main AND "EndedAt" IS NULL)           AS sessions_sin_cerrar,
  (SELECT count(DISTINCT "SessionId") FROM resp WHERE en_main)             AS sessions_con_respuestas,
  (SELECT count(DISTINCT "StudentId") FROM resp WHERE en_main)             AS students_answering,
  (SELECT count(DISTINCT "QuestionId") FROM resp WHERE en_main)            AS questions_answered,
  (SELECT count(*) FROM "SessionQuestionRuns" qr JOIN ses ON ses."Id" = qr."SessionId" WHERE ses.en_main) AS runs_launched,
  (SELECT count(*) FROM resp WHERE en_main)                                AS responses_total,
  (SELECT count(*) FROM resp WHERE en_main AND evaluable)                  AS responses_evaluable;

\echo '=== A2. Alumnos registrados / aprobados (variantes; el 27/09 eran 132 / 131) ==='
WITH st AS (
  SELECT s."Id", s."CreatedAt", (u."RegistrationStatus" = 1) AS aprobado,
         (EXISTS (SELECT 1 FROM "Enrollments" e JOIN "Courses" c ON c."Id" = e."CourseId"
                  WHERE e."StudentId" = s."Id" AND c."Code" IN ('070165','070185','070165V2','070185V2'))
          OR EXISTS (SELECT 1 FROM "Courses" c WHERE c."Id" = s."RequestedCourseId"
                     AND c."Code" IN ('070165','070185','070165V2','070185V2'))) AS ligado_main
  FROM "Students" s LEFT JOIN "AspNetUsers" u ON u."Id" = s."UserId"
)
SELECT 'todos (hoy)' AS variante, count(*) AS registrados, count(*) FILTER (WHERE aprobado) AS aprobados FROM st
UNION ALL SELECT 'creados antes del corte (26/09 Lima)', count(*), count(*) FILTER (WHERE aprobado) FROM st WHERE "CreatedAt" < :'corte'::timestamptz
UNION ALL SELECT 'creados antes del 28/09 Lima', count(*), count(*) FILTER (WHERE aprobado) FROM st WHERE "CreatedAt" < timestamptz '2026-09-28 00:00:00-05'
UNION ALL SELECT 'ligados a 070165/070185', count(*), count(*) FILTER (WHERE aprobado) FROM st WHERE ligado_main
UNION ALL SELECT 'ligados y creados antes del corte', count(*), count(*) FILTER (WHERE aprobado) FROM st WHERE ligado_main AND "CreatedAt" < :'corte'::timestamptz
UNION ALL SELECT 'ligados y creados antes del 28/09', count(*), count(*) FILTER (WHERE aprobado) FROM st WHERE ligado_main AND "CreatedAt" < timestamptz '2026-09-28 00:00:00-05';

\echo '=== A2b. Altas de alumnos por día desde el 20/09 (fecha Lima) ==='
SELECT ("CreatedAt" AT TIME ZONE 'America/Lima')::date AS dia, count(*) AS altas
FROM "Students" WHERE "CreatedAt" >= timestamptz '2026-09-20 00:00:00-05' GROUP BY 1 ORDER BY 1;

\echo '=== A3. Por formato (precisión y RT sobre evaluables) ==='
SELECT tipo,
       count(*)                                        AS respuestas,
       count(*) FILTER (WHERE evaluable)               AS n_evaluables,
       round(avg(CASE WHEN correcta THEN 1.0 ELSE 0.0 END) FILTER (WHERE evaluable), 3) AS accuracy,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY rt) FILTER (WHERE evaluable))::numeric, 1) AS median_rt_s,
       round((percentile_cont(0.25) WITHIN GROUP (ORDER BY rt) FILTER (WHERE evaluable))::numeric, 1) AS p25_s,
       round((percentile_cont(0.75) WITHIN GROUP (ORDER BY rt) FILTER (WHERE evaluable))::numeric, 1) AS p75_s
FROM resp WHERE en_main GROUP BY tipo ORDER BY respuestas DESC;

\echo '=== A4. Cobertura de metadata ==='
SELECT
  count(DISTINCT "QuestionId")                                     AS questions_answered,
  count(DISTINCT "QuestionId") FILTER (WHERE concepto IS NOT NULL) AS questions_with_concept,
  count(DISTINCT lower(trim(concepto)))                            AS distinct_concepts,
  count(*) FILTER (WHERE concepto IS NOT NULL)                     AS responses_covered_by_concept,
  round(100.0 * count(*) FILTER (WHERE concepto IS NOT NULL) / NULLIF(count(*), 0), 1) AS pct_covered,
  count(DISTINCT "QuestionId") FILTER (WHERE concepto IS NOT NULL AND (tema IS NULL OR logro IS NULL)) AS con_concepto_incompletas
FROM resp WHERE en_main;

\echo '=== A5. Grupos concepto × oferta por número de formatos evaluables ==='
WITH por_concepto AS (
  SELECT curso, semestre, lower(trim(concepto)) AS concepto,
         count(DISTINCT tipo) FILTER (WHERE evaluable) AS formatos_evaluables,
         count(*) FILTER (WHERE evaluable)             AS respuestas_evaluables
  FROM resp WHERE en_main AND concepto IS NOT NULL
  GROUP BY curso, semestre, lower(trim(concepto))
)
SELECT formatos_evaluables, count(*) AS grupos, sum(respuestas_evaluables) AS respuestas_evaluables
FROM por_concepto GROUP BY ROLLUP (formatos_evaluables) ORDER BY formatos_evaluables;

\echo '=== A6. Calidad del RT ==='
SELECT count(*) FILTER (WHERE evaluable)                     AS evaluables,
       count(*) FILTER (WHERE evaluable AND rt IS NULL)      AS sin_rt,
       round(max(rt) FILTER (WHERE evaluable)::numeric, 1)   AS rt_max_s,
       count(*) FILTER (WHERE evaluable AND rt > 300)        AS rt_mayor_5min
FROM resp WHERE en_main;

\echo '=== A7. Caso "Redundancia y bucles de capa 2" (Redes II) — total y por formato ==='
SELECT curso, semestre, COALESCE(tipo, '** TOTAL **') AS tipo,
       count(DISTINCT "StudentId")                      AS alumnos,
       count(*)                                         AS respuestas,
       count(*) FILTER (WHERE evaluable)                AS n_evaluables,
       round(avg(CASE WHEN correcta THEN 1.0 ELSE 0.0 END) FILTER (WHERE evaluable), 3) AS accuracy,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE evaluable))::numeric, 1) AS median_rt_s
FROM resp
WHERE en_main AND curso LIKE '070185%' AND lower(trim(concepto)) = 'redundancia y bucles de capa 2'
GROUP BY GROUPING SETS ((curso, semestre), (curso, semestre, tipo))
ORDER BY semestre, tipo;

\echo '=== A8. Por oferta de curso (dataset principal) ==='
SELECT curso, semestre,
       count(DISTINCT "SessionId")  AS sesiones,
       count(DISTINCT "StudentId")  AS alumnos,
       count(DISTINCT "QuestionId") AS preguntas,
       count(*)                     AS respuestas,
       (min("SubmittedAt") AT TIME ZONE 'America/Lima')::date AS primera_lima,
       (max("SubmittedAt") AT TIME ZONE 'America/Lima')::date AS ultima_lima
FROM resp WHERE en_main GROUP BY curso, semestre ORDER BY semestre, curso;

\echo '=== A9. Solo como dato: 070165/070185 DESPUÉS del corte (no entra al paper) ==='
SELECT
  (SELECT count(*) FROM ses WHERE curso_main AND NOT COALESCE(en_main, false))                 AS sesiones_fuera,
  (SELECT count(*) FROM ses WHERE curso_main AND "StartedAt" IS NULL)                          AS de_ellas_sin_iniciar,
  (SELECT count(*) FROM resp WHERE curso_main AND NOT COALESCE(en_main, false))                AS respuestas_despues,
  (SELECT count(*) FROM resp WHERE curso_main AND NOT COALESCE(en_main, false) AND evaluable)  AS evaluables_despues;

-- ───────────────────────────── BLOQUE B ─────────────────────────────

\echo '=== B1. Duración de sesiones (min), dataset principal ==='
SELECT count(*) AS n,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY d))::numeric, 1) AS median_min,
       round((percentile_cont(0.25) WITHIN GROUP (ORDER BY d))::numeric, 1) AS p25_min,
       round((percentile_cont(0.75) WITHIN GROUP (ORDER BY d))::numeric, 1) AS p75_min,
       round(min(d)::numeric, 1) AS min_min,
       round(max(d)::numeric, 1) AS max_min
FROM (SELECT EXTRACT(EPOCH FROM "EndedAt" - "StartedAt") / 60 AS d
      FROM ses WHERE en_main AND "EndedAt" IS NOT NULL) x;

\echo '=== B2. Runs por sesión, dataset principal ==='
SELECT count(*) AS sesiones,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY runs)          AS runs_per_session_median,
       min(runs) AS min_runs, max(runs) AS max_runs, sum(runs) AS total_runs,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY runs_abiertos) AS median_runs_abiertos,
       sum(runs_abiertos) AS total_runs_abiertos
FROM (SELECT ses."Id", count(qr."Id") AS runs, count(qr."OpenedAt") AS runs_abiertos
      FROM ses LEFT JOIN "SessionQuestionRuns" qr ON qr."SessionId" = ses."Id"
      WHERE ses.en_main GROUP BY ses."Id") x;

\echo '=== B3. Detalle por sesión (para auditar B1; sin datos de alumnos) ==='
SELECT ses.curso, ses.semestre,
       to_char(ses."StartedAt" AT TIME ZONE 'America/Lima', 'YYYY-MM-DD HH24:MI') AS inicio_lima,
       round((EXTRACT(EPOCH FROM ses."EndedAt" - ses."StartedAt") / 60)::numeric, 1) AS dur_min,
       count(qr."Id") AS runs
FROM ses LEFT JOIN "SessionQuestionRuns" qr ON qr."SessionId" = ses."Id"
WHERE ses.en_main GROUP BY ses."Id", ses.curso, ses.semestre, ses."StartedAt", ses."EndedAt"
ORDER BY ses."StartedAt";

-- ─────────────────────── BLOQUE C (piloto, opcional) ───────────────────────

\echo '=== C1. Conteos por curso piloto ==='
SELECT ses.curso, ses.semestre,
       count(DISTINCT ses."Id")                               AS sessions,
       count(DISTINCT r."StudentId")                          AS students_answering,
       count(r."Id")                                          AS responses_total,
       count(r."Id") FILTER (WHERE q."QuestionType" IN ('SingleChoice','MultipleChoice','TrueFalse')) AS responses_evaluable_spec,
       count(r."Id") FILTER (WHERE q."QuestionType" IN ('SingleChoice','MultipleChoice','TrueFalse')
                             AND q."HasCorrectAnswer" AND r."IsCorrect" IS NOT NULL)                  AS responses_evaluable_app,
       count(DISTINCT q."Id")                                 AS questions_launched,
       count(DISTINCT lower(trim(q."ConceptTag")))            AS distinct_concepts,
       to_char(min(ses."StartedAt") AT TIME ZONE 'America/Lima', 'YYYY-MM-DD HH24:MI') AS primera_sesion_lima,
       to_char(max(ses."StartedAt") AT TIME ZONE 'America/Lima', 'YYYY-MM-DD HH24:MI') AS ultima_sesion_lima
FROM ses
JOIN "SessionQuestionRuns" sr ON sr."SessionId" = ses."Id"
JOIN "Questions" q            ON q."Id" = sr."QuestionId"
LEFT JOIN "Responses" r       ON r."SessionQuestionRunId" = sr."Id"
WHERE ses.en_piloto
GROUP BY ses.curso, ses.semestre ORDER BY 1, 2;

\echo '=== C2. Conceptos con más de un LearningOutcome (preguntas lanzadas) ==='
SELECT curso, semestre, count(*) AS concepts, count(*) FILTER (WHERE n_lo > 1) AS concepts_with_multiple_lo
FROM (
  SELECT ses.curso, ses.semestre, lower(trim(q."ConceptTag")) AS ct,
         count(DISTINCT lower(trim(q."LearningOutcome"))) AS n_lo
  FROM ses
  JOIN "SessionQuestionRuns" sr ON sr."SessionId" = ses."Id"
  JOIN "Questions" q ON q."Id" = sr."QuestionId"
  WHERE ses.en_piloto AND q."ConceptTag" IS NOT NULL
  GROUP BY 1, 2, 3
) x GROUP BY curso, semestre ORDER BY 1, 2;

\echo '=== C3. Etiquetado prospectivo y ediciones posteriores a la primera apertura ==='
SELECT curso, semestre,
       count(*)                                    AS launched,
       count(*) FILTER (WHERE completa)            AS fully_tagged,
       count(*) FILTER (WHERE primera_apertura IS NOT NULL)                                AS abiertas,
       count(*) FILTER (WHERE primera_apertura IS NOT NULL AND creada > primera_apertura)  AS creadas_despues_de_abrir,
       count(*) FILTER (WHERE primera_apertura IS NOT NULL AND editada > primera_apertura) AS edited_after_first_open
FROM (
  SELECT ses.curso, ses.semestre, q."Id",
         (q."ConceptTag" IS NOT NULL AND q."Topic" IS NOT NULL AND q."LearningOutcome" IS NOT NULL) AS completa,
         q."CreatedAt" AS creada, q."UpdatedAt" AS editada,
         min(sr."OpenedAt") AS primera_apertura
  FROM ses
  JOIN "SessionQuestionRuns" sr ON sr."SessionId" = ses."Id"
  JOIN "Questions" q ON q."Id" = sr."QuestionId"
  WHERE ses.en_piloto
  GROUP BY ses.curso, ses.semestre, q."Id"
) x GROUP BY curso, semestre ORDER BY 1, 2;

\echo '=== C4. Piloto agregado por formato (descriptivo) ==='
SELECT tipo,
       count(*) FILTER (WHERE evaluable) AS n_evaluables,
       round(avg(CASE WHEN correcta THEN 1.0 ELSE 0.0 END) FILTER (WHERE evaluable), 3) AS accuracy,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE evaluable))::numeric, 1) AS median_rt_s
FROM resp WHERE en_piloto GROUP BY tipo ORDER BY 2 DESC;

ROLLBACK;


-- ═══════════════════════════════════════════════════════════════════════════
-- SEGUNDA CORRIDA (transacción aparte): duración activa de las sesiones.
-- Salida: production_stats_v2_1_duracion_out.txt
-- ═══════════════════════════════════════════════════════════════════════════

-- Duración ACTIVA de las sesiones del dataset principal (paper ICITS 2027). SOLO LECTURA.
-- Ejecutar en el droplet:
--   docker exec -i leibtimeter_db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
--     < /root/production_stats_v2_1_duracion.sql > /root/production_stats_v2_1_duracion_out.txt 2>&1
--
-- POR QUÉ existe esta consulta
--   El spec (bloque B) define la duración como Sessions."EndedAt" − Sessions."StartedAt".
--   "EndedAt" se escribe cuando el docente pulsa "Cerrar sesión", no cuando termina la actividad.
--   En 5 de las 21 sesiones el cierre se hizo horas o días después de la clase
--   (469, 3531, 4117, 4313 y 9911 min), así que esa resta mide el olvido del botón y no el uso
--   en el aula: da un máximo de casi 7 días y un IQR de 7.9–106.4 min.
--   Aquí se mide el tramo en que hubo actividad real, con marcas que el servidor escribe solo:
--     inicio = primera pregunta abierta de la sesión   (min SessionQuestionRuns."OpenedAt")
--     fin    = última respuesta recibida en la sesión  (max Responses."SubmittedAt")
--   Como contraste se calcula también fin = último cierre de pregunta (max "ClosedAt"), que
--   vuelve a depender de una acción manual del docente.
--   D2 lista cada sesión para auditar: si una sesión tiene respuestas en más de un día
--   (dias_con_respuestas > 1), su tramo activo tampoco representa una sola clase.
--
-- Mismo dataset y corte que production_stats_v2_1_queries.sql.

SET client_encoding = 'UTF8';
\pset pager off
\set corte '2026-09-26 00:00:00-05'
BEGIN;
SET LOCAL timezone = 'UTC';

CREATE TEMP VIEW dur AS
SELECT s."Id", c."Code" AS curso, c."Term" AS semestre, s."StartedAt", s."EndedAt",
       a.primera_apertura, a.ultimo_cierre, a.runs_abiertos, b.ultima_respuesta, b.respuestas, b.dias_con_respuestas,
       EXTRACT(EPOCH FROM s."EndedAt" - s."StartedAt") / 60               AS min_spec,
       EXTRACT(EPOCH FROM b.ultima_respuesta - a.primera_apertura) / 60    AS min_activa,
       EXTRACT(EPOCH FROM a.ultimo_cierre - a.primera_apertura) / 60       AS min_hasta_ultimo_cierre
FROM "Sessions" s
JOIN "Courses" c ON c."Id" = s."CourseId"
LEFT JOIN LATERAL (
  SELECT min(qr."OpenedAt") AS primera_apertura, max(qr."ClosedAt") AS ultimo_cierre,
         count(qr."OpenedAt") AS runs_abiertos
  FROM "SessionQuestionRuns" qr WHERE qr."SessionId" = s."Id") a ON true
LEFT JOIN LATERAL (
  SELECT max(r."SubmittedAt") AS ultima_respuesta, count(*) AS respuestas,
         count(DISTINCT (r."SubmittedAt" AT TIME ZONE 'America/Lima')::date) AS dias_con_respuestas
  FROM "Responses" r JOIN "SessionQuestionRuns" qr ON qr."Id" = r."SessionQuestionRunId"
  WHERE qr."SessionId" = s."Id") b ON true
WHERE c."Code" IN ('070165','070185','070165V2','070185V2')
  AND s."StartedAt" < :'corte'::timestamptz;

SET LOCAL transaction_read_only = on;

\echo '=== D1. Resumen por definición de duración (min) ==='
SELECT definicion,
       count(d)                                                             AS n,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY d))::numeric, 1) AS median_min,
       round((percentile_cont(0.25) WITHIN GROUP (ORDER BY d))::numeric, 1) AS p25_min,
       round((percentile_cont(0.75) WITHIN GROUP (ORDER BY d))::numeric, 1) AS p75_min,
       round(min(d)::numeric, 1)                                            AS min_min,
       round(max(d)::numeric, 1)                                            AS max_min
FROM (
  SELECT 1 AS ord, 'spec: EndedAt - StartedAt' AS definicion, min_spec AS d FROM dur
  UNION ALL SELECT 2, 'activa: primera apertura -> ultima respuesta', min_activa FROM dur
  UNION ALL SELECT 3, 'primera apertura -> ultimo cierre de pregunta', min_hasta_ultimo_cierre FROM dur
  UNION ALL SELECT 4, 'activa, solo sesiones de un unico dia', min_activa FROM dur WHERE dias_con_respuestas = 1
) x GROUP BY ord, definicion ORDER BY ord;

\echo '=== D2. Detalle por sesión (sin datos de alumnos) ==='
SELECT curso, semestre,
       to_char(primera_apertura AT TIME ZONE 'America/Lima', 'YYYY-MM-DD HH24:MI') AS primera_apertura_lima,
       to_char(ultima_respuesta AT TIME ZONE 'America/Lima', 'YYYY-MM-DD HH24:MI') AS ultima_respuesta_lima,
       round(min_spec::numeric, 1)                AS min_spec,
       round(min_activa::numeric, 1)              AS min_activa,
       round(min_hasta_ultimo_cierre::numeric, 1) AS min_ult_cierre,
       runs_abiertos, respuestas, dias_con_respuestas
FROM dur ORDER BY "StartedAt";

ROLLBACK;
