# Onboarding Courses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Stacks courses made of reusable modules (steps + a limited-attempt quiz), assign them to people with a due date, surface overdue ones as pending tasks, and grant qualifications and badges on completion; seed the first course, Wayfinding.

**Architecture:** Twelve small ActiveRecord models hold structure (course → modules → steps/questions) and per-person proof (step completions, quiz attempts, module completions, grants). All rules live in four plain Ruby classes under `lib/stacks/learning/` (`AutoChecks`, `Checklist`, `Progress`, `Quiz`); ActiveAdmin resources and one TaskBuilder discovery are thin callers of those. Content stays in Notion; Stacks stores only titles, Notion URLs and quiz questions.

**Tech Stack:** Rails 6.1.7, Ruby 3.1, ActiveAdmin 2.9 (Arbre + ERB partials), Postgres, Minitest + mocha. No new gems.

**Spec:** `docs/superpowers/specs/2026-10-13-onboarding-courses-design.md` — read it before starting any task; it is the source of truth for behaviour.

## Global Constraints

- **Work only in the worktree** `/Users/hhff/Documents/Code/stacks/.worktrees/onboarding-courses`. Never `cd` to `/Users/hhff/Documents/Code/stacks`. Before every commit run `git rev-parse --abbrev-ref HEAD`; it must print `feat/onboarding-courses`. If it does not, stop and report BLOCKED.
- **Every Rails command is prefixed** with `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test` (a private test database that already exists and already has the base schema). Never run anything against `stacks_development` or `stacks_test`.
- **Never run the whole suite** inside a task; run the test files the task names. Never run `test/lib/tasks/etl_rake_test.rb` (it makes a live network call and hangs).
- **`db/schema.rb` is hand-curated.** Never commit a dumped schema. Task 1 gives the exact procedure.
- **Model name:** `Module` is a Ruby core class; the model is `LearningModule`. Scope/predicate for an assignment that is neither completed nor waived is `outstanding` / `outstanding?` (not `open`, which collides with `Kernel#open`).
- **Ordering:** steps, questions and course modules are always ordered by `(position, id)`.
- **Person-facing copy never uses** the words "course", "lesson", "training", "learner" or "quiz". A quiz is a "Quick check". Admin screens may use those words.
- **Quiz attempts allowed = 2 + retry grants.** Pass when `correct * 100 >= quiz_pass_percent * total`.
- **Correct answers and explanations never render for a non-admin who has not passed.**
- **All POST actions on a checklist are refused while `impersonating?`.** Admins cannot act on their own assignment.
- Commit messages end with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` exactly (do not substitute your own model name).
- Match the surrounding code's style: 2-space indent, double-quoted strings in app code, comments only where they explain a non-obvious why.

## File Structure

| File | Responsibility |
|---|---|
| `db/migrate/20261013120000_create_learning_tables.rb` | all 12 tables |
| `db/schema.rb` | hand-add the 12 tables, FKs, version |
| `app/models/{qualification,course,learning_module,course_module,module_step,quiz_question,course_assignment,step_completion,quiz_attempt,quiz_retry_grant,module_completion,qualification_grant}.rb` | associations + validations only |
| `app/models/admin_user.rb` | associations, auto-assign callback |
| `lib/stacks/learning/auto_checks.rb` | registry of automatic checks |
| `lib/stacks/learning/checklist.rb` | read-only state of one assignment (what's done, quiz state, readiness) |
| `lib/stacks/learning/progress.rb` | idempotent writer: completes auto-checks, modules, assignments, grants |
| `lib/stacks/learning/quiz.rb` | takes one quiz submission, enforces the attempt limit |
| `lib/stacks/learning/seeder.rb` | idempotent YAML → rows |
| `lib/stacks/task_builder/discoveries/course_assignments.rb` | the two task types |
| `lib/stacks/task_builder.rb`, `app/models/stacks_task.rb` | plumbing + live re-validation |
| `app/models/admin_authorization.rb` | carve-outs |
| `app/admin/course_assignments.rb` + `app/views/admin/course_assignments/{_show,quiz}.html.erb` | checklist page, quiz page, member actions |
| `app/admin/{courses,learning_modules,qualifications,qualification_grants}.rb` | admin authoring |
| `app/views/admin/admin_users/_learning.html.erb` (+ one line in `_show.html.erb`) | profile module |
| `db/seeds/learning/wayfinding.yml`, `lib/tasks/stacks.rake` | seed + daily refresh |

Shared test helper used by every task (created in Task 1): `test/support/learning_test_helpers.rb`.

---

### Task 1: Tables and models

**Files:**
- Create: `db/migrate/20261013120000_create_learning_tables.rb`
- Modify: `db/schema.rb`
- Create: the 12 model files listed above
- Modify: `app/models/admin_user.rb` (associations only, next to the other `has_many` lines near the top)
- Create: `test/support/learning_test_helpers.rb`
- Test: `test/models/learning_models_test.rb`

**Interfaces — Produces** (later tasks rely on these exact names):
- Models and columns exactly as in the migration below.
- `CourseAssignment.outstanding` scope, `#outstanding?`, `#waived?`, `#completed?`.
- `Course#ordered_modules` → `Array<LearningModule>`; `LearningModule#module_steps` and `#quiz_questions` are ordered associations.
- `QuizQuestion#choices_text` / `#choices_text=` (one choice per line).
- `ModuleStep::KINDS = %w[read do auto_check admin_sign_off]`.
- `AdminUser#course_assignments`, `#step_completions`, `#quiz_attempts`, `#quiz_retry_grants`, `#module_completions`, `#qualification_grants`.
- Test helpers: `learning_person!`, `learning_module!`, `learning_course!`, `learning_assign!`, `complete_step!`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20261013120000_create_learning_tables.rb
class CreateLearningTables < ActiveRecord::Migration[6.1]
  def change
    create_table :qualifications do |t|
      t.string :name, null: false
      t.text :description
      t.string :kind, null: false, default: "qualification"
      t.timestamps
      t.index :name, unique: true
    end

    create_table :courses do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :learner_title, null: false
      t.text :description
      t.integer :grace_period_days, null: false, default: 14
      t.boolean :auto_assign, null: false, default: false
      t.references :qualification, foreign_key: true
      t.timestamps
      t.index :name, unique: true
      t.index :slug, unique: true
    end

    create_table :learning_modules do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :summary
      t.string :notion_url
      t.integer :quiz_pass_percent, null: false, default: 80
      t.references :qualification, foreign_key: true
      t.timestamps
      t.index :slug, unique: true
    end

    create_table :course_modules do |t|
      t.references :course, null: false, foreign_key: true
      t.references :learning_module, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index [:course_id, :learning_module_id], unique: true
    end

    create_table :module_steps do |t|
      t.references :learning_module, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :kind, null: false
      t.string :title, null: false
      t.string :notion_url
      t.string :auto_check_key
      t.timestamps
    end

    create_table :quiz_questions do |t|
      t.references :learning_module, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.text :prompt, null: false
      t.jsonb :choices, null: false, default: []
      t.integer :correct_index, null: false
      t.text :explanation
      t.timestamps
    end

    create_table :course_assignments do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :course, null: false, foreign_key: true
      t.date :assigned_on, null: false
      t.date :due_on, null: false
      t.references :assigned_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.datetime :completed_at
      t.datetime :waived_at
      t.references :waived_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.text :waive_note
      t.timestamps
      t.index [:admin_user_id, :course_id], unique: true
    end

    create_table :step_completions do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :module_step, null: false, foreign_key: true
      t.datetime :completed_at, null: false
      t.references :completed_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.string :source, null: false
      t.timestamps
      t.index [:admin_user_id, :module_step_id], unique: true
    end

    create_table :quiz_attempts do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :learning_module, null: false, foreign_key: true
      t.jsonb :answers, null: false, default: {}
      t.integer :correct_count, null: false
      t.integer :question_count, null: false
      t.boolean :passed, null: false, default: false
      t.timestamps
    end

    create_table :quiz_retry_grants do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :learning_module, null: false, foreign_key: true
      t.references :granted_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.text :note
      t.timestamps
    end

    create_table :module_completions do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :learning_module, null: false, foreign_key: true
      t.datetime :completed_at, null: false
      t.timestamps
      t.index [:admin_user_id, :learning_module_id], unique: true
    end

    create_table :qualification_grants do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :qualification, null: false, foreign_key: true
      t.datetime :granted_at, null: false
      t.references :granted_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.text :note
      t.timestamps
      t.index [:admin_user_id, :qualification_id], unique: true
    end
  end
end
```

- [ ] **Step 2: Migrate the private test DB and hand-edit `db/schema.rb`**

Migrating dumps `db/schema.rb`, and that dump contains changes that must NOT be committed (it re-adds things the file deliberately omits). So: take the dump, revert the file, then copy across only this task's parts.

```bash
DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails db:migrate
cp db/schema.rb /tmp/onboarding_courses_schema_dump.rb
git checkout db/schema.rb
```

Then edit `db/schema.rb` by hand, copying from `/tmp/onboarding_courses_schema_dump.rb`:
1. The version line becomes `ActiveRecord::Schema.define(version: 2026_10_13_120000) do`.
2. Each of the 12 `create_table "..."` blocks, inserted in the alphabetical position the dump has them in.
3. Each `add_foreign_key` line whose first argument is one of the 12 new tables, inserted in the dump's (alphabetical) position among the existing `add_foreign_key` lines.

Verify nothing else changed:

```bash
git diff --stat db/schema.rb          # one file, insertions only apart from the version line
git diff db/schema.rb | grep '^-' | grep -v '^---'   # prints exactly one line: the old version line
```

- [ ] **Step 3: Write the shared test helpers**

```ruby
# test/support/learning_test_helpers.rb
# Builders for the onboarding-course models. Included into every test case.
module LearningTestHelpers
  # A plain company-email person (not an admin, no full-time period).
  def learning_person!(prefix: "newbie", roles: [])
    AdminUser.create!(email: "#{prefix}#{SecureRandom.hex(4)}@sanctuary.computer",
                      password: "password12345", password_confirmation: "password12345",
                      roles: roles)
  end

  # steps: array of kinds or [kind, auto_check_key] pairs. questions: how many
  # (each has 4 choices, correct_index 0).
  def learning_module!(slug: "m-#{SecureRandom.hex(4)}", steps: ["read"], questions: 0,
                       pass_percent: 80, qualification: nil)
    mod = LearningModule.create!(name: slug.titleize, slug: slug, quiz_pass_percent: pass_percent,
                                 qualification: qualification)
    steps.each_with_index do |spec, i|
      kind, key = Array(spec)
      mod.module_steps.create!(position: i, kind: kind, title: "#{kind} #{i}", auto_check_key: key)
    end
    questions.times do |i|
      mod.quiz_questions.create!(position: i, prompt: "Question #{i}?",
                                 choices: %w[right wrong1 wrong2 wrong3], correct_index: 0,
                                 explanation: "Because #{i}.")
    end
    mod.reload
  end

  def learning_course!(modules:, slug: "c-#{SecureRandom.hex(4)}", auto_assign: false, qualification: nil)
    course = Course.create!(name: slug.titleize, slug: slug, learner_title: "Getting on board (#{slug})",
                            auto_assign: auto_assign, qualification: qualification)
    modules.each_with_index { |m, i| course.course_modules.create!(learning_module: m, position: i) }
    course.reload
  end

  def learning_assign!(person, course, assigned_on: Date.today, due_on: nil)
    CourseAssignment.create!(admin_user: person, course: course, assigned_on: assigned_on, due_on: due_on)
  end

  def complete_step!(person, step, source: "self", by: nil)
    StepCompletion.create!(admin_user: person, module_step: step, completed_at: Time.current,
                           source: source, completed_by: by)
  end
end

ActiveSupport::TestCase.include(LearningTestHelpers)
```

(`test/test_helper.rb` already requires everything under `test/support/`.)

- [ ] **Step 4: Write the failing model tests**

```ruby
# test/models/learning_models_test.rb
require "test_helper"

class LearningModelsTest < ActiveSupport::TestCase
  test "a step's kind must be one of the four kinds" do
    mod = learning_module!(steps: [])
    step = mod.module_steps.build(position: 0, kind: "watch", title: "x")
    assert_not step.valid?
    assert_includes step.errors[:kind], "is not included in the list"
  end

  test "an auto_check step needs a registered key, and other kinds must not have one" do
    mod = learning_module!(steps: [])
    assert_not mod.module_steps.build(position: 0, kind: "auto_check", title: "x").valid?
    assert_not mod.module_steps.build(position: 0, kind: "auto_check", title: "x", auto_check_key: "nope").valid?
    assert mod.module_steps.build(position: 0, kind: "auto_check", title: "x", auto_check_key: "forecast_account").valid?
    assert_not mod.module_steps.build(position: 0, kind: "read", title: "x", auto_check_key: "forecast_account").valid?
  end

  test "a question needs 2-6 non-blank choices and a correct_index inside them" do
    mod = learning_module!(steps: [])
    base = { position: 0, prompt: "?" }
    assert_not mod.quiz_questions.build(base.merge(choices: ["only"], correct_index: 0)).valid?
    assert_not mod.quiz_questions.build(base.merge(choices: ["a", ""], correct_index: 0)).valid?
    assert_not mod.quiz_questions.build(base.merge(choices: %w[a b], correct_index: 2)).valid?
    assert_not mod.quiz_questions.build(base.merge(choices: %w[a b c d e f g], correct_index: 0)).valid?
    assert mod.quiz_questions.build(base.merge(choices: %w[a b], correct_index: 1)).valid?
  end

  test "choices_text round-trips one choice per line and drops blank lines" do
    q = QuizQuestion.new(choices_text: "one\n\n two \nthree\n")
    assert_equal %w[one two three], q.choices
    assert_equal "one\ntwo\nthree", q.choices_text
  end

  test "an assignment defaults assigned_on to today and due_on to the course's grace period" do
    course = learning_course!(modules: [learning_module!])
    course.update!(grace_period_days: 14)
    a = CourseAssignment.create!(admin_user: learning_person!, course: course)
    assert_equal Date.today, a.assigned_on
    assert_equal Date.today + 14, a.due_on
  end

  test "a person can be assigned a course only once" do
    course = learning_course!(modules: [learning_module!])
    person = learning_person!
    learning_assign!(person, course)
    assert_raises(ActiveRecord::RecordInvalid) { learning_assign!(person, course) }
  end

  test "outstanding excludes completed and waived assignments" do
    course = learning_course!(modules: [learning_module!])
    open_a = learning_assign!(learning_person!, course)
    done = learning_assign!(learning_person!, course)
    done.update!(completed_at: Time.current)
    waived = learning_assign!(learning_person!, course)
    waived.update!(waived_at: Time.current)
    assert_equal [open_a], CourseAssignment.outstanding.where(course: course).to_a
    assert open_a.outstanding?
    assert_not done.outstanding?
    assert_not waived.outstanding?
  end

  test "ordered_modules and module_steps come back by position then id" do
    a = learning_module!(steps: [])
    b = learning_module!(steps: [])
    course = Course.create!(name: "Ordered", slug: "ordered", learner_title: "x")
    course.course_modules.create!(learning_module: a, position: 2)
    course.course_modules.create!(learning_module: b, position: 1)
    assert_equal [b, a], course.reload.ordered_modules
    s2 = a.module_steps.create!(position: 5, kind: "read", title: "later")
    s1 = a.module_steps.create!(position: 1, kind: "read", title: "sooner")
    assert_equal [s1, s2], a.reload.module_steps.to_a
  end

  test "a step with completions cannot be destroyed" do
    mod = learning_module!(steps: ["read"])
    step = mod.module_steps.first
    complete_step!(learning_person!, step)
    assert_not step.destroy
    assert ModuleStep.exists?(step.id)
  end

  test "destroying a person removes their own progress and nulls where they were the actor" do
    badge = Qualification.create!(name: "Badge #{SecureRandom.hex(3)}", kind: "badge")
    mod = learning_module!(steps: ["admin_sign_off"], questions: 1)
    course = learning_course!(modules: [mod])
    leaver = learning_person!(prefix: "leaver", roles: ["admin"])
    other = learning_person!(prefix: "other")

    # leaver's own rows
    own = learning_assign!(leaver, course)
    QuizAttempt.create!(admin_user: leaver, learning_module: mod, correct_count: 0, question_count: 1)
    ModuleCompletion.create!(admin_user: leaver, learning_module: mod, completed_at: Time.current)
    # rows where leaver was the actor on someone else
    theirs = learning_assign!(other, course)
    theirs.update!(assigned_by: leaver, waived_by: leaver, waived_at: Time.current)
    sc = complete_step!(other, mod.module_steps.first, source: "admin", by: leaver)
    retry_grant = QuizRetryGrant.create!(admin_user: other, learning_module: mod, granted_by: leaver)
    grant = QualificationGrant.create!(admin_user: other, qualification: badge, granted_at: Time.current, granted_by: leaver)

    leaver.destroy!

    assert_not CourseAssignment.exists?(own.id)
    assert_equal 0, QuizAttempt.where(admin_user_id: leaver.id).count
    assert_equal 0, ModuleCompletion.where(admin_user_id: leaver.id).count
    assert_nil theirs.reload.assigned_by_id
    assert_nil theirs.waived_by_id
    assert_nil sc.reload.completed_by_id
    assert_nil retry_grant.reload.granted_by_id
    assert_nil grant.reload.granted_by_id
  end
end
```

- [ ] **Step 5: Run to verify it fails**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/models/learning_models_test.rb`
Expected: errors such as `NameError: uninitialized constant LearningModule`.

- [ ] **Step 6: Write the models**

```ruby
# app/models/qualification.rb
# Something a person can hold: a "qualification" (granted by finishing a
# course) or a "badge" (granted by finishing a module). Nothing expires and
# nothing is unlocked by holding one.
class Qualification < ApplicationRecord
  KINDS = %w[qualification badge].freeze

  has_many :qualification_grants, dependent: :restrict_with_error
  has_many :courses, dependent: :restrict_with_error
  has_many :learning_modules, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  def display_name
    name
  end
end
```

```ruby
# app/models/course.rb
class Course < ApplicationRecord
  belongs_to :qualification, optional: true
  has_many :course_modules, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :course
  has_many :learning_modules, through: :course_modules
  has_many :course_assignments, dependent: :restrict_with_error
  accepts_nested_attributes_for :course_modules, allow_destroy: true

  validates :name, :slug, presence: true, uniqueness: true
  validates :learner_title, presence: true
  validates :grace_period_days, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  scope :auto_assigned, -> { where(auto_assign: true) }

  def ordered_modules
    course_modules.includes(:learning_module).map(&:learning_module)
  end

  def display_name
    name
  end
end
```

```ruby
# app/models/learning_module.rb
# The atomic unit: an ordered list of steps plus an optional quiz. Named
# LearningModule because Module is a Ruby core class. A module can sit in
# several courses; a person's progress through it is shared between them.
class LearningModule < ApplicationRecord
  belongs_to :qualification, optional: true
  has_many :course_modules, dependent: :restrict_with_error
  has_many :courses, through: :course_modules
  has_many :module_steps, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :learning_module
  has_many :quiz_questions, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :learning_module
  has_many :quiz_attempts, dependent: :restrict_with_error
  has_many :quiz_retry_grants, dependent: :restrict_with_error
  has_many :module_completions, dependent: :restrict_with_error
  accepts_nested_attributes_for :module_steps, allow_destroy: true
  accepts_nested_attributes_for :quiz_questions, allow_destroy: true

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :quiz_pass_percent, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }

  def display_name
    name
  end
end
```

```ruby
# app/models/course_module.rb
class CourseModule < ApplicationRecord
  belongs_to :course
  belongs_to :learning_module

  validates :learning_module_id, uniqueness: { scope: :course_id }
  validates :position, numericality: { only_integer: true }
end
```

```ruby
# app/models/module_step.rb
class ModuleStep < ApplicationRecord
  KINDS = %w[read do auto_check admin_sign_off].freeze

  belongs_to :learning_module
  has_many :step_completions, dependent: :restrict_with_error

  validates :title, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true }
  validates :auto_check_key, inclusion: { in: ->(_) { Stacks::Learning::AutoChecks.keys } }, if: -> { kind == "auto_check" }
  validates :auto_check_key, absence: true, unless: -> { kind == "auto_check" }

  before_validation { self.auto_check_key = auto_check_key.presence }
end
```

```ruby
# app/models/quiz_question.rb
class QuizQuestion < ApplicationRecord
  belongs_to :learning_module

  validates :prompt, presence: true
  validates :position, numericality: { only_integer: true }
  validate :choices_are_well_formed

  # One choice per line, for the admin form.
  def choices_text
    Array(choices).join("\n")
  end

  def choices_text=(text)
    self.choices = text.to_s.lines.map(&:strip).reject(&:blank?)
  end

  private

  def choices_are_well_formed
    list = choices
    unless list.is_a?(Array) && list.size.between?(2, 6) && list.all? { |c| c.is_a?(String) && c.present? }
      errors.add(:choices, "must be 2 to 6 non-blank choices")
      return
    end
    unless correct_index.is_a?(Integer) && correct_index.between?(0, list.size - 1)
      errors.add(:correct_index, "must point at one of the choices (0 is the first)")
    end
  end
end
```

```ruby
# app/models/course_assignment.rb
class CourseAssignment < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :course
  belongs_to :assigned_by, class_name: "AdminUser", optional: true
  belongs_to :waived_by, class_name: "AdminUser", optional: true

  before_validation :apply_date_defaults, on: :create

  validates :assigned_on, :due_on, presence: true
  validates :course_id, uniqueness: { scope: :admin_user_id, message: "is already assigned to this person" }

  scope :outstanding, -> { where(completed_at: nil, waived_at: nil) }

  def outstanding?
    completed_at.nil? && waived_at.nil?
  end

  def completed?
    completed_at.present?
  end

  def waived?
    waived_at.present?
  end

  def display_name
    "#{admin_user&.email} — #{course&.name}"
  end

  private

  def apply_date_defaults
    self.assigned_on ||= Date.today
    self.due_on ||= assigned_on + course.grace_period_days if course
  end
end
```

```ruby
# app/models/step_completion.rb
class StepCompletion < ApplicationRecord
  include BustsTaskCache
  SOURCES = %w[self auto admin].freeze

  belongs_to :admin_user
  belongs_to :module_step
  belongs_to :completed_by, class_name: "AdminUser", optional: true

  validates :completed_at, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :module_step_id, uniqueness: { scope: :admin_user_id }
end
```

```ruby
# app/models/quiz_attempt.rb
# correct_count / question_count / passed are fixed at submission and never
# recomputed; answers is a record only.
class QuizAttempt < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :learning_module

  validates :correct_count, :question_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
```

```ruby
# app/models/quiz_retry_grant.rb
# One row = one extra quiz attempt an admin allowed a person on a module.
class QuizRetryGrant < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :learning_module
  belongs_to :granted_by, class_name: "AdminUser", optional: true
end
```

```ruby
# app/models/module_completion.rb
class ModuleCompletion < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :learning_module

  validates :completed_at, presence: true
  validates :learning_module_id, uniqueness: { scope: :admin_user_id }
end
```

```ruby
# app/models/qualification_grant.rb
class QualificationGrant < ApplicationRecord
  belongs_to :admin_user
  belongs_to :qualification
  belongs_to :granted_by, class_name: "AdminUser", optional: true

  validates :granted_at, presence: true
  validates :qualification_id, uniqueness: { scope: :admin_user_id, message: "is already held by this person" }
end
```

In `app/models/admin_user.rb`, directly after the line `has_many :permission_grants, dependent: :destroy`, add:

```ruby
  # Onboarding courses. delete_all (not destroy): Stacks::Team.discover!
  # destroys foreign-domain users inside the daily run, and these rows have no
  # callbacks worth running. Rows where this person was only the actor
  # (assigned_by, waived_by, completed_by, granted_by) are nulled by the
  # database's ON DELETE SET NULL.
  has_many :course_assignments, dependent: :delete_all
  has_many :step_completions, dependent: :delete_all
  has_many :quiz_attempts, dependent: :delete_all
  has_many :quiz_retry_grants, dependent: :delete_all
  has_many :module_completions, dependent: :delete_all
  has_many :qualification_grants, dependent: :delete_all
```

`ModuleStep` references `Stacks::Learning::AutoChecks`, which Task 2 creates. So the tests can pass in this task, create a minimal version now (Task 2 replaces it):

```ruby
# lib/stacks/learning/auto_checks.rb
module Stacks
  module Learning
    module AutoChecks
      def self.keys
        %w[forecast_account payment_profile human_operating_manual]
      end
    end
  end
end
```

- [ ] **Step 7: Run to verify it passes**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/models/learning_models_test.rb test/models/admin_user_test.rb`
Expected: all pass. (One `admin_user_test.rb` test about the initial salary window is known to fail between 20:00 and 24:00 US Eastern; that is unrelated.)

- [ ] **Step 8: Commit**

```bash
git rev-parse --abbrev-ref HEAD   # must print feat/onboarding-courses
git add db/migrate/20261013120000_create_learning_tables.rb db/schema.rb app/models lib/stacks/learning test/support/learning_test_helpers.rb test/models/learning_models_test.rb
git commit -m "feat: tables and models for onboarding courses

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Auto-checks, checklist state and progress

**Files:**
- Modify (replace): `lib/stacks/learning/auto_checks.rb`
- Create: `lib/stacks/learning/checklist.rb`, `lib/stacks/learning/progress.rb`
- Modify: `app/models/course_assignment.rb` (add the after-commit refresh)
- Test: `test/lib/stacks/learning/auto_checks_test.rb`, `checklist_test.rb`, `progress_test.rb`

**Interfaces:**
- Consumes: Task 1 models and helpers.
- Produces:
  - `Stacks::Learning::AutoChecks.keys → Array<String>`, `.options_for_select → [[label, key]]`, `.passed?(key, admin_user, context = Context.new) → Boolean`, `AutoChecks::Context#manual_emails → Set<String>`.
  - `Stacks::Learning::Checklist.new(assignment)` with `#modules → Array<ModuleState>`, `#module_state(learning_module_or_id)`, `#step_state(step_or_id)`, `#own_work_remaining?`, `#ready_sign_off_steps → Array<ModuleStep>`, `#steps_total`, `#steps_done`, `#all_done?`.
  - `ModuleState`: `#learning_module`, `#steps → Array<StepState>`, `#attempts`, `#attempts_allowed`, `#attempts_left`, `#completion`, `#steps_done?`, `#has_quiz?`, `#passed?`, `#quiz_state → :none | :not_open | :open | :passed | :locked`, `#done?`.
  - `StepState`: `#step`, `#completion`, `#ready` (true only for a ready, incomplete sign-off step), `#done?`.
  - `Stacks::Learning::Checklist::BASE_ATTEMPTS = 2`.
  - `Stacks::Learning::Progress.refresh!(admin_user, context: nil)`, `.refresh_all!`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/learning/auto_checks_test.rb
require "test_helper"

class StacksLearningAutoChecksTest < ActiveSupport::TestCase
  AC = Stacks::Learning::AutoChecks

  def forecast_person_for!(person)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: person.email, data: {})
  end

  test "an unknown key is never passed" do
    assert_not AC.passed?("nope", learning_person!)
  end

  test "forecast_account passes once a Forecast person shares the email" do
    person = learning_person!
    assert_not AC.passed?("forecast_account", person)
    forecast_person_for!(person)
    assert AC.passed?("forecast_account", person.reload)
  end

  test "payment_profile needs a Forecast person and then Deel or a QBO vendor" do
    person = learning_person!
    assert_not AC.passed?("payment_profile", person)
    fp = forecast_person_for!(person)
    assert_not AC.passed?("payment_profile", person.reload)
    fp.contributor.update_column(:deel_person_id, "deel-123")
    assert AC.passed?("payment_profile", person.reload)
  end

  test "human_operating_manual passes for exempt people and for a listed email" do
    person = learning_person!
    empty = AC::Context.new
    empty.stubs(:manual_emails).returns(Set.new)
    assert_not AC.passed?("human_operating_manual", person, empty)

    listed = AC::Context.new
    listed.stubs(:manual_emails).returns(Set.new([person.email.downcase]))
    assert AC.passed?("human_operating_manual", person, listed)

    person.update!(requires_human_operating_manual: false)
    assert AC.passed?("human_operating_manual", person, empty)
  end

  test "a check that raises counts as not passed" do
    person = learning_person!
    person.stubs(:forecast_person).raises(StandardError, "boom")
    assert_not AC.passed?("forecast_account", person)
  end

  test "every key has a label for the admin select" do
    assert_equal AC.keys.sort, AC.options_for_select.map(&:last).sort
    assert AC.options_for_select.all? { |label, _| label.present? }
  end
end
```

If `ForecastPerson.create!` does not auto-create a `Contributor` in the test environment (it has `after_create :ensure_contributor_exists!`, so it should), create one with `Contributor.create!(forecast_person: fp)`. If `deel_person_id` has a foreign-key constraint that rejects `"deel-123"`, link a `ContributorQboVendor` instead, following `test/integration/ledger_migration_test.rb:9-16`.

```ruby
# test/lib/stacks/learning/checklist_test.rb
require "test_helper"

class StacksLearningChecklistTest < ActiveSupport::TestCase
  CL = Stacks::Learning::Checklist

  test "quiz state moves none / not_open / open / locked / passed" do
    person = learning_person!
    plain = learning_module!(steps: ["read"])
    quizzed = learning_module!(steps: ["read"], questions: 2)
    a = learning_assign!(person, learning_course!(modules: [plain, quizzed]))

    assert_equal :none, CL.new(a).module_state(plain).quiz_state
    assert_equal :not_open, CL.new(a).module_state(quizzed).quiz_state

    complete_step!(person, quizzed.module_steps.first)
    assert_equal :open, CL.new(a).module_state(quizzed).quiz_state
    assert_equal 2, CL.new(a).module_state(quizzed).attempts_left

    2.times { QuizAttempt.create!(admin_user: person, learning_module: quizzed, correct_count: 0, question_count: 2) }
    state = CL.new(a).module_state(quizzed)
    assert_equal :locked, state.quiz_state
    assert_equal 0, state.attempts_left

    QuizRetryGrant.create!(admin_user: person, learning_module: quizzed)
    assert_equal :open, CL.new(a).module_state(quizzed).quiz_state

    QuizAttempt.create!(admin_user: person, learning_module: quizzed, correct_count: 2, question_count: 2, passed: true)
    state = CL.new(a).module_state(quizzed)
    assert_equal :passed, state.quiz_state
    assert state.done?
  end

  test "another person's completions and attempts do not count" do
    person = learning_person!
    other = learning_person!
    mod = learning_module!(steps: ["read"], questions: 1)
    a = learning_assign!(person, learning_course!(modules: [mod]))
    complete_step!(other, mod.module_steps.first)
    QuizAttempt.create!(admin_user: other, learning_module: mod, correct_count: 1, question_count: 1, passed: true)
    state = CL.new(a).module_state(mod)
    assert_not state.steps_done?
    assert_equal :not_open, state.quiz_state
  end

  test "a sign-off is ready only when earlier steps and earlier modules are done" do
    person = learning_person!
    first = learning_module!(steps: ["read"])
    last = learning_module!(steps: ["do", "admin_sign_off"])
    a = learning_assign!(person, learning_course!(modules: [first, last]))
    sign_off = last.module_steps.last

    assert_empty CL.new(a).ready_sign_off_steps
    complete_step!(person, first.module_steps.first)
    assert_empty CL.new(a).ready_sign_off_steps, "the 'do' step before it is not done"
    complete_step!(person, last.module_steps.first)
    assert_equal [sign_off], CL.new(a).ready_sign_off_steps
    assert CL.new(a).step_state(sign_off).ready

    complete_step!(person, sign_off, source: "admin")
    assert_empty CL.new(a).ready_sign_off_steps
  end

  test "a sign-off that is the first step of the first module is ready immediately" do
    person = learning_person!
    mod = learning_module!(steps: ["admin_sign_off", "read"])
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert_equal [mod.module_steps.first], CL.new(a).ready_sign_off_steps
  end

  test "own_work_remaining? ignores sign-offs and locked quizzes" do
    person = learning_person!
    mod = learning_module!(steps: ["read", "admin_sign_off"], questions: 1)
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert CL.new(a).own_work_remaining?, "a read step is theirs"

    complete_step!(person, mod.module_steps.first)
    assert_not CL.new(a).own_work_remaining?, "only the sign-off is left (quiz not open yet)"

    complete_step!(person, mod.module_steps.last, source: "admin")
    assert CL.new(a).own_work_remaining?, "the quiz is open and is theirs"

    2.times { QuizAttempt.create!(admin_user: person, learning_module: mod, correct_count: 0, question_count: 1) }
    assert_not CL.new(a).own_work_remaining?, "locked: waiting on an admin"
  end

  test "an auto_check step counts as the person's own work" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"]])
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert CL.new(a).own_work_remaining?
  end

  test "a module with a completion row stays done after a step is added to it" do
    person = learning_person!
    mod = learning_module!(steps: ["read"])
    a = learning_assign!(person, learning_course!(modules: [mod]))
    complete_step!(person, mod.module_steps.first)
    ModuleCompletion.create!(admin_user: person, learning_module: mod, completed_at: Time.current)
    mod.module_steps.create!(position: 9, kind: "read", title: "added later")
    cl = CL.new(a)
    assert cl.module_state(mod).done?
    assert cl.all_done?
    assert_not cl.own_work_remaining?
    assert_equal [2, 1], [cl.steps_total, cl.steps_done]
  end

  test "a course with no modules is never all done" do
    a = learning_assign!(learning_person!, learning_course!(modules: []))
    assert_not CL.new(a).all_done?
  end
end
```

```ruby
# test/lib/stacks/learning/progress_test.rb
require "test_helper"

class StacksLearningProgressTest < ActiveSupport::TestCase
  P = Stacks::Learning::Progress
  AC = Stacks::Learning::AutoChecks

  test "an auto_check that passes is completed with source auto; one that fails is not" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"], ["auto_check", "payment_profile"]])
    learning_assign!(person, learning_course!(modules: [mod]))
    AC.stubs(:passed?).with("forecast_account", person, anything).returns(true)
    AC.stubs(:passed?).with("payment_profile", person, anything).returns(false)

    P.refresh!(person)

    done = StepCompletion.where(admin_user: person)
    assert_equal [mod.module_steps.first.id], done.pluck(:module_step_id)
    assert_equal "auto", done.first.source
  end

  test "a module with no quiz completes when its steps are done, and grants its badge once" do
    badge = Qualification.create!(name: "Badge #{SecureRandom.hex(3)}", kind: "badge")
    person = learning_person!
    mod = learning_module!(steps: ["read"], qualification: badge)
    learning_assign!(person, learning_course!(modules: [mod, learning_module!]))

    P.refresh!(person)
    assert_equal 0, ModuleCompletion.where(admin_user: person).count

    complete_step!(person, mod.module_steps.first)
    P.refresh!(person)
    P.refresh!(person)
    assert_equal 1, ModuleCompletion.where(admin_user: person, learning_module: mod).count
    grants = QualificationGrant.where(admin_user: person, qualification: badge)
    assert_equal 1, grants.count
    assert_nil grants.first.granted_by_id
  end

  test "a module with a quiz does not complete until an attempt passes" do
    person = learning_person!
    mod = learning_module!(steps: ["read"], questions: 1)
    learning_assign!(person, learning_course!(modules: [mod]))
    complete_step!(person, mod.module_steps.first)
    P.refresh!(person)
    assert_equal 0, ModuleCompletion.where(admin_user: person).count

    QuizAttempt.create!(admin_user: person, learning_module: mod, correct_count: 1, question_count: 1, passed: true)
    P.refresh!(person)
    assert_equal 1, ModuleCompletion.where(admin_user: person).count
  end

  test "finishing every module completes the assignment and grants the qualification" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    person = learning_person!
    m1 = learning_module!(steps: ["read"])
    m2 = learning_module!(steps: ["do"])
    a = learning_assign!(person, learning_course!(modules: [m1, m2], qualification: qual))

    complete_step!(person, m1.module_steps.first)
    P.refresh!(person)
    assert_nil a.reload.completed_at
    assert_equal 0, QualificationGrant.where(admin_user: person, qualification: qual).count

    complete_step!(person, m2.module_steps.first)
    P.refresh!(person)
    assert a.reload.completed_at.present?
    assert_equal 1, QualificationGrant.where(admin_user: person, qualification: qual).count
  end

  test "a module finished in one course counts in a second course" do
    person = learning_person!
    shared = learning_module!(steps: ["read"])
    learning_assign!(person, learning_course!(modules: [shared]))
    complete_step!(person, shared.module_steps.first)
    P.refresh!(person)

    second = learning_assign!(person, learning_course!(modules: [shared]))
    P.refresh!(person)
    assert second.reload.completed_at.present?
  end

  test "an existing manual grant is left untouched" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    admin = learning_person!(prefix: "boss", roles: ["admin"])
    person = learning_person!
    manual = QualificationGrant.create!(admin_user: person, qualification: qual, granted_at: 1.year.ago, granted_by: admin, note: "by hand")
    mod = learning_module!(steps: ["read"])
    learning_assign!(person, learning_course!(modules: [mod], qualification: qual))
    complete_step!(person, mod.module_steps.first)

    P.refresh!(person)

    assert_equal [manual.id], QualificationGrant.where(admin_user: person, qualification: qual).pluck(:id)
    assert_equal admin.id, manual.reload.granted_by_id
    assert_equal "by hand", manual.note
  end

  test "waived assignments are skipped: nothing completes and nothing is granted" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    person = learning_person!
    mod = learning_module!(steps: ["read"])
    a = learning_assign!(person, learning_course!(modules: [mod], qualification: qual))
    complete_step!(person, mod.module_steps.first)
    a.update!(waived_at: Time.current)

    P.refresh!(person)

    assert_nil a.reload.completed_at
    assert_equal 0, QualificationGrant.where(admin_user: person).count
    assert_equal 0, ModuleCompletion.where(admin_user: person).count
  end

  test "creating an assignment refreshes it, so an already-true auto check is done at once" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"]])
    AC.stubs(:passed?).returns(true)
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert a.reload.completed_at.present?
  end

  test "refresh_all! covers everyone with an outstanding assignment and survives one person failing" do
    bad = learning_person!(prefix: "bad")
    good = learning_person!(prefix: "good")
    learning_assign!(bad, learning_course!(modules: [learning_module!(steps: [["auto_check", "forecast_account"]])]))
    good_mod = learning_module!(steps: ["read"])
    good_assignment = learning_assign!(good, learning_course!(modules: [good_mod]))
    complete_step!(good, good_mod.module_steps.first)
    # Stubbing passed? itself bypasses its internal rescue, so refresh! really
    # raises for the one person who has an auto_check step (created first, so
    # find_each reaches them first).
    AC.stubs(:passed?).raises(StandardError, "boom")

    assert_nothing_raised { P.refresh_all! }
    assert good_assignment.reload.completed_at.present?
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/learning`
Expected: `NameError` for `Checklist` / `Progress` / `AutoChecks::Context`.

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/learning/auto_checks.rb
module Stacks
  module Learning
    # Things Stacks can verify about a person without asking them. A step of
    # kind "auto_check" names one of these keys.
    module AutoChecks
      # Shared across one refresh_all! run so the Notion mirror is scanned once,
      # not once per person.
      class Context
        def manual_emails
          @manual_emails ||= Stacks::Notion::HumanOperatingManual.all.flat_map(&:emails).to_set
        end
      end

      CHECKS = {
        "forecast_account" => {
          label: "Has a Harvest Forecast account under their company email",
          check: ->(user, _context) { user.forecast_person.present? },
        },
        "payment_profile" => {
          label: "Has a payment profile linked (Deel, or a QuickBooks vendor)",
          check: ->(user, _context) {
            contributor = user.forecast_person&.contributor
            contributor.present? && (contributor.deel_person_id.present? || contributor.contributor_qbo_vendors.exists?)
          },
        },
        "human_operating_manual" => {
          label: "Has a Human Operating Manual in Notion (or is exempt)",
          check: ->(user, context) {
            !user.requires_human_operating_manual? || context.manual_emails.include?(user.email.to_s.downcase)
          },
        },
      }.freeze

      def self.keys
        CHECKS.keys
      end

      def self.options_for_select
        CHECKS.map { |key, entry| [entry[:label], key] }
      end

      # Never raises: a check that blows up counts as "not yet".
      def self.passed?(key, admin_user, context = Context.new)
        entry = CHECKS[key.to_s]
        return false unless entry
        !!entry[:check].call(admin_user, context)
      rescue => e
        Rails.logger.error("Stacks::Learning::AutoChecks #{key} failed for AdminUser##{admin_user&.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        false
      end
    end
  end
end
```

```ruby
# lib/stacks/learning/checklist.rb
module Stacks
  module Learning
    # Read-only picture of one CourseAssignment for its person: which steps are
    # done, each module's quiz state, and which admin sign-offs are ready.
    # Loads everything in a handful of queries; build a new one after writing.
    class Checklist
      BASE_ATTEMPTS = 2

      StepState = Struct.new(:step, :completion, :ready, keyword_init: true) do
        def done?
          completion.present?
        end
      end

      class ModuleState
        attr_reader :learning_module, :steps, :attempts, :attempts_allowed, :completion

        def initialize(learning_module:, steps:, attempts:, attempts_allowed:, completion:)
          @learning_module = learning_module
          @steps = steps
          @attempts = attempts
          @attempts_allowed = attempts_allowed
          @completion = completion
        end

        def steps_done?
          steps.all?(&:done?)
        end

        def has_quiz?
          learning_module.quiz_questions.any?
        end

        def passed?
          attempts.any?(&:passed)
        end

        def attempts_left
          [attempts_allowed - attempts.size, 0].max
        end

        def quiz_state
          return :none unless has_quiz?
          return :passed if passed? || completion.present?
          return :not_open unless steps_done?
          attempts_left.zero? ? :locked : :open
        end

        # Sticky: a ModuleCompletion row keeps a module done even if steps or
        # questions are added to it later.
        def done?
          completion.present? || (steps_done? && (!has_quiz? || passed?))
        end
      end

      attr_reader :assignment, :modules

      def initialize(assignment)
        @assignment = assignment
        @modules = build
      end

      def module_state(learning_module)
        id = learning_module.respond_to?(:id) ? learning_module.id : learning_module.to_i
        modules.find { |m| m.learning_module.id == id }
      end

      def step_state(step)
        id = step.respond_to?(:id) ? step.id : step.to_i
        modules.each do |m|
          found = m.steps.find { |s| s.step.id == id }
          return found if found
        end
        nil
      end

      def all_done?
        modules.any? && modules.all?(&:done?)
      end

      # True when the person still has something only they can do. Admin
      # sign-offs and quizzes locked pending an admin's retry grant are not theirs.
      def own_work_remaining?
        modules.any? do |m|
          next false if m.done?
          m.steps.any? { |s| !s.done? && s.step.kind != "admin_sign_off" } || m.quiz_state == :open
        end
      end

      def ready_sign_off_steps
        modules.flat_map { |m| m.steps.select(&:ready).map(&:step) }
      end

      def steps_total
        modules.sum { |m| m.steps.size }
      end

      def steps_done
        modules.sum { |m| m.steps.count(&:done?) }
      end

      private

      def build
        user_id = assignment.admin_user_id
        learning_modules = assignment.course.course_modules
          .includes(learning_module: [:module_steps, :quiz_questions])
          .map(&:learning_module)
        module_ids = learning_modules.map(&:id)
        step_ids = learning_modules.flat_map { |m| m.module_steps.map(&:id) }

        completions = StepCompletion.where(admin_user_id: user_id, module_step_id: step_ids)
          .includes(:completed_by).index_by(&:module_step_id)
        attempts = QuizAttempt.where(admin_user_id: user_id, learning_module_id: module_ids)
          .order(:created_at, :id).group_by(&:learning_module_id)
        retry_grants = QuizRetryGrant.where(admin_user_id: user_id, learning_module_id: module_ids)
          .group(:learning_module_id).count
        module_completions = ModuleCompletion.where(admin_user_id: user_id, learning_module_id: module_ids)
          .index_by(&:learning_module_id)

        earlier_modules_done = true
        learning_modules.map do |mod|
          earlier_steps_done = true
          steps = mod.module_steps.map do |step|
            completion = completions[step.id]
            ready = step.kind == "admin_sign_off" && completion.nil? && earlier_modules_done && earlier_steps_done
            earlier_steps_done &&= completion.present?
            StepState.new(step: step, completion: completion, ready: ready)
          end
          state = ModuleState.new(
            learning_module: mod,
            steps: steps,
            attempts: attempts[mod.id] || [],
            attempts_allowed: BASE_ATTEMPTS + retry_grants[mod.id].to_i,
            completion: module_completions[mod.id],
          )
          earlier_modules_done &&= state.done?
          state
        end
      end
    end
  end
end
```

```ruby
# lib/stacks/learning/progress.rb
module Stacks
  module Learning
    # The only writer of derived progress. Idempotent and additive: it never
    # removes a completion or a grant.
    class Progress
      def self.refresh!(admin_user, context: nil)
        context ||= AutoChecks::Context.new
        admin_user.course_assignments.outstanding.includes(:course).each do |assignment|
          complete_auto_checks(assignment, admin_user, context)

          checklist = Checklist.new(assignment)
          checklist.modules.each do |state|
            next if state.completion.present? || !state.done?
            ensure_row(ModuleCompletion, admin_user_id: admin_user.id, learning_module_id: state.learning_module.id) do |row|
              row.completed_at = Time.current
            end
            grant(admin_user, state.learning_module.qualification)
          end

          next unless checklist.all_done?
          assignment.update!(completed_at: Time.current)
          grant(admin_user, assignment.course.qualification)
        end
      end

      def self.refresh_all!
        context = AutoChecks::Context.new
        AdminUser.where(id: CourseAssignment.outstanding.select(:admin_user_id)).find_each do |admin_user|
          refresh!(admin_user, context: context)
        rescue => e
          Rails.logger.error("Stacks::Learning::Progress.refresh! failed for AdminUser##{admin_user.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
        end
      end

      def self.complete_auto_checks(assignment, admin_user, context)
        Checklist.new(assignment).modules.each do |state|
          state.steps.each do |step_state|
            step = step_state.step
            next if step_state.done? || step.kind != "auto_check"
            next unless AutoChecks.passed?(step.auto_check_key, admin_user, context)
            ensure_row(StepCompletion, admin_user_id: admin_user.id, module_step_id: step.id) do |row|
              row.completed_at = Time.current
              row.source = "auto"
            end
          end
        end
      end
      private_class_method :complete_auto_checks

      def self.grant(admin_user, qualification)
        return if qualification.nil?
        ensure_row(QualificationGrant, admin_user_id: admin_user.id, qualification_id: qualification.id) do |row|
          row.granted_at = Time.current
        end
      end
      private_class_method :grant

      # find_or_create_by! that tolerates a concurrent insert of the same row.
      def self.ensure_row(klass, attrs, &block)
        klass.find_or_create_by!(attrs, &block)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        klass.find_by!(attrs)
      end
      private_class_method :ensure_row
    end
  end
end
```

In `app/models/course_assignment.rb`, after the `before_validation` line add:

```ruby
  # So a new checklist shows what Stacks already knows (Forecast account,
  # payment profile). After commit, and rescued: a refresh failure must never
  # undo or block the assignment itself.
  after_create_commit :refresh_progress

  private def refresh_progress
    Stacks::Learning::Progress.refresh!(admin_user)
  rescue => e
    Rails.logger.error("CourseAssignment##{id} initial refresh failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end
```

(Place it so the file still has a single `private` section; `private def` keeps it private wherever it sits.)

Note: Rails tests wrap each test in a transaction, and `after_create_commit` still fires there in Rails 6.1 (test transactions run commit callbacks since 5.0). The test "creating an assignment refreshes it" proves it.

- [ ] **Step 4: Run to verify they pass**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/learning test/models/learning_models_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add lib/stacks/learning app/models/course_assignment.rb test/lib/stacks/learning
git commit -m "feat: checklist state, auto-checks and progress refresh for courses

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Quiz submission with a hard attempt limit

**Files:**
- Create: `lib/stacks/learning/quiz.rb`
- Test: `test/lib/stacks/learning/quiz_test.rb`

**Interfaces:**
- Consumes: `Checklist#module_state`, `ModuleState#quiz_state`, `#attempts_left`, `Progress.refresh!`.
- Produces: `Stacks::Learning::Quiz.submit!(assignment:, learning_module:, answers:) → Quiz::Result` where `Result` has `#status` (`:passed`, `:failed`, `:rejected`), `#attempt` (nil when rejected), `#message` (String, person-facing), `#attempts_left` (Integer). `answers` is a Hash of question id (String or Integer) → chosen original index (String or Integer).

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/learning/quiz_test.rb
require "test_helper"

class StacksLearningQuizTest < ActiveSupport::TestCase
  Q = Stacks::Learning::Quiz

  setup do
    @person = learning_person!
    @mod = learning_module!(steps: ["read"], questions: 5, pass_percent: 80)
    @assignment = learning_assign!(@person, learning_course!(modules: [@mod]))
    complete_step!(@person, @mod.module_steps.first)
  end

  # right: how many of the questions to answer correctly (correct_index is 0).
  def answers(right:)
    @mod.quiz_questions.each_with_index.to_h { |q, i| [q.id.to_s, i < right ? "0" : "1"] }
  end

  def submit(right:)
    Q.submit!(assignment: @assignment, learning_module: @mod, answers: answers(right: right))
  end

  test "4 of 5 at an 80% pass mark passes, completes the module and the assignment" do
    result = submit(right: 4)
    assert_equal :passed, result.status
    assert result.attempt.passed
    assert_equal [4, 5], [result.attempt.correct_count, result.attempt.question_count]
    assert ModuleCompletion.exists?(admin_user: @person, learning_module: @mod)
    assert @assignment.reload.completed_at.present?
  end

  test "3 of 5 fails, is recorded, and leaves one attempt" do
    result = submit(right: 3)
    assert_equal :failed, result.status
    assert_not result.attempt.passed
    assert_equal 1, result.attempts_left
    assert_equal 1, QuizAttempt.where(admin_user: @person).count
  end

  test "the failure message gives the score and pass mark but no answers" do
    result = submit(right: 3)
    assert_includes result.message, "3 of 5"
    assert_includes result.message, "4"
    assert_not_includes result.message, "right"
    assert_not_includes result.message, "Because"
  end

  test "a third attempt is refused and not recorded" do
    2.times { submit(right: 0) }
    result = submit(right: 5)
    assert_equal :rejected, result.status
    assert_nil result.attempt
    assert_equal 2, QuizAttempt.where(admin_user: @person).count
    assert_not ModuleCompletion.exists?(admin_user: @person, learning_module: @mod)
  end

  test "one retry grant allows exactly one more attempt" do
    2.times { submit(right: 0) }
    QuizRetryGrant.create!(admin_user: @person, learning_module: @mod)
    assert_equal :failed, submit(right: 0).status
    assert_equal :rejected, submit(right: 5).status
    assert_equal 3, QuizAttempt.where(admin_user: @person).count
  end

  test "an incomplete or malformed submission is rejected and does not use an attempt" do
    partial = answers(right: 5).first(4).to_h
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: partial).status
    out_of_range = answers(right: 5).transform_values { "9" }
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: out_of_range).status
    junk = answers(right: 5).transform_values { "abc" }
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: junk).status
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: nil).status
    assert_equal 0, QuizAttempt.where(admin_user: @person).count
  end

  test "no attempt after a pass" do
    submit(right: 5)
    assert_equal :rejected, submit(right: 5).status
    assert_equal 1, QuizAttempt.where(admin_user: @person).count
  end

  test "the quiz is closed until every step is done" do
    StepCompletion.where(admin_user: @person).delete_all
    assert_equal :rejected, submit(right: 5).status
    assert_equal 0, QuizAttempt.where(admin_user: @person).count
  end

  test "a module that is not in the assignment's course is rejected" do
    stray = learning_module!(steps: [], questions: 1)
    result = Q.submit!(assignment: @assignment, learning_module: stray, answers: { stray.quiz_questions.first.id.to_s => "0" })
    assert_equal :rejected, result.status
    assert_equal 0, QuizAttempt.count
  end

  test "a waived assignment takes no attempts" do
    @assignment.update!(waived_at: Time.current)
    assert_equal :rejected, submit(right: 5).status
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/learning/quiz_test.rb`
Expected: `NameError: uninitialized constant Stacks::Learning::Quiz`.

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/learning/quiz.rb
module Stacks
  module Learning
    # Takes one "quick check" submission. People get Checklist::BASE_ATTEMPTS
    # attempts plus one per QuizRetryGrant, so they read the material rather
    # than guess their way through.
    class Quiz
      Result = Struct.new(:status, :attempt, :message, :attempts_left, keyword_init: true)

      def self.submit!(assignment:, learning_module:, answers:)
        user = assignment.admin_user
        result = nil

        # Row lock on the person: two simultaneous submissions queue up, so the
        # attempt count read below cannot be stale.
        AdminUser.transaction do
          user.lock!
          state = assignment.outstanding? ? Checklist.new(assignment).module_state(learning_module) : nil

          if state.nil? || state.quiz_state != :open
            result = rejected(message_for_closed(state), state)
            next
          end

          questions = state.learning_module.quiz_questions.to_a
          chosen = parse(answers, questions)
          if chosen.nil?
            result = rejected("Answer every question before submitting. This didn't use up an attempt.", state)
            next
          end

          correct = questions.count { |q| chosen[q.id] == q.correct_index }
          passed = correct * 100 >= state.learning_module.quiz_pass_percent * questions.size
          attempt = QuizAttempt.create!(
            admin_user: user, learning_module: state.learning_module,
            answers: chosen.transform_keys(&:to_s), correct_count: correct,
            question_count: questions.size, passed: passed,
          )
          left = passed ? 0 : state.attempts_left - 1
          result = Result.new(
            status: passed ? :passed : :failed, attempt: attempt, attempts_left: left,
            message: passed ? "Passed: #{correct} of #{questions.size}." : failed_message(correct, questions.size, state.learning_module, left),
          )
        end

        Progress.refresh!(user) if result.status == :passed
        result
      end

      # question id (Integer) => chosen index (Integer), or nil unless every
      # question has an in-range integer answer.
      def self.parse(answers, questions)
        return nil unless answers.respond_to?(:[])
        chosen = {}
        questions.each do |q|
          raw = answers[q.id.to_s] || answers[q.id]
          index = Integer(raw.to_s, exception: false)
          return nil if index.nil? || !index.between?(0, q.choices.size - 1)
          chosen[q.id] = index
        end
        chosen
      end
      private_class_method :parse

      def self.pass_count(learning_module, total)
        (learning_module.quiz_pass_percent * total / 100.0).ceil
      end
      private_class_method :pass_count

      def self.failed_message(correct, total, learning_module, left)
        need = pass_count(learning_module, total)
        tail = left.positive? ? "You have #{left} #{"attempt".pluralize(left)} left, so re-read the pages first." : "You're out of attempts. Ask an admin to allow another."
        "You got #{correct} of #{total}; you need #{need}. #{tail}"
      end
      private_class_method :failed_message

      def self.message_for_closed(state)
        return "This quick check isn't part of your checklist." if state.nil?
        case state.quiz_state
        when :passed then "You've already passed this quick check."
        when :locked then "You're out of attempts. Ask an admin to allow another."
        when :not_open then "Finish the steps above before the quick check."
        else "There is no quick check here."
        end
      end
      private_class_method :message_for_closed

      def self.rejected(message, state)
        Result.new(status: :rejected, attempt: nil, message: message, attempts_left: state&.attempts_left.to_i)
      end
      private_class_method :rejected
    end
  end
end
```

`answers` may arrive as `ActionController::Parameters`; `[]` works on it without permitting, which is all `parse` needs.

- [ ] **Step 4: Run to verify it passes**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/learning`
Expected: all pass.

- [ ] **Step 5: Mutation check, then commit**

Temporarily change `state.quiz_state != :open` to `false` and confirm at least four tests fail; restore. Temporarily change `>=` to `>` in the pass calculation and confirm the "4 of 5" test fails; restore.

```bash
git rev-parse --abbrev-ref HEAD
git add lib/stacks/learning/quiz.rb test/lib/stacks/learning/quiz_test.rb
git commit -m "feat: quiz submission with a two-attempt limit and admin retry grants

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Auto-assign courses to newly discovered people

**Files:**
- Modify: `app/models/admin_user.rb` (callback next to `after_create :sync_salary_windows!` at line ~57, method near `sync_salary_windows!`)
- Test: `test/models/admin_user_course_auto_assign_test.rb`

**Interfaces:**
- Consumes: `Course.auto_assigned`, `CourseAssignment`.
- Produces: `AdminUser#assign_auto_assigned_courses!` (public; idempotent).

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/admin_user_course_auto_assign_test.rb
require "test_helper"

class AdminUserCourseAutoAssignTest < ActiveSupport::TestCase
  setup do
    @auto = learning_course!(modules: [learning_module!], auto_assign: true)
    @manual = learning_course!(modules: [learning_module!], auto_assign: false)
  end

  test "a new company-email person is assigned auto-assign courses only" do
    person = learning_person!
    assert_equal [@auto.id], person.course_assignments.pluck(:course_id)
    a = person.course_assignments.first
    assert_nil a.assigned_by_id
    assert_equal Date.today, a.assigned_on
    assert_equal Date.today + @auto.grace_period_days, a.due_on
  end

  test "the discovery path assigns too" do
    email = "found#{SecureRandom.hex(4)}@xxix.co"
    person = AdminUser.find_or_create_by_g3d_uid!(email)
    assert_equal [@auto.id], person.course_assignments.pluck(:course_id)
    assert_no_difference -> { CourseAssignment.count } do
      AdminUser.find_or_create_by_g3d_uid!(email)
    end
  end

  test "a non-company email is not assigned anything" do
    outsider = AdminUser.create!(email: "x#{SecureRandom.hex(4)}@example.com",
                                 password: "password12345", password_confirmation: "password12345")
    assert_equal 0, outsider.course_assignments.count
  end

  test "people who already exist are not assigned when a course is switched on" do
    existing = learning_person!
    existing.course_assignments.delete_all
    @manual.update!(auto_assign: true)
    assert_equal 0, existing.reload.course_assignments.count
  end

  test "a database error while assigning leaves the account persisted" do
    CourseAssignment.stubs(:create!).raises(ActiveRecord::StatementInvalid, "PG::Error: boom")
    person = nil
    assert_nothing_raised { person = learning_person! }
    assert AdminUser.exists?(person.id)
    assert_equal 0, person.course_assignments.count
  end

  test "calling it twice does not duplicate" do
    person = learning_person!
    assert_no_difference -> { CourseAssignment.count } { person.assign_auto_assigned_courses! }
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/models/admin_user_course_auto_assign_test.rb`
Expected: the first test fails with `[] != [id]`.

- [ ] **Step 3: Implement**

In `app/models/admin_user.rb`, directly under `after_create :sync_salary_windows!`:

```ruby
  # after_create_commit, not after_create: after_create runs inside the INSERT's
  # transaction, where a rescued database error leaves the transaction aborted
  # and silently rolls the new account back.
  after_create_commit :assign_auto_assigned_courses!
```

And as a public method next to `sync_salary_windows!`:

```ruby
  # Every newly discovered company-email person gets the courses flagged
  # auto_assign. Runs only on create, so existing people are never assigned
  # retroactively. Must never prevent an account from being created.
  def assign_auto_assigned_courses!
    return unless email.to_s.ends_with?("@sanctuary.computer") || email.to_s.ends_with?("@xxix.co")

    Course.auto_assigned.where.not(id: course_assignments.select(:course_id)).each do |course|
      CourseAssignment.create!(admin_user: self, course: course)
    end
  rescue => e
    Rails.logger.error("AdminUser##{id} course auto-assign failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end
```

- [ ] **Step 4: Run to verify it passes, plus the neighbours it could disturb**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/models/admin_user_course_auto_assign_test.rb test/models/admin_user_test.rb test/lib/stacks/team_test.rb test/models/learning_models_test.rb test/lib/stacks/learning`
Expected: all pass (bar the known evening-only salary-window test).

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/models/admin_user.rb test/models/admin_user_course_auto_assign_test.rb
git commit -m "feat: assign auto-assign courses when a company-email person is created

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Pending tasks for overdue checklists and admin sign-offs

**Files:**
- Create: `lib/stacks/task_builder/discoveries/course_assignments.rb`
- Modify: `lib/stacks/task_builder.rb` (require, `DISCOVERY_CLASSES`, `SUBJECT_PRELOADS`, `cached_descriptors`)
- Modify: `app/models/stacks_task.rb` (`HUMANIZED_TYPES`, `subject_display_name`, `subject_url`)
- Modify: `lib/tasks/stacks.rake` (`daily_tasks`: call `refresh_all!` before the `TaskBuilder#refresh!` at line ~628)
- Test: `test/lib/stacks/task_builder/discoveries/course_assignments_test.rb`, `test/lib/stacks/task_builder/course_assignment_live_revalidation_test.rb`

**Interfaces:**
- Consumes: `Checklist#own_work_remaining?`, `#ready_sign_off_steps`.
- Produces:
  - `Stacks::TaskBuilder::Discoveries::CourseAssignments::OVERDUE = :course_assignment_overdue`, `SIGN_OFF = :course_assignment_needs_admin_sign_off`.
  - `.task_types_for(assignment, today: Date.today) → Array<Symbol>`, `.live_types_by_id(ids) → Hash{Integer => Array<Symbol>}`, `.eligible?(admin_user, today)`.
  - `StacksTask#subject_url` for a `CourseAssignment` → `admin_course_assignment_path(subject)` (the route exists after Task 6; until then guard with `respond_to?`, see Step 3).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/task_builder/discoveries/course_assignments_test.rb
require "test_helper"

class StacksTaskBuilderCourseAssignmentsDiscoveryTest < ActiveSupport::TestCase
  D = Stacks::TaskBuilder::Discoveries::CourseAssignments

  setup do
    @admin = build_admin!
    @person = learning_person!
    @mod = learning_module!(steps: ["read"])
    @course = learning_course!(modules: [@mod])
  end

  def tasks
    D.new(admin_fallback: AdminUser.admin.to_a).tasks.select { |t| t.subject.course_id == @course.id || @extra_course_ids.to_a.include?(t.subject.course_id) }
  end

  def types
    tasks.map(&:type)
  end

  test "not overdue on or before the due date, overdue the day after" do
    a = learning_assign!(@person, @course, due_on: Date.today)
    assert_empty types
    a.update!(due_on: Date.today - 1)
    assert_equal [D::OVERDUE], types
    assert_equal [@person], tasks.first.owners
    assert_equal a, tasks.first.subject
  end

  test "completed and waived assignments produce nothing" do
    a = learning_assign!(@person, @course, due_on: Date.today - 1)
    a.update!(completed_at: Time.current)
    assert_empty types
    a.update!(completed_at: nil, waived_at: Time.current)
    assert_empty types
  end

  test "an ignored person and a departed person are skipped; a brand-new person with no period is not" do
    learning_assign!(@person, @course, due_on: Date.today - 1)
    assert_equal [D::OVERDUE], types, "no full-time periods yet: still eligible"

    @person.update!(ignore: true)
    assert_empty types
    @person.update!(ignore: false)

    FullTimePeriod.create!(admin_user: @person, started_at: Date.today - 60, ended_at: Date.today - 30,
                           contributor_type: Enum::ContributorType::VARIABLE_HOURS, expected_utilization: 0)
    assert_empty types, "their only period has ended"

    FullTimePeriod.create!(admin_user: @person, started_at: Date.today - 5, ended_at: nil,
                           contributor_type: Enum::ContributorType::VARIABLE_HOURS, expected_utilization: 0)
    assert_equal [D::OVERDUE], types
  end

  test "not overdue when only an admin sign-off remains; the sign-off task goes to admins" do
    mod = learning_module!(steps: ["read", "admin_sign_off"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    complete_step!(@person, mod.module_steps.first)

    found = tasks.select { |t| t.subject == a }
    assert_equal [D::SIGN_OFF], found.map(&:type)
    assert_includes found.first.owners, @admin
    assert_not_includes found.first.owners, @person
  end

  test "not overdue when the only thing left is a locked quiz" do
    mod = learning_module!(steps: ["read"], questions: 1)
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    complete_step!(@person, mod.module_steps.first)
    assert_equal [D::OVERDUE], tasks.select { |t| t.subject == a }.map(&:type), "quiz open: theirs"
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: mod, correct_count: 0, question_count: 1) }
    assert_empty tasks.select { |t| t.subject == a }
  end

  test "a sign-off that is not ready yet produces no admin task" do
    mod = learning_module!(steps: ["read", "admin_sign_off"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course)
    assert_empty tasks.select { |t| t.subject == a }
  end

  test "an admin never owns the sign-off task on their own assignment, and it is dropped if nobody else can" do
    mod = learning_module!(steps: ["admin_sign_off"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@admin, course)

    only_self = D.new(admin_fallback: [@admin]).tasks.select { |t| t.subject == a }
    assert_empty only_self

    second = build_admin!(email_prefix: "second")
    both = D.new(admin_fallback: [@admin, second]).tasks.select { |t| t.subject == a }
    assert_equal [[second]], both.map(&:owners)
  end

  test "both tasks can exist at once" do
    mod = learning_module!(steps: ["admin_sign_off", "read"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    assert_equal [D::OVERDUE, D::SIGN_OFF].sort, tasks.select { |t| t.subject == a }.map(&:type).sort
  end

  test "task labels, display name and url" do
    a = learning_assign!(@person, @course, due_on: Date.today - 1)
    task = tasks.first
    assert_equal "Assigned checklist is overdue", task.humanized_type
    assert_equal "#{@person.email} — #{@course.learner_title}", task.subject_display_name
    assert_equal "#{@person.email} — #{@course.learner_title}", task.subject_display_name(redact_amounts: true)
    assert_equal "course_assignments", task.subject_class_key
    assert_equal "Checklist needs an admin sign-off", StacksTask::HUMANIZED_TYPES[D::SIGN_OFF]
  end

  test "the discovery is registered" do
    assert_includes Stacks::TaskBuilder::DISCOVERY_CLASSES, D
  end
end
```

```ruby
# test/lib/stacks/task_builder/course_assignment_live_revalidation_test.rb
require "test_helper"

# Production's Rails.cache is a per-process memory store, so clearing it in the
# worker that handled a request leaves the other workers' copies stale for up
# to 24h. The overdue pill is the payout block, so TaskBuilder must drop
# course-assignment tasks that are no longer true on every read.
class StacksTaskBuilderCourseAssignmentLiveRevalidationTest < ActiveSupport::TestCase
  D = Stacks::TaskBuilder::Discoveries::CourseAssignments

  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@store)
    build_admin!
    @person = learning_person!
    @mod = learning_module!(steps: ["read"])
    @assignment = learning_assign!(@person, learning_course!(modules: [@mod]), due_on: Date.today - 1)
  end

  def cached_types_for(person)
    Stacks::TaskBuilder.new.tasks_for(person).select { |t| t.subject.is_a?(CourseAssignment) }.map(&:type)
  end

  test "a cached overdue task disappears as soon as the assignment is finished, without clearing the cache" do
    assert_equal [D::OVERDUE], cached_types_for(@person)
    count_before = Stacks::TaskBuilder.new.task_count_for(@person)
    cached = @store.read(Stacks::TaskBuilder::CACHE_KEY)

    complete_step!(@person, @mod.module_steps.first)
    Stacks::Learning::Progress.refresh!(@person)
    # Simulate another worker: put the stale descriptors back.
    @store.write(Stacks::TaskBuilder::CACHE_KEY, cached)

    assert_empty cached_types_for(@person)
    assert_equal count_before - 1, Stacks::TaskBuilder.new.task_count_for(@person)
    assert_empty Stacks::TaskBuilder.new.tasks.select { |t| t.subject.is_a?(CourseAssignment) }
  end

  test "a still-true cached task is kept" do
    cached_types_for(@person)
    assert_equal [D::OVERDUE], cached_types_for(@person)
  end

  test "a cached task whose assignment was deleted is dropped" do
    cached_types_for(@person)
    cached = @store.read(Stacks::TaskBuilder::CACHE_KEY)
    @assignment.delete
    @store.write(Stacks::TaskBuilder::CACHE_KEY, cached)
    assert_empty cached_types_for(@person)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/task_builder`
Expected: `NameError` for `Discoveries::CourseAssignments`.

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/task_builder/discoveries/course_assignments.rb
module Stacks
  class TaskBuilder
    module Discoveries
      # Two tasks per outstanding CourseAssignment:
      #   overdue  — owned by the person, once past due_on and only while they
      #              still have something of their own to do. An admin's delay
      #              (a sign-off, a quiz retry grant) never makes someone overdue,
      #              because the pending-task pill on payables holds their payout.
      #   sign-off — owned by every admin except the assignee, while a sign-off
      #              step is ready.
      class CourseAssignments < Base
        OVERDUE = :course_assignment_overdue
        SIGN_OFF = :course_assignment_needs_admin_sign_off

        def tasks
          CourseAssignment.outstanding.includes(:course, admin_user: :full_time_periods).flat_map do |assignment|
            self.class.task_types_for(assignment).filter_map do |type|
              owners = type == OVERDUE ? [assignment.admin_user] : @admin_fallback.reject { |a| a.id == assignment.admin_user_id }
              # Not Base#task: its empty-owner fallback would hand an admin the
              # sign-off on their own checklist.
              next nil if owners.empty?
              StacksTask.new(type: type, subject: assignment, owners: owners)
            end
          end
        end

        def self.task_types_for(assignment, today: Date.today)
          return [] unless assignment.outstanding? && eligible?(assignment.admin_user, today)

          checklist = Stacks::Learning::Checklist.new(assignment)
          types = []
          types << OVERDUE if assignment.due_on < today && checklist.own_work_remaining?
          types << SIGN_OFF if checklist.ready_sign_off_steps.any?
          types
        end

        # Used by TaskBuilder to re-validate cached descriptors on every read.
        def self.live_types_by_id(ids)
          CourseAssignment.where(id: ids).includes(:course, admin_user: :full_time_periods)
            .to_h { |assignment| [assignment.id, task_types_for(assignment)] }
        end

        # Not ignored, and not departed. AdminUser.active alone would exclude
        # every brand-new account (no full-time period yet), which is exactly
        # who this is for.
        def self.eligible?(admin_user, today)
          return false if admin_user.nil? || admin_user.ignore?
          periods = admin_user.full_time_periods
          periods.empty? || periods.any? { |p| p.started_at <= today && (p.ended_at.nil? || p.ended_at >= today) }
        end
      end
    end
  end
end
```

In `lib/stacks/task_builder.rb`:

1. After the last `require_relative` line add `require_relative "task_builder/discoveries/course_assignments"`.
2. Add `Discoveries::CourseAssignments,` as the last entry of `DISCOVERY_CLASSES`.
3. Add to `SUBJECT_PRELOADS`: `"CourseAssignment" => [:admin_user, :course],`.
4. Replace `cached_descriptors` with:

```ruby
    def cached_descriptors
      @_cached_descriptors ||= drop_stale_course_assignment_descriptors(
        Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
          build_tasks.map { |t| descriptor_for(t) }
        end
      )
    end

    # Rails.cache is a per-process memory store in production, so clear_cache!
    # only reaches the worker that handled the write; the others would go on
    # showing a finished checklist as overdue (and holding the payout pill) for
    # up to CACHE_TTL. Re-check these descriptors against the database on every
    # read. Removal only: newly due tasks still wait for the next rebuild.
    def drop_stale_course_assignment_descriptors(descriptors)
      ids = descriptors.select { |d| d[:subject_type] == "CourseAssignment" }.map { |d| d[:subject_id] }.uniq
      return descriptors if ids.empty?

      live = Discoveries::CourseAssignments.live_types_by_id(ids)
      descriptors.reject do |d|
        d[:subject_type] == "CourseAssignment" && !live.fetch(d[:subject_id], []).include?(d[:type])
      end
    end
```

In `app/models/stacks_task.rb`:

1. In `HUMANIZED_TYPES`, before the closing `}.freeze`:

```ruby
    # Onboarding course issues
    course_assignment_overdue: "Assigned checklist is overdue",
    course_assignment_needs_admin_sign_off: "Checklist needs an admin sign-off",
```

2. In `subject_display_name`, add a branch directly after `when AdminUser then subject.email`:

```ruby
    when CourseAssignment then "#{subject.admin_user&.email} — #{subject.course&.learner_title}"
```

3. In `subject_url`, add a branch directly before `when System`:

```ruby
    when CourseAssignment
      helpers.respond_to?(:admin_course_assignment_path) ? helpers.admin_course_assignment_path(subject) : nil
```

In `lib/tasks/stacks.rake`, inside `task :daily_tasks`, immediately before the line that calls `Stacks::TaskBuilder.new.refresh!` (around line 628), add at the same indentation:

```ruby
      # Tick off what Stacks can now see for itself (Forecast account, payment
      # profile, Human Operating Manual) before tasks are rebuilt. Isolated so
      # a failure here never fails the daily pass.
      begin
        Stacks::Learning::Progress.refresh_all!
      rescue => e
        Rails.logger.error("[stacks:daily_tasks] Course progress refresh failed: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
```

Read the 20 lines around line 628 first and match how neighbouring blocks log and rescue.

- [ ] **Step 4: Run to verify they pass**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/task_builder test/lib/stacks/learning test/integration/payable_qbo_bills_test.rb test/integration/mcp_endpoint_test.rb`
Expected: all pass.

- [ ] **Step 5: Mutation check, then commit**

Temporarily make `drop_stale_course_assignment_descriptors` return `descriptors` unchanged; the first live-revalidation test must fail. Restore. Temporarily remove `&& checklist.own_work_remaining?`; the "only an admin sign-off remains" and "locked quiz" tests must fail. Restore.

```bash
git rev-parse --abbrev-ref HEAD
git add lib/stacks/task_builder.rb lib/stacks/task_builder/discoveries/course_assignments.rb app/models/stacks_task.rb lib/tasks/stacks.rake test/lib/stacks/task_builder
git commit -m "feat: pending tasks for overdue checklists and ready admin sign-offs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Authorization and the checklist page

**Files:**
- Modify: `app/models/admin_authorization.rb`
- Create: `app/admin/course_assignments.rb`
- Create: `app/views/admin/course_assignments/_show.html.erb`, `app/views/admin/course_assignments/quiz.html.erb`
- Test: `test/integration/admin_course_assignments_test.rb`

**Interfaces:**
- Consumes: `Checklist`, `Progress.refresh!`, `Quiz.submit!`, `ApplicationController#impersonating?`.
- Produces: routes `admin_course_assignment_path(a)`, `complete_step_admin_course_assignment_path(a, step_id:)`, `quiz_admin_course_assignment_path(a, learning_module_id:)`, `submit_quiz_…`, `recheck_…`, `sign_off_step_…`, `complete_step_for_…`, `grant_quiz_retry_…`, `waive_…`. `AdminAuthorization::LEARNING_ADMIN_ONLY` (Task 7 relies on the carve-out covering its resources).

Before writing code, read `app/admin/project_capsules.rb` (member actions and how it renders an ERB partial on `show`) and `app/admin/admin_users.rb:60-90` (impersonation). Follow their idiom.

- [ ] **Step 1: Write the failing integration tests**

```ruby
# test/integration/admin_course_assignments_test.rb
require "test_helper"

class AdminCourseAssignmentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = learning_person!(prefix: "boss", roles: ["admin"])
    @person = learning_person!
    @other = learning_person!(prefix: "other")
    @mod = learning_module!(steps: ["read", ["auto_check", "forecast_account"], "admin_sign_off"], questions: 2, pass_percent: 100)
    @course = learning_course!(modules: [@mod])
    @assignment = learning_assign!(@person, @course)
    @read, @auto, @sign_off = @mod.module_steps.to_a
  end

  def lead!
    user = learning_person!(prefix: "lead")
    PermissionGrant.create!(admin_user: user, permission: "lead", granted_by: @admin)
    user
  end

  def done?(person, step)
    StepCompletion.exists?(admin_user: person, module_step: step)
  end

  def all_right
    @mod.quiz_questions.to_h { |q| [q.id.to_s, q.correct_index.to_s] }
  end

  def all_wrong
    @mod.quiz_questions.to_h { |q| [q.id.to_s, ((q.correct_index + 1) % q.choices.size).to_s] }
  end

  # ── the person ────────────────────────────────────────────────────────────

  test "a person sees their own checklist in getting-set-up language" do
    sign_in @person
    get admin_course_assignment_path(@assignment)
    assert_response :success
    assert_includes response.body, @course.learner_title
    assert_includes response.body, @read.title
    assert_includes response.body, "Quick check"
    %w[quiz Quiz lesson training learner].each do |word|
      assert_not_includes response.body.gsub(/href="[^"]*"|action="[^"]*"/, ""), word, "person-facing page says #{word.inspect}"
    end
  end

  test "a person ticks a read step" do
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
    completion = StepCompletion.find_by!(admin_user: @person, module_step: @read)
    assert_equal "self", completion.source
    assert_nil completion.completed_by_id
  end

  test "a person cannot tick an auto_check or admin_sign_off step" do
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert done?(@person, @read), "positive control: the same request shape works for a read step"

    post complete_step_admin_course_assignment_path(@assignment, step_id: @auto.id)
    post complete_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @auto)
    assert_not done?(@person, @sign_off)
  end

  test "a person cannot tick a step from a module outside their course" do
    stray = learning_module!(steps: ["read"]).module_steps.first
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: stray.id)
    assert_not done?(@person, stray)
  end

  test "a person cannot see or act on someone else's checklist" do
    theirs = learning_assign!(@other, @course)
    sign_in @person
    get admin_course_assignment_path(@assignment)
    assert_response :success, "positive control: the session is live"

    get admin_course_assignment_path(theirs)
    assert_not_equal 200, response.status
    assert_not_includes response.body.to_s, @read.title
    post complete_step_admin_course_assignment_path(theirs, step_id: @read.id)
    assert_not done?(@other, @read)
    get quiz_admin_course_assignment_path(theirs, learning_module_id: @mod.id)
    assert_not_equal 200, response.status
    post submit_quiz_admin_course_assignment_path(theirs, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 0, QuizAttempt.count
  end

  test "a person gets no index" do
    sign_in @person
    get admin_course_assignments_path
    assert_not_equal 200, response.status
  end

  test "a person cannot sign off, mark done for, grant a retry or waive, even on their own" do
    sign_in @person
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @auto.id)
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    post waive_admin_course_assignment_path(@assignment), params: { waive_note: "nope" }
    assert_equal 0, StepCompletion.where(admin_user: @person).count
    assert_equal 0, QuizRetryGrant.count
    assert_nil @assignment.reload.waived_at
  end

  # ── the quick check ───────────────────────────────────────────────────────

  def finish_steps!
    [@read, @auto, @sign_off].each { |s| complete_step!(@person, s) }
  end

  test "the quick check is closed until the steps are done" do
    sign_in @person
    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 0, QuizAttempt.count
  end

  test "the quick check page shows questions and choices but never answers or explanations" do
    finish_steps!
    sign_in @person
    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_response :success
    assert_includes response.body, "Question 0?"
    assert_includes response.body, "wrong1"
    assert_not_includes response.body, "Because 0."
    assert_not_includes response.body, "correct_index"
  end

  test "failing shows the score only, then locks after the second attempt" do
    finish_steps!
    sign_in @person
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_wrong }
    assert_redirected_to admin_course_assignment_path(@assignment)
    follow_redirect!
    assert_includes response.body, "0 of 2"
    assert_not_includes response.body, "Because 0."

    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_wrong }
    follow_redirect!
    assert_includes response.body, "out of attempts"

    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 2, QuizAttempt.where(admin_user: @person).count
    assert_nil @assignment.reload.completed_at

    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
  end

  test "passing completes the checklist, and only then are explanations shown" do
    finish_steps!
    sign_in @person
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert @assignment.reload.completed_at.present?

    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_response :success
    assert_includes response.body, "Because 0."
  end

  # ── admins ────────────────────────────────────────────────────────────────

  test "an admin sees anyone's checklist and the index" do
    sign_in @admin
    get admin_course_assignment_path(@assignment)
    assert_response :success
    assert_includes response.body, "Sign off"
    get admin_course_assignments_path
    assert_response :success
    assert_includes response.body, @person.email
  end

  test "an admin signs off a ready step, stamped with who did it" do
    complete_step!(@person, @read)
    complete_step!(@person, @auto, source: "auto")
    sign_in @admin
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    completion = StepCompletion.find_by!(admin_user: @person, module_step: @sign_off)
    assert_equal ["admin", @admin.id], [completion.source, completion.completed_by_id]
  end

  test "an admin cannot sign off a step that is not ready, or a step that is not a sign-off" do
    sign_in @admin
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off), "earlier steps are not done"
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_not done?(@person, @read)
  end

  test "an admin marks a step done for someone, but not a sign-off through that route" do
    sign_in @admin
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @auto.id)
    completion = StepCompletion.find_by!(admin_user: @person, module_step: @auto)
    assert_equal ["admin", @admin.id], [completion.source, completion.completed_by_id]
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off)
  end

  test "an admin grants a retry and waives" do
    sign_in @admin
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { note: "was ill" }
    grant = QuizRetryGrant.find_by!(admin_user: @person, learning_module: @mod)
    assert_equal [@admin.id, "was ill"], [grant.granted_by_id, grant.note]

    post waive_admin_course_assignment_path(@assignment), params: { waive_note: "joined years ago" }
    @assignment.reload
    assert @assignment.waived_at.present?
    assert_equal [@admin.id, "joined years ago"], [@assignment.waived_by_id, @assignment.waive_note]
  end

  test "an admin can do none of the admin actions on their own checklist" do
    mine = learning_assign!(@admin, @course)
    sign_in @admin
    post complete_step_admin_course_assignment_path(mine, step_id: @read.id)
    assert done?(@admin, @read), "positive control: they can still tick their own read step"

    post complete_step_for_admin_course_assignment_path(mine, step_id: @auto.id)
    assert_not done?(@admin, @auto)
    complete_step!(@admin, @auto, source: "auto")
    post sign_off_step_admin_course_assignment_path(mine, step_id: @sign_off.id)
    assert_not done?(@admin, @sign_off)
    post grant_quiz_retry_admin_course_assignment_path(mine, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count
    post waive_admin_course_assignment_path(mine)
    assert_nil mine.reload.waived_at
  end

  test "an admin cannot delete an assignment" do
    sign_in @admin
    assert_raises(ActionController::RoutingError, NoMethodError) do
      delete "/admin/course_assignments/#{@assignment.id}"
    end
    assert CourseAssignment.exists?(@assignment.id)
  end

  test "an admin assigns by hand; assigned_by is stamped server-side and only due_on is editable" do
    sign_in @admin
    course = learning_course!(modules: [learning_module!])
    post admin_course_assignments_path, params: { course_assignment: { admin_user_id: @other.id, course_id: course.id, assigned_by_id: @person.id } }
    created = CourseAssignment.find_by!(admin_user: @other, course: course)
    assert_equal @admin.id, created.assigned_by_id

    patch admin_course_assignment_path(created), params: { course_assignment: { due_on: (Date.today + 30).to_s, admin_user_id: @person.id, completed_at: Time.current.to_s } }
    created.reload
    assert_equal Date.today + 30, created.due_on
    assert_equal @other.id, created.admin_user_id
    assert_nil created.completed_at
  end

  # ── impersonation ─────────────────────────────────────────────────────────

  test "while impersonating, the admin sees the person's view and every POST is refused" do
    finish = -> { [@read, @auto].each { |s| complete_step!(@person, s) } }
    sign_in @admin
    post impersonate_admin_admin_user_path(@person)
    get admin_course_assignment_path(@assignment)
    assert_response :success

    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_not done?(@person, @read)
    finish.call
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off)
    complete_step!(@person, @sign_off, source: "admin")
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 0, QuizAttempt.count
    post waive_admin_course_assignment_path(@assignment)
    assert_nil @assignment.reload.waived_at
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count
  end

  # ── past project leads (the blanket grant in AdminAuthorization) ──────────

  test "a lead who is not an admin cannot see someone else's checklist, the index, or act on it" do
    lead = lead!
    sign_in lead
    get admin_admin_user_path(@person)
    assert_response :success, "positive control: leads really do pass the blanket grant"

    get admin_course_assignment_path(@assignment)
    assert_not_equal 200, response.status
    get admin_course_assignments_path
    assert_not_equal 200, response.status
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_not done?(@person, @read)
    post waive_admin_course_assignment_path(@assignment)
    assert_nil @assignment.reload.waived_at
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off)
  end
end
```

Check how `PermissionGrant` rows are built in `test/integration/admin_permission_grants_test.rb` and copy that shape for `lead!` if it differs (a global grant has no subject).

- [ ] **Step 2: Run to verify it fails**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/integration/admin_course_assignments_test.rb`
Expected: `NameError: undefined local variable or method 'admin_course_assignment_path'`.

- [ ] **Step 3: Authorization carve-outs**

In `app/models/admin_authorization.rb`, add below `OWN_LEDGER_ITEM_DENY`:

```ruby
  # Onboarding courses. Authoring, and every record of someone's progress, is
  # admin-only: Hugh's rule is that only admins see a person's progress.
  LEARNING_ADMIN_ONLY = [
    Course, LearningModule, CourseModule, ModuleStep, QuizQuestion,
    Qualification, QualificationGrant, QuizAttempt, QuizRetryGrant,
    StepCompletion, ModuleCompletion,
  ].freeze
  # What a person may do on their OWN CourseAssignment.
  COURSE_ASSIGNMENT_ASSIGNEE_ACTIONS = [:read, :complete_step, :quiz, :submit_quiz, :recheck].freeze
```

In `authorized?`, immediately **above** the line `return true if (user.is_admin? || user.can_act_as_lead?)`:

```ruby
    # Must sit above the blanket lead grant below, or every past project lead
    # could read anyone's checklist and sign off or waive it.
    if subject == CourseAssignment || subject.is_a?(CourseAssignment)
      return true if user.is_admin?
      return subject.is_a?(CourseAssignment) &&
        subject.admin_user_id == user.id &&
        COURSE_ASSIGNMENT_ASSIGNEE_ACTIONS.include?(action)
    end
    return user.is_admin? if LEARNING_ADMIN_ONLY.any? { |klass| subject == klass || subject.is_a?(klass) }
```

- [ ] **Step 4: The resource**

```ruby
# app/admin/course_assignments.rb
ActiveAdmin.register CourseAssignment do
  menu label: "Assignments", parent: "Onboarding", priority: 1, if: proc { current_admin_user.is_admin? }
  # No destroy: an admin waives instead, so delete-and-recreate can't reset a due date.
  actions :index, :show, :new, :create, :edit, :update
  permit_params :admin_user_id, :course_id, :due_on
  config.filters = false
  config.sort_order = "created_at_desc"
  includes :admin_user, :course

  before_create do |assignment|
    assignment.assigned_by = current_admin_user
  end

  controller do
    helper_method :checklist, :acting_as_assignee?, :acting_as_admin?

    def checklist
      @checklist ||= Stacks::Learning::Checklist.new(resource)
    end

    # The signed-in person on their own checklist — never an admin impersonating them.
    def acting_as_assignee?
      !impersonating? && current_admin_user.id == resource.admin_user_id
    end

    # An admin acting on someone else's checklist, as themselves.
    def acting_as_admin?
      !impersonating? && current_admin_user.is_admin? && current_admin_user.id != resource.admin_user_id
    end

    def back(flash_opts = {})
      redirect_to admin_course_assignment_path(resource), flash_opts
    end

    # The authorization adapter already allowed the action name; these guards
    # are the real enforcement of who may do what on which row.
    def require_assignee!
      return true if acting_as_assignee? && resource.outstanding?
      back(alert: impersonating? ? "Stop impersonating first." : "That isn't available on this checklist.")
      false
    end

    def require_admin!
      return true if acting_as_admin?
      back(alert: impersonating? ? "Stop impersonating first." : "Only an admin can do that, and not on their own checklist.")
      false
    end

    def step_state_from_params
      checklist.step_state(params[:step_id])
    end

    def module_state_from_params
      checklist.module_state(params[:learning_module_id])
    end

    # Only due_on is editable after creation.
    def update
      params[:course_assignment] = ActionController::Parameters.new(due_on: params.dig(:course_assignment, :due_on))
      super
    end
  end

  index download_links: false do
    column :person do |a|
      link_to a.admin_user.email, admin_course_assignment_path(a)
    end
    column :course
    column :assigned_on
    column :due_on
    column :state do |a|
      if a.completed? then status_tag("Done", class: "yes")
      elsif a.waived? then status_tag("Waived")
      elsif a.due_on < Date.today then status_tag("Overdue", class: "no")
      else status_tag("In progress")
      end
    end
    column :steps do |a|
      cl = Stacks::Learning::Checklist.new(a)
      "#{cl.steps_done} of #{cl.steps_total}"
    end
    actions defaults: false do |a|
      item "Edit due date", edit_admin_course_assignment_path(a)
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      if f.object.new_record?
        f.input :admin_user, as: :select, collection: AdminUser.order(:email).map { |u| [u.email, u.id] }
        f.input :course, as: :select, collection: Course.order(:name)
        f.input :due_on, as: :datepicker, hint: "Leave blank to use the course's grace period."
      else
        f.input :due_on, as: :datepicker
      end
    end
    f.actions
  end

  show title: proc { |a| a.course.learner_title } do
    render "show", assignment: resource, checklist: checklist
  end

  member_action :complete_step, method: :post do
    next unless require_assignee!
    state = step_state_from_params
    if state.nil? || state.done? || !%w[read do].include?(state.step.kind)
      next back(alert: "That step can't be marked done here.")
    end
    StepCompletion.create!(admin_user: resource.admin_user, module_step: state.step, completed_at: Time.current, source: "self")
    Stacks::Learning::Progress.refresh!(resource.admin_user)
    back(notice: "Done.")
  end

  member_action :quiz, method: :get do
    @module_state = module_state_from_params
    viewer_may_review = current_admin_user.is_admin? && !impersonating?
    if @module_state.nil? || !@module_state.has_quiz?
      next back(alert: "There is no quick check here.")
    end
    case @module_state.quiz_state
    when :passed
      @review = true
    when :open
      next back(alert: "Stop impersonating first.") if impersonating?
      next back(alert: "Only the person can take their quick check.") unless acting_as_assignee?
      @review = false
    else
      next back(alert: "The quick check isn't open.") unless viewer_may_review
      @review = true
    end
    @page_title = "Quick check: #{@module_state.learning_module.name}"
    render "admin/course_assignments/quiz"
  end

  member_action :submit_quiz, method: :post do
    next unless require_assignee!
    learning_module = module_state_from_params&.learning_module
    next back(alert: "There is no quick check here.") if learning_module.nil?
    result = Stacks::Learning::Quiz.submit!(assignment: resource, learning_module: learning_module, answers: params[:answers])
    back(result.status == :passed ? { notice: result.message } : { alert: result.message })
  end

  member_action :recheck, method: :post do
    next back(alert: "Stop impersonating first.") if impersonating?
    Stacks::Learning::Progress.refresh!(resource.admin_user)
    Stacks::TaskBuilder.clear_cache!
    back(notice: "Checked again.")
  end

  member_action :sign_off_step, method: :post do
    next unless require_admin!
    state = step_state_from_params
    next back(alert: "That step isn't ready to sign off.") if state.nil? || !state.ready
    StepCompletion.create!(admin_user: resource.admin_user, module_step: state.step, completed_at: Time.current,
                           source: "admin", completed_by: current_admin_user)
    Stacks::Learning::Progress.refresh!(resource.admin_user)
    back(notice: "Signed off.")
  end

  member_action :complete_step_for, method: :post do
    next unless require_admin!
    state = step_state_from_params
    if state.nil? || state.done? || state.step.kind == "admin_sign_off"
      next back(alert: "That step can't be marked done here.")
    end
    StepCompletion.create!(admin_user: resource.admin_user, module_step: state.step, completed_at: Time.current,
                           source: "admin", completed_by: current_admin_user)
    Stacks::Learning::Progress.refresh!(resource.admin_user)
    back(notice: "Marked done for #{resource.admin_user.email}.")
  end

  member_action :grant_quiz_retry, method: :post do
    next unless require_admin!
    state = module_state_from_params
    next back(alert: "There is no quick check here.") if state.nil? || !state.has_quiz?
    QuizRetryGrant.create!(admin_user: resource.admin_user, learning_module: state.learning_module,
                           granted_by: current_admin_user, note: params[:note].presence)
    back(notice: "Allowed one more attempt.")
  end

  member_action :waive, method: :post do
    next unless require_admin!
    next back(alert: "This checklist is already closed.") unless resource.outstanding?
    resource.update!(waived_at: Time.current, waived_by: current_admin_user, waive_note: params[:waive_note].presence)
    back(notice: "Waived.")
  end
end
```

Implementation notes (verify each against the running tests, and adjust the code — not the tests — if ActiveAdmin 2.9 behaves differently):
- `next` inside a `member_action` block returns from the action; `next unless require_assignee!` works because the guard has already redirected.
- The "viewer_may_review" branch lets an admin look at a person's quiz with answers; a non-admin only ever reaches `@review = true` after passing.
- `recheck` is allowed for the assignee and admins by the adapter (`:recheck` is in the assignee list; admins pass everything).
- If `before_create` in the ActiveAdmin DSL does not fire for `create`, override `create` in the `controller` block instead and set `assigned_by` there. Either way `assigned_by_id` must never come from params (it is not in `permit_params`).
- The `update` override replaces the params so that even a permitted `admin_user_id` / `course_id` cannot change on edit.
- "No destroy": the test accepts either a routing error or a `NoMethodError` from the missing route helper; what matters is that the row survives.

- [ ] **Step 5: The checklist partial**

```erb
<%# app/views/admin/course_assignments/_show.html.erb
  The person-facing checklist. Copy here must read as getting set up: never
  "course", "lesson", "training", "learner" or "quiz" (a quiz is a "Quick check").
  Locals: assignment (CourseAssignment), checklist (Stacks::Learning::Checklist).
%>
<% course = assignment.course %>
<div class="dashboard-modules table index_table index">
  <div class="dashboard-module">
    <div class="module-body">
      <% if course.description.present? %>
        <div class="markdown-body"><%= raw RDiscount.new(course.description).to_html %></div>
      <% end %>
      <p>
        <strong><%= checklist.steps_done %> of <%= checklist.steps_total %> steps done.</strong>
        <% if assignment.completed? %>
          <span class="pill ready">All done <%= assignment.completed_at.to_date.to_s(:long) %></span>
        <% elsif assignment.waived? %>
          <span class="pill">Waived<%= " by #{assignment.waived_by.email}" if assignment.waived_by %></span>
        <% else %>
          Please finish by <strong><%= assignment.due_on.to_s(:long) %></strong>.
        <% end %>
      </p>
      <% if assignment.outstanding? && !impersonating? %>
        <%= button_to "Check again", recheck_admin_course_assignment_path(assignment), method: :post, form: { style: "display:inline" } %>
      <% end %>
      <% if assignment.outstanding? && acting_as_admin? %>
        <%= form_tag waive_admin_course_assignment_path(assignment), method: :post, style: "display:inline; margin-left: 12px;" do %>
          <%= text_field_tag :waive_note, nil, placeholder: "Why waive? (optional)" %>
          <%= submit_tag "Waive", data: { confirm: "Waive this for #{assignment.admin_user.email}? Nothing will be granted." } %>
        <% end %>
      <% end %>
    </div>
  </div>
</div>

<% checklist.modules.each do |mod_state| %>
  <% mod = mod_state.learning_module %>
  <div class="panel">
    <h3>
      <%= mod.name %>
      <% if mod_state.done? %><span class="pill ready">Done</span><% end %>
    </h3>
    <div class="panel_contents">
      <% if mod.summary.present? %>
        <div class="markdown-body"><%= raw RDiscount.new(mod.summary).to_html %></div>
      <% end %>
      <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
        <tbody>
          <% mod_state.steps.each_with_index do |step_state, idx| %>
            <% step = step_state.step %>
            <tr class="<%= idx.even? ? "even" : "odd" %>">
              <td class="col" style="width: 32px;"><%= step_state.done? ? "✅" : "⬜" %></td>
              <td class="col">
                <%= step.title %>
                <% if step.notion_url.present? %>
                  &nbsp;<%= link_to "Open in Notion ↗", step.notion_url, target: "_blank", rel: "noopener" %>
                <% end %>
              </td>
              <td class="col text-right">
                <% if step_state.done? %>
                  <% c = step_state.completion %>
                  <%= c.completed_at.to_date.to_s(:long) %><%= " · #{c.completed_by.email}" if c.completed_by %>
                <% elsif !assignment.outstanding? %>
                  —
                <% else %>
                  <% case step.kind %>
                  <% when "read", "do" %>
                    <% if acting_as_assignee? %>
                      <%= button_to "Mark as done", complete_step_admin_course_assignment_path(assignment, step_id: step.id), method: :post %>
                    <% end %>
                  <% when "auto_check" %>
                    Not yet — Stacks checks this automatically
                  <% when "admin_sign_off" %>
                    <% if acting_as_admin? && step_state.ready %>
                      <%= button_to "Sign off", sign_off_step_admin_course_assignment_path(assignment, step_id: step.id), method: :post %>
                    <% else %>
                      Waiting on an admin
                    <% end %>
                  <% end %>
                  <% if acting_as_admin? && step.kind != "admin_sign_off" %>
                    <%= button_to "Mark done for them", complete_step_for_admin_course_assignment_path(assignment, step_id: step.id), method: :post, data: { confirm: "Mark this done for #{assignment.admin_user.email}?" } %>
                  <% end %>
                <% end %>
              </td>
            </tr>
          <% end %>
          <% if mod_state.has_quiz? %>
            <tr>
              <td class="col"><%= mod_state.quiz_state == :passed ? "✅" : "⬜" %></td>
              <td class="col"><strong>Quick check</strong></td>
              <td class="col text-right">
                <% case mod_state.quiz_state %>
                <% when :passed %>
                  Passed · <%= link_to "Review answers", quiz_admin_course_assignment_path(assignment, learning_module_id: mod.id) %>
                <% when :not_open %>
                  Opens when the steps above are done
                <% when :open %>
                  <% if acting_as_assignee? %>
                    <%= link_to "Take the quick check →", quiz_admin_course_assignment_path(assignment, learning_module_id: mod.id) %>
                    (<%= pluralize(mod_state.attempts_left, "attempt") %> left)
                  <% else %>
                    Open · <%= pluralize(mod_state.attempts_left, "attempt") %> left
                  <% end %>
                <% when :locked %>
                  <% if acting_as_admin? %>
                    Out of attempts.
                    <%= form_tag grant_quiz_retry_admin_course_assignment_path(assignment, learning_module_id: mod.id), method: :post, style: "display:inline" do %>
                      <%= text_field_tag :note, nil, placeholder: "Note (optional)" %>
                      <%= submit_tag "Allow another attempt" %>
                    <% end %>
                  <% else %>
                    You're out of attempts. Ask an admin to allow another.
                  <% end %>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  </div>
<% end %>
```

`acting_as_assignee?`, `acting_as_admin?` and `impersonating?` are controller helper methods and are available in the partial. If `render "show", …` inside the `show do` block cannot find the partial, use `render partial: "admin/course_assignments/show", locals: { … }` as `app/admin/admin_users.rb` does for its own show partial.

The language test strips `href`/`action` attributes before looking for the word "quiz" (routes contain it). Make sure no visible text, button label, placeholder, `class` or `id` in the person's view contains "quiz", "lesson", "training" or "learner". Admin-only controls may say what they like but none of the above do.

- [ ] **Step 6: The quick-check page**

```erb
<%# app/views/admin/course_assignments/quiz.html.erb
  @review false: the form (prompts and choices only — never answers).
  @review true:  read-only, with the correct answer and explanation. Reached
                 only after a pass, or by an admin.
%>
<% assignment = resource %>
<% mod = @module_state.learning_module %>
<% questions = mod.quiz_questions.to_a %>
<div class="panel">
  <h3>Quick check: <%= mod.name %></h3>
  <div class="panel_contents">
    <% if @review %>
      <% questions.each_with_index do |q, i| %>
        <p><strong><%= i + 1 %>. <%= q.prompt %></strong></p>
        <p>Answer: <%= q.choices[q.correct_index] %></p>
        <% if q.explanation.present? %><p><em><%= q.explanation %></em></p><% end %>
      <% end %>
      <p><%= link_to "← Back", admin_course_assignment_path(assignment) %></p>
    <% else %>
      <p>
        Answer every question. You need <%= (mod.quiz_pass_percent * questions.size / 100.0).ceil %> of <%= questions.size %> to pass,
        and you have <%= pluralize(@module_state.attempts_left, "attempt") %> left. After that an admin has to allow another, so read the pages first.
      </p>
      <%= form_tag submit_quiz_admin_course_assignment_path(assignment, learning_module_id: mod.id), method: :post do %>
        <% questions.each_with_index do |q, i| %>
          <fieldset style="margin-bottom: 16px;">
            <p><strong><%= i + 1 %>. <%= q.prompt %></strong></p>
            <% q.choices.each_with_index.to_a.shuffle.each do |choice, original_index| %>
              <p>
                <label>
                  <%= radio_button_tag "answers[#{q.id}]", original_index, false, required: true %>
                  <%= choice %>
                </label>
              </p>
            <% end %>
          </fieldset>
        <% end %>
        <%= submit_tag "Submit answers", data: { confirm: "Submit? This uses one attempt." } %>
        &nbsp;<%= link_to "Not yet", admin_course_assignment_path(assignment) %>
      <% end %>
    <% end %>
  </div>
</div>
```

`radio_button_tag "answers[12]", 3` generates the id `answers_12_3`; that is not visible text. If the language test trips on an `id="…"` containing nothing forbidden, leave it; if you rename params, keep `params[:answers]` as the hash the controller reads.

If the template does not render inside the ActiveAdmin chrome, look at how another custom GET `member_action` or `page_action` in `app/admin/` renders an ERB view and copy it.

- [ ] **Step 7: Run to verify it passes**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/integration/admin_course_assignments_test.rb test/integration/admin_permission_grants_test.rb test/integration/admin_project_capsule_sign_off_test.rb test/lib/stacks/task_builder`
Expected: all pass.

- [ ] **Step 8: Mutation checks, then commit**

1. Move the `CourseAssignment` carve-out below the blanket lead grant: the "a lead who is not an admin" test must fail. Restore.
2. Make `require_admin!` return true unconditionally: the "a person cannot sign off…" and "own checklist" tests must fail. Restore.
3. Make `acting_as_assignee?` ignore `impersonating?`: the impersonation test must fail. Restore.
4. In `quiz`, force `@review = true`: the "never answers or explanations" test must fail. Restore.

```bash
git rev-parse --abbrev-ref HEAD
git add app/models/admin_authorization.rb app/admin/course_assignments.rb app/views/admin/course_assignments test/integration/admin_course_assignments_test.rb
git commit -m "feat: checklist page, quick check and admin sign-off for course assignments

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Admin authoring and the profile module

**Files:**
- Create: `app/admin/courses.rb`, `app/admin/learning_modules.rb`, `app/admin/qualifications.rb`, `app/admin/qualification_grants.rb`
- Create: `app/views/admin/admin_users/_learning.html.erb`
- Modify: `app/views/admin/admin_users/_show.html.erb` (one `render` line)
- Test: `test/integration/admin_course_authoring_test.rb`, `test/integration/admin_user_learning_module_test.rb`

**Interfaces:**
- Consumes: `AdminAuthorization::LEARNING_ADMIN_ONLY` carve-out (Task 6), `QuizQuestion#choices_text=`, `AutoChecks.options_for_select`, `Checklist#steps_done/#steps_total`.
- Produces: routes `admin_courses_path`, `admin_learning_modules_path`, `admin_qualifications_path`, `admin_qualification_grants_path`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/integration/admin_course_authoring_test.rb
require "test_helper"

class AdminCourseAuthoringTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = learning_person!(prefix: "boss", roles: ["admin"])
    @mod = learning_module!(steps: ["read"], questions: 1)
    @course = learning_course!(modules: [@mod])
    @qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
  end

  def lead!
    user = learning_person!(prefix: "lead")
    PermissionGrant.create!(admin_user: user, permission: "lead", granted_by: @admin)
    user
  end

  AUTHORING_PATHS = %i[admin_courses_path admin_learning_modules_path admin_qualifications_path admin_qualification_grants_path].freeze

  test "an admin can open every authoring index, new and edit page" do
    sign_in @admin
    AUTHORING_PATHS.each do |helper|
      get send(helper)
      assert_response :success, helper.to_s
    end
    [new_admin_course_path, edit_admin_course_path(@course), admin_course_path(@course),
     new_admin_learning_module_path, edit_admin_learning_module_path(@mod), admin_learning_module_path(@mod),
     new_admin_qualification_path, edit_admin_qualification_path(@qual),
     new_admin_qualification_grant_path].each do |path|
      get path
      assert_response :success, path
    end
  end

  test "a lead and an ordinary person can open none of them, and the answers never leak" do
    [lead!, learning_person!].each do |user|
      sign_in user
      get admin_admin_user_path(user)
      assert_response :success, "positive control: signed in"
      AUTHORING_PATHS.each do |helper|
        get send(helper)
        assert_not_equal 200, response.status, "#{user.email} reached #{helper}"
      end
      get admin_learning_module_path(@mod)
      assert_not_equal 200, response.status
      assert_not_includes response.body.to_s, "Because 0."
      get edit_admin_learning_module_path(@mod)
      assert_not_equal 200, response.status
      sign_out user
    end
  end

  test "an admin creates a module with a step and a question whose choices are typed one per line" do
    sign_in @admin
    post admin_learning_modules_path, params: { learning_module: {
      name: "How to send a weekly ship", slug: "weekly-ship", quiz_pass_percent: 80,
      module_steps_attributes: { "0" => { position: 0, kind: "auto_check", title: "Have a Forecast account", auto_check_key: "forecast_account" } },
      quiz_questions_attributes: { "0" => { position: 0, prompt: "When?", choices_text: "Friday\nMonday\n", correct_index: 0, explanation: "Fridays." } },
    } }
    mod = LearningModule.find_by!(slug: "weekly-ship")
    assert_equal ["auto_check", "forecast_account"], [mod.module_steps.first.kind, mod.module_steps.first.auto_check_key]
    assert_equal %w[Friday Monday], mod.quiz_questions.first.choices
  end

  test "an admin builds a course from existing modules in order" do
    other = learning_module!
    sign_in @admin
    post admin_courses_path, params: { course: {
      name: "Great Project Lead", slug: "great-pl", learner_title: "Becoming a Project Lead", grace_period_days: 30,
      qualification_id: @qual.id,
      course_modules_attributes: { "0" => { learning_module_id: other.id, position: 2 }, "1" => { learning_module_id: @mod.id, position: 1 } },
    } }
    course = Course.find_by!(slug: "great-pl")
    assert_equal [@mod, other], course.ordered_modules
    assert_equal @qual, course.qualification
  end

  test "an admin grants a qualification by hand; granted_by is stamped server-side" do
    person = learning_person!
    sign_in @admin
    post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: person.id, qualification_id: @qual.id, note: "pre-dates Stacks", granted_by_id: person.id } }
    grant = QualificationGrant.find_by!(admin_user: person, qualification: @qual)
    assert_equal @admin.id, grant.granted_by_id
    assert grant.granted_at.present?
  end

  test "an admin cannot grant themselves a qualification" do
    sign_in @admin
    post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: @admin.id, qualification_id: @qual.id } }
    assert_equal 0, QualificationGrant.where(admin_user: @admin).count
  end

  test "an impersonating admin cannot grant a qualification" do
    person = learning_person!
    sign_in @admin
    post impersonate_admin_admin_user_path(person)
    post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: person.id, qualification_id: @qual.id } }
    assert_equal 0, QualificationGrant.count
  end
end
```

```ruby
# test/integration/admin_user_learning_module_test.rb
require "test_helper"

class AdminUserLearningModuleTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = learning_person!(prefix: "boss", roles: ["admin"])
    @person = learning_person!
    @mod = learning_module!(steps: ["read", "do"])
    @course = learning_course!(modules: [@mod])
  end

  test "nothing renders for a person with no assignment and no badge" do
    sign_in @person
    get admin_admin_user_path(@person)
    assert_response :success
    assert_not_includes response.body, "Getting on board"
    assert_not_includes response.body, "Badges"
  end

  test "the person sees their checklist with progress, due date and a link" do
    a = learning_assign!(@person, @course)
    complete_step!(@person, @mod.module_steps.first)
    sign_in @person
    get admin_admin_user_path(@person)
    assert_response :success
    assert_includes response.body, @course.learner_title
    assert_includes response.body, "1 of 2 steps done"
    assert_includes response.body, admin_course_assignment_path(a)
  end

  test "an admin sees it on someone else's profile" do
    learning_assign!(@person, @course)
    sign_in @admin
    get admin_admin_user_path(@person)
    assert_includes response.body, @course.learner_title
  end

  test "a lead does not see it on someone else's profile" do
    learning_assign!(@person, @course)
    badge = Qualification.create!(name: "Secret Badge #{SecureRandom.hex(3)}", kind: "badge")
    QualificationGrant.create!(admin_user: @person, qualification: badge, granted_at: Time.current)
    lead = learning_person!(prefix: "lead")
    PermissionGrant.create!(admin_user: lead, permission: "lead", granted_by: @admin)
    sign_in lead
    get admin_admin_user_path(@person)
    assert_response :success, "positive control: the lead can open the profile"
    assert_not_includes response.body, @course.learner_title
    assert_not_includes response.body, badge.name
  end

  test "badges show even with no assignment" do
    badge = Qualification.create!(name: "Hand Granted #{SecureRandom.hex(3)}", kind: "qualification")
    QualificationGrant.create!(admin_user: @person, qualification: badge, granted_at: Time.current)
    sign_in @person
    get admin_admin_user_path(@person)
    assert_includes response.body, "Badges"
    assert_includes response.body, badge.name
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/integration/admin_course_authoring_test.rb test/integration/admin_user_learning_module_test.rb`
Expected: `NameError` for `admin_courses_path`.

- [ ] **Step 3: Authoring resources**

```ruby
# app/admin/qualifications.rb
ActiveAdmin.register Qualification do
  menu label: "Qualifications & Badges", parent: "Onboarding", priority: 4, if: proc { current_admin_user.is_admin? }
  permit_params :name, :description, :kind
  config.filters = false

  index download_links: false do
    column :name
    column :kind
    column :holders do |q|
      q.qualification_grants.count
    end
    actions
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :name
      f.input :kind, as: :select, collection: Qualification::KINDS, include_blank: false,
        hint: "A course grants a qualification; a module grants a badge."
      f.input :description
    end
    f.actions
  end
end
```

```ruby
# app/admin/qualification_grants.rb
ActiveAdmin.register QualificationGrant do
  menu label: "Grants", parent: "Onboarding", priority: 5, if: proc { current_admin_user.is_admin? }
  actions :index, :new, :create
  permit_params :admin_user_id, :qualification_id, :note
  config.filters = false
  includes :admin_user, :qualification, :granted_by

  controller do
    # Granted by hand: stamped with the acting admin, never from the client,
    # never while impersonating, and never to oneself.
    def create
      attrs = permitted_params[:qualification_grant] || {}
      if impersonating?
        return redirect_to admin_qualification_grants_path, alert: "Stop impersonating first."
      end
      if attrs[:admin_user_id].to_i == current_admin_user.id
        return redirect_to admin_qualification_grants_path, alert: "You can't grant yourself a qualification."
      end
      @qualification_grant = QualificationGrant.new(attrs.to_h.merge(granted_by: current_admin_user, granted_at: Time.current))
      if @qualification_grant.save
        redirect_to admin_qualification_grants_path, notice: "Granted."
      else
        render :new
      end
    end
  end

  index download_links: false do
    column :person do |g|
      g.admin_user.email
    end
    column :qualification
    column :granted_at
    column :granted_by do |g|
      g.granted_by&.email || "Earned"
    end
    column :note
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :admin_user, as: :select, collection: AdminUser.order(:email).map { |u| [u.email, u.id] }
      f.input :qualification, as: :select, collection: Qualification.order(:name)
      f.input :note
    end
    f.actions
  end
end
```

```ruby
# app/admin/learning_modules.rb
ActiveAdmin.register LearningModule do
  menu label: "Modules", parent: "Onboarding", priority: 3, if: proc { current_admin_user.is_admin? }
  permit_params :name, :slug, :summary, :notion_url, :quiz_pass_percent, :qualification_id,
    module_steps_attributes: [:id, :position, :kind, :title, :notion_url, :auto_check_key, :_destroy],
    quiz_questions_attributes: [:id, :position, :prompt, :choices_text, :correct_index, :explanation, :_destroy]
  config.filters = false

  index download_links: false do
    column :name
    column :slug
    column :steps do |m|
      m.module_steps.size
    end
    column :questions do |m|
      m.quiz_questions.size
    end
    column :courses do |m|
      m.courses.map(&:name).join(", ")
    end
    actions
  end

  show do
    attributes_table do
      row :name
      row :slug
      row :summary
      row :notion_url
      row :quiz_pass_percent
      row :qualification
    end
    panel "Steps" do
      table_for resource.module_steps do
        column :position
        column :kind
        column :title
        column :auto_check_key
        column :notion_url
      end
    end
    panel "Quiz questions" do
      table_for resource.quiz_questions do
        column :position
        column :prompt
        column :choices do |q|
          q.choices.each_with_index.map { |c, i| i == q.correct_index ? "✔ #{c}" : c }.join(" · ")
        end
        column :explanation
      end
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs "Module" do
      f.input :name
      f.input :slug, hint: "Stable identifier. Don't change it once people have started."
      f.input :summary, hint: "Markdown. Shown to the person above the steps."
      f.input :notion_url
      f.input :quiz_pass_percent, hint: "Only used if the module has questions."
      f.input :qualification, as: :select, collection: Qualification.where(kind: "badge").order(:name),
        hint: "Optional badge granted when someone finishes this module."
    end
    f.has_many :module_steps, heading: "Steps", allow_destroy: true, new_record: "Add a step" do |s|
      s.input :position
      s.input :kind, as: :select, collection: ModuleStep::KINDS, include_blank: false
      s.input :title, hint: "Phrase it as an action for the person."
      s.input :notion_url
      s.input :auto_check_key, as: :select, collection: Stacks::Learning::AutoChecks.options_for_select,
        include_blank: true, hint: "Only for auto_check steps."
    end
    f.has_many :quiz_questions, heading: "Quiz questions", allow_destroy: true, new_record: "Add a question" do |q|
      q.input :position
      q.input :prompt
      q.input :choices_text, as: :text, label: "Choices", hint: "One per line, 2 to 6.", input_html: { rows: 5 }
      q.input :correct_index, hint: "0 is the first choice."
      q.input :explanation, hint: "Shown only after the person passes."
    end
    f.actions
  end
end
```

```ruby
# app/admin/courses.rb
ActiveAdmin.register Course do
  menu label: "Courses", parent: "Onboarding", priority: 2, if: proc { current_admin_user.is_admin? }
  permit_params :name, :slug, :learner_title, :description, :grace_period_days, :auto_assign, :qualification_id,
    course_modules_attributes: [:id, :learning_module_id, :position, :_destroy]
  config.filters = false

  index download_links: false do
    column :name
    column :learner_title
    column :auto_assign
    column :grace_period_days
    column :modules do |c|
      c.course_modules.size
    end
    column :assigned do |c|
      c.course_assignments.count
    end
    actions
  end

  show do
    attributes_table do
      row :name
      row :slug
      row :learner_title
      row :description
      row :grace_period_days
      row :auto_assign
      row :qualification
    end
    panel "Modules" do
      table_for resource.course_modules.includes(:learning_module) do
        column :position
        column :module do |cm|
          link_to cm.learning_module.name, admin_learning_module_path(cm.learning_module)
        end
      end
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs "Course" do
      f.input :name
      f.input :slug
      f.input :learner_title, hint: "What the assigned person sees. Avoid the words course, training and quiz."
      f.input :description, hint: "Markdown. Shown to the person at the top of their checklist."
      f.input :grace_period_days, hint: "Days from assignment until it's due."
      f.input :auto_assign, hint: "Assign to every newly discovered company-email person. Existing people are not affected."
      f.input :qualification, as: :select, collection: Qualification.where(kind: "qualification").order(:name)
    end
    f.has_many :course_modules, heading: "Modules", allow_destroy: true, new_record: "Add a module" do |cm|
      cm.input :position
      cm.input :learning_module, as: :select, collection: LearningModule.order(:name)
    end
    f.actions
  end
end
```

If the "Onboarding" parent menu shows for non-admins as an empty item, that is acceptable only if it is hidden when it has no visible children (ActiveAdmin hides childless parents by default); confirm by signing in as a non-admin in a test: `assert_not_includes response.body, ">Onboarding<"` on the profile page — add that assertion to "nothing renders for a person with no assignment and no badge".

- [ ] **Step 4: Profile module**

```erb
<%# app/views/admin/admin_users/_learning.html.erb
  A person's checklists and badges. Shown only to the person themselves and to
  admins — never to leads viewing someone else's profile.
%>
<% viewer_allowed = current_admin_user.is_admin? || current_admin_user.id == resource.id %>
<% assignments = viewer_allowed ? resource.course_assignments.includes(:course).order(:assigned_on, :id).to_a : [] %>
<% grants = viewer_allowed ? resource.qualification_grants.includes(:qualification).order(:granted_at).to_a : [] %>
<% if assignments.any? || grants.any? %>
  <div class="dashboard-modules table index_table index">
    <div class="dashboard-module">
      <div class="module-header">
        <p>Getting on board</p>
      </div>
      <div class="module-body">
        <% if assignments.any? %>
          <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
            <tbody>
              <% assignments.each_with_index do |assignment, idx| %>
                <% checklist = Stacks::Learning::Checklist.new(assignment) %>
                <tr class="<%= idx.even? ? "even" : "odd" %>">
                  <td class="col"><%= link_to "#{assignment.course.learner_title} →", admin_course_assignment_path(assignment) %></td>
                  <td class="col"><%= checklist.steps_done %> of <%= checklist.steps_total %> steps done</td>
                  <td class="col text-right">
                    <% if assignment.completed? %>
                      <span class="pill ready">Done</span>
                    <% elsif assignment.waived? %>
                      <span class="pill">Waived</span>
                    <% elsif assignment.due_on < Date.today %>
                      <span class="pill at_risk">Was due <%= assignment.due_on.to_s(:long) %></span>
                    <% else %>
                      Due <%= assignment.due_on.to_s(:long) %>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
        <% if grants.any? %>
          <p style="margin-top: 12px;">
            <strong>Badges:</strong>
            <% grants.each do |grant| %>
              <span class="pill ready" style="margin-left: 4px;"><%= grant.qualification.name %></span>
            <% end %>
          </p>
        <% end %>
      </div>
    </div>
  </div>
<% end %>
```

In `app/views/admin/admin_users/_show.html.erb`, insert this single line immediately after the closing `</div>` of the first `<div class="dashboard-modules table index_table index">` block that contains "Balance" and "Pending Tasks" (i.e. directly before the `<% if current_admin_user.is_admin? && resource.permission_grants.any? %>` line):

```erb
<%= render partial: "admin/admin_users/learning" %>
```

- [ ] **Step 5: Run to verify they pass**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/integration/admin_course_authoring_test.rb test/integration/admin_user_learning_module_test.rb test/integration/admin_course_assignments_test.rb test/integration/admin_permission_grants_test.rb`
Expected: all pass.

- [ ] **Step 6: Mutation check, then commit**

Remove the `LEARNING_ADMIN_ONLY` line from `AdminAuthorization#authorized?`: the "a lead and an ordinary person can open none of them" test must fail for the lead. Restore. In `_learning.html.erb` set `viewer_allowed = true`: "a lead does not see it" must fail. Restore.

```bash
git rev-parse --abbrev-ref HEAD
git add app/admin/courses.rb app/admin/learning_modules.rb app/admin/qualifications.rb app/admin/qualification_grants.rb app/views/admin/admin_users test/integration/admin_course_authoring_test.rb test/integration/admin_user_learning_module_test.rb
git commit -m "feat: admin authoring for courses and modules, and the profile checklist module

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Seed the Wayfinding course

**Files:**
- Create: `db/seeds/learning/wayfinding.yml` — copy verbatim from `/private/tmp/claude-501/-Users-hhff-Documents-Code-stacks/4dae38b1-bded-4ad3-a8ae-2aec3fcff8db/scratchpad/wayfinding.yml` (already drafted from Notion and reviewed; do not rewrite its content)
- Create: `lib/stacks/learning/seeder.rb`
- Modify: `lib/tasks/stacks.rake` (new task inside the existing `namespace :stacks`)
- Test: `test/lib/stacks/learning/seeder_test.rb`

**Interfaces:**
- Consumes: Task 1 models, `AutoChecks.keys`.
- Produces: `Stacks::Learning::Seeder.call(path) → Course`; rake task `stacks:seed_wayfinding_course`.

YAML shape (already what the file has): top-level `qualification` (`name`, `description`), `course` (`name`, `slug`, `learner_title`, `description`, `grace_period_days`), `modules` (list of `slug`, `name`, `summary`, `notion_url`, `badge` (string or null), `steps` (list of `kind`, `title`, `notion_url`, optional `auto_check_key`), `questions` (list of `prompt`, `choices`, `correct_index`, `explanation`)).

- [ ] **Step 1: Copy the YAML**

```bash
mkdir -p db/seeds/learning
cp /private/tmp/claude-501/-Users-hhff-Documents-Code-stacks/4dae38b1-bded-4ad3-a8ae-2aec3fcff8db/scratchpad/wayfinding.yml db/seeds/learning/wayfinding.yml
ruby -ryaml -e 'y = YAML.load_file("db/seeds/learning/wayfinding.yml"); puts y["modules"].map { |m| [m["slug"], m["steps"].size, m["questions"].size].inspect }'
```

Expected output:

```
["paperwork-and-payment", 2, 0]
["your-accounts", 4, 0]
["how-you-get-paid", 4, 5]
["policies", 4, 5]
["how-we-communicate", 5, 5]
["onboarding-sign-off", 1, 0]
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/lib/stacks/learning/seeder_test.rb
require "test_helper"

class StacksLearningSeederTest < ActiveSupport::TestCase
  PATH = Rails.root.join("db/seeds/learning/wayfinding.yml")
  DATA = YAML.load_file(PATH)

  test "the YAML is well formed: registered auto-check keys, valid kinds, 5 questions where there is a quiz" do
    DATA["modules"].each do |mod|
      mod["steps"].each do |step|
        assert_includes ModuleStep::KINDS, step["kind"], mod["slug"]
        if step["kind"] == "auto_check"
          assert_includes Stacks::Learning::AutoChecks.keys, step["auto_check_key"], mod["slug"]
        else
          assert_nil step["auto_check_key"], mod["slug"]
        end
      end
      assert_includes [0, 5], mod["questions"].size, mod["slug"]
      mod["questions"].each do |q|
        assert_equal 4, q["choices"].size, q["prompt"]
        assert_includes 0..3, q["correct_index"], q["prompt"]
        assert q["explanation"].present?, q["prompt"]
      end
    end
  end

  test "person-facing copy avoids training language" do
    texts = [DATA["course"]["learner_title"], DATA["course"]["description"]]
    DATA["modules"].each do |mod|
      texts << mod["name"] << mod["summary"]
      mod["steps"].each { |s| texts << s["title"] }
    end
    texts.compact.each do |text|
      assert_no_match(/\b(course|lesson|training|learner|quiz)\b/i, text)
    end
  end

  test "seeding builds Wayfinding: six modules in order, not auto-assigned" do
    course = Stacks::Learning::Seeder.call(PATH)
    assert_equal "wayfinding", course.slug
    assert_equal "Getting on board at garden3d", course.learner_title
    assert_not course.auto_assign
    assert_equal 14, course.grace_period_days
    assert_equal "Onboarded to garden3d", course.qualification.name
    assert_equal "qualification", course.qualification.kind
    assert_equal %w[paperwork-and-payment your-accounts how-you-get-paid policies how-we-communicate onboarding-sign-off],
                 course.ordered_modules.map(&:slug)
    assert_equal [2, 4, 4, 4, 5, 1], course.ordered_modules.map { |m| m.module_steps.size }
    assert_equal [0, 0, 5, 5, 5, 0], course.ordered_modules.map { |m| m.quiz_questions.size }
    paid = LearningModule.find_by!(slug: "how-you-get-paid")
    assert_equal ["How you get paid", "badge"], [paid.qualification.name, paid.qualification.kind]
    assert_nil LearningModule.find_by!(slug: "your-accounts").qualification
    first = LearningModule.find_by!(slug: "paperwork-and-payment").module_steps.to_a
    assert_equal %w[admin_sign_off auto_check], first.map(&:kind)
    assert_equal "payment_profile", first.last.auto_check_key
  end

  test "seeding twice creates nothing new" do
    Stacks::Learning::Seeder.call(PATH)
    counts = -> { [Course, LearningModule, CourseModule, ModuleStep, QuizQuestion, Qualification].map(&:count) }
    before = counts.call
    Stacks::Learning::Seeder.call(PATH)
    assert_equal before, counts.call
  end

  test "re-seeding never overwrites admin edits or re-adds removed rows" do
    course = Stacks::Learning::Seeder.call(PATH)
    course.update!(auto_assign: true, learner_title: "Edited title")
    mod = LearningModule.find_by!(slug: "policies")
    mod.update!(name: "Edited name")
    mod.quiz_questions.first.destroy!
    step = mod.module_steps.first
    step.update!(title: "Edited step")
    course.course_modules.find_by!(learning_module: LearningModule.find_by!(slug: "onboarding-sign-off")).destroy!

    Stacks::Learning::Seeder.call(PATH)

    course.reload
    assert course.auto_assign
    assert_equal "Edited title", course.learner_title
    assert_equal "Edited name", mod.reload.name
    assert_equal 4, mod.quiz_questions.count
    assert_equal "Edited step", step.reload.title
    assert_equal 5, course.course_modules.count
  end

  test "a newly seeded person can be assigned it and the first sign-off is ready at once" do
    course = Stacks::Learning::Seeder.call(PATH)
    person = learning_person!
    assignment = learning_assign!(person, course)
    checklist = Stacks::Learning::Checklist.new(assignment)
    assert_equal 20, checklist.steps_total
    assert_equal ["Your signed GCA is on file"], checklist.ready_sign_off_steps.map(&:title)
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/learning/seeder_test.rb`
Expected: the two YAML-only tests pass; the rest fail with `NameError: uninitialized constant Stacks::Learning::Seeder`.

- [ ] **Step 4: Implement the seeder and the rake task**

```ruby
# lib/stacks/learning/seeder.rb
module Stacks
  module Learning
    # Builds a course from a YAML file. Create-only, so it is safe to re-run:
    #   - a qualification is matched by name, a course and a module by slug;
    #   - a module that already exists is left entirely alone (steps and
    #     questions included);
    #   - the course's module list is written only when the course is created.
    # Anything an admin has since edited or removed therefore stays that way.
    class Seeder
      def self.call(path)
        data = YAML.load_file(path)

        ActiveRecord::Base.transaction do
          modules = data.fetch("modules").map { |attrs| ensure_module(attrs) }

          course_attrs = data.fetch("course")
          course = Course.find_by(slug: course_attrs.fetch("slug"))
          next course if course

          qualification = ensure_qualification(data.dig("qualification", "name"), "qualification", data.dig("qualification", "description"))
          course = Course.create!(
            name: course_attrs.fetch("name"),
            slug: course_attrs.fetch("slug"),
            learner_title: course_attrs.fetch("learner_title"),
            description: course_attrs["description"],
            grace_period_days: course_attrs.fetch("grace_period_days", 14),
            auto_assign: false,
            qualification: qualification,
          )
          modules.each_with_index do |learning_module, index|
            course.course_modules.create!(learning_module: learning_module, position: index)
          end
          course
        end
      end

      def self.ensure_module(attrs)
        existing = LearningModule.find_by(slug: attrs.fetch("slug"))
        return existing if existing

        badge = ensure_qualification(attrs["badge"], "badge", nil)
        learning_module = LearningModule.create!(
          name: attrs.fetch("name"), slug: attrs.fetch("slug"), summary: attrs["summary"],
          notion_url: attrs["notion_url"], qualification: badge,
        )
        Array(attrs["steps"]).each_with_index do |step, index|
          learning_module.module_steps.create!(
            position: index, kind: step.fetch("kind"), title: step.fetch("title"),
            notion_url: step["notion_url"], auto_check_key: step["auto_check_key"],
          )
        end
        Array(attrs["questions"]).each_with_index do |question, index|
          learning_module.quiz_questions.create!(
            position: index, prompt: question.fetch("prompt"), choices: question.fetch("choices"),
            correct_index: question.fetch("correct_index"), explanation: question["explanation"],
          )
        end
        learning_module
      end
      private_class_method :ensure_module

      def self.ensure_qualification(name, kind, description)
        return nil if name.blank?
        Qualification.find_by(name: name) || Qualification.create!(name: name, kind: kind, description: description)
      end
      private_class_method :ensure_qualification
    end
  end
end
```

Note `next course if course` inside the `transaction` block returns the existing course as the block's value without the deprecated `return`-from-transaction.

In `lib/tasks/stacks.rake`, inside `namespace :stacks do`, add a new task (put it next to another small one-off task; do not put it inside `daily_tasks`):

```ruby
  desc "Create the Wayfinding onboarding course from db/seeds/learning/wayfinding.yml (safe to re-run; never overwrites edits)"
  task :seed_wayfinding_course => :environment do
    course = Stacks::Learning::Seeder.call(Rails.root.join("db/seeds/learning/wayfinding.yml"))
    puts "Wayfinding course ##{course.id}: #{course.course_modules.count} modules, auto_assign=#{course.auto_assign}"
  end
```

- [ ] **Step 5: Run to verify it passes**

Run: `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test test/lib/stacks/learning`
Expected: all pass.

If "person-facing copy avoids training language" fails on a word in the YAML, reword that one title or summary in the YAML minimally (this is the only permitted edit to its content) and say so in your report.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add db/seeds/learning/wayfinding.yml lib/stacks/learning/seeder.rb lib/tasks/stacks.rake test/lib/stacks/learning/seeder_test.rb
git commit -m "feat: seed the Wayfinding onboarding course

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After all tasks (controller, not a subagent)

1. Confirm no other `rails test` is running (`ps -ax | grep "[r]ails test"`), then run the full suite once:
   `DATABASE_URL=postgres:///stacks_test_onboarding_courses RAILS_ENV=test bin/rails test --exclude "/EtlRakeTest/"`
2. Normalise commit trailers if any subagent substituted its own model name.
3. Push and open the PR; PR body ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)` and includes the rollout steps from the spec (migrate → `heroku restart` → `stacks:seed_wayfinding_course`; nothing is assigned until `auto_assign` is switched on).
4. Adversarial review of the PR diff; fix; wait for Heroku CI.

## Spec coverage

| Spec section | Task |
|---|---|
| Data model, deletion rules | 1 |
| Progress sticky / per person, `refresh!`, auto-checks, admin override data path | 2 (override UI in 6) |
| Quizzes | 3 (UI in 6) |
| Assignment (auto, manual, waive, no destroy) | 4, 6 |
| Tasks, plumbing, stale cache, daily refresh | 5 |
| Authorization, impersonation and self-service, checklist page | 6 |
| Admin authoring, profile module, manual qualification grants | 7 |
| Wayfinding seed | 8 |
| Language rule | 6 (page test), 8 (seed test) |
