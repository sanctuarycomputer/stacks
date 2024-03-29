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
