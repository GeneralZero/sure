# All accounts are "anchored" with start/end valuation records, with transactions,
# trades, and reconciliations between them.
module Account::Anchorable
  extend ActiveSupport::Concern

  included do
    include Monetizable

    monetize :opening_balance
  end

  def set_opening_anchor_balance(**opts)
    result = opening_balance_manager.set_opening_balance(**opts)
    sync_later if result.success?
    result
  end

  def opening_anchor_date
    opening_balance_manager.opening_date
  end

  def opening_anchor_balance
    opening_balance_manager.opening_balance
  end

  def has_opening_anchor?
    opening_balance_manager.has_opening_anchor?
  end

  # An account whose history a provider imports gets its opening anchor before
  # any of that history exists, so it is dated by default -- two years back.
  # Once the entries are in, an anchor that is not before the oldest of them
  # sits in the middle of the series: the reverse calculator pins the balance
  # there and every earlier day is derived from it, running the flows the
  # wrong way. Called after an import, this moves the anchor to the day before
  # the first entry and keeps its balance. Uses the manager directly so it does
  # not queue a sync of its own; the caller's sync follows anyway.
  # Only the zero anchor an exchange account is bootstrapped with is moved: an
  # anchor with a balance is one somebody entered, on a manual account linked
  # to the exchange later, and it means "this much, on this day".
  def ensure_opening_anchor_precedes_entries
    return unless has_opening_anchor? && opening_anchor_balance.zero?

    # Every entry but the anchor itself, which is how the manager decides
    # whether a date is early enough. Skipping valuations wholesale instead
    # would pick a date it then rejects, leaving the anchor where it was.
    anchor_entry_id = valuations.opening_anchor.first&.entry&.id
    oldest = entries.where.not(id: anchor_entry_id).minimum(:date)
    return if oldest.nil? || opening_anchor_date < oldest

    result = opening_balance_manager.set_opening_balance(balance: opening_anchor_balance, date: oldest.prev_day)
    raise result.error if result.error

    result
  end

  # True when real activity (a Transaction or Trade, not a Valuation) exists
  # before the opening anchor's own date -- the anchor is then sitting in the
  # middle of the account's history rather than before the start of it, so
  # the reverse calculator pins the balance there and runs every earlier
  # day's flows backward from a date that isn't actually the earliest
  # evidence the account has. #ensure_opening_anchor_precedes_entries already
  # fixes this automatically, but only for a zero-balance anchor (a brand new
  # account's bootstrap default) -- a NON-zero anchor is read elsewhere as
  # "somebody entered this deliberately, on this day" and never
  # auto-adjusted, which is exactly the case this surfaces instead: a
  # non-zero anchor that still predates real history it didn't know about
  # yet (e.g. a bulk historical statement import that landed after the
  # anchor was already set).
  def opening_anchor_after_history_start?
    return false unless has_opening_anchor?

    anchor_entry_id = valuations.opening_anchor.first&.entry&.id
    oldest_real_entry_date = entries
      .where.not(id: anchor_entry_id)
      .where.not(entryable_type: "Valuation")
      .excluding_pending
      .minimum(:date)

    oldest_real_entry_date.present? && opening_anchor_date > oldest_real_entry_date
  end

  def history_start_date
    if linked? && balance_type == :investment
      Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(self)
    else
      [
        (opening_anchor_date if has_opening_anchor?),
        entries.excluding_pending.minimum(:date),
        balances.minimum(:date)
      ].compact.min
    end
  end

  # `date` is the day the balance describes, for a provider whose figures are
  # as of a statement rather than of this moment; it defaults to today.
  # Pass schedule_sync: false when the caller schedules the account sync
  # itself, such as a provider sync that syncs its accounts afterwards.
  def set_current_balance(balance, date: nil, schedule_sync: true)
    result = current_balance_manager.set_current_balance(balance, date: date)
    sync_later if schedule_sync && result.success?
    result
  end

  def current_anchor_balance
    current_balance_manager.current_balance
  end

  def current_anchor_date
    current_balance_manager.current_date
  end

  def has_current_anchor?
    current_balance_manager.has_current_anchor?
  end

  private
    def opening_balance_manager
      @opening_balance_manager ||= Account::OpeningBalanceManager.new(self)
    end

    def current_balance_manager
      @current_balance_manager ||= Account::CurrentBalanceManager.new(self)
    end
end
