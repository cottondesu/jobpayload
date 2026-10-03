# frozen_string_literal: true

# A later version of the dummy application with only compatible changes:
# MoneySerializer now writes "value" but still reads the old "amount" field,
# and TenantJob gained an optional field.
require_relative "../shared/setup"

class Account < ApplicationRecord
end

class MoneySerializer < ActiveJob::Serializers::ObjectSerializer
  def serialize(money)
    super("value" => money.amount, "currency" => money.currency)
  end

  def deserialize(hash)
    Money.new(hash.fetch("value") { hash.fetch("amount") }, hash.fetch("currency"))
  end

  def klass
    Money
  end

  def serialize?(argument)
    argument.is_a?(Money)
  end
end

class LegacyMoney < Money; end

class LegacyMoneySerializer < ActiveJob::Serializers::ObjectSerializer
  def serialize(money)
    super("cents" => money.amount, "currency" => money.currency)
  end

  def deserialize(hash)
    LegacyMoney.new(hash["cents"], hash["currency"])
  end

  def klass
    LegacyMoney
  end

  def serialize?(argument)
    argument.is_a?(LegacyMoney)
  end
end

ActiveJob::Serializers.add_serializers(LegacyMoneySerializer, MoneySerializer)

class BillingJob < ActiveJob::Base
  def perform(_money)
    raise "perform must never be called"
  end
end

class LegacyBillingJob < ActiveJob::Base
  def perform(*)
    raise "perform must never be called"
  end
end

class TenantJob < ActiveJob::Base
  attr_accessor :tenant_id, :region

  def serialize
    super.merge("tenant_id" => tenant_id, "region" => region)
  end

  def deserialize(job_data)
    super
    self.tenant_id = job_data.fetch("tenant_id")
    self.region = job_data.fetch("region", "default")
  end

  def perform(*)
    raise "perform must never be called"
  end
end

class AccountSyncJob < ActiveJob::Base
  def perform(_account)
    raise "perform must never be called"
  end
end

jobpayload_seed!
