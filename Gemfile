# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# CI tries each supported Active Record.
if (version = ENV.fetch('ACTIVERECORD_VERSION', nil))
  gem 'activerecord', "~> #{version}.0"
end

gem 'rake', '~> 13.0'
gem 'rbs', '>= 3.9'
gem 'rspec', '~> 3.13'
gem 'rubocop', '~> 1.81', require: false
gem 'rubocop-rake', require: false
gem 'rubocop-rspec', require: false
