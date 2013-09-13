require 'neography/tasks'
require './app.rb'

namespace :gcc do

	task :createdb do
		puts 'Creating graph'
		create_graph
		puts 'Done'
	end

	task :setup do
		puts 'Creating graph'
		create_graph
		puts 'Building nodes json'
		get_relationships(true)
		puts 'Building longest paths json'
		get_longest_path(true)
		puts 'Done'
	end

	task :repos do
		puts 'Building nodes json'
		get_relationships(true)
		puts 'Done'
	end

	task :longest do
		puts 'Building longest paths json'
		get_longest_path(true)
		puts 'Done'
	end

end