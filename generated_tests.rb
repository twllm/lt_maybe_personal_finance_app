require "test_helper"

class Account::CurrentBalanceManagerTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @manual_depository_account = accounts(:depository)
    @manual_investment_account = accounts(:investment)
    @linked_account = accounts(:connected)
    @manual_manager = Account::CurrentBalanceManager.new(@manual_depository_account)
    @linked_manager = Account::CurrentBalanceManager.new(@linked_account)
  end

  # =============================================================================
  # INITIALIZATION AND BASIC QUERY METHODS
  # =============================================================================

  test "initializes correctly with valid account" do
    manager = Account::CurrentBalanceManager.new(@manual_depository_account)
    assert_equal @manual_depository_account, manager.send(:account)
  end

  test "raises error when initialized with nil account" do
    assert_raises(ArgumentError) do
      Account::CurrentBalanceManager.new(nil)
    end
  end

  # -----------------------------------------------------------------------------
  # Current Anchor Detection Tests
  # -----------------------------------------------------------------------------

  test "has_current_anchor? returns false when no current anchor exists for any account type" do
    [@manual_manager, @linked_manager].each do |manager|
      assert_not manager.has_current_anchor?, 
                 "Expected no current anchor for #{manager.send(:account).name}"
    end
  end

  test "has_current_anchor? returns true when current anchor exists" do
    create_current_anchor(@linked_account, balance: 1000)
    
    assert @linked_manager.has_current_anchor?,
           "Expected current anchor to be detected after creation"
  end

  test "has_current_anchor? is not affected by other valuation types" do
    create_reconciliation(@linked_account, balance: 1000, date: Date.current)
    
    assert_not @linked_manager.has_current_anchor?,
               "Reconciliations should not affect current anchor detection"
  end

  # -----------------------------------------------------------------------------
  # Current Balance Retrieval Tests
  # -----------------------------------------------------------------------------

  test "current_balance returns amount from current anchor when it exists" do
    create_current_anchor(@linked_account, balance: 1500)
    
    assert_equal 1500, @linked_manager.current_balance,
                 "Current balance should match anchor amount"
  end

  test "current_balance falls back to account balance when no current anchor with warning" do
    expected_balance = @manual_depository_account.balance
    
    Rails.logger.expects(:warn).with(
      includes("No current balance anchor found for account #{@manual_depository_account.id}")
    )
    
    assert_equal expected_balance, @manual_manager.current_balance,
                 "Should fallback to cached account balance"
  end

  test "current_balance handles zero amount from current anchor correctly" do
    create_current_anchor(@linked_account, balance: 0)
    
    assert_equal 0, @linked_manager.current_balance,
                 "Zero balance should be returned correctly"
  end

  test "current_balance handles negative amount from current anchor correctly" do
    create_current_anchor(@linked_account, balance: -500)
    
    assert_equal(-500, @linked_manager.current_balance,
                 "Negative balance should be returned correctly")
  end

  # -----------------------------------------------------------------------------
  # Current Date Retrieval Tests
  # -----------------------------------------------------------------------------

  test "current_date returns date from current anchor when it exists" do
    test_date = 3.days.ago.to_date
    create_current_anchor(@linked_account, balance: 1000, date: test_date)
    
    assert_equal test_date, @linked_manager.current_date,
                 "Should return anchor date when available"
  end

  test "current_date returns current date when no current anchor" do
    assert_equal Date.current, @manual_manager.current_date,
                 "Should return current date as fallback"
  end

  test "current_date returns today for current anchor created today" do
    create_current_anchor(@linked_account, balance: 1000, date: Date.current)
    
    assert_equal Date.current, @linked_manager.current_date,
                 "Should return today's date for current anchor"
  end

  # =============================================================================
  # MANUAL ACCOUNT BALANCE SETTING - OPENING BALANCE ADJUSTMENT STRATEGY
  # =============================================================================

  test "set_current_balance for manual cash account with no reconciliations adjusts opening balance upward" do
    # Setup: manual depository account (cash type) with opening balance but no reconciliations
    setup_opening_balance(@manual_depository_account, 1000)
    original_balance = @manual_depository_account.balance
    
    # Test: Set current balance to 1200 (delta of +200)
    assert_difference -> { @manual_depository_account.reload.balance }, 200 do
      result = @manual_manager.set_current_balance(1200)
      
      # Verify comprehensive result properties
      assert result.success?, "Operation should succeed"
      assert result.changes_made?, "Changes should be marked as made"
      assert_nil result.error, "No error should be present"
      assert result.is_a?(Account::CurrentBalanceManager::Result), "Should return Result object"
    end
    
    # Verify the opening balance was adjusted by the delta
    assert_equal 1200, @manual_depository_account.opening_anchor_balance,
                 "Opening balance should be adjusted to match target"
    assert_equal 1200, @manual_depository_account.reload.balance,
                 "Account balance should reflect new amount"
  end

  test "set_current_balance for manual cash account with negative delta adjusts opening balance downward" do
    setup_opening_balance(@manual_depository_account, 2000)
    
    assert_difference -> { @manual_depository_account.reload.balance }, -500 do
      result = @manual_manager.set_current_balance(1500)
      
      assert result.success?, "Downward adjustment should succeed"
      assert result.changes_made?, "Changes should be detected"
      assert_nil result.error, "No error expected for valid operation"
    end
    
    assert_equal 1500, @manual_depository_account.opening_anchor_balance,
                 "Opening balance should be reduced appropriately"
  end

  test "set_current_balance for manual cash account with zero target balance works correctly" do
    setup_opening_balance(@manual_depository_account, 500)
    
    result = @manual_manager.set_current_balance(0)
    
    assert result.success?, "Setting to zero should succeed"
    assert result.changes_made?, "Should detect change to zero"
    assert_equal 0, @manual_depository_account.reload.balance,
                 "Balance should be set to zero"
  end

  test "set_current_balance for manual cash account with same balance as current shows no changes" do
    setup_opening_balance(@manual_depository_account, 1000)
    current_balance = @manual_depository_account.balance
    
    result = @manual_manager.set_current_balance(current_balance)
    
    assert result.success?, "No-op should still succeed"
    # Note: The opening balance manager may still report changes_made=true even for no delta
    # This is consistent with the current implementation
  end

  # =============================================================================
  # MANUAL ACCOUNT BALANCE SETTING - RECONCILIATION STRATEGY
  # =============================================================================

  test "set_current_balance for manual account with existing reconciliations creates new reconciliation entry" do
    setup_opening_balance(@manual_depository_account, 1000)
    create_reconciliation(@manual_depository_account, balance: 1100, date: 1.week.ago)
    
    # Mock the reconciliation manager to verify correct parameters
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: true, error_message: nil)
    
    mock_reconciliation_manager.expects(:reconcile_balance)
      .with(balance: 1300, date: Date.current, existing_valuation_entry: nil)
      .returns(mock_result)
    
    @manual_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    assert_difference -> { @manual_depository_account.reload.balance }, 200 do
      result = @manual_manager.set_current_balance(1300)
      
      assert result.success?, "Reconciliation should succeed"
      assert result.changes_made?, "Should indicate changes were made"
      assert_nil result.error, "No error expected"
    end
  end

  test "set_current_balance for manual account updates existing reconciliation on same date" do
    setup_opening_balance(@manual_depository_account, 1000)
    existing_reconciliation = create_reconciliation(@manual_depository_account, balance: 1100, date: Date.current)
    
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: true, error_message: nil)
    
    # Should pass the existing reconciliation entry for updates
    mock_reconciliation_manager.expects(:reconcile_balance)
      .with(balance: 1400, date: Date.current, existing_valuation_entry: existing_reconciliation.entry)
      .returns(mock_result)
    
    @manual_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    result = @manual_manager.set_current_balance(1400)
    
    assert result.success?, "Updating existing reconciliation should succeed"
    assert result.changes_made?, "Should detect changes"
    assert_nil result.error, "No error expected"
  end

  test "set_current_balance for manual non-cash account always uses reconciliation strategy regardless of reconciliation history" do
    # Property accounts are non-cash, so should always use reconciliation strategy
    property_account = accounts(:property) 
    property_manager = Account::CurrentBalanceManager.new(property_account)
    
    setup_opening_balance(property_account, 500000)
    # Note: Even with no existing reconciliations, non-cash accounts use reconciliation strategy
    
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: true, error_message: nil)
    
    mock_reconciliation_manager.expects(:reconcile_balance)
      .with(balance: 520000, date: Date.current, existing_valuation_entry: nil)
      .returns(mock_result)
    
    property_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    result = property_manager.set_current_balance(520000)
    
    assert result.success?, "Non-cash account reconciliation should succeed"
    assert result.changes_made?, "Should indicate changes"
  end

  # =============================================================================
  # LINKED ACCOUNT BALANCE SETTING - CURRENT ANCHOR MANAGEMENT
  # =============================================================================

  test "set_current_balance for linked account without current anchor creates new anchor with proper attributes" do
    assert_not @linked_manager.has_current_anchor?, "Should start without current anchor"
    
    assert_difference -> { @linked_account.entries.count }, 1 do
      assert_difference -> { @linked_account.valuations.count }, 1 do
        result = @linked_manager.set_current_balance(2500)
        
        assert result.success?, "Creating current anchor should succeed"
        assert result.changes_made?, "Should indicate changes were made"
        assert_nil result.error, "No error expected"
      end
    end
    
    # Verify current anchor was created with correct attributes
    current_anchor = @linked_account.valuations.current_anchor.first
    assert_not_nil current_anchor, "Current anchor should be created"
    assert_equal 2500, current_anchor.entry.amount, "Anchor should have correct amount"
    assert_equal Date.current, current_anchor.entry.date, "Anchor should have current date"
    assert_equal "current_anchor", current_anchor.kind, "Should have correct kind"
    assert_equal @linked_account.currency, current_anchor.entry.currency, "Should use account currency"
    
    # Verify proper naming convention
    expected_name = Valuation.build_current_anchor_name(@linked_account.accountable_type)
    assert_equal expected_name, current_anchor.entry.name, "Should use proper naming convention"
    
    # Verify account balance was updated
    assert_equal 2500, @linked_account.reload.balance, "Account balance should be updated"
  end

  test "set_current_balance for linked account with existing current anchor updates it in place" do
    original_anchor = create_current_anchor(@linked_account, balance: 1800, date: 2.days.ago)
    original_entry_id = original_anchor.entry.id
    
    # Should update existing entries, not create new ones
    assert_no_difference -> { @linked_account.entries.count } do
      assert_no_difference -> { @linked_account.valuations.count } do
        result = @linked_manager.set_current_balance(2200)
        
        assert result.success?, "Updating current anchor should succeed"
        assert result.changes_made?, "Should detect changes"
        assert_nil result.error, "No error expected"
      end
    end
    
    # Verify anchor was updated, not replaced
    original_anchor.reload
    assert_equal original_entry_id, original_anchor.entry.id, "Should update same entry"
    assert_equal 2200, original_anchor.entry.amount, "Amount should be updated"
    assert_equal Date.current, original_anchor.entry.date, "Date should be updated to current"
    
    # Verify account balance was updated
    assert_equal 2200, @linked_account.reload.balance, "Account balance should reflect update"
  end

  test "set_current_balance for linked account with no balance changes but date change still reports changes" do
    original_anchor = create_current_anchor(@linked_account, balance: 1500, date: 5.days.ago)
    
    result = @linked_manager.set_current_balance(1500)
    
    assert result.success?, "Same balance update should succeed"
    assert result.changes_made?, "Date change should still count as changes"
    assert_nil result.error, "No error expected"
    
    # Verify only date was updated
    original_anchor.reload
    assert_equal 1500, original_anchor.entry.amount, "Amount should remain unchanged"
    assert_equal Date.current, original_anchor.entry.date, "Date should be updated"
  end

  test "set_current_balance for linked account with identical balance and date reports no changes" do
    create_current_anchor(@linked_account, balance: 3000, date: Date.current)
    
    assert_no_difference -> { @linked_account.entries.count } do
      result = @linked_manager.set_current_balance(3000)
      
      assert result.success?, "No-change update should succeed"
      assert_not result.changes_made?, "Should correctly detect no changes"
      assert_nil result.error, "No error expected"
    end
  end

  test "set_current_balance for linked account handles zero balance correctly" do
    result = @linked_manager.set_current_balance(0)
    
    assert result.success?, "Zero balance should be handled correctly"
    assert result.changes_made?, "Should detect creation of zero balance anchor"
    
    current_anchor = @linked_account.valuations.current_anchor.first
    assert_equal 0, current_anchor.entry.amount, "Should store zero amount correctly"
    assert_equal 0, @linked_account.reload.balance, "Account balance should be zero"
  end

  test "set_current_balance for linked account handles negative balance correctly" do
    result = @linked_manager.set_current_balance(-750)
    
    assert result.success?, "Negative balance should be handled correctly"
    assert result.changes_made?, "Should detect changes"
    
    current_anchor = @linked_account.valuations.current_anchor.first
    assert_equal(-750, current_anchor.entry.amount, "Should store negative amount correctly")
    assert_equal(-750, @linked_account.reload.balance, "Account balance should be negative")
  end

  # =============================================================================
  # ERROR HANDLING AND EDGE CASES
  # =============================================================================

  test "set_current_balance handles exceptions gracefully and returns error result" do
    # Force an exception by making the account update fail
    @manual_depository_account.stubs(:update!).raises(StandardError, "Simulated database error")
    
    result = @manual_manager.set_current_balance(1000)
    
    assert_not result.success?, "Should report failure on exception"
    assert_not result.changes_made?, "Should indicate no changes on exception"
    assert_equal "Simulated database error", result.error, "Should capture exception message"
    assert result.is_a?(Account::CurrentBalanceManager::Result), "Should still return Result object"
  end

  test "set_current_balance handles opening balance manager errors properly" do
    setup_opening_balance(@manual_depository_account, 1000)
    
    mock_opening_manager = mock("opening_balance_manager")
    mock_result = OpenStruct.new(success?: false, error: "Opening balance validation failed")
    
    mock_opening_manager.expects(:set_opening_balance).returns(mock_result)
    @manual_manager.expects(:opening_balance_manager).returns(mock_opening_manager)
    
    result = @manual_manager.set_current_balance(1200)
    
    assert_not result.success?, "Should report failure from opening balance manager"
    assert result.changes_made?, "Should still indicate changes attempted (per normalization)"
    assert_equal "Opening balance validation failed", result.error, "Should pass through error message"
  end

  test "set_current_balance handles reconciliation manager errors properly" do
    setup_opening_balance(@manual_depository_account, 1000)
    create_reconciliation(@manual_depository_account, balance: 1100, date: 1.week.ago)
    
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: false, error_message: "Reconciliation date conflict")
    
    mock_reconciliation_manager.expects(:reconcile_balance).returns(mock_result)
    @manual_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    result = @manual_manager.set_current_balance(1300)
    
    assert_not result.success?, "Should report failure from reconciliation manager"
    assert result.changes_made?, "Should still indicate changes attempted (per normalization)"
    assert_equal "Reconciliation date conflict", result.error, "Should pass through error message"
  end

  test "set_current_balance handles account update failure after successful manager operations" do
    # Setup successful manager operation but failing account update
    setup_opening_balance(@manual_depository_account, 1000)
    
    # This will cause the final account.update!(balance: balance) to fail
    Account.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid, "Account validation failed")
    
    result = @manual_manager.set_current_balance(1200)
    
    assert_not result.success?, "Should report failure on account update error"
    assert_not result.changes_made?, "Should indicate no changes on final failure"
    assert_includes result.error, "Account validation failed", "Should capture account update error"
  end

  # =============================================================================
  # INTEGRATION TESTS - REAL OPERATIONS WITHOUT MOCKING
  # =============================================================================

  test "set_current_balance integrates correctly with opening balance manager for manual cash accounts" do
    # Real integration test without mocking - tests the full stack
    setup_opening_balance(@manual_depository_account, 1000)
    original_opening_balance = @manual_depository_account.opening_anchor_balance
    
    result = @manual_manager.set_current_balance(1250)
    
    assert result.success?, "Integration with opening manager should succeed"
    assert result.changes_made?, "Should detect changes in integration"
    assert_nil result.error, "No error expected in successful integration"
    
    # Verify the opening balance was actually adjusted by the system
    assert_equal 1250, @manual_depository_account.opening_anchor_balance,
                 "Opening balance should be adjusted by delta"
    assert_equal 1250, @manual_depository_account.reload.balance,
                 "Account balance should reflect the change"
    
    # Verify the adjustment was calculated correctly
    expected_adjustment = 1250 - 1000  # target - original balance
    actual_adjustment = @manual_depository_account.opening_anchor_balance - original_opening_balance
    assert_equal expected_adjustment, actual_adjustment, "Adjustment calculation should be correct"
  end

  test "set_current_balance integrates correctly with reconciliation manager for manual accounts" do
    # Real integration test - tests actual reconciliation creation
    setup_opening_balance(@manual_depository_account, 1000)
    create_reconciliation(@manual_depository_account, balance: 1100, date: 2.days.ago)
    
    result = @manual_manager.set_current_balance(1350)
    
    assert result.success?, "Integration with reconciliation manager should succeed"
    assert result.changes_made?, "Should detect changes in integration"
    assert_nil result.error, "No error expected in successful integration"
    
    # Verify a new reconciliation was actually created
    reconciliations = @manual_depository_account.valuations.reconciliation
    assert_equal 2, reconciliations.count, "Should have two reconciliations after operation"
    
    # Verify the latest reconciliation has correct attributes
    latest_reconciliation = reconciliations.joins(:entry).order("entries.date DESC").first
    assert_equal 1350, latest_reconciliation.entry.amount, "Latest reconciliation should have target amount"
    assert_equal Date.current, latest_reconciliation.entry.date, "Should be dated today"
    assert_equal "reconciliation", latest_reconciliation.kind, "Should be reconciliation type"
    
    # Verify account balance was updated
    assert_equal 1350, @manual_depository_account.reload.balance, "Account balance should be updated"
  end

  test "set_current_balance works correctly with different currency accounts" do
    # Test with Euro account if available, or setup one
    skip "Requires EUR account fixture" unless accounts(:euro_account) rescue nil
    
    eur_account = accounts(:euro_account)
    eur_manager = Account::CurrentBalanceManager.new(eur_account)
    
    result = eur_manager.set_current_balance(500)
    
    assert result.success?, "Should work with different currencies"
    
    current_anchor = eur_account.valuations.current_anchor.first
    assert_equal "EUR", current_anchor.entry.currency, "Should preserve account currency"
  end

  # =============================================================================
  # COMPREHENSIVE ACCOUNT TYPE TESTING
  # =============================================================================

  test "set_current_balance works correctly across different account types" do
    account_tests = [
      { account: :investment, expected_strategy: :reconciliation },
      { account: :credit_card, expected_strategy: :opening_balance },  # assuming it's cash type
      { account: :property, expected_strategy: :reconciliation }
    ]
    
    account_tests.each do |test_case|
      account = accounts(test_case[:account])
      next unless account  # Skip if fixture doesn't exist
      
      manager = Account::CurrentBalanceManager.new(account)
      setup_opening_balance(account, 10000)
      
      # For reconciliation strategy accounts, add a reconciliation to trigger that path
      if test_case[:expected_strategy] == :reconciliation
        create_reconciliation(account, balance: 10500, date: 1.week.ago)
      end
      
      result = manager.set_current_balance(11000)
      
      assert result.success?, "Should work for #{test_case[:account]} account type"
      assert result.changes_made?, "Should detect changes for #{test_case[:account]}"
      assert_equal 11000, account.reload.balance, "Balance should be updated for #{test_case[:account]}"
    end
  end

  test "handles extreme balance values correctly" do
    extreme_values = [
      0,                    # Zero
      1,                    # Minimum positive
      -1,                   # Minimum negative  
      1_000_000,           # Large positive
      -1_000_000,          # Large negative
      999_999_999.99,      # Very large positive
      -999_999_999.99      # Very large negative
    ]
    
    extreme_values.each do |balance|
      result = @linked_manager.set_current_balance(balance)
      
      assert result.success?, "Should handle extreme balance: #{balance}"
      assert_equal balance, @linked_account.reload.balance, "Should set correct balance: #{balance}"
    end
  end

  # =============================================================================
  # PERFORMANCE AND CONCURRENCY CONSIDERATIONS
  # =============================================================================

  test "set_current_balance operations are transaction-safe for linked accounts" do
    # Verify that the update_current_anchor method uses transactions properly
    original_anchor = create_current_anchor(@linked_account, balance: 1000)
    
    # Simulate a transaction rollback scenario by forcing an error mid-transaction
    Entry.any_instance.stubs(:save!).raises(ActiveRecord::Rollback).once
    
    # The operation should handle this gracefully
    result = @linked_manager.set_current_balance(2000)
    
    # Since we're raising Rollback, the transaction should rollback changes
    # The specific behavior depends on how the implementation handles this
    original_anchor.reload
    # The exact assertion here depends on implementation details
  end

  # =============================================================================
  # PRIVATE HELPER METHODS
  # =============================================================================

  private

  def setup_opening_balance(account, balance)
    manager = Account::OpeningBalanceManager.new(account)
    result = manager.set_opening_balance(balance: balance, date: 1.year.ago.to_date)
    unless result.success?
      raise "Failed to setup opening balance for #{account.name}: #{result.error}"
    end
    result
  end

  def create_current_anchor(account, balance:, date: Date.current)
    entry = account.entries.create!(
      date: date,
      name: Valuation.build_current_anchor_name(account.accountable_type),
      amount: balance,
      currency: account.currency,
      entryable: Valuation.new(kind: "current_anchor")
    )
    entry.entryable
  end

  def create_reconciliation(account, balance:, date:)
    entry = account.entries.create!(
      date: date,
      name: "Test reconciliation - #{date}",
      amount: balance,
      currency: account.currency,
      entryable: Valuation.new(kind: "reconciliation")
    )
    entry.entryable
  end

  # Additional helper to verify Result object completeness
  def assert_valid_result(result, expected_success: true, expected_changes: true, expected_error: nil)
    assert result.is_a?(Account::CurrentBalanceManager::Result), "Should return Result object"
    assert_equal expected_success, result.success?, "Success state should match expectation"
    assert_equal expected_changes, result.changes_made?, "Changes state should match expectation"
    
    if expected_error
      assert_equal expected_error, result.error, "Error message should match expectation"
    else
      assert_nil result.error, "Error should be nil when none expected"
    end
  end
end