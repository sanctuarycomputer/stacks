# Project Capsule opt-out sign-off

**Date:** 2026-09-16
**Status:** Approved, ready for planning

## Problem

Project leads closing out a Project Capsule can opt out of sending the client a
feedback survey — and of three other close-out obligations — and the capsule
silently reads as Complete. Nobody is told. We want these bypasses to require an
admin's explicit sign-off, while leaving the honest path completely frictionless.

### How close-out works today

`ProjectCapsule#complete?` (`app/models/project_capsule.rb:44`) is *purely
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

Selecting an opt-out flips `work_status` from `:capsule_pending` to `:complete`
(`project_tracker.rb:850`), which clears the `:project_capsule_incomplete` nag
task assigned to the lead (`discoveries/project_trackers.rb:37`), drops the
"Pending" pill on the tracker page, and makes the project count as complete
everywhere downstream. That is the hole.

Because `complete?` is derived, the gate is a change to one method plus a nag
route. No state machine is required.

## Scope decisions

- **All four opt-outs are gated** — not just the client feedback survey.
- **"No response from client" is gated after a grace period**, not immediately.
  Chasing an unresponsive client is a legitimate outcome; sitting on it forever
  is not. Grace is **4 weeks measured from `project_tracker.work_completed_at`**,
  so the clock starts at wrap and cannot be reset by editing the capsule late.
- **The happy path also needs proof**: selecting "received & shared with project
  team" requires `client_feedback_survey_url` to be present, mirroring the
  internal survey's `closed?` requirement.
- **Both admins and the project lead are nagged** while a capsule waits on
  sign-off, so the lead stays under pressure to go do the real thing rather than
  wait out an admin.
- **Existing capsules are exempt.** This applies to future capsules only.

## Design

### 1. Data model

One migration on `project_capsules`:

```ruby
add_column :project_capsules, :admin_signed_off_at, :datetime
add_reference :project_capsules, :admin_signed_off_by,
  foreign_key: { to_table: :admin_users }, null: true
add_column :project_capsules, :sign_off_exempt, :boolean, null: false, default: false

# Grandfather everything that exists at deploy time. Capsules created afterwards
# pick up the `false` default and are gated. Raw SQL rather than the model, so
# the backfill can't break later if ProjectCapsule's validations or callbacks
# change out from under this migration.
execute "UPDATE project_capsules SET sign_off_exempt = true"
```

The backfill must run **after** the column is added and in the same migration, so
there is no window in which a pre-existing capsule reads as gated.

`db/schema.rb` is hand-curated in this repo — update it to match rather than
relying on a dump.

The exempt flag is preferred over a hardcoded cutoff date: it is immune to
deploy timing, is self-documenting in the data, and leaves room to exempt a
one-off edge case by hand later.

### 2. Rename: `ProjectCapsule.complete` → `.all_statuses_set`

Three things currently share two names, one of which is a lie:

| | What it actually checks |
|---|---|
| `ProjectCapsule.complete` (scope, `:8`) | the 4 enums are non-nil |
| `ProjectTracker#capsule_complete_by_statuses?` (`:282`) | **the same 4 enums, hand-copied in Ruby** |
| `ProjectCapsule#complete?` (`:44`) | those 4 + client satisfaction + survey closed + (new) URL + sign-off |

The scope and the instance method mean materially different things, and this
change widens the gap — sign-off and URL proof land in `complete?` only.

Rename the scope to `all_statuses_set`, add a matching `#all_statuses_set?`, and
have both `#complete?` and `ProjectTracker#capsule_complete_by_statuses?` call
it. One definition instead of three. The scope has exactly one caller
(`project_tracker.rb:67`).

`ProjectTracker.complete` keeps its name — it is user-facing as an ActiveAdmin
scope tab (`app/admin/project_trackers.rb:11`).

The SQL scope is **deliberately not** taught about sign-off. Its only consumer is
forecast-project archiving (`discoveries/forecast_projects.rb:18`), it already
ignored client satisfaction and survey closure long before this change, and the
honest name makes that divergence legible rather than hiding it behind the word
"complete".

### 3. `ProjectCapsule` gating logic

```ruby
belongs_to :admin_signed_off_by, class_name: "AdminUser", optional: true

NO_RESPONSE_GRACE_PERIOD = 4.weeks

GATED_STATUS_COLUMNS = %w[
  client_feedback_survey_status
  internal_marketing_status
  capsule_status
  project_satisfaction_survey_status
].freeze

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

def complete?
  completeness_checks_pass? && admin_sign_off_satisfied?
end

# True when the lead has done everything they can and only an admin's signature
# is outstanding. Drives the admin nag — we don't pester admins about a capsule
# that is still half-filled.
def complete_but_for_admin_sign_off?
  completeness_checks_pass? && !admin_sign_off_satisfied?
end

# Human-readable list of the selections blocking this capsule. Used by both the
# warning panel and the admin sign-off confirmation, so the two can't drift.
def gated_selections
  return [] if sign_off_exempt?
  [
    ("Sending a client feedback survey"      if opt_out_of_sending_client_feedback_survey?),
    ("Chasing an unresponsive client"        if no_response_from_client? && no_response_grace_expired?),
    ("Publishing a case study"               if opt_out_out_of_publishing_a_case_study?),
    ("Sharing the capsule with garden3d"     if opt_out_of_sharing_project_capsule_with_garden3d?),
    ("The internal team satisfaction survey" if opt_out_of_internal_project_team_satisfaction_survey?),
  ].compact
end

def requires_admin_sign_off?
  gated_selections.any?
end

def admin_sign_off_satisfied?
  !requires_admin_sign_off? || admin_signed_off_at.present?
end

# Mirrors project_satisfaction_survey_status_valid?: claiming the client
# responded requires linking their response.
def client_feedback_survey_url_valid?
  return true if sign_off_exempt?
  return true unless client_feedback_survey_received_and_shared_with_project_team?
  client_feedback_survey_url.present?
end

private

def completeness_checks_pass?
  all_statuses_set? &&
    client_satisfaction_status.present? &&
    project_satisfaction_survey_status_valid? &&
    client_feedback_survey_url_valid?
end

def no_response_grace_expired?
  wrapped_at = project_tracker&.work_completed_at
  wrapped_at.present? && wrapped_at < NO_RESPONSE_GRACE_PERIOD.ago
end
```

Note `opt_out_out_of_publishing_a_case_study?` — the doubled "out" is a typo in
the existing enum key, preserved here. See Optional cleanup below.

### 4. Sign-off cannot be pre-farmed

```ruby
before_save :clear_stale_admin_sign_off

private def clear_stale_admin_sign_off
  return if admin_signed_off_at.blank?
  return if admin_signed_off_at_changed? # this save *is* the sign-off
  return unless GATED_STATUS_COLUMNS.any? { |c| public_send(:"#{c}_changed?") }
  self.admin_signed_off_at = nil
  self.admin_signed_off_by_id = nil
end
```

Without this, a lead could get approved for the case-study opt-out and then
quietly swap in the client-survey opt-out under cover of the existing signature.
Any edit to a gated enum discards the approval.

### 5. Self-clearing

Nothing needs undoing if the lead does the real work. Flipping to "received &
shared" and pasting the URL makes `requires_admin_sign_off?` false and
`complete?` true, with no admin involved. The gate only ever bites a bypass.

### 6. Why the URL check is derived, not an AR validation

`ProjectSatisfactionSurvey`'s create hook calls
`resource.project_capsule.update!(...)` (`app/admin/project_satisfaction_surveys.rb`).
A hard `validates :client_feedback_survey_url, presence: true` would make that
raise on any capsule already sitting in the received-but-blank-URL state.
Deriving it instead means such capsules simply read as Pending until someone
pastes the URL — the desired outcome, with no save-path breakage. This matches
how the rest of this model works: everything is derived.

### 7. UI (`app/admin/project_capsules.rb`)

Same shape as the existing Close/Reopen Survey pair in
`app/admin/project_satisfaction_surveys.rb`:

```ruby
action_item :sign_off, only: [:edit],
  if: proc { current_admin_user.is_admin? && resource.requires_admin_sign_off? && resource.admin_signed_off_at.blank? } do
  link_to "✅ Approve Opt-Outs", sign_off_admin_project_capsule_path(resource), method: :post
end

action_item :revoke_sign_off, only: [:edit],
  if: proc { current_admin_user.is_admin? && resource.admin_signed_off_at.present? } do
  link_to "Revoke Sign-Off", revoke_sign_off_admin_project_capsule_path(resource), method: :post
end

member_action :sign_off, method: :post do
  resource.update!(admin_signed_off_at: DateTime.now, admin_signed_off_by: current_admin_user)
  redirect_to admin_project_tracker_path(resource.project_tracker_id), notice: "Opt-outs approved."
end

member_action :revoke_sign_off, method: :post do
  resource.update!(admin_signed_off_at: nil, admin_signed_off_by: nil)
  redirect_to admin_project_tracker_path(resource.project_tracker_id), notice: "Sign-off revoked."
end
```

Neither sign-off column is added to `permit_params` — the member actions are the
only write path, so a lead cannot approve themselves by posting the form.

A panel at the top of the capsule form, shown whenever
`requires_admin_sign_off?`, names exactly which selections are blocking (from
`gated_selections`) and, for non-admins, says an admin must approve before the
capsule counts as complete. Where sign-off is already present, it shows who
approved and when.

On the tracker show page (`app/views/admin/project_trackers/_show.html.erb:32`),
the Pending pill gains a "needs admin sign-off" note so the state is visible
without opening the form, and the Client Feedback row reads "received (survey URL
missing)" when the URL proof is what's outstanding.

### 8. Nagging

New task type in `StacksTask::HUMANIZED_TYPES`:

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

Owner routing needs no new plumbing: `owners_for` returns `[]` for the new type,
and `Base#task` already substitutes `@admin_fallback` (which is `AdminUser.admin`)
when owners come back empty. The lead's existing `:project_capsule_incomplete`
task keeps firing alongside it, since `work_status` stays `:capsule_pending`.

`ProjectCapsule` already includes `BustsTaskCache`, so signing off clears the nag
on the next read rather than up to 24h later.

The discovery already eager-loads `{ project_capsule: :project_satisfaction_survey }`,
so `complete_but_for_admin_sign_off?` adds no N+1. `no_response_grace_expired?`
reads `project_tracker.work_completed_at`, which is on the already-loaded tracker.

## Testing

New `test/models/project_capsule_test.rb` (none exists today):

- each of the four opt-outs blocks `complete?` on a non-exempt capsule
- `admin_signed_off_at` unblocks each of them
- doing the real work unblocks without any sign-off
- editing a gated enum after sign-off clears it and re-blocks
- signing off does not clear itself (the `admin_signed_off_at_changed?` guard)
- `no_response_from_client` at 3 weeks past wrap: complete; at 5 weeks: blocked
- `no_response_from_client` with a nil `work_completed_at`: not gated
- "received & shared" with a blank URL blocks; with a URL, completes
- `sign_off_exempt: true` bypasses both the sign-off gate and the URL proof
- `complete_but_for_admin_sign_off?` is false while other requirements are unmet
- `all_statuses_set?` agrees with the `all_statuses_set` scope on the same records

Extend the existing task-builder discovery test: a gated capsule produces
`:project_capsule_needs_admin_sign_off` owned by admins **and**
`:project_capsule_incomplete` owned by the project lead.

Per `docs`/prior art, run the suite with `db:environment:set` set, and skip
`EtlRakeTest`'s `sync_meet` test locally — it makes a live Google call and can
hang the run.

## Non-goals

- Teaching the SQL `all_statuses_set` scope about sign-off (see §2).
- Any notification/email on opt-out. The nag task is the channel.
- Per-opt-out granular approval. Sign-off is one signature covering the capsule;
  changing any gated selection invalidates it, which is the equivalent guarantee
  at a fraction of the complexity.
- Backfilling or migrating existing capsules beyond setting `sign_off_exempt`.

## Optional cleanup (separate, your call)

The enum key `opt_out_out_of_publishing_a_case_study` has a doubled "out", and
the tracker show page renders it through `.humanize`, so it displays to users as
"Opt out out of publishing a case study". Renaming the key is data-safe (enum
keys are code-only; the stored value is the integer `1`) and touches the model
plus any code referencing the predicate. Left out of this spec to keep the diff
focused.
