require "test_helper"

class Account::OpeningBalanceManagerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @manager = Account::OpeningBalanceManager.new(@account)
  end

  # Initialization and interface tests
  test "initializes with account and exposes expected interface" do
    assert_instance_of Account::OpeningBalanceManager, @manager
    assert_respond_to @manager, :has_opening_anchor?
    assert_respond_to @manager, :opening_date
    assert_respond_to @manager, :opening_balance
    assert_respond_to @manager, :set_opening_balance
  end

  # opening_anchor? predicate method tests
  test "has_opening_anchor? returns false when no opening anchor exists" do
    refute @manager.has_opening_anchor?
  end

  test "has_opening_anchor? returns true when opening anchor exists" do
    create_opening_anchor_entry(@account, date: 1.year.ago.to_date, amount: 1000)
    
    assert @manager.has_opening_anchor?
  end

  # opening_date calculation tests
  test "opening_date returns anchor date when opening anchor exists" do
    anchor_date = 1.year.ago.to_date
    create_opening_anchor_entry(@account, date: anchor_date, amount: 1000)
    
    assert_equal anchor_date, @manager.opening_date
  end

  test "opening_date returns oldest valuation date when no anchor but valuations exist" do
    oldest_date = 6.months.ago.to_date
    newer_date = 3.months.ago.to_date
    
    create_valuation_entry(@account, date: newer_date, amount: 1200)
    create_valuation_entry(@account, date: oldest_date, amount: 1100)
    
    assert_equal oldest_date, @manager.opening_date
  end

  test "opening_date returns day before oldest transaction when only transactions exist" do
    transaction_date = 3.months.ago.to_date
    create_transaction_entry(@account, date: transaction_date, amount: 100)
    
    expected_date = transaction_date.prev_day
    assert_equal expected_date, @manager.opening_date
  end

  test "opening_date returns current date when account has no entries" do
    @account.entries.destroy_all
    assert_empty @account.entries
    
    assert_equal Date.current, @manager.opening_date
  end

  test "opening_date prioritizes earliest of valuations and transaction predecessors" do
    valuation_date = 6.months.ago.to_date
    transaction_date = 3.months.ago.to_date
    
    create_valuation_entry(@account, date: valuation_date, amount: 1200)
    create_transaction_entry(@account, date: transaction_date, amount: 100)
    
    expected_date = [valuation_date, transaction_date.prev_day].min
    assert_equal expected_date, @manager.opening_date
  end

  # opening_balance retrieval tests
  test "opening_balance returns amount from opening anchor when present" do
    balance_amount = 1500
    create_opening_anchor_entry(@account, date: 1.year.ago.to_date, amount: balance_amount)
    
    assert_equal balance_amount, @manager.opening_balance
  end

  test "opening_balance returns zero when no opening anchor exists" do
    assert_equal 0, @manager.opening_balance
  end

  test "opening_balance handles orphaned valuation gracefully" do
    # Create valuation without proper entry relationship
    orphaned_valuation = Valuation.create!(kind: "opening_anchor")
    @account.valuations << orphaned_valuation
    
    assert_equal 0, @manager.opening_balance
  end

  # set_opening_balance - new anchor creation tests
  test "set_opening_balance creates new opening anchor successfully" do
    balance = 2000
    
    assert_difference -> { @account.entries.count } => 1,
                     -> { @account.valuations.opening_anchor.count } => 1 do
      result = @manager.set_opening_balance(balance: balance)
      
      assert_successful_result(result, changes_made: true)
    end
    
    verify_opening_anchor(@account, expected_amount: balance)
  end

  test "set_opening_balance creates anchor with custom date when specified" do
    custom_date = 2.years.ago.to_date
    balance = 3000
    
    result = @manager.set_opening_balance(balance: balance, date: custom_date)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: balance, expected_date: custom_date)
  end

  test "set_opening_balance calculates appropriate default date from transaction history" do
    transaction_date = 6.months.ago.to_date
    create_transaction_entry(@account, date: transaction_date, amount: 100)
    
    result = @manager.set_opening_balance(balance: 2500)
    
    assert_successful_result(result, changes_made: true)
    
    expected_date = [transaction_date - 1.day, 2.years.ago.to_date].min
    verify_opening_anchor(@account, expected_amount: 2500, expected_date: expected_date)
  end

  test "set_opening_balance defaults to two years ago when no entries exist" do
    @account.entries.destroy_all
    
    result = @manager.set_opening_balance(balance: 1000)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: 1000, expected_date: 2.years.ago.to_date)
  end

  test "set_opening_balance preserves account currency" do
    eur_account = create_account_with_currency("EUR")
    manager = Account::OpeningBalanceManager.new(eur_account)
    
    result = manager.set_opening_balance(balance: 2000)
    
    assert_successful_result(result, changes_made: true)
    
    opening_anchor = eur_account.valuations.opening_anchor.first
    assert_equal "EUR", opening_anchor.entry.currency
  end

  # set_opening_balance - existing anchor update tests
  test "set_opening_balance updates existing anchor amount without creating new entries" do
    original_amount = 1000
    new_amount = 1500
    create_opening_anchor_entry(@account, date: 1.year.ago.to_date, amount: original_amount)
    
    assert_no_difference -> { @account.entries.count } do
      assert_no_difference -> { @account.valuations.count } do
        result = @manager.set_opening_balance(balance: new_amount)
        
        assert_successful_result(result, changes_made: true)
      end
    end
    
    verify_opening_anchor(@account, expected_amount: new_amount)
  end

  test "set_opening_balance updates existing anchor date when specified" do
    original_date = 1.year.ago.to_date
    new_date = 6.months.ago.to_date
    create_opening_anchor_entry(@account, date: original_date, amount: 1000)
    
    result = @manager.set_opening_balance(balance: 1000, date: new_date)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: 1000, expected_date: new_date)
  end

  test "set_opening_balance updates both amount and date simultaneously" do
    original_date = 1.year.ago.to_date
    original_amount = 1000
    new_date = 6.months.ago.to_date
    new_amount = 2000
    
    create_opening_anchor_entry(@account, date: original_date, amount: original_amount)
    
    result = @manager.set_opening_balance(balance: new_amount, date: new_date)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: new_amount, expected_date: new_date)
  end

  test "set_opening_balance reports no changes when values are identical" do
    existing_date = 1.year.ago.to_date
    existing_amount = 1000
    create_opening_anchor_entry(@account, date: existing_date, amount: existing_amount)
    
    result = @manager.set_opening_balance(balance: existing_amount, date: existing_date)
    
    assert_successful_result(result, changes_made: false)
    verify_opening_anchor(@account, expected_amount: existing_amount, expected_date: existing_date)
  end

  test "set_opening_balance reports no changes when amount matches and no date specified" do
    existing_amount = 1000
    create_opening_anchor_entry(@account, date: 1.year.ago.to_date, amount: existing_amount)
    
    result = @manager.set_opening_balance(balance: existing_amount)
    
    assert_successful_result(result, changes_made: false)
  end

  # Date validation tests
  test "set_opening_balance rejects date equal to oldest entry date" do
    oldest_entry_date = 6.months.ago.to_date
    create_transaction_entry(@account, date: oldest_entry_date, amount: 100)
    
    result = @manager.set_opening_balance(balance: 1000, date: oldest_entry_date)
    
    assert_failed_result(result, expected_error: "Opening balance date must be before the oldest entry date")
    assert_equal 0, @account.valuations.opening_anchor.count
  end

  test "set_opening_balance rejects date after oldest entry date" do
    oldest_entry_date = 6.months.ago.to_date
    create_transaction_entry(@account, date: oldest_entry_date, amount: 100)
    
    invalid_date = oldest_entry_date + 1.day
    result = @manager.set_opening_balance(balance: 1000, date: invalid_date)
    
    assert_failed_result(result, expected_error: "Opening balance date must be before the oldest entry date")
  end

  test "set_opening_balance accepts date before oldest entry date" do
    oldest_entry_date = 6.months.ago.to_date
    create_transaction_entry(@account, date: oldest_entry_date, amount: 100)
    
    valid_date = oldest_entry_date - 1.day
    result = @manager.set_opening_balance(balance: 1000, date: valid_date)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: 1000, expected_date: valid_date)
  end

  test "set_opening_balance skips date validation when using default date calculation" do
    oldest_entry_date = 6.months.ago.to_date
    create_transaction_entry(@account, date: oldest_entry_date, amount: 100)
    
    # Should succeed using default date calculation
    result = @manager.set_opening_balance(balance: 1000)
    
    assert_successful_result(result, changes_made: true)
  end

  # Default date calculation edge case tests
  test "default date calculation handles recent entries correctly" do
    recent_entry_date = 1.month.ago.to_date
    create_transaction_entry(@account, date: recent_entry_date, amount: 100)
    
    result = @manager.set_opening_balance(balance: 1000)
    
    assert_successful_result(result, changes_made: true)
    
    # Should use 2.years.ago since recent_entry_date - 1.day is after 2.years.ago
    verify_opening_anchor(@account, expected_date: 2.years.ago.to_date)
  end

  test "default date calculation handles ancient entries correctly" do
    ancient_entry_date = 3.years.ago.to_date
    create_transaction_entry(@account, date: ancient_entry_date, amount: 100)
    
    result = @manager.set_opening_balance(balance: 1000)
    
    assert_successful_result(result, changes_made: true)
    
    # Should use ancient_entry_date - 1.day since it's before 2.years.ago
    expected_date = ancient_entry_date - 1.day
    verify_opening_anchor(@account, expected_date: expected_date)
  end

  # Edge case and boundary condition tests
  test "set_opening_balance handles zero balance correctly" do
    result = @manager.set_opening_balance(balance: 0)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: 0)
  end

  test "set_opening_balance handles negative balance correctly" do
    negative_balance = -500
    result = @manager.set_opening_balance(balance: negative_balance)
    
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: negative_balance)
  end

  test "manager handles accounts with mixed entry types efficiently" do
    # Setup various entry types
    create_opening_anchor_entry(@account, date: 1.year.ago.to_date, amount: 1000)
    create_transaction_entry(@account, date: 6.months.ago.to_date, amount: 100)
    create_valuation_entry(@account, date: 3.months.ago.to_date, amount: 1200)
    
    # Verify manager state
    assert @manager.has_opening_anchor?
    assert_equal 1.year.ago.to_date, @manager.opening_date
    assert_equal 1000, @manager.opening_balance
    
    # Verify updates work correctly
    result = @manager.set_opening_balance(balance: 1500)
    assert_successful_result(result, changes_made: true)
    verify_opening_anchor(@account, expected_amount: 1500)
  end

  test "manager performs efficiently with many account entries" do
    # Create substantial entry history
    50.times do |i|
      create_transaction_entry(@account, 
        date: (100 - i).days.ago.to_date,
        amount: 10 + i
      )
    end
    
    result = @manager.set_opening_balance(balance: 5000)
    
    assert_successful_result(result, changes_made: true)
    
    # Verify correct date calculation with many entries
    oldest_transaction_date = @account.entries.minimum(:date)
    expected_date = [oldest_transaction_date - 1.day, 2.years.ago.to_date].min
    verify_opening_anchor(@account, expected_amount: 5000, expected_date: expected_date)
  end

  # Result object structure tests
  test "result object has correct interface and attributes" do
    result = @manager.set_opening_balance(balance: 1000)
    
    assert_respond_to result, :success?
    assert_respond_to result, :changes_made?
    assert_respond_to result, :error
    
    assert result.success?
    assert result.changes_made?
    assert_nil result.error
  end

  test "failed result has correct error information" do
    create_transaction_entry(@account, date: 1.day.ago.to_date, amount: 100)
    
    result = @manager.set_opening_balance(balance: 1000, date: Date.current)
    
    refute result.success?
    refute result.changes_made?
    assert_not_nil result.error
    assert_includes result.error, "must be before"
  end

  private

  # Helper methods for creating test data
  def create_opening_anchor_entry(account, date:, amount:)
    account.entries.create!(
      date: date,
      name: "Opening balance",
      amount: amount,
      currency: account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )
  end

  def create_valuation_entry(account, date:, amount:)
    account.entries.create!(
      date: date,
      name: "Manual valuation",
      amount: amount,
      currency: account.currency,
      entryable: Valuation.new(kind: "reconciliation")
    )
  end

  def create_transaction_entry(account, date:, amount:)
    account.entries.create!(
      date: date,
      name: "Test transaction",
      amount: amount,
      currency: account.currency,
      entryable: Transaction.new
    )
  end

  def create_account_with_currency(currency)
    @family.accounts.create!(
      name: "#{currency} Account",
      balance: 1000,
      currency: currency,
      accountable: Depository.new
    )
  end

  # Helper methods for assertions
  def assert_successful_result(result, changes_made:)
    assert result.success?, "Expected successful result but got: #{result.error}"
    assert_equal changes_made, result.changes_made?
    assert_nil result.error
  end

  def assert_failed_result(result, expected_error:)
    refute result.success?
    refute result.changes_made?
    assert_equal expected_error, result.error
  end

  def verify_opening_anchor(account, expected_amount:, expected_date: nil)
    opening_anchor = account.valuations.opening_anchor.first
    
    assert_not_nil opening_anchor, "Expected opening anchor to exist"
    assert_equal "opening_anchor", opening_anchor.kind
    
    entry = opening_anchor.entry
    assert_not_nil entry, "Expected opening anchor to have associated entry"
    assert_equal expected_amount, entry.amount
    assert_equal account.currency, entry.currency
    assert_includes entry.name, "Opening balance"
    
    if expected_date
      assert_equal expected_date, entry.date
    end
  end
end