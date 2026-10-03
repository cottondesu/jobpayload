# frozen_string_literal: true

# A tiny "current application" loaded into the test process itself, for unit
# tests of the checker, snapshotter and classifier. Integration tests boot the
# dummy apps under test/apps in subprocesses instead.
require "logger"
require "active_job"
require "active_record"
require "global_id"

ActiveJob::Base.logger = Logger.new(nil)
GlobalID.app = "inprocess"

module InProcess
  PERFORMED = []

  class Point
    attr_reader :x, :y

    def initialize(x, y)
      @x = x
      @y = y
    end
  end

  class PointSerializer < ActiveJob::Serializers::ObjectSerializer
    def serialize(point)
      super("x" => point.x, "y" => point.y)
    end

    def deserialize(hash)
      Point.new(hash.fetch("x"), hash.fetch("y"))
    end

    def klass
      Point
    end

    def serialize?(argument)
      argument.is_a?(Point)
    end
  end
  ActiveJob::Serializers.add_serializers(PointSerializer)

  # A GlobalID-locatable model with no records: every real GlobalID lookup
  # raises ActiveRecord::RecordNotFound, like a record deleted since snapshot.
  class Account
    include GlobalID::Identification

    attr_reader :id

    def self.find(id)
      raise ActiveRecord::RecordNotFound, "Couldn't find InProcess::Account with 'id'=#{id}"
    end
  end

  # Fails the first time it deserializes after reset!, then succeeds: models
  # an argument that fails in the full Arguments.deserialize call but not when
  # retried on its own.
  class FlakySerializer < ActiveJob::Serializers::ObjectSerializer
    @calls = 0

    class << self
      attr_accessor :calls, :error_class

      def reset!(error_class = ArgumentError)
        self.calls = 0
        self.error_class = error_class
      end
    end

    def deserialize(hash)
      self.class.calls += 1
      raise self.class.error_class, "flaky" if self.class.calls == 1

      hash["value"]
    end

    def klass
      Struct
    end

    def serialize?(_argument)
      false
    end
  end

  # A custom serializer whose lookup raises RecordNotFound: a broken payload
  # (for example a renamed lookup key), never a missing GlobalID record.
  class MissingRecordSerializer < ActiveJob::Serializers::ObjectSerializer
    def deserialize(hash)
      raise ActiveRecord::RecordNotFound, "Couldn't find Point with 'id'=#{hash['id']}"
    end

    def klass
      Struct
    end

    def serialize?(_argument)
      false
    end
  end

  class PlotJob < ActiveJob::Base
    def perform(*)
      PERFORMED << self
      raise "perform must never be called"
    end
  end

  # Looks a record up in its own deserialize(job_data) override.
  class LookupJob < ActiveJob::Base
    def deserialize(job_data)
      super
      raise ActiveRecord::RecordNotFound, "Couldn't find Account with 'id'=#{job_data['account_id']}"
    end
  end

  class StampedJob < ActiveJob::Base
    attr_accessor :stamp

    def serialize
      super.merge("stamp" => stamp)
    end

    def deserialize(job_data)
      super
      self.stamp = job_data.fetch("stamp")
    end

    def perform(*)
      PERFORMED << self
    end
  end

  # Mutates its input during deserialize; must not affect the argument phase.
  class MutatingJob < ActiveJob::Base
    def deserialize(job_data)
      super
      job_data["arguments"].clear
    end

    def perform(*); end
  end

  NotAJob = Class.new
end
