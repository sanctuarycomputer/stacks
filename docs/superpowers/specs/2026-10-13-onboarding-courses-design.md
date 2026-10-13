# Onboarding courses, modules and qualifications

**Date:** 2026-10-13
**Status:** Approved, ready for planning

## Problem

New people are onboarded to garden3d by hand over email. Christian sends the
GCA, sets up payment (QuickBooks Bill Pay + W-9, or Deel), creates the company
email, invites the person to Notion / Twist / Forecast and points them at the
Wayfinding page in Notion. Wayfinding says people must "fully understand" Roles
& Compensation and that failing to read the four policies can mean termination
for cause, but nothing records that anyone read anything. The email threads show
the same failures repeating: hours logged under a personal email, a QuickBooks
profile still unlinked when the first payment is due, Deel onboarding left
pending.

We want Stacks to hold a checklist each new person works through, with proof
that they did, and we want the structure to carry later courses (the next one
is "Learn to be a great Project Lead") and the qualifications they lead to.

## Decisions already made (by Hugh, 2026-10-13)

- **Notion owns content, Stacks owns structure and proof.** A step in Stacks is
  a title, a link to Notion, and a way of proving it's done. Stacks never
  renders Notion page bodies.
- **Module is the atomic unit; a course is an ordered list of modules.** Two
  courses may share a module.
- **Completing a course grants a qualification; completing a module may grant a
  badge.** Neither expires or unlocks anything in Stacks in this build.
- **A quiz pass is the proof of understanding.** Questions and answers live in
  Stacks. A person gets **two attempts** (one retry); further attempts must be
  granted by an admin.
- **Audience:** every newly discovered company-email person is assigned the
  courses flagged for auto-assignment. Existing people are not assigned
  anything automatically.
- **Grace period** lives on the assignment, defaulting to 14 calendar days.
- **Overdue assignments become pending tasks.** The pending-task pill on the
  payables screen is the whole payout "block"; no code refuses a payout.
- **Sign-off steps are completed by any admin.**
- **Only admins can see a person's progress.** The person sees their own.
- **Framing:** the person-facing interface reads as getting set up, not as
  training (see "Language").
- **Build only the Wayfinding course now**, but the structure must fit the
  Project Lead course.

## Non-goals

- Rendering or syncing Notion content; detecting that a Notion page changed.
- Versioning of modules, or re-requesting acknowledgement after an edit.
- Prerequisites between courses or modules.
- Expiry or renewal of qualifications; qualifications unlocking permissions.
- Logins for people without a company email.
- File uploads (GCA, W-9). Proof of those stays a sign-off or an auto-check.
- Hard-blocking payouts in code.
- MCP tools for any of this.
- Notifying a person at the moment of assignment (see "Open follow-ups").

## Vocabulary and naming

`Module` is a Ruby core class, so the model cannot be called `Module`.

| Concept | Model | Table |
|---|---|---|
| Course | `Course` | `courses` |
| Module | `LearningModule` | `learning_modules` |
| Course ↔ module join | `CourseModule` | `course_modules` |
| Step in a module | `ModuleStep` | `module_steps` |
| Quiz question | `QuizQuestion` | `quiz_questions` |
| Assignment of a course to a person | `CourseAssignment` | `course_assignments` |
| A person finished a step | `StepCompletion` | `step_completions` |
| A person's quiz attempt | `QuizAttempt` | `quiz_attempts` |
| Admin allows more attempts | `QuizRetryGrant` | `quiz_retry_grants` |
| A person finished a module | `ModuleCompletion` | `module_completions` |
| Qualification or badge definition | `Qualification` | `qualifications` |
| A person holds one | `QualificationGrant` | `qualification_grants` |

Non-model logic lives under `lib/stacks/learning/` as `Stacks::Learning::*`,
matching the existing `lib/stacks` layout.

### Language

Admin screens and code say course, module, quiz, qualification. Everything the
assigned person sees avoids "course", "lesson", "training", "learner" and
"quiz":

| Admin word | Person sees |
|---|---|
| Course assignment | the course's `learner_title` (Wayfinding: "Getting on board at garden3d") |
| Module | a headed group of steps |
| Step | a checklist item phrased as an action |
| Quiz | "Quick check" |
| Qualification / badge | shown by name under "Badges" on their profile |

## Data model

All tables get `created_at` / `updated_at`. All foreign keys are indexed and
`null: false` unless marked optional.

**`qualifications`** — `name` (string, unique, required), `description` (text),
`kind` (string, `qualification` or `badge`, required).

**`courses`** — `name` (unique, required), `slug` (unique, required),
`learner_title` (required; what the assigned person sees), `description`
(text, Markdown), `grace_period_days` (integer, default 14, must be ≥ 1),
`auto_assign` (boolean, default false), `qualification_id` (optional).

**`learning_modules`** — `name` (required), `slug` (unique, required),
`summary` (text, Markdown), `notion_url` (string, optional; the module's home
page in Notion), `quiz_pass_percent` (integer, default 80, 1–100),
`qualification_id` (optional; the badge this module grants).

**`course_modules`** — `course_id`, `learning_module_id`, `position` (integer,
required). Unique on `[course_id, learning_module_id]`.

**`module_steps`** — `learning_module_id`, `position`, `kind` (string,
required), `title` (required), `notion_url` (optional), `auto_check_key`
(string; required when `kind` is `auto_check`, must be a registered key, blank
otherwise).

Step kinds:

| Kind | Completed by | How |
|---|---|---|
| `read` | the person | opens the Notion link, ticks it |
| `do` | the person | does the thing, ticks it |
| `auto_check` | Stacks | a registered check returns true |
| `admin_sign_off` | any admin other than the person | button on the checklist page |

**`quiz_questions`** — `learning_module_id`, `position`, `prompt` (text,
required), `choices` (jsonb array of 2–6 non-blank strings), `correct_index`
(integer, within `choices`), `explanation` (text, optional). A module "has a
quiz" when it has at least one question.

**`course_assignments`** — `admin_user_id`, `course_id`, `assigned_on` (date),
`due_on` (date), `assigned_by_id` (optional; null means auto-assigned),
`completed_at` (datetime, optional), `waived_at` (optional), `waived_by_id`
(optional), `waive_note` (text). Unique on `[admin_user_id, course_id]`.
`due_on` defaults to `assigned_on + course.grace_period_days` when blank.

**`step_completions`** — `admin_user_id`, `module_step_id`, `completed_at`,
`completed_by_id` (optional; set for sign-offs), `source` (string: `self`,
`auto`, `admin`). Unique on `[admin_user_id, module_step_id]`.

**`quiz_attempts`** — `admin_user_id`, `learning_module_id`, `answers` (jsonb:
question id → chosen index), `correct_count`, `question_count`, `passed`
(boolean).

**`quiz_retry_grants`** — `admin_user_id`, `learning_module_id`,
`granted_by_id`, `note`. Each row allows one more attempt.

**`module_completions`** — `admin_user_id`, `learning_module_id`,
`completed_at`. Unique on `[admin_user_id, learning_module_id]`.

**`qualification_grants`** — `admin_user_id`, `qualification_id`, `granted_at`,
`granted_by_id` (optional; null means earned), `note`. Unique on
`[admin_user_id, qualification_id]`.

Deleting an `AdminUser` destroys their assignments, completions, attempts,
retry grants and qualification grants (`Stacks::Team.discover!` destroys users
on foreign domains). Deleting a course, module, step or qualification that has
any assignment, completion, attempt or grant is refused (`restrict_with_error`).

## Rules

### Progress belongs to the person, not the assignment

`StepCompletion`, `QuizAttempt` and `ModuleCompletion` reference the person and
the step or module. A module finished through one course is finished in every
course that includes it.

### Progress is sticky

Completions are only ever added. If a QuickBooks profile is later unlinked, or
an admin adds a step to a module someone already finished, nothing is
un-completed. The existing `missing_qbo_vendor_for_contributor` task covers the
former.

### When things are done

- A **step** is done when a `StepCompletion` exists.
- A **module** is done when a `ModuleCompletion` exists. One is created when
  every step of the module is done **and** (the module has no questions **or**
  the person has a passed attempt).
- An **assignment** is done when `completed_at` is set. It is set when every
  module of the course is done.
- When a module is done and has a `qualification_id`, the badge is granted.
  When an assignment is done and its course has a `qualification_id`, the
  qualification is granted. Grants are idempotent (unique index); an existing
  grant, including a manual one, is left untouched.

### `Stacks::Learning::Progress.refresh!(admin_user)`

One idempotent service applies all of the above for one person, in order:

1. For each incomplete `auto_check` step in any module of any of the person's
   open assignments, run the check; if true, create a `StepCompletion` with
   `source: "auto"`.
2. Create missing `ModuleCompletion`s and their badge grants.
3. Set `completed_at` on assignments whose modules are all done, and grant the
   course qualification.

It is called after a person ticks a step, after a quiz attempt, after an admin
sign-off, after an assignment is created, from a "Check again" button on the
checklist page, and for every person with an open assignment in the daily
`stacks:daily_tasks` run (before `TaskBuilder#refresh!`, isolated in its own
`begin/rescue` with Sentry capture like its neighbours). A check that raises is
logged, captured and treated as false; it never fails the refresh.

An "open" assignment is one with neither `completed_at` nor `waived_at`.

### Auto-checks

`Stacks::Learning::AutoChecks` is a frozen registry of key → label + lambda
taking an `AdminUser`:

| Key | True when |
|---|---|
| `forecast_account` | `admin_user.forecast_person` is present |
| `payment_profile` | the person's `Contributor` has a `deel_person_id` or at least one `ContributorQboVendor` |
| `human_operating_manual` | a Human Operating Manual in the Notion mirror lists their email (same match as the existing discovery: downcased email) |

`ModuleStep` validates `auto_check_key` against the registry's keys. The admin
form offers the registry as a select.

### Ticking a step

A person may tick `read` and `do` steps of modules in their own open
assignments, in any order. They can never complete an `auto_check` or
`admin_sign_off` step. Ticking is one-way; there is no untick.

### Quizzes

- The quick check for a module opens only when every step of the module is
  done.
- **Attempts allowed = 2 + number of `QuizRetryGrant`s** for that person and
  module. When attempts are used up and none passed, the module is **locked**:
  the person sees "You're out of attempts. Ask an admin to allow another." and
  no form.
- A person with a passed attempt cannot attempt again.
- Submitting requires an answer to every question. An incomplete submission is
  rejected with an error and **does not count** as an attempt.
- Score = correct / total questions at submission time. Passed when
  `correct * 100 >= quiz_pass_percent * total`.
- The attempt count is checked and the attempt inserted inside a transaction
  holding a row lock on the person's `AdminUser` row, so a double-submit cannot
  exceed the allowance.
- **After a failed attempt** the person sees only their score and the pass
  mark — not which questions were wrong and not the correct answers.
  **After a pass** they see each question's explanation.
- Choices render in a per-request shuffled order; the form submits the
  original index.
- Correct answers never reach a non-admin: the quiz page renders prompts and
  choices only, and `QuizQuestion` is an admin-only resource.

### Admin sign-off

A sign-off step is **ready** when every earlier step in its module is done and
every earlier module in the course (by `position`) is done. Only ready
sign-offs show a "Sign off" button and produce an admin task. An admin cannot
sign off a step on their own assignment. Signing creates a `StepCompletion`
with `source: "admin"` and `completed_by` set.

### Assignment

- `AdminUser` gains `after_create :assign_auto_assigned_courses!`, which
  creates a `CourseAssignment` for every `Course.where(auto_assign: true)`.
  This covers both discovery paths (`Stacks::Team.discover!` and first Google
  sign-in). Failures are rescued, logged and captured so they can never block
  account creation.
- Because it runs only on create, people who already exist get nothing.
- Admins can assign any course to anyone by hand, edit `due_on`, and **waive**
  an assignment (records who and when, with a note). A waived assignment
  produces no tasks and grants nothing.
- Wayfinding is seeded with `auto_assign: false`. Hugh turns it on once the
  quiz questions are reviewed.

### Tasks

Two new `StacksTask` types, produced by a new discovery
`Stacks::TaskBuilder::Discoveries::CourseAssignments`, both with the
`CourseAssignment` as subject:

| Type | Label | Owners | Emitted when |
|---|---|---|---|
| `course_assignment_overdue` | "Onboarding checklist is overdue" | the person | assignment is open, `due_on < Date.today`, the person is `active.not_ignored`, and the person has something of their own left to do |
| `course_assignment_needs_admin_sign_off` | "Onboarding checklist needs an admin sign-off" | all admins except the assignee | assignment is open and has at least one ready, incomplete sign-off step |

"Something of their own left to do" means an incomplete `read`, `do` or
`auto_check` step, or a module whose steps are done but whose quiz is not
passed. A person waiting only on an admin sign-off is not overdue, so an
admin's delay never puts a pill on someone's payout.

Both link to the checklist page. `StacksTask#subject_display_name` shows
"`<email>` — `<course name>`". `CourseAssignment`, `StepCompletion`,
`QuizAttempt`, `QuizRetryGrant` and `ModuleCompletion` include
`BustsTaskCache`. Date-driven transitions (becoming overdue) are picked up by
the existing daily `TaskBuilder#refresh!`.

Before the due date an assignment is not a task. It shows only on the profile.

Known and accepted: an overdue task is visible wherever tasks are (the
`/admin/tasks` page leads can see, the `list_open_admin_tasks` MCP tool, the
payables pill). That reveals "this person's checklist is overdue" but none of
the detail.

## Screens

### The person's profile (`app/views/admin/admin_users/_show.html.erb`)

A new dashboard module, rendered only when the viewer is an admin or is the
person themselves, and only when the person has at least one assignment:

- One row per assignment: the course's `learner_title`, "n of m steps done",
  the due date (or "Done" / "Waived"), and a link to the checklist.
- A "Badges" line listing the names of the person's qualification grants, if
  any.

### The checklist page (`CourseAssignment` show)

Registered as an ActiveAdmin resource (`app/admin/course_assignments.rb`), show
page rendered by an ERB partial. For each module in order: its name, summary
(Markdown via `RDiscount` in `.markdown-body`, as elsewhere), then its steps:

- `read` / `do`: title, "Open in Notion ↗" link (new tab), and a "Mark as
  done" button (POST) or a done tick with the date.
- `auto_check`: done tick, or "Not yet — Stacks checks this automatically".
- `admin_sign_off`: done tick with who signed, or "Waiting on an admin"; admins
  see a "Sign off" button when it is ready.
- Then, if the module has a quiz: "Quick check" with its state — not yet open,
  open (link to the quiz page), passed, or locked.

Page-level: a "Check again" button (runs `refresh!`), and for admins "Waive"
and, on a locked module, "Allow another attempt".

Member actions on `CourseAssignment`:

| Action | Verb | Who |
|---|---|---|
| `complete_step` (`step_id`) | POST | the assignee |
| `quiz` (`learning_module_id`) | GET | the assignee |
| `submit_quiz` (`learning_module_id`, `answers`) | POST | the assignee |
| `recheck` | POST | the assignee, admins |
| `sign_off_step` (`step_id`) | POST | admins, not the assignee |
| `grant_quiz_retry` (`learning_module_id`, `note`) | POST | admins |
| `waive` (`waive_note`) | POST | admins |

Every action re-verifies in the controller that the step or module belongs to
this assignment's course, and that the acting user is allowed, independent of
the authorization adapter.

### Admin authoring

ActiveAdmin resources, admin-only, under a new "Onboarding" menu:

- **Courses**: fields above, plus ordered modules (nested `course_modules`
  with position).
- **Modules**: fields above, plus nested steps and nested quiz questions
  (choices edited as one-per-line text).
- **Qualifications**: name, description, kind.
- **Course Assignments**: index across people (person, course, assigned, due,
  state, steps done); `new` to assign by hand; `edit` for `due_on`.
- **Qualification Grants**: index, and `new` to grant by hand
  (`granted_by` stamped server-side).

## Authorization

`AdminAuthorization#authorized?` ends with a blanket grant to anyone who can
act as a lead, so every new class needs a carve-out **above** that line:

- `Course`, `LearningModule`, `CourseModule`, `ModuleStep`, `QuizQuestion`,
  `Qualification`, `QualificationGrant`, `QuizAttempt`, `QuizRetryGrant`,
  `StepCompletion`, `ModuleCompletion` (class or instance): admins only.
- `CourseAssignment`: admins may do anything. A non-admin may perform only
  `:read`, `:complete_step`, `:quiz`, `:submit_quiz` and `:recheck`, and only
  on an instance whose `admin_user_id` is their own. Class-level checks for
  non-admins are false, so they get no index and no menu item; they reach
  their checklist from their profile.

The profile module is hidden from leads viewing someone else's profile.

## Wayfinding: the first course

Seeded by an idempotent rake task, `stacks:seed_wayfinding_course`, from
`db/seeds/learning/wayfinding.yml`. Rows are matched by slug (course, module),
name (qualification) and position within their module (steps, questions). An
existing row is never updated, so edits made in the admin survive a re-run.
`auto_assign` is false. Qualification: **Onboarded to garden3d**.

| # | Module (slug) | Steps | Quiz | Badge |
|---|---|---|---|---|
| 1 | Paperwork and payment (`paperwork-and-payment`) | sign-off: GCA signed and returned; auto: payment profile linked | no | — |
| 2 | Your accounts (`your-accounts`) | auto: Forecast account under your company email; do: sign in to Twist; do: set up 1Password; do: set up your Notion task board | no | — |
| 3 | How you get paid (`how-you-get-paid`) | read: Roles & Compensation; read: pay when paid; read: time tracking; read: how to draw payment | yes | How you get paid |
| 4 | Policies (`policies`) | read ×4, one per policy page | yes | Policies |
| 5 | How we communicate (`how-we-communicate`) | read: who to ask; read: company meetings; read: How to Be; do: post your intro in Twist; auto: Human Operating Manual | yes | How we communicate |
| 6 | Onboarding sign-off (`onboarding-sign-off`) | sign-off: an admin confirms setup is complete | no | — |

Each quiz has 5 questions at an 80% pass mark (4 of 5). Questions are drafted
from the linked Notion pages and test facts and procedures a person needs
(for example when hours become final, when payment is released, where to ask
a payments question), not trivia. Every step's `notion_url` is the URL of the
real Notion page or section it refers to.

## How the Project Lead course fits

No extra structure is needed: its reading list becomes `read` steps, its
"shadow for six weeks" and experience milestones become `admin_sign_off`
steps, its quizzes are quizzes, and it can reuse `how-we-communicate`.
Its prerequisites are out of scope.

## Testing

Minitest, following the repo's conventions (records built in-test, mocha for
stubs, integration tests with Devise helpers).

- **Models:** validations (step kinds, `auto_check_key`, choices /
  `correct_index`, uniqueness, `due_on` default).
- **`Progress.refresh!`:** auto-check completes a step; a raising check is
  treated as false; module completes with and without a quiz; a shared module
  counts in two courses; assignment completes; qualification and badge are
  granted once; a manual grant is untouched; adding a step later does not
  un-complete; waived assignments are skipped.
- **Quiz attempts:** pass at exactly the pass mark; third attempt refused;
  a retry grant allows exactly one more; incomplete submission does not count;
  no attempt after a pass; quiz closed until steps are done.
- **Discovery:** not overdue before `due_on`; overdue after; not overdue when
  only a sign-off remains; inactive or ignored people skipped; waived and
  completed skipped; sign-off task only when ready and never owned by the
  assignee.
- **Auto-assign:** creating an `AdminUser` assigns `auto_assign` courses and
  not others; a failure inside does not prevent creation.
- **Integration (authorization), each with a positive control:**
  - a non-admin sees their own checklist, ticks a step, takes the quiz;
  - a non-admin cannot see, tick or submit on someone else's;
  - a past project lead (global `lead` grant) cannot see someone else's
    checklist, the assignments index, or any authoring resource, and does not
    see the profile module on someone else's profile;
  - a non-admin cannot tick an `auto_check` or `admin_sign_off` step, sign
    off, grant a retry or waive;
  - an admin can sign off, grant a retry and waive, and cannot sign off their
    own;
  - the quiz page and a failed result contain no correct-answer or
    explanation text.
- **Seed:** running the task twice creates each row once; an edited row is not
  overwritten; every `auto_check_key` in the YAML is registered.

## Rollout

Migrations are manual in this app: after the deploy lands, run `db:migrate`,
then `heroku restart` (the `admin_users` show page reads new associations).
Then run `stacks:seed_wayfinding_course`. Nothing is assigned to anyone until
`auto_assign` is switched on or an admin assigns by hand.

`db/schema.rb` is hand-curated; edit it by hand and never dump it.

## Open follow-ups (not in this build)

- Telling a person they have a checklist at the moment it is assigned. Today
  they find it on their profile, which is their Stacks home page; Christian's
  welcome email should point there.
- A task for admins when someone is locked out of a quiz. For now the person
  asks, as Hugh specified.
- Legal review (Max) of mandatory, payout-gated onboarding for contractors.
