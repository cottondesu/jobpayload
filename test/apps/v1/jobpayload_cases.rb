# frozen_string_literal: true

# Snapshot cases for the v1 dummy application.
JobPayload.define do
  fixture "billing-money-v1" do
    BillingJob.new(Money.new(1_250, "USD"))
  end

  fixture "billing-legacy-money-v1" do
    BillingJob.new(LegacyMoney.new(500, "JPY"))
  end

  fixture "legacy-billing-v1" do
    LegacyBillingJob.new("invoice-1")
  end

  fixture "tenant-v1" do
    TenantJob.new("rebuild-index").tap { |job| job.tenant_id = 42 }
  end

  fixture "notify-user-v1" do
    NotifyUserJob.new(User.find(1))
  end

  fixture "notify-user-missing-v1" do
    # Created only while snapshotting, so it will not exist when checking.
    user = User.find_or_create_by!(id: 999, email: "jobpayload@example.test")
    NotifyUserJob.new(user)
  end

  fixture "notify-users-nested-v1" do
    NotifyUserJob.new([User.find(1), { "owner" => User.find(1), "tags" => %w[a b] }])
  end

  fixture "notify-users-nested-missing-v1" do
    ghost = User.find_or_create_by!(id: 1000, email: "ghost@example.test")
    NotifyUserJob.new({ "batch" => [User.find(1), ghost] })
  end

  fixture "account-sync-v1" do
    AccountSyncJob.new(Account.find(1))
  end

  fixture "exploding-v1" do
    ExplodingJob.new("boom", count: 3)
  end

  fixture "scheduled-v1" do
    job = ExplodingJob.new("later").set(wait_until: Time.now + 3600, queue: "low", priority: 5)
    job.executions = 7
    job.exception_executions = { "[RuntimeError]" => 2 }
    job
  end

  {
    "nil" => nil,
    "string" => "hello ✓",
    "integer" => 42,
    "float" => 3.25,
    "true" => true,
    "false" => false,
    "symbol" => :ready,
    "date" => Date.new(2024, 2, 29),
    "time" => Time.utc(2024, 1, 2, 3, 4, 5, 678_901),
    "datetime" => DateTime.new(2024, 1, 2, 3, 4, 5, "+09:00"),
    "bigdecimal" => BigDecimal("12345.6789"),
    "array" => [1, "two", [3, [4]]],
    "hash" => { "b" => 2, "a" => { "nested" => [1, 2] } },
    "hash-symbol-keys" => { status: "active", count: 2 },
    "hash-indifferent" => ActiveSupport::HashWithIndifferentAccess.new("k" => "v"),
    "range" => (1..10),
    "duration" => 90.minutes,
    "time-with-zone" => Time.zone.local(2024, 6, 1, 9, 30, 0),
    "module" => Comparable
  }.each do |type, value|
    fixture "builtin-#{type}-v1" do
      BuiltinTypesJob.new(value)
    end
  end
end
