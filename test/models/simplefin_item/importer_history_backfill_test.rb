require "test_helper"

class SimplefinItem::ImporterHistoryBackfillTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Backfill Test",
      access_url: "https://example.com/access"
    )
    @sync = Sync.create!(syncable: @item)
  end

  # last_synced_at is derived from the latest completed Sync's completed_at
  # (Syncable#latest_completed_sync_record), not a column on SimplefinItem.
  def simulate_last_synced_at(time)
    completed = Sync.create!(syncable: @item, status: :completed)
    completed.update_column(:completed_at, time)
  end

  # Regression for GH #2864: no_txns_yet used to be evaluated item-wide
  # (.all?), so one sibling account already having history stopped a
  # genuinely-blank sibling (e.g. just relinked to a new upstream id) from
  # ever qualifying for a chunked backfill.
  test "forces a chunked backfill when any linked account has no history, even if a sibling already does" do
    simulate_last_synced_at(1.day.ago)

    synced_account = accounts(:depository)
    synced_sfa = @item.simplefin_accounts.create!(
      name: "Synced Sibling", account_id: "sf_synced", account_type: "checking",
      currency: "USD", current_balance: 100, raw_transactions_payload: [ { "id" => "already_here" } ]
    )
    synced_account.update!(simplefin_account_id: synced_sfa.id)

    blank_account = accounts(:other_asset)
    blank_sfa = @item.simplefin_accounts.create!(
      name: "Relinked Sibling", account_id: "sf_relinked", account_type: "checking",
      currency: "USD", current_balance: 50, raw_transactions_payload: nil
    )
    blank_account.update!(simplefin_account_id: blank_sfa.id)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock, sync: @sync)
    importer.expects(:import_with_chunked_history).once
    importer.expects(:import_regular_sync).never

    importer.send(:import)
  end

  test "uses the regular sync path when every linked account already has history" do
    simulate_last_synced_at(1.day.ago)

    account = accounts(:depository)
    sfa = @item.simplefin_accounts.create!(
      name: "Synced", account_id: "sf_synced_only", account_type: "checking",
      currency: "USD", current_balance: 100, raw_transactions_payload: [ { "id" => "already_here" } ]
    )
    account.update!(simplefin_account_id: sfa.id)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock, sync: @sync)
    importer.expects(:import_regular_sync).once
    importer.expects(:import_with_chunked_history).never

    importer.send(:import)
  end

  # Regression for GH #4790: a failed sync never advances last_synced_at, so
  # determine_sync_start_date's window (gap + 30-day buffer) only grows on
  # every retry, past SimpleFIN's real-world per-request limit, with no
  # self-healing path. The regular-sync window must be capped and fall back
  # to the same safely-sized chunked requests the first-sync backfill uses.
  test "flags the regular sync window as too wide once the gap plus buffer exceeds one safe request" do
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock, sync: @sync)

    assert_not @importer.send(:regular_sync_window_too_wide?), "no last_synced_at means the chunked-history path already handles this"

    simulate_last_synced_at(10.days.ago) # start_date = 40 days ago, under the 44-day chunk size
    assert_not @importer.send(:regular_sync_window_too_wide?)

    simulate_last_synced_at(20.days.ago) # start_date = 50 days ago, over the 44-day chunk size
    assert @importer.send(:regular_sync_window_too_wide?)
  end

  test "falls back to chunked history, targeted at the real gap, when the regular sync window is too wide" do
    simulate_last_synced_at(20.days.ago)
    account = accounts(:depository)
    sfa = @item.simplefin_accounts.create!(
      name: "Synced", account_id: "sf_wide_gap", account_type: "checking",
      currency: "USD", current_balance: 100, raw_transactions_payload: [ { "id" => "already_here" } ]
    )
    account.update!(simplefin_account_id: sfa.id)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock, sync: @sync)
    expected_target = importer.send(:determine_sync_start_date)
    importer.expects(:import_with_chunked_history).with(target_start_date: expected_target).once
    importer.expects(:import_regular_sync).never

    importer.send(:import)
  end

  # Regression for GH #3778: new_txns_in_chunk used to be measured by diffing
  # count_linked_transactions (stored payload size on linked accounts)
  # before/after each chunk. That's zero growth in both syncs the normal
  # setup flow actually runs (before anything is linked, and re-fetching
  # already-stored data after linking), so the loop hit "2 consecutive empty
  # chunks" by chunk 2 while the provider was still returning real data,
  # capping every backfill at ~120 days regardless of how much history
  # exists or what start date was chosen.
  test "keeps pulling chunks past the old 2-chunk stop as long as each chunk's own response has transactions" do
    chunk_response = {
      accounts: [
        { id: "sf_never_linked", name: "Never Linked", balance: 10, currency: "USD",
          transactions: [ { id: "t1", amount: -5, description: "x", posted: Time.current.to_i } ] }
      ]
    }

    provider = mock
    provider.stubs(:get_accounts).returns(chunk_response)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: provider, sync: @sync)
    importer.send(:import_with_chunked_history)

    stats = @sync.reload.sync_stats
    assert_operator stats["chunked_history"]["chunks_processed"], :>, 2,
      "the old stored-payload-diff heuristic stopped after 2 chunks even though every chunk here returns real transactions"
    assert_operator stats["chunked_history"]["total_new_transactions"], :>, 0
    assert_not_equal "no_new_data", stats["chunked_history"]["reason"]
  end
end
