# Committed baseline fixtures

`active_job_X.Y/` holds fixtures written by `jobpayload snapshot` from
`test/apps/v1` while running Active Job X.Y (Ruby 3.3). They model payloads
that an application persisted *before* upgrading Rails.

`test/cross_version_test.rb` checks every set whose Active Job version is less
than or equal to the version under test against the v1 and v2_compatible
dummy apps (backward-read only; forward compatibility is out of scope).

Regenerate a set with, for example:

    BUNDLE_GEMFILE=gemfiles/activejob_7.2.gemfile bundle exec exe/jobpayload snapshot \
      --boot test/apps/v1/environment.rb --cases test/apps/v1/jobpayload_cases.rb \
      --output test/fixtures/active_job_7.2 --update
