# frozen_string_literal: true

# Minimal, Rails-free host application used by the jobpayload test suite:
# Active Job + Active Record on an in-memory SQLite database.
#
# Each dummy app (v1, v2_compatible, v2_breaking) requires this file from its
# own environment.rb, then defines its own jobs and serializers. That models
# "the same application at two versions".

if (log = ENV["JOBPAYLOAD_BOOT_LOG"])
  File.open(log, "a") { |f| f.puts("boot pid=#{Process.pid} RAILS_ENV=#{ENV['RAILS_ENV']}") }
end

if ENV["JOBPAYLOAD_TEST_NOISY"]
  puts "noisy boot output"
  print "more noise\n"
end

exit 1 if ENV["JOBPAYLOAD_TEST_BOOT_EXIT"]

# Test-only race injection for `snapshot --check` (test/support/race_after_lstat.rb).
require ENV["JOBPAYLOAD_TEST_RACE_HOOK"] if ENV["JOBPAYLOAD_TEST_RACE_HOOK"]

if ENV["JOBPAYLOAD_TEST_BOOT_FAIL"]
  raise "simulated boot failure"
end

require "logger"
require "bigdecimal"
require "date"
require "active_support"
require "active_support/core_ext"
require "active_job"
require "active_record"
require "global_id"

Time.zone_default = Time.find_zone!("Asia/Tokyo")
ActiveJob::Base.logger = Logger.new(nil)
ActiveRecord::Base.logger = nil
GlobalID.app = "dummy"
ActiveRecord::Base.include(GlobalID::Identification) unless ActiveRecord::Base < GlobalID::Identification

# Any attempt to enqueue a job during a check is a bug in jobpayload.
class ForbiddenQueueAdapter
  def enqueue(*)
    abort "jobpayload test app: enqueue must never be called"
  end
  alias enqueue_at enqueue
  alias enqueue_all enqueue

  def enqueue_after_transaction_commit?
    false
  end
end
ActiveJob::Base.queue_adapter = ForbiddenQueueAdapter.new

if ENV["JOBPAYLOAD_TEST_NO_DB"]
  # Simulates a broken test environment: no database connection can be made.
  # An existing directory is not a valid SQLite database file, so opening it
  # fails without the adapter trying to create a missing parent directory
  # (which depends on FileUtils having been loaded by something else).
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: __dir__)
else
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  ActiveRecord::Migration.verbose = false
  ActiveRecord::Schema.define do
    create_table :users, force: true do |t|
      t.string :email, null: false
    end
    create_table :accounts, force: true do |t|
      t.string :name, null: false
    end
  end
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class User < ApplicationRecord
end

# Plain value object serialized by a custom Active Job serializer.
class Money
  attr_reader :amount, :currency

  def initialize(amount, currency)
    @amount = amount
    @currency = currency
  end

  def ==(other)
    other.is_a?(Money) && amount == other.amount && currency == other.currency
  end
end

# Seed data that exists in every "test environment" boot, like Rails fixtures.
def jobpayload_seed!
  return if ENV["JOBPAYLOAD_TEST_NO_DB"]

  User.create!(id: 1, email: "seeded@example.test")
  Account.create!(id: 1, name: "seeded") if defined?(Account)
end

# A job whose business logic must never run during a check.
class ExplodingJob < ActiveJob::Base
  def perform(*)
    if (marker = ENV["JOBPAYLOAD_PERFORM_MARKER"])
      File.write(marker, "perform was called")
    end
    raise "perform must never be called"
  end
end

# Every built-in argument type Active Job 7.2+ can serialize.
class BuiltinTypesJob < ActiveJob::Base
  def perform(*)
    raise "perform must never be called"
  end
end

class NotifyUserJob < ActiveJob::Base
  def perform(_user)
    raise "perform must never be called"
  end
end
