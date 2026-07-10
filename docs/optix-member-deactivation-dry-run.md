# Optix: Automated Deactivation of Inactive Members — Dry Run for Team Review

**Status: awaiting team sign-off — no changes have been made to Optix.**

- Dry run performed: **July 10, 2026** (read-only queries against the live Optix API)
- Proposed by: Stacks automation (`stacks:daily_enterprise_tasks`)
- Applies to: Index Space's Optix organization

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
3. They have **no ACTIVE or IN_TRIAL plan** right now.
4. Their most recent plan **ended or was canceled more than 7 days ago**
   (the grace period protects people between billing cycles or mid-rejoin).
5. They are **not an Optix admin**.

Mechanics: removal happens via Optix's official `memberRemove` API with
`collect_payment: true` — meaning if the member has any pending charges, Optix
creates an invoice due immediately as part of the removal. This is the same
operation as clicking "remove member" in the Optix admin dashboard.

## Dry run results

Snapshot of who would be deactivated **if the automation ran today**:

| | |
|---|---|
| Total users in Optix | 541 |
| Would be deactivated today | **75** |
| Skipped — plan ended within the last 7 days | 2 |
| Skipped — Optix admin | 1 (Hugh Francis) |

After this first run clears the backlog, the daily run will typically
deactivate 0–2 people per day (members whose plans ended 8 days prior).

### The 75 members who would be deactivated today

| # | Name | Email | Last plan | Plan status | Ended | Days ago |
|---|------|-------|-----------|-------------|-------|----------|
| 1 | Charles Broskoski | cab@are.na | Dedicated Desk (presale) | ENDED | 2023-08-31 | 1043 |
| 2 | emma warren | 092emma@gmail.com | [Chinatown] Friend | ENDED | 2024-08-11 | 697 |
| 3 | May Shek | may@boundlessstud.io | [Chinatown] Regular | ENDED | 2024-11-22 | 594 |
| 4 | Myles Larson | mail@myleslarson.com | [Chinatown] Patron | ENDED | 2024-12-13 | 573 |
| 5 | Bianca Bramham | bianca@jackywinter.com | [Chinatown] Regular | ENDED | 2025-01-07 | 548 |
| 6 | Pooja Nitturkar | pooja.nitt@gmail.com | [Chinatown] Regular | ENDED | 2025-01-19 | 536 |
| 7 | Cory Etzkorn | coryetzkorn@gmail.com | [Chinatown] Patron | ENDED | 2025-02-09 | 515 |
| 8 | Lucy McKendrick | lucymckendrick@gmail.com | [Chinatown] Fellow | ENDED | 2025-03-09 | 487 |
| 9 | Cheryl Kao | cheryl@monopo.nyc | [Chinatown] Patron | ENDED | 2025-04-15 | 450 |
| 10 | Lucy Dayman | lucy@nowhere-nyc.com | [Chinatown] Friend | ENDED | 2025-06-05 | 399 |
| 11 | Liam Fitzgerald | lfitz258@gmail.com | [Chinatown] Friend | ENDED | 2025-07-28 | 346 |
| 12 | Annie Zhang | annie.zhang@sanctuary.computer | [Chinatown] Fellow | ENDED | 2025-07-28 | 346 |
| 13 | Jess De-Graft Quansah | degrj277@newschool.edu | [Chinatown] Friend | ENDED | 2025-08-01 | 342 |
| 14 | andrew fu | andrewwfu@gmail.com | [Chinatown] Friend | ENDED | 2025-08-12 | 331 |
| 15 | Nikki D'Ambrosio | naturallynicoletta@gmail.com | [Greenpoint] Regular | CANCELED | 2025-10-23 | 260 |
| 16 | Rose Rutledge | Rose.rutledge@output.com | Output 4x | ENDED | 2025-11-14 | 237 |
| 17 | Ane Aranburu | ane.aranburu@output.com | Output 4x | ENDED | 2025-11-14 | 237 |
| 18 | Rishin Doshi | rishin.doshi@output.com | Output 4x | ENDED | 2025-11-14 | 237 |
| 19 | Frankie DeGruy | francesadegruy@gmail.com | [Greenpoint] Regular | ENDED | 2025-12-05 | 216 |
| 20 | Kelly Cavender | kellycavender5@gmail.com | [Greenpoint] Regular | ENDED | 2025-12-07 | 214 |
| 21 | Sonya Gimon | sgimon@3fwild.com | [Chinatown] Fellow | ENDED | 2025-12-07 | 214 |
| 22 | Alex Darby | alex@thehybrid.studio | [Chinatown] Regular | ENDED | 2025-12-07 | 214 |
| 23 | Lauren Slowik | laurenlaceyslowik@gmail.com | [Greenpoint] Regular | ENDED | 2025-12-09 | 212 |
| 24 | Tina Smith | hello@tinasmith.studio | [Greenpoint] Patron | ENDED | 2025-12-15 | 206 |
| 25 | B Milder | b@bmilder.studio | [Greenpoint] Patron | CANCELED | 2025-12-16 | 205 |
| 26 | aliya donn | aliya@kernel.community | [Greenpoint] Friend | ENDED | 2025-12-16 | 205 |
| 27 | Mac Watrous | macwatrous@gmail.com | [Chinatown] Patron | ENDED | 2025-12-17 | 204 |
| 28 | emily um | emilyum16@gmail.com | [Greenpoint] Regular | ENDED | 2025-12-19 | 202 |
| 29 | Alessandro Amato | alessandro@neuehaus.io | [Chinatown] Regular | ENDED | 2025-12-24 | 197 |
| 30 | Lena Pia Hammerstingl | lenapia@neuehaus.io | [Chinatown] Regular | ENDED | 2025-12-24 | 197 |
| 31 | Gemma C | astrayproject@proton.me | [Chinatown] Fellow | ENDED | 2025-12-30 | 191 |
| 32 | Kyra Levau | kyramlevau@gmail.com | $140 | ENDED | 2025-12-31 | 190 |
| 33 | Tomas Markevicius | hi.tomasm@gmail.com | [Chinatown] Friend | ENDED | 2025-12-31 | 190 |
| 34 | Michelle Belgrod | michelle.belgrod@gmail.com | [Greenpoint] Fellow | ENDED | 2026-01-09 | 181 |
| 35 | Marisa Rowland | mhoperowland@gmail.com | [Chinatown] Patron | ENDED | 2026-01-09 | 181 |
| 36 | kendal kulley | kendal@daisy.so | [Chinatown] Patron | ENDED | 2026-01-11 | 179 |
| 37 | Victor Pedraza | vpedrazalopez@gmail.com | [Greenpoint] Regular | CANCELED | 2026-01-12 | 178 |
| 38 | Alexandra Bendek | alexandra.bendek@gmail.com | [Greenpoint] Regular | ENDED | 2026-01-19 | 171 |
| 39 | Linda Yang | linda@culturalcounsel.com | [Greenpoint] Regular | ENDED | 2026-01-24 | 166 |
| 40 | Adam Ziel | adam@ziel.today | [Chinatown] Patron | ENDED | 2026-01-26 | 164 |
| 41 | David Dellamura | david@ddbaagency.com | [Greenpoint] Regular | ENDED | 2026-01-30 | 160 |
| 42 | Maddie Woods | madelinewoods@icloud.com | [Chinatown] Regular | ENDED | 2026-01-30 | 160 |
| 43 | Colton Brown | c@lt.email | [Chinatown] Regular | ENDED | 2026-02-04 | 155 |
| 44 | Lauren Wagner | laurenbwagner@gmail.com | [Chinatown] Friend | ENDED | 2026-02-07 | 152 |
| 45 | Laura Lu | lauraelu@gmail.com | [Greenpoint] Regular | ENDED | 2026-02-23 | 136 |
| 46 | Andy Nagashima | andykainagashima@gmail.com | [Greenpoint] Patron | ENDED | 2026-02-24 | 135 |
| 47 | Angelica Moody | angelicamoody3@gmail.com | [Greenpoint] Friend | ENDED | 2026-02-27 | 132 |
| 48 | Artem Ivanov | ivanovart8@gmail.com | [Chinatown] Regular | ENDED | 2026-02-27 | 132 |
| 49 | Megan Arizmendi | mearizmendi1@gmail.com | [Chinatown] Friend | ENDED | 2026-03-03 | 128 |
| 50 | Mary Bibbey | mary@joinorderly.com | Discounted Fellow Plan | ENDED | 2026-03-13 | 118 |
| 51 | Jessica Dimcevski | Jessica@blurrbureau.com | [Greenpoint] Week Pass | ENDED | 2026-03-23 | 108 |
| 52 | Ned Hardy | ned@two.studio | [Chinatown] Fellow | ENDED | 2026-03-24 | 107 |
| 53 | Lucy Dellar | lucy.dellar@gmail.com | [Chinatown] Friend | ENDED | 2026-03-24 | 107 |
| 54 | Erik Ruuska | erikruuska@gmail.com | [Chinatown] Friend | ENDED | 2026-03-31 | 100 |
| 55 | Andres Rabellino | andres.rabellino@gmail.com | [Greenpoint] Fellow | ENDED | 2026-04-01 | 99 |
| 56 | Daniel Morrow | danmorrow@gmail.com | [Greenpoint] Friend | ENDED | 2026-04-01 | 99 |
| 57 | Drew Litowitz | dlitowit@gmail.com | [Greenpoint] Friend | ENDED | 2026-04-10 | 90 |
| 58 | Max Smouha | maxsmouha@gmail.com | [Chinatown] Regular | ENDED | 2026-04-16 | 84 |
| 59 | Steven Phillips | hello@steven-phillips.com | [Greenpoint] Friend | ENDED | 2026-04-25 | 75 |
| 60 | Francis Barth | francis@trestle.inc | [Chinatown] Regular | ENDED | 2026-04-27 | 73 |
| 61 | Sam Wlody | swlody@gmail.com | [Greenpoint] Friend | ENDED | 2026-04-28 | 72 |
| 62 | Sophie Chen | sophie@offmenumag.com | Weekly Pass | ENDED | 2026-05-02 | 68 |
| 63 | Morry Kolman | wttdotm@gmail.com | [Chinatown] Fellow | ENDED | 2026-05-10 | 60 |
| 64 | Lauren McCurry | lauren@ballet-season.com | [Chinatown] Friend | ENDED | 2026-05-13 | 57 |
| 65 | Claire Gustavson | claire.gustavson@gmail.com | [Greenpoint] Fellow | ENDED | 2026-05-15 | 55 |
| 66 | Rita Juarez | rita@ritajuarez.com | [Greenpoint] Patron | ENDED | 2026-05-16 | 54 |
| 67 | diego funken | diego@funken.work | [Greenpoint] Patron | ENDED | 2026-05-20 | 50 |
| 68 | Nico Salinas | nico@funken.work | [Greenpoint] Patron | ENDED | 2026-05-20 | 50 |
| 69 | Daniel Brenners | danbrenners@gmail.com | [Greenpoint] Friend | ENDED | 2026-05-27 | 43 |
| 70 | Ben Perez | benperez1227@gmail.com | 2 Weeks | ENDED | 2026-05-29 | 41 |
| 71 | Aaron Free | aaa2141@gmail.com | [Chinatown] Friend | ENDED | 2026-05-31 | 39 |
| 72 | Jackson Strambi | jackson@seekeasy.ai | [Chinatown] Fellow | ENDED | 2026-06-05 | 34 |
| 73 | Hoyd Breton | hi@hoydbreton.com | [Greenpoint] Patron | ENDED | 2026-06-19 | 20 |
| 74 | Andy Lee | andylulee1013@gmail.com | [Chinatown] Patron | ENDED | 2026-06-22 | 17 |
| 75 | Roman Bellisari | romanbellisari@gmail.com | [Chinatown] Fellow | ENDED | 2026-06-30 | 9 |

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
- Each daily run logs exactly who was deactivated; failures are reported through
  Stacks' existing error reporting (Sentry + SystemTask status).
- Runs only for the Index Space enterprise inside `stacks:daily_enterprise_tasks`.

## Questions for the team before we deploy

1. Does anyone on the list above need to stay active (e.g. informal arrangements,
   staff on comp'd access, partners)? Reply with names and we'll remove them from
   the first run — and tell us the rule so we can encode it.
2. Is `collect_payment: true` right? Anyone on this list with lingering pending
   charges will get an invoice due immediately when they're removed.
3. Is 7 days the right grace period?

## Sign-off

- [ ] Index Space team lead
- [ ] Operations
- [ ] Engineering

Once checked off, engineering will deploy the automation and it will begin
running daily.
