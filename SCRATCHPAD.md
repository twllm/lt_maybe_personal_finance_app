# Scratchpad for Maybe Finance App repo

## Repo Overview
- Rails-based personal finance app with features like bank account syncing (Plaid), transaction management, budgets, investments, etc.
- Domain logic primarily in `app/models` with subdirectories (e.g., `account`, `balance`, `transaction`).
- Background jobs in `app/jobs`, controllers in `app/controllers`, etc.
- Custom money handling code in `lib/money`.
- Many unit and integration tests under `test/` using Minitest fixtures.

## Key Points from CLAUDE.md
- Use `bin/rails test` for tests, `bin/rubocop` for linting, etc.
- Business logic should reside in models; services are minimal.
- Testing philosophy: minimal yet effective tests using fixtures, Mocha for mocks.
- Multi-currency support via custom Money class and exchange rates.
- Two application modes: managed vs self-hosted.

## Observed Important Modules
- `Money` class (`lib/money.rb`): arithmetic, formatting, currency exchange with fallback rate.
- `Account::CurrentBalanceManager` & `Account::OpeningBalanceManager`: handle account balance anchoring logic.
- `Sync` model (`app/models/sync.rb`): state machine for syncing data with child/parent relationships.
- `Transaction::Search` (`app/models/transaction/search.rb`): complex filtering and totals computation with caching.
- `ApiRateLimiter` service: per-API-key rate limiting in Redis.
- `Import` model: CSV parsing and mapping; `sanitize_number` method handles different number formats.
- `TransactionsController` has filtering logic and parameter persistence.
