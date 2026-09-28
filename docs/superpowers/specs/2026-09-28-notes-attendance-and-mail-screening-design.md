# Notes attendance + sensitive-group mail screening (privacy wall, wave 2)

**Goal.** #189 (G2) walls off Gemini notes when nobody knows who actually attended (646 docs). Recover real
attendance where Google still has it, so notes from genuine 3+ person meetings become searchable again after the
content review. Notes whose attendance stays unknown remain walled. Separately, screen the *bodies* of jobs@,
admin@ and accounting@ mail, which #189 only screened by subject.

## What the Meet API gives us (read-only probe, 2026-09-28)
- `conferenceRecords.smartNotes` works with our scopes. Each smart note names its notes Doc (`docs_destination.document`),
  so a notes file maps to exactly one conference record, and from there to its real participants. No calendar guessing.
- Conference records only go back **~4 weeks**. Older standalone notes cannot be recovered and stay walled.
- In a sample of 60 of Hugh's meetings, 27 were notes-only (no transcript). **14 of those 27 had 1–2 real participants.**
  They were genuine 1:1s that the old invite-count rule could have exposed, which confirms G2.

## Design
1. **Notes-only meetings in the Meet API sync.** `MeetApiSource#records_for` used to skip a conference record with no
   transcript. Now it lists that record's smart notes and emits each notes Doc as a `gemini_notes` record carrying
   `raw_metadata["meet_attendance"] = {participants: N, conference_record: name}`. N is the Meet API participant count,
   which is real attendance.
2. **Classifier.** A notes doc with no transcript but a recorded attendance is classified on that attendance with the usual
   1:1 rule (≤2 → `one_on_one`), then the content review. No attendance → `attendance_unknown`, as before.
   The notes' title rule and transcript inheritance are unchanged and still come first.
3. **The attendance sticks.** Ingest keeps `meet_attendance` when a later source (the Drive notes sync) re-ingests the same
   file without it. Otherwise the nightly Drive pass would flip the doc back to "unknown". Keys a source does send
   still win (`preserved.merge(new)`).
4. **Mail screening.** `Groups::Connector` runs the content review on threads to jobs@, admin@ and accounting@ that pass
   the subject rules. The prompt now covers email and says vendor, billing and invoice notices to the company are not
   personal. That changes the prompt, so `ContentReview::VERSION` goes to 2 and meetings are re-reviewed once (~$4).
5. **Nightly budget.** Those groups hold ~11k threads (~23M characters, ~$6 once). Reviewing them all at ~1–2s each would
   stretch the nightly run by hours. So the Reclassifier reviews at most 1,500 group threads per run. Threads past the
   budget are held `unreviewed` (fail closed; chunks kept, hidden) and drained on later runs, or at once with
   `rake "stacks:etl:reclassify_privacy[unbounded]"` on a detached dyno.

## Backfill
- `rake "stacks:etl:sync_meet_all[30]"` once: re-reads the last ~30 days of conference records (the most Google keeps)
  and stamps attendance on notes-only meetings. Unchanged transcripts are not re-embedded, and their review memo is reused.
- `heroku run:detached rake "stacks:etl:reclassify_privacy[unbounded]"` once: applies the new rules everywhere and drains
  the mail backlog.

## Not doing
- Recovering notes older than ~4 weeks. Google no longer has attendance for them; they stay walled (a human can include one).
- Treating job applications as private by themselves. The review flags *assessments* of a candidate. Whether inbound
  applications should be hidden from the agent is a policy call for Hugh.
