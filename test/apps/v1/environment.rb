# frozen_string_literal: true

# "v1" of the dummy application: the version that writes baseline fixtures.
require_relative "../shared/setup"

class Account < ApplicationRecord
end

class MoneySerializer < ActiveJob::Serializers::ObjectSerializer
  def serialize(money)
    super("amount" => money.amount, "currency" => money.currency)
  end

  def deserialize(hash)
    Money.new(hash["amount"], hash["currency"])
  end

  def klass
    Money
  end

  # Active Job < 8.1 asks serializers whether they handle an object.
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

# Wraps a user referenced by email address (not by GlobalID).
UserEmail = Struct.new(:email)

class UserEmailSerializer < ActiveJob::Serializers::ObjectSerializer
  def serialize(user_email)
    super("email" => user_email.email)
  end

  def deserialize(hash)
    User.find_by!(email: hash.fetch("email"))
  end

  def klass
    UserEmail
  end

  def serialize?(argument)
    argument.is_a?(UserEmail)
  end
end
ActiveJob::Serializers.add_serializers(UserEmailSerializer)

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
  attr_accessor :tenant_id

  def serialize
    super.merge("tenant_id" => tenant_id)
  end

  def deserialize(job_data)
    super
    self.tenant_id = job_data.fetch("tenant_id")
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
