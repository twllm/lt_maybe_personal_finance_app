require "test_helper"

class Account::OpeningBalanceManagerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  # -------------------------------------------------------------------------------------------------
  # Initialization tests
  # -------------------------------------------------------------------------------------------------

  test "initializes with account" do
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_not_nil manager
    assert_respond_to manager, :has_opening_anchor?
    assert_respond_to manager, :opening_date
    assert_respond_to manager, :opening_balance
    assert_respond_to manager, :set_opening_balance
  end

  # -------------------------------------------------------------------------------------------------
  # has_opening_anchor? tests
  # -------------------------------------------------------------------------------------------------

  test "has_opening_anchor? returns false when no opening anchor exists" do
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_not manager.has_opening_anchor?
  end

  test "has_opening_anchor? returns true when opening anchor exists" do
    @account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Opening balance",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert manager.has_opening_anchor?
  end

  # -------------------------------------------------------------------------------------------------
  # opening_date tests
  # -------------------------------------------------------------------------------------------------

  test "opening_date returns date from opening anchor when present" do
    anchor_date = 1.year.ago.to_date
    @account.entries.create!(
      date: anchor_date,
      name: "Opening balance",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_equal anchor_date, manager.opening_date
  end

  test "opening_date returns oldest valuation date when no opening anchor but valuations exist" do
    oldest_valuation_date = 6.months.ago.to_date
    newer_valuation_date = 3.months.ago.to_date
    
    @account.entries.create!(
      date: newer_valuation_date,
      name: "Manual valuation",
      amount: 1200,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    
    @account.entries.create!(
      date: oldest_valuation_date,
      name: "Earlier valuation",
      amount: 1100,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_equal oldest_valuation_date, manager.opening_date
  end

  test "opening_date returns day before oldest transaction when transactions exist but no valuations" do
    transaction_date = 3.months.ago.to_date
    @account.entries.create!(
      date: transaction_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_equal transaction_date.prev_day, manager.opening_date
  end

  test "opening_date returns current date when no entries exist" do
    # Clear any existing entries
    @account.entries.destroy_all
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_equal Date.current, manager.opening_date
  end

  test "opening_date returns minimum of valuation date and transaction prev_day" do
    valuation_date = 6.months.ago.to_date
    transaction_date = 3.months.ago.to_date
    
    @account.entries.create!(
      date: valuation_date,
      name: "Manual valuation",
      amount: 1200,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    
    @account.entries.create!(
      date: transaction_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Should return the earlier of valuation_date and transaction_date.prev_day
    expected_date = [valuation_date, transaction_date.prev_day].min
    assert_equal expected_date, manager.opening_date
  end

  # -------------------------------------------------------------------------------------------------
  # opening_balance tests
  # -------------------------------------------------------------------------------------------------

  test "opening_balance returns amount from opening anchor when present" do
    @account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Opening balance",
      amount: 1500,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_equal 1500, manager.opening_balance
  end

  test "opening_balance returns 0 when no opening anchor exists" do
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_equal 0, manager.opening_balance
  end

  # -------------------------------------------------------------------------------------------------
  # set_opening_balance tests - creating new anchor
  # -------------------------------------------------------------------------------------------------

  test "set_opening_balance creates new opening anchor when none exists" do
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_difference -> { @account.entries.count } => 1,
                     -> { @account.valuations.count } => 1 do
      result = manager.set_opening_balance(balance: 2000)
      
      assert result.success?
      assert result.changes_made?
      assert_nil result.error
    end
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_not_nil opening_anchor
    assert_equal 2000, opening_anchor.entry.amount
    assert_equal "opening_anchor", opening_anchor.kind
    
    entry = opening_anchor.entry
    assert_equal 2000, entry.amount
    assert_equal "USD", entry.currency
    assert_includes entry.name, "Opening balance"
  end

  test "set_opening_balance creates new anchor with specified date" do
    custom_date = 2.years.ago.to_date
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 3000, date: custom_date)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal custom_date, opening_anchor.entry.date
    assert_equal 3000, opening_anchor.entry.amount
  end

  test "set_opening_balance creates new anchor with default date when no date specified" do
    # Add a transaction to set the oldest entry date
    transaction_date = 6.months.ago.to_date
    @account.entries.create!(
      date: transaction_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 2500)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    # Default date should be the earlier of (oldest_entry_date - 1.day) or 2.years.ago
    expected_date = [transaction_date - 1.day, 2.years.ago.to_date].min
    assert_equal expected_date, opening_anchor.entry.date
  end

  test "set_opening_balance uses 2 years ago as default when no entries exist" do
    # Clear any existing entries
    @account.entries.destroy_all
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 1000)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal 2.years.ago.to_date, opening_anchor.entry.date
  end

  # -------------------------------------------------------------------------------------------------
  # set_opening_balance tests - updating existing anchor
  # -------------------------------------------------------------------------------------------------

  test "set_opening_balance updates existing opening anchor amount" do
    # Create initial opening anchor
    @account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Opening balance",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert_no_difference -> { @account.entries.count } do
      assert_no_difference -> { @account.valuations.count } do
        result = manager.set_opening_balance(balance: 1500)
        
        assert result.success?
        assert result.changes_made?
        assert_nil result.error
      end
    end
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal 1500, opening_anchor.entry.amount
  end

  test "set_opening_balance updates existing opening anchor date when specified" do
    original_date = 1.year.ago.to_date
    new_date = 6.months.ago.to_date
    
    # Create initial opening anchor
    @account.entries.create!(
      date: original_date,
      name: "Opening balance",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 1000, date: new_date)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal new_date, opening_anchor.entry.date
    assert_equal 1000, opening_anchor.entry.amount
  end

  test "set_opening_balance updates both amount and date" do
    original_date = 1.year.ago.to_date
    new_date = 6.months.ago.to_date
    
    # Create initial opening anchor
    @account.entries.create!(
      date: original_date,
      name: "Opening balance",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 2000, date: new_date)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal new_date, opening_anchor.entry.date
    assert_equal 2000, opening_anchor.entry.amount
  end

  test "set_opening_balance returns no changes when values are identical" do
    original_date = 1.year.ago.to_date
    original_amount = 1000
    
    # Create initial opening anchor
    @account.entries.create!(
      date: original_date,
      name: "Opening balance",
      amount: original_amount,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: original_amount, date: original_date)
    
    assert result.success?
    assert_not result.changes_made?
    assert_nil result.error
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal original_date, opening_anchor.entry.date
    assert_equal original_amount, opening_anchor.entry.amount
  end

  test "set_opening_balance returns no changes when only amount is same and no date specified" do
    original_amount = 1000
    
    # Create initial opening anchor
    @account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Opening balance",
      amount: original_amount,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: original_amount)
    
    assert result.success?
    assert_not result.changes_made?
    assert_nil result.error
  end

  # -------------------------------------------------------------------------------------------------
  # set_opening_balance date validation tests
  # -------------------------------------------------------------------------------------------------

  test "set_opening_balance validates date is before oldest entry" do
    oldest_entry_date = 6.months.ago.to_date
    @account.entries.create!(
      date: oldest_entry_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Try to set opening balance date on same day as oldest entry (should fail)
    result = manager.set_opening_balance(balance: 1000, date: oldest_entry_date)
    
    assert_not result.success?
    assert_not result.changes_made?
    assert_equal "Opening balance date must be before the oldest entry date", result.error
    
    # Should not create any entries
    assert_equal 0, @account.valuations.opening_anchor.count
  end

  test "set_opening_balance validates date is before oldest entry when date is after" do
    oldest_entry_date = 6.months.ago.to_date
    @account.entries.create!(
      date: oldest_entry_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Try to set opening balance date after oldest entry (should fail)
    result = manager.set_opening_balance(balance: 1000, date: oldest_entry_date + 1.day)
    
    assert_not result.success?
    assert_not result.changes_made?
    assert_equal "Opening balance date must be before the oldest entry date", result.error
  end

  test "set_opening_balance allows date before oldest entry" do
    oldest_entry_date = 6.months.ago.to_date
    @account.entries.create!(
      date: oldest_entry_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Set opening balance date before oldest entry (should succeed)
    valid_date = oldest_entry_date - 1.day
    result = manager.set_opening_balance(balance: 1000, date: valid_date)
    
    assert result.success?
    assert result.changes_made?
    assert_nil result.error
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal valid_date, opening_anchor.entry.date
  end

  test "set_opening_balance validation only applies when date is explicitly provided" do
    oldest_entry_date = 6.months.ago.to_date
    @account.entries.create!(
      date: oldest_entry_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Without explicit date, should use default calculation and succeed
    result = manager.set_opening_balance(balance: 1000)
    
    assert result.success?
    assert result.changes_made?
    assert_nil result.error
  end

  # -------------------------------------------------------------------------------------------------
  # set_opening_balance default date calculation tests
  # -------------------------------------------------------------------------------------------------

  test "default date calculation uses oldest entry date minus 1 day when available" do
    oldest_entry_date = 3.months.ago.to_date
    @account.entries.create!(
      date: oldest_entry_date,
      name: "Test transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 1000)
    
    assert result.success?
    
    opening_anchor = @account.valuations.opening_anchor.first
    expected_date = [oldest_entry_date - 1.day, 2.years.ago.to_date].min
    assert_equal expected_date, opening_anchor.entry.date
  end

  test "default date calculation uses 2 years ago when oldest entry date minus 1 day is after 2 years ago" do
    # Create a recent entry (within 2 years)
    recent_entry_date = 1.month.ago.to_date
    @account.entries.create!(
      date: recent_entry_date,
      name: "Recent transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 1000)
    
    assert result.success?
    
    opening_anchor = @account.valuations.opening_anchor.first
    # Since recent_entry_date - 1.day is after 2.years.ago, should use 2.years.ago
    assert_equal 2.years.ago.to_date, opening_anchor.entry.date
  end

  test "default date calculation uses oldest entry date minus 1 day when it's before 2 years ago" do
    # Create an old entry (more than 2 years ago)
    old_entry_date = 3.years.ago.to_date
    @account.entries.create!(
      date: old_entry_date,
      name: "Old transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 1000)
    
    assert result.success?
    
    opening_anchor = @account.valuations.opening_anchor.first
    # Since old_entry_date - 1.day is before 2.years.ago, should use old_entry_date - 1.day
    assert_equal old_entry_date - 1.day, opening_anchor.entry.date
  end

  # -------------------------------------------------------------------------------------------------
  # Edge case tests
  # -------------------------------------------------------------------------------------------------

  test "set_opening_balance handles zero balance" do
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: 0)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal 0, opening_anchor.entry.amount
  end

  test "set_opening_balance handles negative balance" do
    manager = Account::OpeningBalanceManager.new(@account)
    
    result = manager.set_opening_balance(balance: -500)
    
    assert result.success?
    assert result.changes_made?
    
    opening_anchor = @account.valuations.opening_anchor.first
    assert_equal(-500, opening_anchor.entry.amount)
  end

  test "opening_balance handles missing entry gracefully" do
    # Create a valuation without a proper entry relationship
    valuation = Valuation.create!(kind: "opening_anchor")
    @account.valuations << valuation
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Should not raise an error and should return 0
    assert_equal 0, manager.opening_balance
  end

  test "manager works with accounts having multiple entry types" do
    # Create various entry types
    @account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Opening balance",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    
    @account.entries.create!(
      date: 6.months.ago.to_date,
      name: "Transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    
    @account.entries.create!(
      date: 3.months.ago.to_date,
      name: "Reconciliation",
      amount: 1200,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    assert manager.has_opening_anchor?
    assert_equal 1.year.ago.to_date, manager.opening_date
    assert_equal 1000, manager.opening_balance
    
    # Should be able to update the opening balance
    result = manager.set_opening_balance(balance: 1500)
    assert result.success?
    assert result.changes_made?
  end

  test "manager preserves currency when creating opening anchor" do
    eur_account = @family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )
    
    manager = Account::OpeningBalanceManager.new(eur_account)
    
    result = manager.set_opening_balance(balance: 2000)
    
    assert result.success?
    
    opening_anchor = eur_account.valuations.opening_anchor.first
    assert_equal "EUR", opening_anchor.entry.currency
  end

  test "Result struct has correct attributes" do
    manager = Account::OpeningBalanceManager.new(@account)
    result = manager.set_opening_balance(balance: 1000)
    
    assert_respond_to result, :success?
    assert_respond_to result, :changes_made?
    assert_respond_to result, :error
    
    assert result.success?
    assert result.changes_made?
    assert_nil result.error
  end

  test "handles account with many entries efficiently" do
    # Create many entries to test performance characteristics
    50.times do |i|
      @account.entries.create!(
        date: (100 - i).days.ago.to_date,
        name: "Transaction #{i}",
        amount: 10 + i,
        currency: "USD",
        entryable: Transaction.new
      )
    end
    
    manager = Account::OpeningBalanceManager.new(@account)
    
    # Should still work efficiently
    result = manager.set_opening_balance(balance: 5000)
    
    assert result.success?
    assert result.changes_made?
    
    # Verify the opening date is calculated correctly (before oldest transaction)
    oldest_transaction_date = @account.entries.minimum(:date)
    opening_anchor = @account.valuations.opening_anchor.first
    expected_date = [oldest_transaction_date - 1.day, 2.years.ago.to_date].min
    assert_equal expected_date, opening_anchor.entry.date
  end
end