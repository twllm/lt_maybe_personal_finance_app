## Money currency exchange
**Name:** `Money#exchange_to`
**Excerpt:**
```ruby
  def exchange_to(other_currency, date: Date.current, fallback_rate: nil)
    iso_code = currency.iso_code
    other_iso_code = Money::Currency.new(other_currency).iso_code

    if iso_code == other_iso_code
      self
    else
      exchange_rate = store.find_or_fetch_rate(from: iso_code, to: other_iso_code, date: date)&.rate || fallback_rate

      raise ConversionError.new(from_currency: iso_code, to_currency: other_iso_code, date: date) unless exchange_rate

      Money.new(amount * exchange_rate, other_iso_code)
    end
  end
```
**File:** lib/money.rb:42-55
**Why Selected:** Handles currency conversion with fallback rates and custom error handling. Important for money operations and exchange rate retrieval.
**Primary Risks:** Fragile tests might hard-code exact BigDecimal operations or rely on internal exchange rate retrieval logic.
**Hidden / Edge Cases:** Same-currency conversion path, missing exchange rate with or without fallback, rounding behavior.
**Spec Clarity:** Medium – method is short but interaction with exchange rate store and error messaging could be misinterpreted.
**Whether tests already exist for this, and if so, when those tests were written:** Yes, tests in `test/lib/money_test.rb` added March 2025.
**Suggested Robust Tests:**
- Stub `ExchangeRate.find_or_fetch_rate` to return specific rate or nil.
- Verify returned Money objects' amount and currency without asserting intermediate calls.
- Parameterize by same/different currency and with/without fallback rate.

## Opening balance management
**Name:** `Account::OpeningBalanceManager#set_opening_balance`
**Excerpt:**
```ruby
  def set_opening_balance(balance:, date: nil)
    resolved_date = date || default_date

    # Validate date is before oldest entry
    if date && oldest_entry_date && resolved_date >= oldest_entry_date
      return Result.new(success?: false, changes_made?: false, error: "Opening balance date must be before the oldest entry date")
    end

    if opening_anchor_valuation.nil?
      create_opening_anchor(
        balance: balance,
        date: resolved_date
      )
      Result.new(success?: true, changes_made?: true, error: nil)
    else
      changes_made = update_opening_anchor(balance: balance, date: date)
      Result.new(success?: true, changes_made?: changes_made, error: nil)
    end
  end
```
**File:** app/models/account/opening_balance_manager.rb:26-77
**Why Selected:** Determines how accounts establish or update opening balances, including date validations and conditional creation vs. update. Impacts historical balance calculations.
**Primary Risks:** Over-asserting internal transaction creation details or exact date calculations; ignoring error cases.
**Hidden / Edge Cases:** Dates after oldest entry; updating versus creating anchor; default date calculation when no entries exist.
**Spec Clarity:** Medium – purpose is clear from comments but underlying assumptions about account types and oldest entry logic may be ambiguous.
**Whether tests already exist for this, and if so, when those tests were written:** Yes, tests added July 2025 (`test/models/account/opening_balance_manager_test.rb`).
**Suggested Robust Tests:**
- Parameterize account types with/without existing anchors.
- Assert only on resulting balance/date and whether a new valuation record was created.
- Check rejection when date is after oldest entry.

## Current balance management
**Name:** `Account::CurrentBalanceManager#set_current_balance`
**Excerpt:**
```ruby
  def set_current_balance(balance)
    if account.linked?
      result = set_current_balance_for_linked_account(balance)
    else
      result = set_current_balance_for_manual_account(balance)
    end

    # Update cache field so changes appear immediately to the user
    account.update!(balance: balance)

    result
  rescue => e
    Result.new(success?: false, changes_made?: false, error: e.message)
  end
```
**File:** app/models/account/current_balance_manager.rb:34-140
**Why Selected:** Complex method for updating current balance with different strategies depending on account state (manual vs linked). Includes reconciliation logic and opening balance adjustments.
**Primary Risks:** Tests could depend on specific queries or the number of created records, leading to brittleness.
**Hidden / Edge Cases:** Accounts with or without reconciliations, linked account anchor creation vs. update, transactions altering opening balance, error handling.
**Spec Clarity:** Medium-Low – comments explain high level but exact behavior across account types could be misinterpreted.
**Whether tests already exist for this, and if so, when those tests were written:** Extensive tests from July 2025.
**Suggested Robust Tests:**
- Parameterize across account types and presence of reconciliations.
- Verify results via balance values and existence of valuation records, not intermediate updates.
- Use time travel helpers to test date-dependent logic.

## Sync state machine
**Name:** `Sync` AASM definition
**Excerpt:**
```ruby
  # Sync state machine
  aasm column: :status, timestamps: true do
    state :pending, initial: true
    state :syncing
    state :completed
    state :failed
    state :stale

    after_all_transitions :handle_transition

    event :start, after_commit: :handle_start_transition do
      transitions from: :pending, to: :syncing
    end

    event :complete, after_commit: :handle_completion_transition do
      transitions from: :syncing, to: :completed
    end

    event :fail do
      transitions from: :syncing, to: :failed
```
**File:** app/models/sync.rb:26-195
**Why Selected:** Implements a multi-state AASM workflow with parent/child syncs and window expansion logic. Critical for data synchronization.
**Primary Risks:** Over-specifying internal event sequence or exact logging; ignoring asynchronous race conditions.
**Hidden / Edge Cases:** Stale sync marking, parent-child failure propagation, window expansion when called multiple times.
**Spec Clarity:** Medium – states are defined but implications of transitions may be subtle.
**Whether tests already exist for this, and if so, when those tests were written:** Tests exist (May 2025) in `test/models/sync_test.rb`.
**Suggested Robust Tests:**
- Simulate nested syncs and assert final statuses of parent/child without inspecting logs.
- Trigger errors to verify failure propagation and post-sync callbacks.
- Test window expansion idempotently.

## CSV number sanitization
**Name:** `Import#sanitize_number`
**Excerpt:**
```ruby
    def sanitize_number(value)
      return "" if value.nil?

      format = NUMBER_FORMATS[number_format]
      return "" unless format

      # First, normalize spaces and remove any characters that aren't numbers, delimiters, separators, or minus signs
      sanitized = value.to_s.strip

      # Handle French/Scandinavian format specially
      if format[:delimiter] == " "
        sanitized = sanitized.gsub(/\s+/, "") # Remove all spaces first
      else
        sanitized = sanitized.gsub(/[^\d#{Regexp.escape(format[:delimiter])}#{Regexp.escape(format[:separator])}\-]/, "")

        # Replace delimiter with empty string
        if format[:delimiter].present?
          sanitized = sanitized.gsub(format[:delimiter], "")
        end
      end
```
**File:** app/models/import.rb:253-284
**Why Selected:** Parses numeric values from CSV considering various international formats. Failure to parse correctly can corrupt imports.
**Primary Risks:** Tests may fixate on regex patterns or exact string replacements, making refactors difficult.
**Hidden / Edge Cases:** Handling spaces for French formats, delimiters/separators absent, invalid numeric strings.
**Spec Clarity:** Low – comment explains general idea but allowed inputs and outputs could be ambiguous.
**Whether tests already exist for this, and if so, when those tests were written:** No direct tests found as of July 2025.
**Suggested Robust Tests:**
- Parameterize across `NUMBER_FORMATS` variants with valid and invalid numbers.
- Assert sanitized output equals expected string; ensure nil or invalid inputs return empty string.

## API rate limiting
**Name:** `ApiRateLimiter`
**Excerpt:**
```ruby
  # Check if the API key has exceeded its rate limit
  def rate_limit_exceeded?
    current_count >= rate_limit
  end

  # Increment the request count for this API key
  def increment_request_count!
    key = redis_key
    current_time = Time.current.to_i
    window_start = (current_time / 3600) * 3600 # Hourly window

    @redis.multi do |transaction|
      # Use a sliding window with hourly buckets
      transaction.hincrby(key, window_start.to_s, 1)
      transaction.expire(key, 7200) # Keep data for 2 hours to handle sliding window
    end
  end

  # Get current request count within the current hour
```
**File:** app/services/api_rate_limiter.rb:16-81
**Why Selected:** Manages per-API-key request counts using Redis with sliding window. Includes self-hosted bypass logic.
**Primary Risks:** Tests might rely on actual Redis state or exact expiration times, causing flakiness.
**Hidden / Edge Cases:** Crossing hour boundaries, reset_time calculation, self-hosted mode bypass.
**Spec Clarity:** Medium – comments hint at design but tier system and time windows may be misunderstood.
**Whether tests already exist for this, and if so, when those tests were written:** No explicit tests spotted.
**Suggested Robust Tests:**
- Use a Redis mock; simulate multiple increments and verify counts and reset times.
- Test `usage_info` and `rate_limit_exceeded?` around boundary conditions.

## Transaction search totals
**Name:** `Transaction::Search#totals`
**Excerpt:**
```ruby
  def totals
    @totals ||= begin
      Rails.cache.fetch("transaction_search_totals/#{cache_key_base}") do
        result = transactions_scope
                  .select(
                    "COALESCE(SUM(CASE WHEN entries.amount >= 0 AND transactions.kind NOT IN ('funds_movement', 'cc_payment') THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as expense_total",
                    "COALESCE(SUM(CASE WHEN entries.amount < 0 AND transactions.kind NOT IN ('funds_movement', 'cc_payment') THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as income_total",
                    "COUNT(entries.id) as transactions_count"
                  )
                  .joins(
                    ActiveRecord::Base.sanitize_sql_array([
                      "LEFT JOIN exchange_rates er ON (er.date = entries.date AND er.from_currency = entries.currency AND er.to_currency = ?)",
                      family.currency
                    ])
                  )
                  .take

        Totals.new(
          count: result.transactions_count.to_i,
```
**File:** app/models/transaction/search.rb:45-67
**Why Selected:** Computes totals with currency conversion and caching based on dynamic search filters.
**Primary Risks:** Over-asserting exact SQL queries or caching keys; tests may become brittle when query structure changes.
**Hidden / Edge Cases:** Missing exchange rates, different filters affecting cache key, zero-result cases.
**Spec Clarity:** Medium – logic is explicit but caching and exchange rate join may be tricky.
**Whether tests already exist for this, and if so, when those tests were written:** Yes, tests from June 2025 (`test/models/transaction/search_test.rb`).
**Suggested Robust Tests:**
- Parameterize across filters (types, categories) and currencies.
- Stub exchange rate lookup to verify totals without hitting DB join assumptions.
- Clear cache between runs to avoid order dependencies.

## Filter clearing logic
**Name:** `TransactionsController#clear_filter`
**Excerpt:**
```ruby
  def clear_filter
    updated_params = {
      "q" => search_params,
      "page" => params[:page],
      "per_page" => params[:per_page]
    }

    q_params = updated_params["q"] || {}

    param_key = params[:param_key]
    param_value = params[:param_value]

    if q_params[param_key].is_a?(Array)
      q_params[param_key].delete(param_value)
      q_params.delete(param_key) if q_params[param_key].empty?
    else
      q_params.delete(param_key)
    end
```
**File:** app/controllers/transactions_controller.rb:27-54
**Why Selected:** Implements clearing of search filters and persistence of parameters in session. Correct behavior impacts navigation UX.
**Primary Risks:** Tests might depend on session internals or exact redirect parameters, leading to brittleness.
**Hidden / Edge Cases:** Clearing array-based filters vs single values, restoring previous params when query empty, filter_cleared flag.
**Spec Clarity:** Medium – code structure shows intent but interactions between params and session could confuse.
**Whether tests already exist for this, and if so, when those tests were written:** Tests exist July 2025 (`test/controllers/transactions_controller_test.rb`).
**Suggested Robust Tests:**
- Simulate requests with various stored session params and ensure resulting redirect parameters are correct.
- Verify session update and presence/absence of `filter_cleared` flag without checking internal storage structure.
