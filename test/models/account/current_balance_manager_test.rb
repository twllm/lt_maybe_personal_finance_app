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

  # Basic initialization and getter tests
  test "initializes with account" do
    manager = Account::CurrentBalanceManager.new(@manual_depository_account)
    assert_equal @manual_depository_account, manager.send(:account)
  end

  test "has_current_anchor? returns false when no current anchor exists" do
    assert_not @manual_manager.has_current_anchor?
    assert_not @linked_manager.has_current_anchor?
  end

  test "has_current_anchor? returns true when current anchor exists" do
    create_current_anchor(@linked_account, balance: 1000)
    
    assert @linked_manager.has_current_anchor?
  end

  test "current_balance returns amount from current anchor when it exists" do
    create_current_anchor(@linked_account, balance: 1500)
    
    assert_equal 1500, @linked_manager.current_balance
  end

  test "current_balance falls back to account balance when no current anchor" do
    Rails.logger.expects(:warn).with(includes("No current balance anchor found"))
    
    assert_equal @manual_depository_account.balance, @manual_manager.current_balance
  end

  test "current_date returns date from current anchor when it exists" do
    test_date = 3.days.ago.to_date
    create_current_anchor(@linked_account, balance: 1000, date: test_date)
    
    assert_equal test_date, @linked_manager.current_date
  end

  test "current_date returns current date when no current anchor" do
    assert_equal Date.current, @manual_manager.current_date
  end

  # Manual account tests - no reconciliations (opening balance adjustment strategy)
  test "set_current_balance for manual cash account with no reconciliations adjusts opening balance" do
    # Setup: manual depository account (cash type) with opening balance but no reconciliations
    setup_opening_balance(@manual_depository_account, 1000)
    
    # Test: Set current balance to 1200 (delta of +200)
    assert_difference -> { @manual_depository_account.reload.balance } => 200 do
      result = @manual_manager.set_current_balance(1200)
      
      assert result.success?
      assert result.changes_made?
      assert_nil result.error
    end
    
    # Verify the opening balance was adjusted by the delta
    assert_equal 1200, @manual_depository_account.opening_anchor_balance
  end

  test "set_current_balance for manual cash account with negative delta adjusts opening balance down" do
    setup_opening_balance(@manual_depository_account, 2000)
    
    assert_difference -> { @manual_depository_account.reload.balance } => -500 do
      result = @manual_manager.set_current_balance(1500)
      
      assert result.success?
      assert result.changes_made?
    end
    
    assert_equal 1500, @manual_depository_account.opening_anchor_balance
  end

  # Manual account tests - with reconciliations (reconciliation strategy)
  test "set_current_balance for manual account with existing reconciliations creates new reconciliation" do
    setup_opening_balance(@manual_depository_account, 1000)
    create_reconciliation(@manual_depository_account, balance: 1100, date: 1.week.ago)
    
    # Mock the reconciliation manager
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: true, error_message: nil)
    
    mock_reconciliation_manager.expects(:reconcile_balance)
      .with(balance: 1300, date: Date.current, existing_valuation_entry: nil)
      .returns(mock_result)
    
    @manual_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    assert_difference -> { @manual_depository_account.reload.balance } => 200 do
      result = @manual_manager.set_current_balance(1300)
      
      assert result.success?
      assert result.changes_made?
      assert_nil result.error
    end
  end

  test "set_current_balance for manual account updates existing reconciliation on same date" do
    setup_opening_balance(@manual_depository_account, 1000)
    existing_reconciliation = create_reconciliation(@manual_depository_account, balance: 1100, date: Date.current)
    
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: true, error_message: nil)
    
    mock_reconciliation_manager.expects(:reconcile_balance)
      .with(balance: 1400, date: Date.current, existing_valuation_entry: existing_reconciliation)
      .returns(mock_result)
    
    @manual_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    result = @manual_manager.set_current_balance(1400)
    
    assert result.success?
    assert result.changes_made?
  end

  test "set_current_balance for manual non-cash account always uses reconciliation strategy" do
    # Property accounts are non-cash, so should always use reconciliation strategy
    property_account = accounts(:property)
    property_manager = Account::CurrentBalanceManager.new(property_account)
    
    setup_opening_balance(property_account, 500000)
    
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: true, error_message: nil)
    
    mock_reconciliation_manager.expects(:reconcile_balance)
      .with(balance: 520000, date: Date.current, existing_valuation_entry: nil)
      .returns(mock_result)
    
    property_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    result = property_manager.set_current_balance(520000)
    
    assert result.success?
    assert result.changes_made?
  end

  # Linked account tests - create current anchor
  test "set_current_balance for linked account without current anchor creates new anchor" do
    assert_not @linked_manager.has_current_anchor?
    
    assert_difference -> { @linked_account.entries.count } => 1,
                     -> { @linked_account.valuations.count } => 1 do
      result = @linked_manager.set_current_balance(2500)
      
      assert result.success?
      assert result.changes_made?
      assert_nil result.error
    end
    
    # Verify current anchor was created
    current_anchor = @linked_account.valuations.current_anchor.first
    assert_not_nil current_anchor
    assert_equal 2500, current_anchor.entry.amount
    assert_equal Date.current, current_anchor.entry.date
    assert_equal "current_anchor", current_anchor.kind
    
    # Verify account balance was updated
    assert_equal 2500, @linked_account.reload.balance
  end

  # Linked account tests - update existing current anchor
  test "set_current_balance for linked account with existing current anchor updates it" do
    original_anchor = create_current_anchor(@linked_account, balance: 1800, date: 2.days.ago)
    
    assert_no_difference -> { @linked_account.entries.count } do
      assert_no_difference -> { @linked_account.valuations.count } do
        result = @linked_manager.set_current_balance(2200)
        
        assert result.success?
        assert result.changes_made?
        assert_nil result.error
      end
    end
    
    # Verify anchor was updated
    original_anchor.reload
    assert_equal 2200, original_anchor.entry.amount
    assert_equal Date.current, original_anchor.entry.date
    
    # Verify account balance was updated
    assert_equal 2200, @linked_account.reload.balance
  end

  test "set_current_balance for linked account with no changes returns success with no changes made" do
    create_current_anchor(@linked_account, balance: 3000, date: Date.current)
    
    assert_no_difference -> { @linked_account.entries.count } do
      result = @linked_manager.set_current_balance(3000)
      
      assert result.success?
      assert_not result.changes_made?
      assert_nil result.error
    end
  end

  test "set_current_balance for linked account only updates date when balance unchanged" do
    original_anchor = create_current_anchor(@linked_account, balance: 1500, date: 5.days.ago)
    
    result = @linked_manager.set_current_balance(1500)
    
    assert result.success?
    assert result.changes_made? # Date changed
    
    original_anchor.reload
    assert_equal 1500, original_anchor.entry.amount
    assert_equal Date.current, original_anchor.entry.date
  end

  # Error handling tests
  test "set_current_balance handles exceptions and returns error result" do
    # Force an exception by making the account invalid
    @manual_depository_account.stubs(:update!).raises(StandardError, "Test error")
    
    result = @manual_manager.set_current_balance(1000)
    
    assert_not result.success?
    assert_not result.changes_made?
    assert_equal "Test error", result.error
  end

  test "set_current_balance handles opening balance manager errors" do
    setup_opening_balance(@manual_depository_account, 1000)
    
    mock_opening_manager = mock("opening_balance_manager")
    mock_result = OpenStruct.new(success?: false, error: "Opening balance error")
    
    mock_opening_manager.expects(:set_opening_balance).returns(mock_result)
    @manual_manager.expects(:opening_balance_manager).returns(mock_opening_manager)
    
    result = @manual_manager.set_current_balance(1200)
    
    assert_not result.success?
    assert result.changes_made? # Still true as per the normalization
    assert_equal "Opening balance error", result.error
  end

  test "set_current_balance handles reconciliation manager errors" do
    setup_opening_balance(@manual_depository_account, 1000)
    create_reconciliation(@manual_depository_account, balance: 1100, date: 1.week.ago)
    
    mock_reconciliation_manager = mock("reconciliation_manager")
    mock_result = OpenStruct.new(success?: false, error_message: "Reconciliation error")
    
    mock_reconciliation_manager.expects(:reconcile_balance).returns(mock_result)
    @manual_manager.expects(:reconciliation_manager).returns(mock_reconciliation_manager)
    
    result = @manual_manager.set_current_balance(1300)
    
    assert_not result.success?
    assert result.changes_made? # Still true as per the normalization
    assert_equal "Reconciliation error", result.error
  end

  # Integration tests
  test "set_current_balance integrates with opening balance manager for manual accounts" do
    # Real integration test without mocking
    setup_opening_balance(@manual_depository_account, 1000)
    
    result = @manual_manager.set_current_balance(1250)
    
    assert result.success?
    assert result.changes_made?
    assert_nil result.error
    
    # Verify the opening balance was actually adjusted
    assert_equal 1250, @manual_depository_account.opening_anchor_balance
    assert_equal 1250, @manual_depository_account.reload.balance
  end

  test "set_current_balance integrates with reconciliation manager for manual accounts" do
    # Real integration test without mocking
    setup_opening_balance(@manual_depository_account, 1000)
    create_reconciliation(@manual_depository_account, balance: 1100, date: 2.days.ago)
    
    result = @manual_manager.set_current_balance(1350)
    
    assert result.success?
    assert result.changes_made?
    assert_nil result.error
    
    # Verify a new reconciliation was created
    reconciliations = @manual_depository_account.valuations.reconciliation
    assert_equal 2, reconciliations.count
    
    latest_reconciliation = reconciliations.joins(:entry).order("entries.date DESC").first
    assert_equal 1350, latest_reconciliation.entry.amount
    assert_equal Date.current, latest_reconciliation.entry.date
  end

  # Edge cases
  test "current anchor creation uses correct name for account type" do
    result = @linked_manager.set_current_balance(1000)
    
    assert result.success?
    
    current_anchor = @linked_account.valuations.current_anchor.first
    expected_name = Valuation.build_current_anchor_name(@linked_account.accountable_type)
    assert_equal expected_name, current_anchor.entry.name
  end

  test "works with different account types" do
    # Test with investment account
    investment_account = accounts(:investment)
    investment_manager = Account::CurrentBalanceManager.new(investment_account)
    
    setup_opening_balance(investment_account, 10000)
    create_reconciliation(investment_account, balance: 10500, date: 1.week.ago)
    
    result = investment_manager.set_current_balance(11000)
    
    assert result.success?
    assert result.changes_made?
  end

  test "handles zero balance correctly" do
    result = @linked_manager.set_current_balance(0)
    
    assert result.success?
    assert result.changes_made?
    
    current_anchor = @linked_account.valuations.current_anchor.first
    assert_equal 0, current_anchor.entry.amount
    assert_equal 0, @linked_account.reload.balance
  end

  test "handles negative balance correctly" do
    # Credit card accounts can have negative balances
    credit_account = accounts(:credit_card)
    credit_manager = Account::CurrentBalanceManager.new(credit_account)
    
    setup_opening_balance(credit_account, 500)
    
    result = credit_manager.set_current_balance(-200)
    
    assert result.success?
    assert result.changes_made?
    assert_equal(-200, credit_account.reload.balance)
  end

  private

  def setup_opening_balance(account, balance)
    manager = Account::OpeningBalanceManager.new(account)
    result = manager.set_opening_balance(balance: balance, date: 1.year.ago.to_date)
    raise "Failed to setup opening balance: #{result.error}" unless result.success?
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
      name: "Test reconciliation",
      amount: balance,
      currency: account.currency,
      entryable: Valuation.new(kind: "reconciliation")
    )
    entry.entryable
  end
end