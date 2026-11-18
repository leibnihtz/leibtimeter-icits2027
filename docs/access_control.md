# Access control (v2.2.1)

## Mechanism

- **Authentication.** ASP.NET Core Identity accounts and a stateless JWT carrying
  the user id and role claims. Self-registration requires an institutional
  address ending in `.edu.pe` and creates the account as *Pending*. An
  administrator approves it (*Active*, with automatic enrollment in the requested
  course) or rejects it. Accounts created by Admin or Teacher endpoints start
  active.
- **Roles.** Admin, Teacher and Student. Endpoints first check the role
  (`[Authorize(Roles = …)]`), then the course.
- **Course scope.** The rules live in one helper class, `CourseAccess`:

| Rule | Meaning |
|---|---|
| `CanViewCourseAsync` | Admin can view any course. A Teacher can view only courses with a matching `CourseTeachers` row. Any other role is denied |
| `DenyIfNoAccessAsync` / `DenyIfNoSessionAccessAsync` | Return 403 when the course check fails. The session variant first resolves session → course (404 if the session does not exist) |
| `VisibleBanksAsync` / `VisibleQuestionsAsync` | Banks and questions of the teacher's courses (shared among the teachers of a course), plus banks and questions without a course that the teacher created |
| `DenyIfNoBankAccessAsync` / `DenyIfNoQuestionAccessAsync` | 404 if the bank or question does not exist; 403 if it is not visible |
| `DenyIfNoStudentAccessAsync` / `VisibleCourseIdsOfStudentAsync` | A teacher can see a student only if the student is enrolled in one of the teacher's courses, and only that student's data from those courses |

## Role × endpoint matrix

Legend:

- **A** = Admin.
- **T✓** = Teacher assigned to the course of the resource.
- **T✗** = Teacher not assigned (receives 403).
- **S** = Student.
- "—" = the role is rejected by the role check.

"Scoped since" is the version that added the course check. v2.0 is the version
in which the main dataset was recorded.

| Endpoint | A | T✓ | T✗ | S | Check | Scoped since | Test |
|---|---|---|---|---|---|---|---|
| `GET /api/courses/{courseId}/learning-analytics/concepts` (+ `/detail`) | ✓ | ✓ | 403 | — | `CanViewCourseAsync` | v2.0 | `LearningMetadataApiTests` |
| `GET /api/questions/metadata-suggestions` | ✓ | ✓ | 403 / own questions only | — | `CanViewCourseAsync`, or own questions when no course is given | v2.0 | `LearningMetadataApiTests` |
| `GET /api/reports/sessions/{id}` (+ `/export`) | ✓ | ✓ | 403 | — | `DenyIfNoSessionAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `GET /api/reports/courses/{id}` (+ `/export`, `/ranking`, `/ranking/export`) | ✓ | ✓ | 403 | — | `DenyIfNoAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `GET /api/sessions` | all | own courses | 403 with another course's `courseId` | — | `DenyIfNoAccessAsync`, or filter to the teacher's courses | v2.1 | `CourseScopedAccessTests.Session_list_without_courseId_returns_only_teachers_courses` |
| `GET /api/sessions/{id}` (staff) | ✓ | ✓ | 403 | see exceptions | `DenyIfNoSessionAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `POST /api/sessions`, `/{id}/start`, `/{id}/close`, `GET /{id}/qr`, `/{id}/qr/image` | ✓ | ✓ | 403 | — | `DenyIfNoAccessAsync` / `DenyIfNoSessionAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `POST /api/sessions/{id}/question-runs` (+ `/open`, `/close`) | ✓ | ✓ | 403 | — | session check (v2.1) + question visibility (v2.2) | v2.1 / v2.2 | `QuestionBankAccessTests.Teacher_cannot_add_question_from_other_course_to_own_session` |
| `GET /api/sessions/{id}/question-runs/{runId}/text-responses` | ✓ | ✓ | 403 | — | `DenyIfNoSessionAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `GET /api/courses/{id}/students` | ✓ | ✓ | 403 | — (since v2.1) | `DenyIfNoAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `POST /api/courses/{id}/enrollments`, `DELETE …/enrollments/{studentId}`, `POST …/enrollments/csv` | ✓ | ✓ | 403 | — | `DenyIfNoAccessAsync` | v2.1 | `CourseScopedAccessTests` |
| `GET /api/reports/students/{id}` | ✓ | own students, own courses only | 403 | — | `DenyIfNoStudentAccessAsync` + `VisibleCourseIdsOfStudentAsync` | v2.2 | `StudentAccessTests.Teacher_student_history_is_limited_to_own_students_and_own_courses` |
| `GET /api/students/{id}` | ✓ | own students | 403 | — | `DenyIfNoStudentAccessAsync` | v2.2 | `StudentAccessTests.Teacher_sees_detail_only_of_students_in_own_courses` |
| `GET /api/students` (no `code`) | ✓ | 400 | 400 | — | Admin only | v2.2 | `StudentAccessTests.Teacher_cannot_list_all_students` |
| `POST` / `PUT` / `DELETE /api/students` | ✓ | — | — | — | Admin only | v2.2 | `StudentAccessTests.Creating_editing_and_deleting_students_is_admin_only` |
| `GET /api/question-banks` | all | visible banks | (not listed) | — | `VisibleBanksAsync` | v2.2 | `QuestionBankAccessTests` |
| `GET` / `PUT` / `DELETE /api/question-banks/{id}`, `POST /api/question-banks` | ✓ | ✓ | 403 | — | `DenyIfNoBankAccessAsync` / `DenyIfNoAccessAsync` | v2.2 | `QuestionBankAccessTests.Teacher_gets_403_on_every_bank_action_of_other_course` |
| `GET /api/questions` | all | visible questions | (not listed) | — | `VisibleQuestionsAsync` | v2.2 | `QuestionBankAccessTests.Teacher_question_list_contains_only_visible_questions` |
| `GET` / `PUT` / `DELETE /api/questions/{id}`, options, `POST /api/questions` | ✓ | ✓ | 403 | — | `DenyIfNoQuestionAccessAsync` / `DenyIfNoBankAccessAsync` | v2.2 | `QuestionBankAccessTests.Teacher_gets_403_on_every_question_action_of_other_course` |
| `POST /api/sessions/join`, `POST /api/responses` | — | — | — | ✓ if actively enrolled | Active enrollment in the session's course (403 otherwise) | v2.0 | — |
| `GET /api/reports/students/me` | ✓ | ✓ | ✓ | ✓ | Own history only | v2.0 | — |

Administrative endpoints are role-only and have no course dimension:

- registrations, teachers, course create/update/delete, teacher assignment;
- creating, editing and deleting score policies.

The test names come from the test classes. Each row is mapped to a test class
or test name. It was not audited line by line that every verb in a row has its
own assertion.

## SignalR groups

The hub `SessionHub` (`/hubs/session`) requires an authenticated connection. The
JWT is passed as a query parameter only on `/hubs` paths. `JoinSession(sessionId)`
picks the group from the **role in the JWT**, never from client input:

| Caller | Group | Check |
|---|---|---|
| Admin, or Teacher assigned to the session's course | `session-{id}-teacher` | `CanViewCourseAsync`. An unassigned teacher gets a `HubException` and joins no group |
| Student | `session-{id}-students` | None (see exceptions) |

| Event | Payload (summary) | Teacher group | Student group |
|---|---|---|---|
| `QuestionOpened` | Question prompt and options, **without** the answer key; `OpenedAt`; time limit | ✓ | ✓ |
| `QuestionClosed` | `runId`, `ClosedAt`, correct options (answer reveal after the run closes) | ✓ | ✓ |
| `SessionClosed` | `sessionId` | ✓ | ✓ |
| `ResponseReceived` | `runId`, response count, **student id**, **free text**, format | ✓ | — |
| `ScoresUpdated` | Top-20 **student ids** and points | ✓ | — |
| `ParticipantJoined` | **Student id**, session id | ✓ | — |

Tests:

- `SessionHubGroupTests.Unassigned_teacher_cannot_join_teacher_group`;
- `SessionHubGroupTests.Private_events_go_to_teacher_group_only`;
- `SessionHubGroupTests.Student_group_never_receives_student_ids_or_texts`.

## Version history

| Version | Date | Access model |
|---|---|---|
| v2.0 | until 2026-09-27 | Role checks only, except learning analytics and metadata suggestions, which checked the course assignment. Any teacher could read any course's reports and exports. **One SignalR group per session**: student connections also received `ResponseReceived`, `ScoresUpdated` and `ParticipantJoined`, which carry classmates' internal ids and free-text answers. The student UI did not render them. **The main dataset was recorded with this version.** |
| v2.1 (`v2.1-privacy-and-fr9`) | 2026-09-27 | Course check added to reports, exports, sessions, question runs, course student lists and enrollments. Students can no longer list classmates. The SignalR hub split into teacher and student groups, with the teacher group course-checked. |
| v2.2 / v2.2.1 | 2026-09-29 | Course check extended to students, question banks, questions and a student's report history. Listing all students and creating, editing or deleting students became Admin-only. Adding a question to a session also checks that the question is visible. |

## Deliberate exceptions

These cases are not course-scoped, on purpose:

1. **Student lookup by exact code.** `GET /api/students?code=XXXX` (Teacher)
   returns the id, code and name of any **active** student with exactly that code,
   with no e-mail address and no course filter. Teachers need it to enroll a
   student who is not yet in their course. Test:
   `StudentAccessTests.Teacher_finds_active_student_by_exact_code_without_email`.
2. **Subscribing to a live session does not verify enrollment.**
   - For a student, `GET /api/sessions/{id}` and `SessionHub.JoinSession` check
     only the role.
   - A student who knows a session id can therefore read the session's questions
     and options (no answer key) and receive the student-group events:
     `QuestionOpened`, `QuestionClosed` with the correct options after a run
     closes, and `SessionClosed`.
   - The student group never receives other students' data.
   - **Joining with the code (`POST /api/sessions/join`) and answering
     (`POST /api/responses`) do require an active enrollment.** A non-enrolled
     student cannot be recorded as a participant or submit a response.

One more case is not course-scoped and does not involve student data:
`GET /api/courses/{id}` returns the course and the names and e-mail addresses of
its teachers to any authenticated user.

These rows match the `access_control` block of `data/production_stats_v2_1.json`
(`scoped_endpoints`, `unscoped_endpoints`).

## Test suite

105 xUnit tests at v2.2.1, all passing on 2026-10-05.

| Class | Tests | Scope |
|---|---|---|
| `CourseScopedAccessTests` | 10 | Course scope on reports, sessions, enrollments (v2.1) |
| `SessionHubGroupTests` | 12 | Hub groups and the target group of every event (v2.1) |
| `QuestionBankAccessTests` | 11 | Banks and questions (v2.2) |
| `StudentAccessTests` | 9 | Student data (v2.2) |
| `LearningMetadataApiTests` | 25 | Metadata and analytics endpoints, including their course check |
| `LearningAnalyticsTests` | 30 | Analytics computation (no access control) |
| `CoursesControllerTests` | 8 | Course management |

42 tests are in the four access-control classes. The analytics endpoint tests
add their own course checks.
