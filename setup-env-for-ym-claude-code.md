# Environment Setup Steps for Maybe Personal Finance App

## Prerequisites
- Ruby 3.4.4 (already installed via mise)
- PostgreSQL client library (libpq)
- PostgreSQL server

## Setup Steps

### 1. Install PostgreSQL Dependencies
```bash
# Install PostgreSQL client library
brew install libpq

# Install PostgreSQL server
brew install postgresql@15

# Start PostgreSQL service
brew services start postgresql@15
```

### 2. Configure Bundler for PostgreSQL
```bash
# Configure bundler to use Homebrew libpq for pg gem compilation
bundle config build.pg --with-pg-config=/opt/homebrew/opt/libpq/bin/pg_config
```

### 3. Project Setup
```bash
# Copy environment configuration
cp .env.local.example .env.local

# Install dependencies and prepare database
bin/setup
```

## What `bin/setup` Does
- Installs Ruby gem dependencies via `bundle install`
- Creates development and test databases
- Runs database migrations
- Seeds OAuth applications
- Cleans up old logs and temp files

## Development Server
```bash
# Start development server (Rails + Sidekiq + Tailwind watcher)
bin/dev

# Or start Rails server only
bin/rails server
```

## Access the App
- URL: http://localhost:3000
- Email: `user@maybe.local`
- Password: `password`

## Notes
- PostgreSQL@15 is keg-only, so it won't conflict with other PostgreSQL installations
- The pg gem is configured to use Homebrew's libpq instead of Postgres.app
- All dependencies are managed through the lockfile versions for consistency