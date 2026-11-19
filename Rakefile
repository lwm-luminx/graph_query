# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

desc 'Check the RBS signatures parse'
task :rbs do
  sh 'bundle exec rbs -I sig validate'
end

desc 'Build the docs site into site/'
task :docs do
  sh 'ruby bin/build-docs site'
end

task default: %i[spec rubocop rbs]
