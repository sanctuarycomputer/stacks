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

## Prod Commands

[As per Parity's documentation](https://github.com/thoughtbot/parity)

### Deploy
`production deploy`

### Console
`production console`

### Logs
`production tail`

### DB Migration
`production migrate`
