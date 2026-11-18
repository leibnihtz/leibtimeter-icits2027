# Concept-level learning analytics (v2.2.1)

The analytics are computed at read time from the stored responses. Nothing is
pre-aggregated, so features added in later versions also apply to data recorded
earlier. The computation is descriptive only: the system assigns no mastery
scores and no labels such as "fast = understood".

## Endpoints

Both endpoints require Admin, or a Teacher assigned to the course.

| Endpoint | Returns |
|---|---|
| `GET /api/courses/{courseId}/learning-analytics/concepts` | One summary per concept group, each with its `formatBreakdown` |
| `GET /api/courses/{courseId}/learning-analytics/concepts/detail?conceptTag=&topic=` | The concept summary with `formatBreakdown`, plus `learningOutcomeBreakdown` and one row per question |

## Population

The population is every `Response` whose run belongs to a session of the course
(`Response → SessionQuestionRun → Session.CourseId = courseId`).

- Session status is not filtered.
- Responses to questions that were later deactivated are included, so historical
  data keep counting.
- `courseId` identifies one course **offering** (one Code × Term row). The same
  course code in two terms therefore produces two separate dashboards.

## Evaluable response

A response is **evaluable** if all of the following hold:

```
QuestionType ∈ {SingleChoice, MultipleChoice, TrueFalse}
AND Question.HasCorrectAnswer = true
AND Response.IsCorrect IS NOT NULL
```

- Word cloud, short text and Likert responses are never evaluable.
- They are still counted in `responseCount` and `nonEvaluableResponseCount`.

## Scoring of a single response (server side, at submission)

| Format | Correct when |
|---|---|
| SingleChoice, TrueFalse | The selected option has `IsCorrect = true`. No option selected counts as incorrect |
| MultipleChoice | The set of selected options equals the set of correct options exactly. **All-or-nothing**: no partial credit, and option weights are ignored |
| Others, or `HasCorrectAnswer = false` | Not evaluated (`IsCorrect = null`) |

## Metrics

For any set *E* of evaluable responses (a concept, a format within a concept, or
an outcome within a concept):

```
accuracy  = |{ r ∈ E : IsCorrect = true }| / |E|          (null if E is empty; rounded to 4 decimals)
median RT = median{ RT(r) : r ∈ E, RT(r) not null }       (seconds; rounded to 1 decimal)
```

- Accuracy and median RT use the **same population**, the evaluable responses.
- The median is the classic median: the middle value, or the mean of the two
  middle values when n is even.
- RT is defined in `docs/response_time.md`.

The concept summary also reports:

| Field | Meaning |
|---|---|
| `questionCount` | Distinct questions |
| `responseCount` | All responses, evaluable or not |
| `studentCount` | Distinct students |
| `evaluableResponseCount` | Evaluable responses |
| `nonEvaluableResponseCount` | All other responses |

## Grouping

### Concept groups

The dashboard groups by **topic + concept within the course offering**, not by
concept alone. The grouping key is:

```
if ConceptTag is null or blank:   key = ("", "")                                  → one "uncategorized" group
else:                             key = (lower(trim(Topic ?? "")), lower(trim(ConceptTag)))
```

- The same `ConceptTag` under two different `Topic` values forms **two groups**.
- When `ConceptTag` is empty, `Topic` is ignored and all such responses fall into
  a single uncategorized group (`isUncategorized = true`), which is listed last.
  The other groups are sorted by topic, then by concept.
- The displayed spelling is deterministic: the first trimmed variant in ordinal
  order. The UI shows the topic under the concept name.
- The detail endpoint receives `topic` and `conceptTag` and applies the same key.

### Format breakdown

Within a concept, the evaluable responses are grouped by `QuestionType`, and each
group gets the same accuracy and median-RT formulas.

- Only formats with ≥ 1 evaluable response appear, so word cloud and short text
  never appear.
- `questionCount` = distinct questions of that format with evaluable responses.
- The concept's top-level accuracy and median RT still pool all formats. The
  per-format values appear only in `formatBreakdown`.
- The UI shows the "format breakdown" table in the concept detail when the
  concept has ≥ 2 formats.

### Learning-outcome breakdown

Within a concept, the evaluable responses are grouped by
`lower(trim(LearningOutcome))`, with the same formulas.

- Questions without an outcome are excluded, and no "no outcome" group is created.
- An outcome attached only to non-evaluable questions does not appear.
- A concept can have several outcomes.
- There is no course-wide outcome view across concepts.

## Normalization of the metadata fields

`Topic`, `ConceptTag` and `LearningOutcome` are normalized in two places.

**On input** (create and update question endpoints):

- leading and trailing whitespace is removed;
- internal runs of whitespace are collapsed to one space;
- an empty value is stored as null;
- a value over the maximum length (100 / 100 / 250) returns HTTP 400;
- on update, `null` leaves the field unchanged and `""` clears it.

**At aggregation:**

- values are compared after `trim` and lower-casing, so "MapReduce" and
  "mapreduce" are the same concept;
- internal whitespace is **not** collapsed again at this point. Values written
  directly to the database (for example by a migration script) and differing only
  in internal spacing would form separate groups.

## Metadata suggestions

`GET /api/questions/metadata-suggestions?courseId=` returns the distinct existing
topics and concepts of the course's active questions. They are returned as two
independent lists, de-duplicated without regard to case. The editor offers them
as autocomplete, but any new text is accepted.

## Relation to the SQL used in the paper

`sql/production_stats_v2_1_queries.sql` applies the same evaluable rule and the
same RT definition. Its concept-level blocks (A4 `distinct_concepts`,
A5 concept groups, A7 illustrative case) group by
`(course code, term, lower(trim(ConceptTag)))`. They do **not** include `Topic`,
which the dashboard does. The two counts agree only when no concept appears
under more than one topic in the same offering.
