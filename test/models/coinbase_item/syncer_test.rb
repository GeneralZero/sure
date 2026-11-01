require "test_helper"

class CoinbaseItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @coinbase_item = CoinbaseItem.create!(
      family: families(:dylan_family),
      name: "Coinbase",
      api_key: "key",
      api_secret: "secret"
    )
    @syncer = CoinbaseItem::Syncer.new(@coinbase_item)
    @sync = Sync.create!(syncable: @coinbase_item)
  end

  # A revoked or expired API key reaches Provider::Coinbase as a 401, raised
  # as AuthenticationError. Before this fix nothing in the Coinbase sync path
  # caught it: the sync still failed (Sync#perform's own blanket rescue sees
  # to that), but coinbase_item.status never moved to requires_update, so the
  # UI never prompted a reconnect and every later scheduled sync retried the
  # same dead credentials.
  test "marks the item requires_update when Coinbase reports invalid credentials" do
    @coinbase_item.expects(:import_latest_coinbase_data)
      .raises(Provider::Coinbase::AuthenticationError, "Unauthorized - check your API key and secret")

    assert_raises(Provider::Coinbase::AuthenticationError) do
      @syncer.perform_sync(@sync)
    end

    assert @coinbase_item.reload.requires_update?
    assert_equal "failed", @sync.reload.status
  end
end
