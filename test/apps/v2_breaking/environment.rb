# frozen_string_literal: true

# A later version of the dummy application with breaking payload changes:
#
# * MoneySerializer#deserialize now requires a "value" field
# * LegacyMoneySerializer (and LegacyMoney) were removed
# * LegacyBillingJob was removed
# * TenantJob#deserialize now requires "organization_id" instead of "tenant_id"
# * the Account model was removed
# * UserEmailSerializer now looks users up by "email_address" (renamed from "email")
require_relative "../shared/setup"

class MoneySerializer < ActiveJob::Serializers::ObjectSerializer
  def serialize(money)
    super("value" => money.amount, "currency" => money.currency)
  end

  def deserialize(hash)
    Money.new(hash.fetch("value"), hash.fetch("currency"))
  end

  def klass
    Money
  end

  def serialize?(argument)
    argument.is_a?(Money)
  end
end

ActiveJob::Serializers.add_serializers(MoneySerializer)

# Wraps a user referenced by email address (not by GlobalID).
UserEmail = Struct.new(:email)

class UserEmailSerializer < ActiveJob::Serializers::ObjectSerializer
  def serialize(user_email)
    super("email_address" => user_email.email)
  end

  def deserialize(hash)
    User.find_by!(email: hash["email_address"])
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

class TenantJob < ActiveJob::Base
  attr_accessor :organization_id

  def serialize
    super.merge("organization_id" => organization_id)
  end

  def deserialize(job_data)
    super
    self.organization_id = job_data.fetch("organization_id")
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
