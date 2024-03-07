# Stacks

## Warning

Stacks was originally developed very quickly, as a hack on top of
[Active Admin](https://activeadmin.info/) to help people do skill tree reviews.

So, it does not conform to our Rails best practices, and it
is riddled with anti-patterns and hacks. I (@hhff) would like
to clean it up one day (refactor to use service objects and
fix the myriad of n+1 issues there are) but that day very well
may never come.

## Gotchas

### OAuth2::Error (invalid_grant)

If you ever see an error like:

```
OAuth2::Error (invalid_grant: )
{"error":"invalid_grant"}
```

Just re-sync the production database as per instructions below.
It means Quickbooks API has revoked the current OAuth token.
We freshen it every 10 minutes on prod.

### Feeding prod a new QBO Oauth 2.0 Token

This is tricky. You'll need access to the "QBO App" on the Intuit
Developer portal first, then you can follow the steps described here:

https://www.loom.com/share/2c4f15512009443bb4e4c92d42e23a46

**You have been warned!**

## Prerequisites

1. A Ruby on Rails ready dev environment (w/ PostgresQL)
2. [parity](https://github.com/thoughtbot/parity)
3. Access to the garden3d 1password

## Development

1. Copy the Stacks master.key from 1password to `config/master.key`
2. Run:

```sh
# Install dependencies
bundle

# Add the Heroku remote
git remote add production https://git.heroku.com/g3d-stacks.git

# Login to heroku with dev@sanctuary.computer (in 1pass)
heroku login

# Backup the production database and copy it to your local
production backup
development restore-from production

# Run the server
rails s
```

Navigate to `localhost:3000`, and you should see a local version
of Stacks running a recent backup of the production database.

## Deploying

Heroku is configured to automatically deploy Stacks from the `main` branch when
PR's are merged. If you need to trigger a deploy manually, you can run:

`production deploy`

## Prod Commands

[As per Parity's documentation](https://github.com/thoughtbot/parity)

### Console
`production console`

### Logs
`production tail`

### DB Migration
`production migrate`


## The Stacks Domain Model

This is a quick overview of the Garden3D domain model that Stacks embodies.

### Studio

Within Garden3D, there are several distinct studios (Sanctuary, XXIX, etc).
Each studio has certain [team members](#team-member) that belong to it.
Studios use [OKR's](#okr) to measure their performance.

Model name: `Studio`

Additional attributes:
- Mailing lists - a list of public subscribers to updates for this studio
- Studio coordinators - the list of team members acting in a coordinator role for this studio


### Team member
The employees of Garden3D. Each team member can belong to one or more [studios](#studio),
A team member can be assigned as a contributor to a [project](#project).
Each team member earns [compensation](#compensation) for their work,
and we keep track of their [periods of employment](#employment-period).

Model name: `AdminUser`


### Project
We organize the work we do into distinct projects. Each project is staffed by
creating [assignments](#assignment) of team members to do the work. A project
is billed to a single [client](#client) via [invoices](#invoice).

We use Project Trackers to track the status of each in-flight project.
Each project tracker is synchronized with our project tracking data in Forecast
via a scheduled task. It's possible for project trackers to incorporate information
from multiple Forecast projects under the same umbrella.

When a project is completed, we create a [Project Capsule](#project-capsule)
to record the results of the project and capture any lessons learned.

Each project has a single team member designated as the Project Lead.
A project can have multiple different Project Leads over its lifespan.

Model name: `ProjectTracker`

### Project Capsule
A retrospective conducted after a project is completed. We use these for recording
learnings and measuring client satisfaction.

Model name: `ProjectCapsule`

### Client
A client represents the external company or organization that we are billing
for project work. Stacks reads client information from Forecast via
a daily [scheduled task](#scheduled-tasks). We send [invoices](#invoice)
to clients for the work we complete on their behalf.

Model name: `ForecastClient`


### Invoice
We create invoices to charge clients for the work we do on their behalf.
Stacks generates invoices on a monthly cadence by calculating all of the
hours that team members worked on a given project via their recorded [assignments](#assignment),
then computing the rate to charge for each hour of work.

Once an invoice has been successfully created, Stacks will submit it to Quickbooks.
From there, someone on our team will approve it and it will be sent to the client
for them to pay.

Model name: `InvoiceTracker`


### Assignment
Team members are assigned to projects, and can be assigned to multiple projects
at the same time. An assignment is essentially a discrete block of hours that
a team member marks as needing to be billed toward the project in question.
If a team member is working on a project over multiple weeks (assuming they
aren't working on the weekends), then each week will constitute its own assignment.

We use Harvest Forecast for managing team member assignments, and Stacks
reimports these assignments from the Forecast API via a daily cron ([see below](#scheduled-tasks)).

You may also hear these called `allocations` (that's the term Forecast uses).

Model name: `ForecastAssignment`

### Compensation
Team members have different attributes that define their amount of compensation.
The base amount that each team member is paid is based on their skill tree band
(midlevel, senior, lead, etc). We periodically conduct [reviews](#review) of team members'
skill tree bands, which can result in an increase in pay.

Team members are also awarded profit shares based on factors like their
tenure at the company.

### Employment period
Each team member has one or more periods of employment with the company.
These reflect the team member's current schedule (4-day, 5-day, or hourly).
When their schedule type changes, we close their previous employment period
and create a new one to match.

Model name: `FullTimePeriod`


<br />
<br />

## Scheduled tasks

- [Team discovery](#team-discovery)
- [Project tracker snapshots](#project-tracker-snapshots)
- [Studio snapshots](#studio-snapshots)
- [Invoicing](#invoicing)
- [Forecast sync](#forecast-sync)
- [Quickbooks sync](#quickbooks-sync)
- [Hour recording reminder](#hour-recording-reminder)

Stacks runs a number of scheduled tasks to re-sync its local database with
external systems (Google, Forecast, Quickbooks, etc) and to generate fresh views
of business data. Most tasks run on a daily cadence.

### Team discovery

Entrypoint: `Stacks::Team.discover!`

Cadence: daily

This task will fetch the latest information for Garden3D from Google Groups
and use it to update local models for team members so that the Stacks database
remains in sync.


### Project tracker snapshots

Entrypoint: `ProjectTracker#generate_snapshot!`

Cadence: daily

This task is responsible for updating our financial snapshot for each project.
We determine the number of hours that each team member worked on a given project,
the estimated cost to the studio for those hours, and use that to build a
historical snapshot of the project's costs over time. This snapshot is refreshed
with each run of the daily task.

### Studio snapshots

Entrypoint: `Studio#generate_snapshot!`

Cadence: daily

Similar to the project snapshots above, we also generate financial snapshots
for each of the larger studios in Garden3D. These are essentially rollups
of our financial performance across all of the projects within a given studio.
These snapshots are overwritten with each run of the daily task.

### Invoicing

Entrypoint: `Stacks::Automator.attempt_invoicing_for_previous_month`

Cadence: daily (effectively, monthly)

Even though this task runs daily, it will only create invoices for prior months
that are still pending. In practice this means that invoices are typically
only generated at the beginning of each month; during the rest of the month
this task will bail out early.

### Forecast sync

Entrypoint: `Stacks::Forecast.new.sync_all!`

Cadence: daily

This task syncs Stack's internal database with Forecast, our software for tracking
hourly assignments to client projects. Stacks will *delete* all of the previous
data from Forecast and re-fetch it. This includes:
- Projects
- Clients
- Assignments (in Forecast these are called `allocations`)

Stacks uses this information to generate representations of our projects
via instances of `ProjectTracker`.

### Quickbooks sync

Entrypoint: `Stacks::Quickbooks.sync_all!`

Cadence: daily

This task updates all of the Quickbooks invoice records in Stack's local database
(model name: `QboInvoice`) to match their remote references in Quickbooks.

It also fetches all of the profit and loss reports from Quickbooks on
monthly, quarterly, and yearly timescales. If we don't yet have a local record
for one of these reports (model name: `QboProfitAndLossReport`), then this
task will create one. Otherwise we'll update its attribute to match the
corresponding Quickbooks remote record.

### Hour recording reminder

Entrypoint: `Stacks::Automator.remind_people_to_record_hours_weekly`

Cadence: daily (effectively, monthly)

This task collects all of the current Forecast assignments for the prior
invoicing period and determines which team members are currently lacking
assignment data. Then it sends notifications to those team members via Twist.
