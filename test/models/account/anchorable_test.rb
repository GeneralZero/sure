require "test_helper"

class Account::AnchorableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    family = families(:dylan_family)
    @account = family.accounts.create!(name: "Anchored", balance: 1000, currency: "USD", accountable: Depository.new)
  end

  test "an anchor dated after the oldest transaction sits after the account's history" do
    @account.set_opening_anchor_balance(balance: 500, date: 10.days.ago.to_date)
    create_transaction(account: @account, date: 20.days.ago.to_date, amount: 10)

    assert Account.find(@account.id).opening_anchor_after_history_start?
  end

  test "an anchor before every transaction does not" do
    @account.set_opening_anchor_balance(balance: 500, date: 30.days.ago.to_date)
    create_transaction(account: @account, date: 20.days.ago.to_date, amount: 10)

    assert_not Account.find(@account.id).opening_anchor_after_history_start?
  end

  test "an older valuation is not history the anchor should precede" do
    @account.set_opening_anchor_balance(balance: 500, date: 10.days.ago.to_date)
    @account.entries.create!(date: 20.days.ago.to_date, name: "Balance update", amount: 400, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))

    assert_not Account.find(@account.id).opening_anchor_after_history_start?
  end

  test "an account without an anchor never warns" do
    create_transaction(account: @account, date: 20.days.ago.to_date, amount: 10)

    assert_not Account.find(@account.id).opening_anchor_after_history_start?
  end
end
