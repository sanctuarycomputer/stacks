# Project Capsule opt-out sign-off

**Date:** 2026-09-16
**Status:** Approved, revised after adversarial review, ready for planning

## Problem

Project leads closing out a Project Capsule can opt out of sending the client a
feedback survey — and of three other close-out obligations — and the capsule
silently reads as Complete. Nobody is told. We want these bypasses to require an
admin's explicit sign-off, while leaving the honest path completely frictionless.

### How close-out works today

`ProjectCapsule#complete?` (`app/models/project_capsule.rb:42`) is *purely
derived*. There is no close button, no sign-off, no timestamp. It returns true
when four enums are non-nil, plus `client_satisfaction_status`:

| Field | "Did the work" value | Escape hatch |
|---|---|---|
| `client_feedback_survey_status` | received & shared with team | **no response from client** · **opt out of sending** |
| `internal_marketing_status` | case study scheduled | **opt out of case study** |
| `capsule_status` | shared on Twist | **opt out of sharing** |
| `project_satisfaction_survey_status` | survey created *(+ must be closed)* | **opt out of survey** |

Only the internal satisfaction survey carries a *proof* requirement:
`project_satisfaction_survey_status_valid?` (`:51`) additionally checks that the
survey record exists and is `closed?`. The client feedback survey has a
`client_feedback_survey_url` column, but nothing validates it — it is not
referenced by `complete?` at all.

Selecting an opt-out flips `work_status` (`project_tracker.rb:847`, branch at
`:856-862`) from `:capsule_pending` to `:complete`, which clears the
`:project_capsule_incomplete` nag (`discoveries/project_trackers.rb:37`), drops
the "Pending" pill, and makes the project count as complete downstream. That is
the hole.

Because `complete?` is derived, the gate is a change to one method plus a nag
route. No state machine is required.

## Scope decisions

- **All four opt-outs are gated.**
- **"No response from client" is gated after a 4-week grace period.** Chasing an
  unresponsive client is legitimate; sitting on it forever is not.
- **The happy path also needs proof**: "received & shared with project team"
  requires a well-formed `client_feedback_survey_url`.
- **Both admins and the project lead are nagged** while a capsule waits on
  sign-off, so the lead stays under pressure to do the real thing.
- **Capsules whose close-out decisions are already made are exempt** — see §2.

## Design

### 1. Data model

```ruby
add_column :project_capsules, :admin_signed_off_at, :datetime
add_reference :project_capsules, :admin_signed_off_by,
  foreign_key: { to_table: :admin_users }, null: true
add_column :project_capsules, :admin_signed_off_selections, :string,
  array: true, null: false, default: []
add_column :project_capsules, :sign_off_exempt, :boolean, null: false, default: false
```

`db/schema.rb` is hand-curated in this repo. The edit must bump the `version:`
(currently `2026_08_04_000001`) to the new migration's timestamp **and** add the
`index_project_capsules_on_admin_signed_off_by_id` index that `add_reference`
creates.

### 2. Backfill — exempt the *decided*, not merely the *existing*

```sql
UPDATE project_capsules SET sign_off_exempt = true
WHERE client_feedback_survey_status    IS NOT NULL
  AND internal_marketing_status        IS NOT NULL
  AND capsule_status                   IS NOT NULL
  AND project_satisfaction_survey_status IS NOT NULL;
```

Raw SQL, not the model, so the backfill can't break if `ProjectCapsule`'s
callbacks change later. Must run in the same migration, immediately after the
column is added, so no pre-existing capsule ever reads as gated.

**Why this predicate rather than exempting everything.** Capsules are created at
wrap time (`ensure_project_capsule_exists!`, called only from `complete_work` /
`uncomplete_work` at `app/admin/project_trackers.rb:305,311`), so a blanket
`SET sign_off_exempt = true` would exempt the entire in-flight close-out backlog
— every capsule a lead hasn't finished filling in yet — and the feature would
enforce nothing until that backlog drained.

This predicate exempts exactly the set that would otherwise flip from Complete
back to Pending, which was the actual concern. A capsule with statuses still
blank is already Pending; gating it reopens nothing and surprises no one.

> **Reversible in one line.** If you'd rather exempt *every* existing capsule
> literally, drop the `WHERE` clause. Nothing else in the design changes.

**Known consequence:** `has_one :project_capsule, dependent: :delete`
(`project_tracker.rb:21`) means a destroyed capsule is gone. An old project whose
capsule is missing, toggled through `complete_work` after deploy, gets a fresh,
*gated* capsule. Accepted — it's rare, and the lead can still complete it
honestly or get a signature.

### 3. Rename: `ProjectCapsule.complete` → `.all_statuses_set`

Three things currently share two names, one of which is a lie:

| | What it actually checks |
|---|---|
| `ProjectCapsule.complete` (scope, `:8`) | the 4 enums are non-nil |
| `ProjectTracker#capsule_complete_by_statuses?` (`:282`, private) | **the same 4 enums, hand-copied in Ruby** |
| `ProjectCapsule#complete?` (`:42`) | those 4 + client satisfaction + survey closed + (new) URL + sign-off |

Rename the scope to `all_statuses_set`, add `#all_statuses_set?`, and have
`#complete?` and `ProjectTracker#capsule_complete_by_statuses?` both call it.
Keep `capsule_complete_by_statuses?` private (its caller `likely_complete?` at
`:276` is internal); write it as `!!project_capsule&.all_statuses_set?` to
preserve the existing `false`-not-`nil` return.

`ProjectTracker.complete` keeps its name — it is user-facing as an ActiveAdmin
scope tab.

**Correction to the pre-review draft:** `ProjectCapsule.complete` has one direct
caller (`project_tracker.rb:67`), but that caller — `ProjectTracker.complete` —
has five consumers: the AA `:complete` tab (`app/admin/project_trackers.rb:11`),
`scope :in_progress` (`:72`, **the default tab**), `scope :dormant` (`:78`),
`ProjectTracker.likely_complete` (`:187`, transitively via `.dormant`), and
`discoveries/forecast_projects.rb:18`.

Because the SQL scope checks only the four enums, a capsule awaiting sign-off is
excluded from the **Active** tab and filed under **Complete**, while its own page
reads "Pending". The lead who must act on it can't find it where they work. The
SQL scope is still deliberately left behaviourally unchanged — teaching it about
sign-off duplicates Ruby logic into SQL for one archiving query — so §8 adds a
**"Needs sign-off" ActiveAdmin scope** to make these findable instead.

### 4. `ProjectCapsule` gating logic

```ruby
belongs_to :admin_signed_off_by, class_name: "AdminUser", optional: true

NO_RESPONSE_GRACE_PERIOD = 4.weeks

# Stable keys, not prose — they're persisted in admin_signed_off_selections.
GATED_SELECTION_LABELS = {
  "client_feedback_survey"      => "Sending a client feedback survey",
  "client_feedback_no_response" => "Chasing an unresponsive client",
  "internal_marketing"          => "Publishing a case study",
  "capsule_sharing"             => "Sharing the capsule with garden3d",
  "satisfaction_survey"         => "The internal team satisfaction survey",
}.freeze

scope :all_statuses_set, -> {
  where.not(client_feedback_survey_status: nil)
    .where.not(internal_marketing_status: nil)
    .where.not(capsule_status: nil)
    .where.not(project_satisfaction_survey_status: nil)
}

def all_statuses_set?
  client_feedback_survey_status.present? &&
    internal_marketing_status.present? &&
    capsule_status.present? &&
    project_satisfaction_survey_status.present?
end

# The close-out bar as it stood before bypass protections existed. Metrics that
# feed compensation and OKRs read THIS, not #complete? — see §6.
def substantively_complete?
  all_statuses_set? &&
    client_satisfaction_status.present? &&
    project_satisfaction_survey_status_valid?
end

def complete?
  completeness_checks_pass? && admin_sign_off_satisfied?
end

# Lead has done all they can; only an admin's signature is outstanding.
def complete_but_for_admin_sign_off?
  completeness_checks_pass? && !admin_sign_off_satisfied?
end

def gated_selections
  return [] if sign_off_exempt?
  [
    ("client_feedback_survey"      if opt_out_of_sending_client_feedback_survey?),
    ("client_feedback_no_response" if no_response_from_client? && no_response_grace_expired?),
    ("internal_marketing"          if opt_out_out_of_publishing_a_case_study?),
    ("capsule_sharing"             if opt_out_of_sharing_project_capsule_with_garden3d?),
    ("satisfaction_survey"         if opt_out_of_internal_project_team_satisfaction_survey?),
  ].compact
end

def gated_selection_labels
  gated_selections.map { |k| GATED_SELECTION_LABELS.fetch(k) }
end

def requires_admin_sign_off?
  gated_selections.any?
end

# Sign-off covers the selections an admin actually saw. Still valid if the lead
# has since REMOVED some (doing the honest thing shouldn't void an approval);
# void the moment a selection appears that nobody approved.
def admin_sign_off_satisfied?
  return true unless requires_admin_sign_off?
  return false if admin_signed_off_at.blank?
  (gated_selections - admin_signed_off_selections.to_a).empty?
end

# Mirrors project_satisfaction_survey_status_valid?: claiming the client
# responded requires linking their response.
def client_feedback_survey_url_valid?
  return true if sign_off_exempt?
  return true unless client_feedback_survey_received_and_shared_with_project_team?
  client_feedback_survey_url.to_s.match?(%r{\Ahttps?://\S+\z})
end

private

def completeness_checks_pass?
  substantively_complete? && client_feedback_survey_url_valid?
end

# Anchored on the EARLIEST wrap signal we have. work_completed_at alone is
# resettable: uncomplete_work then complete_work rewrites it to DateTime.now
# (app/admin/project_trackers.rb:303-312), which would buy another 4 weeks,
# repeatably. project_capsules.created_at is immutable and is stamped at the
# first complete_work, so the earlier of the two can't be pushed forward.
def no_response_grace_anchor
  [project_tracker&.work_completed_at, created_at].compact.min
end

def no_response_grace_expired?
  anchor = no_response_grace_anchor
  anchor.present? && anchor < NO_RESPONSE_GRACE_PERIOD.ago
end
```

Note `opt_out_out_of_publishing_a_case_study?` — the doubled "out" is a typo in
the existing enum key, preserved deliberately. See Optional cleanup.

### 5. Sign-off validity is derived, not a callback

The pre-review draft used a `before_save` to null out a stale signature. That was
wrong in three ways, all fixed by the subset rule in `admin_sign_off_satisfied?`:

- **`update_column` bypasses callbacks entirely.**
  `ProjectSatisfactionSurvey#reset_project_capsule_survey_flow`
  (`project_satisfaction_survey.rb:173-179`) is an `after_destroy` that writes
  `project_satisfaction_survey_status` with callbacks skipped — it would have
  preserved a signature across a gated-column change.
- **A single `update!` touching both a gated enum and the sign-off** would have
  kept the signature.
- **Honest work would have voided approval.** Creating the internal survey
  (`app/admin/project_satisfaction_surveys.rb:161-163`) calls
  `project_capsule.update!(...)`, which would have revoked an admin's unrelated
  approval and forced a re-signature.

Deriving from the persisted selection list fixes all three at once, needs no
callback, and matches how the rest of this model works. A lead who swaps the
case-study opt-out for the client-survey opt-out produces a selection nobody
approved, so the capsule re-blocks; a lead who *removes* an opt-out keeps the
approval and simply needs less of it.

### 6. Decoupling metrics from the gate (**required** — this was a live footgun)

`considered_successful?` (`project_tracker.rb:328`) branches on
`work_status == :complete`:

```ruby
if work_status == :complete
  client_satisfied? && target_profit_margin_satisfied? && target_free_hours_ratio_satisfied?
else
  target_profit_margin_satisfied? && target_free_hours_ratio_satisfied?
end
```

Gating a capsule pushes `work_status` back to `:capsule_pending`, which takes the
`else` branch and **drops the `client_satisfied?` requirement**. A project with a
dissatisfied client would flip from Unsuccessful to Successful *because* its lead
bypassed the survey. That value feeds PSU allocation (`profit_share_pass.rb:216`,
`:232`, `:252-260`), `Studio` OKR metrics (`studio.rb:550,557`), the OKR explorer
view, and three MCP tools. The bypass would have paid better than compliance.

Separately, `Studio#project_satisfaction_score` (`studio.rb:489-491`) filters on
`pt.capsule_complete?` → `project_capsule.complete?`, so gated capsules would
silently drop out of the satisfaction average even with a closed, fully-answered
survey.

**Fix — one rule:** the new gates change `complete?` (and therefore
`work_status`, the nags, and the UI) but must not change any metric.

- `ProjectTracker#considered_successful?` branches on
  `work_completed_at.present? && !!project_capsule&.substantively_complete?`
  instead of `work_status == :complete`.
- `Studio#project_satisfaction_score`'s `select` uses
  `pt.project_capsule&.substantively_complete?` instead of `pt.capsule_complete?`.

`substantively_complete?` is byte-identical to today's `complete?`, so **both
call sites keep exactly their current behaviour on all existing data** — this is
a decoupling, not a metric change. Regression tests pin that (§9).

### 7. Authorization (**required** — the draft's claim here was false)

`AdminAuthorization#authorized?` (`app/models/admin_authorization.rb:66`) reads:

```ruby
return true if (user.is_admin? || user.can_act_as_lead?)
```

and `can_act_as_lead?` (`admin_user.rb:566`) is true for anyone who has ever held
an `AccountLeadPeriod` or `ProjectLeadPeriod` — precisely the population this
feature polices. Guarding only the `action_item` hides a link; it does not stop a
`POST /admin/project_capsules/:id/sign_off`. The draft's claim that "the member
actions are the only write path, so a lead cannot approve themselves" was wrong.

Two changes, both required:

1. In `AdminAuthorization#authorized?`, **above** the `can_act_as_lead?` line,
   alongside the existing `ContributorAdjustment` / `ProjectSatisfactionSurvey`
   branches:

   ```ruby
   if subject.is_a?(ProjectCapsule) || subject == ProjectCapsule
     return user.is_admin? if [:sign_off, :revoke_sign_off].include?(action)
   end
   ```

2. Defence in depth inside each member action:

   ```ruby
   raise ActiveAdmin::AccessDenied.new(current_admin_user, :sign_off, resource) unless current_admin_user.is_admin?
   ```

`admin_signed_off_at`, `admin_signed_off_by_id`, `admin_signed_off_selections`
and `sign_off_exempt` are **not** added to `permit_params`.

> **Pre-existing bug, deliberately out of scope:** `member_action :close_survey`
> and `:reopen_survey` (`app/admin/project_satisfaction_surveys.rb:41-59`) have
> the same hole — their `action_item`s check `is_admin?` but the actions don't.
> Any lead can close or reopen a satisfaction survey today. Flagged for a
> separate PR; fixing it here would widen this diff into unrelated territory.

> **Accepted policy:** an admin who is also the project lead *can* approve their
> own capsule. Blocking self-approval risks deadlocking a small team where the
> only available admin is the lead. The signature records who approved and when,
> and the sign-off nag is visible to all admins. Revisit if it gets abused.

### 8. UI (`app/admin/project_capsules.rb`)

```ruby
action_item :sign_off, only: [:edit],
  if: proc { current_admin_user.is_admin? && resource.requires_admin_sign_off? && !resource.admin_sign_off_satisfied? } do
  link_to "✅ Approve Opt-Outs", sign_off_admin_project_capsule_path(resource), method: :post
end

action_item :revoke_sign_off, only: [:edit],
  if: proc { current_admin_user.is_admin? && resource.admin_signed_off_at.present? } do
  link_to "Revoke Sign-Off", revoke_sign_off_admin_project_capsule_path(resource), method: :post
end

member_action :sign_off, method: :post do
  raise ActiveAdmin::AccessDenied.new(current_admin_user, :sign_off, resource) unless current_admin_user.is_admin?
  resource.update!(
    admin_signed_off_at: DateTime.now,
    admin_signed_off_by: current_admin_user,
    admin_signed_off_selections: resource.gated_selections,
  )
  redirect_to admin_project_tracker_path(resource.project_tracker_id), notice: "Opt-outs approved."
end

member_action :revoke_sign_off, method: :post do
  raise ActiveAdmin::AccessDenied.new(current_admin_user, :revoke_sign_off, resource) unless current_admin_user.is_admin?
  resource.update!(admin_signed_off_at: nil, admin_signed_off_by: nil, admin_signed_off_selections: [])
  redirect_to admin_project_tracker_path(resource.project_tracker_id), notice: "Sign-off revoked."
end
```

A panel at the top of the capsule form, shown whenever `requires_admin_sign_off?`,
lists `gated_selection_labels` and — for non-admins — says an admin must approve
before the capsule counts as complete. Where a signature exists it shows who
approved and when.

On the tracker show page (`_show.html.erb:32`), the Pending pill gains a "needs
admin sign-off" note, and the Client Feedback row reads "received (survey URL
missing)" when the URL proof is what's outstanding.

**New ActiveAdmin scope** on `app/admin/project_trackers.rb`, so gated trackers
don't hide under the Complete tab (see §3):

```ruby
scope :needs_capsule_sign_off, -> { ... }
```

Implemented as a Ruby-filtered scope over `ProjectTracker.complete` (the
population is small — only trackers with all four statuses set), selecting those
whose capsule `complete_but_for_admin_sign_off?`.

### 9. Nagging

New type in `StacksTask::HUMANIZED_TYPES`:

```ruby
project_capsule_needs_admin_sign_off: "Project capsule opt-outs need admin sign-off",
```

In `discoveries/project_trackers.rb`:

```ruby
else
  out << :project_capsule_incomplete if pt.work_status == :capsule_pending
  out << :project_capsule_needs_admin_sign_off if pt.project_capsule&.complete_but_for_admin_sign_off?
end
```

Routing needs no new plumbing: `owners_for` returns `nil`/`[]` for the new type
and `Base#task` (`discoveries/base.rb:19`) substitutes `@admin_fallback`
(`AdminUser.admin`) when owners come back empty. The lead's existing
`:project_capsule_incomplete` keeps firing alongside, since `work_status` stays
`:capsule_pending`.

Add `inverse_of:` to the `ProjectTracker has_one :project_capsule` /
`ProjectCapsule belongs_to :project_tracker` pair so
`no_response_grace_anchor`'s `project_tracker` read doesn't re-query per capsule
in the discovery. Pin it with a query-count assertion rather than asserting it in
prose.

**Accepted staleness.** `no_response_grace_expired?` makes `complete?` a function
of wall-clock time, so at the 4-week boundary a capsule changes state with no
write — `BustsTaskCache` can't fire, and the nag appears only when the 24h
`TaskBuilder` TTL lapses (`lib/stacks/task_builder.rb:42`). Acceptable for a nag.
Also note `complete_work` / `uncomplete_work` use `update_column`
(`project_trackers.rb:304,311`), which skips `after_commit`, so those already
don't bust the cache today — unchanged by this work, not fixed here.

## Testing

New `test/models/project_capsule_test.rb` (none exists today):

- each of the four opt-outs blocks `complete?` on a non-exempt capsule
- sign-off with matching selections unblocks each
- doing the real work unblocks with no sign-off
- **subset rule:** approved `[A, B]`, lead removes `B` ⇒ still complete
- **swap rule:** approved `[A]`, lead swaps to `[B]` ⇒ blocked again
- `update_column` on a gated enum cannot preserve a stale signature
- creating the internal survey (the `update!` at `project_satisfaction_surveys.rb:161`) does not void an unrelated approval
- `no_response_from_client` at 3 weeks past anchor: complete; at 5 weeks: blocked
- **grace clock can't be reset** by `uncomplete_work` → `complete_work`
- `no_response_from_client` with nil `work_completed_at` falls back to `created_at`
- "received & shared" with blank / `"n/a"` / valid URL
- `sign_off_exempt: true` bypasses both the sign-off gate and the URL proof
- `complete_but_for_admin_sign_off?` false while other requirements unmet
- `all_statuses_set?` agrees with the `all_statuses_set` scope on the same records

Regression tests for §6 (these are the ones that matter most):

- dissatisfied client + gated capsule ⇒ `considered_successful?` still **false**
- `Studio#project_satisfaction_score` still counts a gated project whose survey is closed

Authorization (§7) — `test/models/admin_authorization_test.rb` exists; add:

- a `can_act_as_lead?` non-admin is **denied** `:sign_off` / `:revoke_sign_off`
- an `is_admin?` user is allowed

New `test/lib/stacks/task_builder/discoveries/project_trackers_test.rb` — the
directory has tests for other discoveries but **none** for this one, and
`project_capsule_incomplete` is currently untested. Write from scratch:

- a gated capsule yields `:project_capsule_needs_admin_sign_off` owned by admins
  **and** `:project_capsule_incomplete` owned by the project lead
- a query-count assertion pinning no N+1 on `project_tracker`

Existing tests that touch `ProjectCapsule.create!` and must still pass:
`test/models/project_tracker_test.rb:48`,
`test/models/project_satisfaction_survey_test.rb:7,32`.

Run the suite with `db:environment:set` applied; exclude
`test/lib/tasks/etl_rake_test.rb` locally (its `sync_meet` test makes a live
Google call and can hang the run). `AdminUserTest`'s salary-window test fails
between 20:00 and 24:00 ET for unrelated reasons.

## Non-goals

- Teaching the SQL `all_statuses_set` scope about sign-off (§3) — the new AA
  scope addresses findability instead.
- Fixing the identical missing-auth bug on `close_survey` / `reopen_survey` (§7).
- Making `complete_work` / `uncomplete_work` bust the task cache (§9).
- Any notification or email on opt-out. The nag task is the channel.
- Per-opt-out granular approval UI. One signature records the selection set it
  covered, which gives the same guarantee.

## Optional cleanup (separate, your call)

The enum key `opt_out_out_of_publishing_a_case_study` (`project_capsule.rb:29`)
has a doubled "out" and renders through `.humanize` as "Opt out out of publishing
a case study". Renaming is data-safe (enum keys are code-only; the stored value
is the integer `1`). Left out to keep the diff focused.
