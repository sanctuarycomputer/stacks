# Stacks

## Warning

Stacks was originally developed very quickly, as a hack on top of
[Active Admin](https://activeadmin.info/) to help people do skill tree reviews.

So, it does not conform to our Rails best practices, and it
is riddled with anti-patterns and hacks. I (@hhff) would like
to clean it up one day (refactor to use service objects and
fix the myriad of n+1 issues there are) but that day very well
may never come.

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

## Deployment

`git push heroku main`
