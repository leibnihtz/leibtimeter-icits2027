# Response time (RT)

## Definition

```
RT = Response.SubmittedAt − SessionQuestionRun.OpenedAt      (seconds)
```

Both timestamps come from the **server clock** (`DateTime.UtcNow` in the API process):

| Timestamp | Written when |
|---|---|
| `OpenedAt` | The API processes the teacher's request `POST /api/sessions/{id}/question-runs/{runId}/open`. The value is set before the change is saved and before `QuestionOpened` is broadcast. |
| `SubmittedAt` | The API processes the student's request `POST /api/responses`, after the run, enrollment and duplicate checks. |

RT is **null** (not computable) when `OpenedAt` is null or the difference is
negative. Such responses are excluded from medians. In the main dataset, no
evaluable response had a null RT, and the maximum RT was 127.4 s
(`data/production_stats_v2_1.json`, `main.rt_missing`, `main.rt_max_s`).

No timestamp from the client is stored. Using only the server clock avoids skew
between student devices.

## What RT includes

For a student who is already connected when the run opens, RT is the sum of:

1. **Delivery of the question.** The server broadcasts `QuestionOpened` over
   SignalR (WebSocket), and the student's browser renders it.
2. **The student's reading, reasoning and interaction time.**
3. **The HTTP round trip of the submission.** The request travels from the device
   to the API and is processed until `SubmittedAt` is set. The response does not
   travel back before `SubmittedAt` is set, so only the outbound half counts.

Components 1 and 3 are not subtracted, and network conditions were not logged.

A student who opens the session page **after** the run opened, or reloads it,
does not receive `QuestionOpened`. The page loads the open run over HTTP
(`GET /api/sessions/{id}`). In that case RT also includes the time before the
student joined or reloaded. The system does not flag these responses.

## The timer is advisory

`SessionQuestionRun.TimeLimitSeconds` is optional:

- the student screen shows it only as a static label (no countdown);
- nothing closes a run automatically;
- the server accepts answers until the teacher closes the run.

The value is used only for the optional speed bonus of a score policy:

```
bonus = round(MaxSpeedBonus × max(0, 1 − RT / TimeLimitSeconds))
```

The bonus applies only to correct answers, and only when the policy enables it and the run has a time limit.

## Where RT is used

- `docs/analytics.md`: median RT per concept, per format and per learning outcome,
  over evaluable responses only.
- `sql/production_stats_v2_1_queries.sql`: the column `rt` of the `resp` view uses
  the same definition, including the exclusion of null or negative values.

RT is not included in any CSV export. It can be derived from the API or the database.
