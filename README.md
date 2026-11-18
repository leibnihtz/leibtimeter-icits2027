# LeibtiMeter — supplementary technical documentation (ICITS 2027)

This repository accompanies the ICITS 2027 paper (submission 598) that describes
**LeibtiMeter**, a self-hosted classroom response system. LeibtiMeter records
response time on the server for every answer, and it aggregates accuracy and
response time by pedagogical concept, question format and learning outcome.

## What this repository contains

| Path | Content |
|---|---|
| `docs/architecture.md` | Stack and versions, component diagram, live-session sequence, generic deployment model |
| `docs/data_model.md` | Entities, relevant columns, relationships, unique constraints, personal-data fields |
| `docs/response_time.md` | Definition of response time (RT) and what it includes |
| `docs/analytics.md` | Exact computation of accuracy and median RT by concept, format and learning outcome |
| `docs/access_control.md` | Role × endpoint matrix, SignalR groups, version history, tests, deliberate exceptions |
| `sql/production_stats_v2_1_queries.sql` | The read-only SQL used to produce every number in the paper's deployment section |
| `data/production_stats_v2_1.json` | The aggregated results of that SQL (no student-level data) |

## What it does not contain

- **The application source code.** It is available from the author on request.
- **Student-level data.** Responses, names, student codes, e-mail addresses and
  join IP addresses are personal data and are not shared. `data/` holds aggregates only.
- **Deployment credentials or infrastructure identifiers** (hostnames, addresses,
  credentials).

## Documented version

The documents describe **LeibtiMeter v2.2.1**, the version deployed when the
numbers were frozen (verified on 2026-10-06). The relevant tags of the private
application repository are:

| Tag | Date | Meaning |
|---|---|---|
| `v2.1-privacy-and-fr9` | 2026-09-27 | Course-scoped reports, split SignalR groups, format and learning-outcome breakdowns |
| `v2.2` / `v2.2.1` | 2026-09-29 | Course scoping extended to students, question banks and questions |
| `v2.1-paper-freeze-icits` | 2026-10-06 | Commit that froze `sql/` and `data/` as used in the paper |

All responses of the main dataset were recorded with **v2.0** (before
2026-09-27). The analytics added in v2.1 are computed at query time, so they
apply to those data too. `docs/access_control.md` lists what changed in each version.

The files in `sql/` and `data/` are byte-identical copies of the files at tag
`v2.1-paper-freeze-icits` (git blob ids `1a03fef0` and `388358a4`).

## Paper section → file

| Paper section | File |
|---|---|
| §4.1 Technology Stack | `docs/architecture.md` |
| §4.2 Domain Model (Fig. 1) | `docs/data_model.md` |
| §4.3 Real-Time Session Flow | `docs/architecture.md` (sequence diagram), `docs/response_time.md` |
| §4.3 Role-Separated Event Routing | `docs/access_control.md` (SignalR section) |
| §4.4 Access Control | `docs/access_control.md`; JSON block `access_control` |
| §5 Concept-Level Learning Analytics | `docs/analytics.md` |
| §6.1 Setting and Data (Table 2) | `sql/` blocks 0b, A1, A2, A4, A8; JSON `main` |
| §6.2 Accuracy and RT by Format (Table 3) | `sql/` block A3; JSON `main.by_format` |
| §6.3 Illustrative Case | `sql/` block A7; JSON `main.case_l2loops` |
| §6.4 Coverage of the Format Breakdown | `sql/` block A5; JSON `main.concept_groups` |
| §6.5 Ongoing Pilot | `sql/` block C; JSON `pilot` (not used in Tables 2–3) |
| §6.6 Operational Observations (session length) | `sql/` second run, D blocks; JSON `main.session_duration_min` |
| §7.1 Response-Time Measurement | `docs/response_time.md` |
| §7.2 Data Custody and Privacy | `docs/data_model.md` (personal data), `docs/access_control.md` |

## How the numbers in Tables 2 and 3 are computed

The SQL runs in one read-only transaction that ends in `ROLLBACK`. It defines two
temporary views:

- `ses` marks each session as part of the **main dataset** (`en_main`): course
  codes 070165 (Big Data) or 070185 (Computer Networks II), and
  `Sessions.StartedAt < 2026-09-26 00:00 (UTC−5)`.
- `resp` holds one row per response with its format, concept fields,
  `evaluable` flag and `rt`.
  - **Evaluable**: `QuestionType ∈ {SingleChoice, MultipleChoice, TrueFalse}`,
    `HasCorrectAnswer` is true and `IsCorrect` is not null. This is the same rule
    the application uses (`docs/analytics.md`).
  - **RT**: `SubmittedAt − OpenedAt` in seconds, or null if `OpenedAt` is null or
    the difference is negative (`docs/response_time.md`).

### Table 2 — Production deployment

| Row | SQL block | JSON field |
|---|---|---|
| Course offerings | A1 `course_offerings` = distinct (code, term) | `main.course_offerings` |
| Students registered / approved | A2, variant "creados antes del corte": student profiles created before the cutoff, and those whose account has `RegistrationStatus = 1` (Active) | `main.students_registered`, `main.students_approved` |
| Students answering | A1 `students_answering` = distinct `StudentId` in `resp` | `main.students_answering` |
| Sessions (all closed, all with responses) | A1 `sessions`, `sessions_sin_cerrar` (= 0), `sessions_con_respuestas` | `main.sessions`, `main.sessions_unclosed` |
| Questions answered / runs launched | A1 `questions_answered` (distinct questions with ≥ 1 response), `runs_launched` (all `SessionQuestionRuns` of main sessions) | `main.questions_answered`, `main.runs_launched` |
| Responses / evaluable responses | A1 `responses_total`, `responses_evaluable` | `main.responses_total`, `main.responses_evaluable` |
| Questions with a concept tag (distinct concepts) | A4 `questions_with_concept`; `distinct_concepts` = distinct `lower(trim(ConceptTag))` across all offerings | `main.questions_with_concept`, `main.distinct_concepts` |
| Responses covered by a concept tag | A4 `responses_covered_by_concept`, `pct_covered` | `main.responses_covered_by_concept(_pct)` |
| First / last session | A8 (per offering), 0b | `main.offerings[].first/last` |

### Table 3 — Evaluable responses by format

Block A3 groups `resp` (main dataset) by `QuestionType`, over evaluable responses:

- `n` = number of evaluable responses;
- accuracy = mean of `IsCorrect` (1 = correct, 0 = incorrect);
- median RT and IQR = `percentile_cont(0.5)`, `(0.25)` and `(0.75)` of `rt`.
  `percentile_cont(0.5)` equals the classic median used by the dashboard
  (mean of the two middle values when n is even).

JSON: `main.by_format`. Block A6 checks RT quality (`rt_missing = 0`,
`rt_max_s = 127.4`, `rt_over_300s = 0`).

## Reproducing

The SQL needs the production database, so it cannot be re-run outside the
deployment. Each block prints its result. The JSON is a transcription of that
output, and every JSON field names its source block in this README. The
definitions match the application code described in `docs/`.

## License and citation

Documentation and aggregated data: [CC BY 4.0](LICENSE). The license does not
cover the LeibtiMeter application. To cite this repository, see `CITATION.cff`.
