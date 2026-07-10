# Optix: Automated Deactivation of Inactive Members — Dry Run for Team Review

**Status: awaiting team sign-off — no changes have been made to Optix.**

- Dry run performed: **July 10, 2026** (read-only queries against the live Optix API)
- Proposed by: Stacks automation (`stacks:daily_enterprise_tasks`)
- Applies to: Index Space's Optix organization

> **Revision 2 (July 10, 2026):** an earlier version of this document listed 75
> members, incorrectly including B Milder and 6 others who are still members.
> The first draft only counted ACTIVE/IN_TRIAL plans as "membership" — it missed
> members with an UPCOMING (scheduled) plan, and members whose plans are held
> through a team. The rules now also honor Optix's own `has_plans` flag, which
> covers both cases. The list below is corrected: **68 members**, and notably
> none of them now carry a pending balance.

---

## What we're proposing

A daily automated task in Stacks that deactivates (removes) Optix members who no
longer hold a membership. Today these people accumulate forever as "active" users
in Optix — 541 active users, of which only ~450 hold a current plan.

Once approved and deployed, this runs automatically every day as part of the
existing Stacks daily task pipeline. Members removed this way can rejoin at any
time — re-adding a user with the same email reactivates their existing Optix
account (booking history, profile, etc. are retained by Optix).

## The rules

A member is deactivated when **all** of the following are true:

1. They are currently an **active user** in Optix.
2. They have held **at least one membership plan** in the past
   (people who never had a plan — leads, contacts — are never touched).
3. They have **no ACTIVE, IN_TRIAL, or UPCOMING plan** right now — a member
   with a scheduled future plan (e.g. returning after a pause) is still a member.
4. **Optix itself agrees they hold no plans** (`has_plans` is false). This
   catches memberships our plan-by-plan reconstruction can't see, such as plans
   held through a team.
5. Their most recent plan that **actually ran** ended more than **7 days ago**
   (the grace period protects people between billing cycles or mid-rejoin).
   Plans canceled before they ever started don't count as "membership ended" —
   they never began.
6. They are **not an Optix admin**.

Mechanics: removal happens via Optix's official `memberRemove` API with
`collect_payment: true` — meaning if the member has any pending charges, Optix
creates an invoice due immediately as part of the removal. This is the same
operation as clicking "remove member" in the Optix admin dashboard.

## Dry run results

Snapshot of who would be deactivated **if the automation ran today**:

| | |
|---|---|
| Total users in Optix | 541 |
| Would be deactivated today | **68** |
| Skipped — still a member (UPCOMING plan or team-held plan) | 7 |
| Skipped — plan ended within the last 7 days | 2 |
| Skipped — Optix admin | 1 (Hugh Francis) |

After this first run clears the backlog, the daily run will typically
deactivate 0–2 people per day (members whose plans ended 8 days prior).

### The 68 members who would be deactivated today

Also available as a standalone file for spreadsheet import:
[`optix-member-deactivation-dry-run.csv`](./optix-member-deactivation-dry-run.csv)

The **"Invoiced balance on Deactivation"** column comes from Optix's
`memberRemovePreview` API — the exact invoice `memberRemove` would generate
for each member, previewed read-only on July 10, 2026.

```csv
Name,Email,Last plan,Plan status,Plan ended,Days ago,Invoiced balance on Deactivation
emma warren,092emma@gmail.com,[Chinatown] Friend,ENDED,2024-08-11,697,$0.00
May Shek,may@boundlessstud.io,[Chinatown] Regular,ENDED,2024-11-22,594,$0.00
Myles Larson,mail@myleslarson.com,[Chinatown] Patron,ENDED,2024-12-13,573,$0.00
Pooja Nitturkar,pooja.nitt@gmail.com,[Chinatown] Regular,ENDED,2025-01-19,536,$0.00
Cory Etzkorn,coryetzkorn@gmail.com,[Chinatown] Patron,ENDED,2025-02-09,515,$0.00
Lucy McKendrick,lucymckendrick@gmail.com,[Chinatown] Fellow,ENDED,2025-03-09,487,$0.00
Cheryl  Kao,cheryl@monopo.nyc,[Chinatown] Patron,ENDED,2025-04-15,450,unknown (no invoices on record)
Lucy Dayman,lucy@nowhere-nyc.com,[Chinatown] Friend,ENDED,2025-06-05,399,$0.00
Liam Fitzgerald,lfitz258@gmail.com,[Chinatown] Friend,ENDED,2025-07-28,346,$0.00
Annie Zhang,annie.zhang@sanctuary.computer,[Chinatown] Fellow,ENDED,2025-07-28,346,$0.00
andrew fu,andrewwfu@gmail.com,[Chinatown] Friend,ENDED,2025-08-12,331,$0.00
Nikki D'Ambrosio,naturallynicoletta@gmail.com,[Greenpoint] Regular,CANCELED,2025-10-23,260,unknown (no invoices on record)
Rose Rutledge,Rose.rutledge@output.com,Output 4x,ENDED,2025-11-14,237,unknown (no invoices on record)
Ane Aranburu,ane.aranburu@output.com,Output 4x,ENDED,2025-11-14,237,unknown (no invoices on record)
Rishin Doshi,rishin.doshi@output.com,Output 4x,ENDED,2025-11-14,237,unknown (no invoices on record)
Frankie DeGruy,francesadegruy@gmail.com,[Greenpoint] Regular,ENDED,2025-12-05,216,$0.00
Alex Darby,alex@thehybrid.studio,[Chinatown] Regular,ENDED,2025-12-07,214,$0.00
Lauren Slowik,laurenlaceyslowik@gmail.com,[Greenpoint] Regular,ENDED,2025-12-09,212,$0.00
Kelly Cavender,kellycavender5@gmail.com,[Chinatown] Regular,CANCELED,2025-12-12,209,$0.00
Tina Smith,hello@tinasmith.studio,[Greenpoint] Patron,ENDED,2025-12-15,206,$0.00
aliya donn,aliya@kernel.community,[Greenpoint] Friend,ENDED,2025-12-16,205,$0.00
Mac Watrous,macwatrous@gmail.com,[Chinatown] Patron,ENDED,2025-12-17,204,$0.00
emily um,emilyum16@gmail.com,[Greenpoint] Regular,ENDED,2025-12-19,202,$0.00
Alessandro Amato,alessandro@neuehaus.io,[Greenpoint] Regular,CANCELED,2025-12-25,196,$0.00
Lena Pia Hammerstingl,lenapia@neuehaus.io,[Chinatown] Regular,CANCELED,2025-12-25,196,$0.00
Gemma C,astrayproject@proton.me,[Chinatown] Fellow,ENDED,2025-12-30,191,$0.00
Tomas Markevicius,hi.tomasm@gmail.com,[Chinatown] Friend,ENDED,2025-12-31,190,$0.00
Kyra Levau,kyramlevau@gmail.com,$140,ENDED,2025-12-31,190,$0.00
Michelle Belgrod,michelle.belgrod@gmail.com,[Greenpoint] Fellow,ENDED,2026-01-09,181,$0.00
Victor Pedraza,vpedrazalopez@gmail.com,[Greenpoint] Regular,CANCELED,2026-01-12,179,$0.00
kendal kulley,kendal@daisy.so,[Chinatown] Patron,ENDED,2026-01-11,179,unknown (no invoices on record)
Alexandra  Bendek ,alexandra.bendek@gmail.com,[Greenpoint] Regular,ENDED,2026-01-19,171,$0.00
Linda Yang,linda@culturalcounsel.com,[Greenpoint] Regular,ENDED,2026-01-24,166,$0.00
Adam Ziel,adam@ziel.today,[Chinatown] Patron,ENDED,2026-01-26,164,$0.00
Maddie Woods,madelinewoods@icloud.com,[Chinatown] Regular,ENDED,2026-01-30,160,$0.00
David Dellamura,david@ddbaagency.com,[Greenpoint] Regular,ENDED,2026-01-30,160,$0.00
Colton Brown,c@lt.email,[Chinatown] Regular,ENDED,2026-02-04,155,$0.00
Lauren Wagner,laurenbwagner@gmail.com,[Chinatown] Friend,ENDED,2026-02-07,152,$0.00
Laura Lu,lauraelu@gmail.com,[Greenpoint] Regular,ENDED,2026-02-23,136,$0.00
Andy Nagashima,andykainagashima@gmail.com,[Greenpoint] Patron,ENDED,2026-02-24,135,$0.00
Angelica Moody ,angelicamoody3@gmail.com,[Greenpoint] Friend,ENDED,2026-02-27,132,$0.00
Artem Ivanov,ivanovart8@gmail.com,[Chinatown] Regular,ENDED,2026-02-27,132,$0.00
Megan Arizmendi,mearizmendi1@gmail.com,[Chinatown] Friend,ENDED,2026-03-03,128,$0.00
Mary Bibbey,mary@joinorderly.com,Discounted Fellow Plan,ENDED,2026-03-13,118,$0.00
Jessica Dimcevski,Jessica@blurrbureau.com,[Greenpoint] Week Pass,ENDED,2026-03-23,108,$0.00
Ned Hardy,ned@two.studio,[Chinatown] Fellow,ENDED,2026-03-24,107,$0.00
Lucy Dellar,lucy.dellar@gmail.com,[Chinatown] Friend,ENDED,2026-03-24,107,$0.00
Erik Ruuska,erikruuska@gmail.com,[Chinatown] Friend,ENDED,2026-03-31,100,$0.00
Daniel Morrow,danmorrow@gmail.com,[Greenpoint] Friend,ENDED,2026-04-01,99,$0.00
Andres Rabellino,andres.rabellino@gmail.com,[Greenpoint] Fellow,ENDED,2026-04-01,99,$0.00
Drew Litowitz,dlitowit@gmail.com,[Greenpoint] Friend,ENDED,2026-04-10,90,$0.00
Max Smouha,maxsmouha@gmail.com,[Chinatown] Regular,ENDED,2026-04-16,84,$0.00
Steven Phillips,hello@steven-phillips.com,[Greenpoint] Friend,ENDED,2026-04-25,75,$0.00
Francis Barth,francis@trestle.inc,[Chinatown] Regular,ENDED,2026-04-27,73,$0.00
Sam Wlody,swlody@gmail.com,[Greenpoint] Friend,ENDED,2026-04-28,72,$0.00
Sophie Chen,sophie@offmenumag.com,Weekly Pass,ENDED,2026-05-02,68,$0.00
Morry Kolman,wttdotm@gmail.com,[Chinatown] Fellow,ENDED,2026-05-10,60,unknown (no invoices on record)
Lauren McCurry,lauren@ballet-season.com,[Chinatown] Friend,ENDED,2026-05-13,57,$0.00
Claire  Gustavson,claire.gustavson@gmail.com,[Greenpoint] Fellow,ENDED,2026-05-15,55,$0.00
Rita Juarez,rita@ritajuarez.com,[Greenpoint] Patron,ENDED,2026-05-16,54,$0.00
Nico Salinas,nico@funken.work,[Greenpoint] Patron,ENDED,2026-05-20,50,$0.00
diego funken,diego@funken.work,[Greenpoint] Patron,ENDED,2026-05-20,50,$0.00
Daniel Brenners,danbrenners@gmail.com,[Greenpoint] Friend,ENDED,2026-05-27,43,$0.00
Ben Perez,benperez1227@gmail.com,2 Weeks,ENDED,2026-05-29,41,$0.00
Aaron Free,aaa2141@gmail.com,[Chinatown] Friend,ENDED,2026-05-31,39,$0.00
Hoyd Breton,hi@hoydbreton.com,[Greenpoint] Patron,ENDED,2026-06-19,20,$0.00
Andy Lee,andylulee1013@gmail.com,[Chinatown] Patron,ENDED,2026-06-22,17,$0.00
Roman Bellisari,romanbellisari@gmail.com,[Chinatown] Fellow,ENDED,2026-06-30,9,$0.00
```

**Flags from the balance preview:**

- **Every previewable member is at $0.00** — no invoices will be generated by
  deactivating anyone on this list.
- **7 members show "unknown":** they have no invoices on record in Optix, so we
  couldn't map them to a member record to preview (likely comp'd or manually
  managed members — including all three Output members). The automation will
  skip anyone it can't preview and report them for manual handling.

### Skipped — still members (listed in error in revision 1 of this document)

| Name | Email | Why they're still a member |
|------|-------|---------------------------|
| B Milder | b@bmilder.studio | UPCOMING [Greenpoint] Patron plan starting 2026-07-16 |
| Charles Broskoski | cab@are.na | Optix reports they hold a plan (likely via a team) |
| Bianca Bramham | bianca@jackywinter.com | Optix reports they hold a plan (likely via a team) |
| Sonya Gimon | sgimon@3fwild.com | Optix reports they hold a plan (likely via a team) |
| Jess De-Graft Quansah | degrj277@newschool.edu | Optix reports they hold a plan (likely via a team) |
| Marisa Rowland | mhoperowland@gmail.com | Optix reports they hold a plan (likely via a team) |
| Jackson Strambi | jackson@seekeasy.ai | Optix reports they hold a plan (likely via a team) |

### Skipped — within the 7-day grace period (would be deactivated in the coming days)

2 members whose plans ended fewer than 8 days ago. They'll be picked up by a
future daily run if they don't renew.

### Skipped — Optix admins

| Name | Email | Last plan | Ended | Days ago |
|------|-------|-----------|-------|----------|
| Hugh Francis | hugh@sanctuary.computer | [Chinatown] Patron | 2026-04-16 | 84 |

## What deactivation does (and doesn't do)

- **Does:** removes the member from the Optix organization — they lose app and
  space access, and stop appearing as an active member. If they have pending
  charges, an invoice is created and due immediately (`collect_payment: true`).
- **Doesn't:** delete their account or history. Optix retains the user; adding
  them again by email reactivates them.
- **Reversible:** yes — any removal can be undone by re-inviting the member.

## Safeguards

- Never touches Optix admins.
- Never touches anyone who never held a plan (leads/contacts are out of scope).
- 7-day grace period after a plan ends.
- Before each removal, the automation previews the invoice `memberRemove` would
  generate (`memberRemovePreview`). Anyone it can't preview (see the "unknown"
  rows above) is skipped and reported for manual handling.
- Each daily run logs exactly who was deactivated and any invoice generated;
  failures are reported through Stacks' existing error reporting
  (Sentry + SystemTask status).
- Runs only for the Index Space enterprise inside `stacks:daily_enterprise_tasks`.

## Questions for the team before we deploy

1. Does anyone on the list above need to stay active (e.g. informal arrangements,
   staff on comp'd access, partners)? Reply with names and we'll remove them from
   the first run — and tell us the rule so we can encode it.
2. The **7 "unknown" members** (no invoices on record — including the three
   Output members): should they be deactivated manually, or left alone?
3. Is `collect_payment: true` right as the default? (Everyone on today's list
   previews at $0.00, so it currently affects no one — this is about future
   daily runs.)
4. Is 7 days the right grace period?

## Sign-off

- [ ] Index Space team lead
- [ ] Operations
- [ ] Engineering

Once checked off, engineering will deploy the automation and it will begin
running daily.
