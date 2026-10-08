# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

# Rails main only (see gemfiles/rails_edge.gemfile); not part of `test`.
Rake::TestTask.new("test:rails_edge") do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/edge/*_regression.rb"]
  t.warning = false
end

task default: :test
