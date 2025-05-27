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

### Gem installation on a Mac M1

If you ever see an error upon running `bundle install` along the lines of:

```
Results logged to
/Users/josephineweidner/.asdf/installs/ruby/2.7.2/lib/ruby/gems/2.7.0/extensions/arm64-darwin-23/2.7.0/nio4r-2.5.5/gem_make.out

An error occurred while installing nio4r (2.5.5), and Bundler cannot continue.
Make sure that `gem install nio4r -v '2.5.5' --source 'https://rubygems.org/'` succeeds before bundling.
```

Open up the `gem_make.out` log file. Search for "error" (there are lots of warnings
you can ignore). You should see a line that ends in something like "[-Wincompatible-function-pointer-types]".
The trick is to pass a flag in the `gem install` command that tells the compiler to ignore
that error. For example:

```
gem install nio4r -v '2.5.5' --source 'https://rubygems.org/' -- --with-cflags="-Wno-error=incompatible-function-pointer-types"
```

This may happen for gems other than `nio4r`, but the same steps apply. Good luck!

## On Windows:

Note: this is probably best run through WSL2 and not Windows. If you do dev on windows, don't check in any Gemfile.lock changes since these will be windows specific

### Gem installation on Windows

If you have issues installing mimemagic on windows you can follow the accepted answer [here](https://stackoverflow.com/questions/69248078/mimemagic-install-error-could-not-find-mime-type-database-in-the-following-loc)

The .xml doc linked in the answer might be dead, instead you can grab it's contents [here](https://raw.githubusercontent.com/Rob--W/open-in-browser/master/shared-mime-info/freedesktop.org.xml)

### Parity restore on Windows

Parity doesn't seem to be fully windows compatible for restoring on windows (seemingly different flags for some commands), instead you can follow the restoration steps manually by referencing the [parity restore source code](https://github.com/thoughtbot/parity/blob/0c61821f78e4ad6ae5461f208f056100a84749ab/lib/parity/backup.rb#L40)

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
