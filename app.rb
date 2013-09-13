require 'sinatra'
require 'neography' unless defined?(Neography)
require 'yajl'

=begin

	create db: rake neo4j:create

	neo4j data location on mac osx with homebrew: cd /usr/local/Cellar/neo4j/community-1.9.2-unix/libexec
	to clear the db: neo4j stop && rm -rf data/* && neo4j start

	BigQuery query:
	SELECT repository_name, repository_url, actor_attributes_login, type
	FROM [githubarchive:github.timeline]
	WHERE
	type IN ("FollowEvent", "ForkEvent", "ForkApplyEvent", "IssueCommentEvent", "IssuesEvent", "MemberEvent", "PullRequestEvent", "PullRequestReviewCommentEvent", "PushEvent", "WatchEvent")
	AND created_at > '2013-01-01 00:00:00'
	AND repository_name IS NOT NULL AND actor_attributes_login IS NOT NULL
	GROUP EACH BY repository_name, repository_url, actor_attributes_login, type
	LIMIT 100000

	to test the indexes: (make sure irc-logs is inside the dataset)
	START repo = node:nodes_index(type = "repo") WHERE repo.name = "irc-logs" RETURN ID(repo), repo.name;

	find duplicates:
	START n=node(*), m=node(*) WHERE HAS(n.name) AND HAS(m.name) AND n.name = m.name RETURN n, m;

=end

# detect if rake is running
def is_rake
	File.basename($0) == 'rake'
end

def node_cache_file
	'public/nodes_cache.json'
end

def longest_cache_file
	'public/longest_path_cache.json'
end

# for "rake neo4j:create"
def create_graph

	File.delete(node_cache_file) if File.exist?(node_cache_file)

	neo = Neography::Rest.new(ENV['NEO4J_URL'] || 'http://localhost:7474')
	graph_exists = nil
	begin
		graph_exists = neo.get_node_properties(1)
	rescue
		# do nothing, database hasn't been setup
	end

	if graph_exists && graph_exists['name']
		puts 'Nothing to do, db already exists'
		return
	end

	#batch docs: https://github.com/maxdemarzi/neography/wiki/Batch
	commands = []
	processed_repos = %w()
	processed_users = %w()
	command_index = 0
	batch_index = 0
	File.open('data/data.csv').read.split("\n").each_with_index do |line, line_number|

		if batch_index > 1000 # batches of batches
			puts "#{commands.length} commands processed. At row #{line_number}"
			neo.batch *commands
			commands.clear
			command_index = 0
			batch_index = 0
		end

		repo, _, user = line.split(',')

		#do it one by one, but slower:
		#user_node = neo.create_unique_node(:user, :name, user, {:name  => user})
		#repo_node = neo.create_unique_node(:repo, :name, repo, {:name => repo})
		#neo.create_relationship(:contributors, repo_node, user_node)

		# create the nodes and indexes
		#{X} and {X} refer back to the previous X job
		commands << [:create_unique_node, :user, :name, user, {'name' => user, 'type' => :user}]
		unless processed_users.include? user
			# these should be unique (, true) but the indexing fails
			commands << [:add_node_to_index, 'nodes_index', 'type', 'user', "{#{command_index}}" ]
			processed_users << user
			command_index = command_index + 1
		end
		command_index = command_index + 1

		commands << [:create_unique_node, :repo, :name, repo, {'name' => repo, 'type' => :repo}]
		unless processed_repos.include? repo
			commands << [:add_node_to_index, 'nodes_index', 'type', 'repo', "{#{command_index}}" ]
			processed_repos << repo
			command_index = command_index + 1
		end
		command_index = command_index + 1

		# relationship
		# this will not work because create_unique_node returns an index: https://github.com/neo4j/neo4j/issues/84
		# commands << [:create_relationship, :contributors, "{#{index}}", "{#{index + 1}}"]
		commands << [:execute_query, 'START a = node:user(name={user}), b = node:repo(name={repo}) CREATE UNIQUE a-[new_rel:follows]->b RETURN new_rel', {:user => user, :repo => repo}]
		command_index = command_index + 1

		batch_index = batch_index + 1

	end

	puts "#{commands.length} commands to process"
	neo.batch *commands

	puts 'Finished.'

end

# get all users in the graph
def get_users(neo)

	cypher_query =  ' START me = node:nodes_index(type = "user")'
	cypher_query << ' RETURN ID(me), me.name'
	cypher_query << ' ORDER BY ID(me)'
	neo.execute_query(cypher_query)['data']

end

# get all repo's with a follow_count > 2
def get_repos(neo)

	# return repo's that have more than 1 connection
	# TODO: try this; n<-r[follows*2..]-m
	cypher_query =  ' START n = node:nodes_index(type = "repo")'
	cypher_query << ' MATCH n<-[r:follows]-m'
	cypher_query << ' WITH n, count(m) AS follow_count'
	cypher_query << ' WHERE follow_count > 2'
	cypher_query << ' RETURN ID(n), n.name, follow_count'
	cypher_query << ' ORDER BY ID(n)'
	neo.execute_query(cypher_query)['data']

end

# get the users for a repo
def get_users_for_repo(neo, repo)

	neo.traverse(repo, 'nodes', {
		:order         => 'breadth first',
		:uniqueness    => 'node global',
		:relationships => {
			:type      => 'follows',
			:direction => 'in'
		},
	})

end

# get the relationsgips for a repo, with user id and user name
def get_relationships_for_repo(neo, repo)

	cypher_query =  ' START user = node:nodes_index(type = "user"), repo = node:nodes_index(type = "repo")'
	cypher_query << ' MATCH user-[r:follows]->repo'
	cypher_query << ' WHERE ID(repo) = {repo_id}'
	cypher_query << ' RETURN ID(user), user.name'

	neo.execute_query(cypher_query, { :repo_id => repo[0] })['data']

end

# find the longest paths
def find_longest_path(neo)

	cypher_query =  ' START user = node:nodes_index(type = "user")'
	cypher_query << ' MATCH path=user-[:follows*]-repo'
	cypher_query << ' WITH path, LENGTH(path) AS cnt'
	cypher_query << ' RETURN extract(n in nodes(path): [ID(n), n.name, n.type])'
	cypher_query << ' ORDER BY cnt DESC'
	cypher_query << ' LIMIT 5'

	neo.execute_query(cypher_query)['data']

end

# find the longest path in the graph
def get_longest_path(clear_cache = false)

	File.delete(longest_cache_file) if clear_cache && File.exist?(longest_cache_file)

	if File.exist?(longest_cache_file)

		content_type :json unless is_rake
		send_file longest_cache_file

	else

		neo = Neography::Rest.new(ENV['NEO4J_URL'] || 'http://localhost:7474')

		out = {
			:nodes => [],
			:links => [],
		}

		i = 0
		find_longest_path(neo).each do |path|

			path[0].each_with_index do |n, index|

				out[:nodes]  << {
					:name  => n[1],
					:type  => n[2],
					:id    => n[0],
					:group => n[2] == 'user' ? 2 : 1,
				}

				if index < path[0].length - 1

					out[:links] << {
						:source => i,
						:target => i + 1,
						:value  => 1,
					}

				end

				i = i + 1

			end

		end

		File.open(longest_cache_file, 'w'){ |f| f << out.to_json }

		unless is_rake

			content_type :json
			#JSON.pretty_generate(out) # pretty print
			out.to_json # normal out

		end

	end

end


# get the relationships for all nodes
def get_relationships(clear_cache = false)

	File.delete(node_cache_file) if clear_cache && File.exist?(node_cache_file)

	if File.exist?(node_cache_file)

		content_type :json unless is_rake
		send_file node_cache_file

	else

		neo = Neography::Rest.new(ENV['NEO4J_URL'] || 'http://localhost:7474')

		out = {
			:nodes => [],
			:links => [],
		}

		users = {}
		repos = []
		repo_index = 0
		user_index = 0

		get_repos(neo).each do |repo|

			relationships = get_relationships_for_repo(neo, repo)

			repos << {
				:name  => repo[1],
				:type  => :repo,
				:id    => repo[0],
				:group => 1,
			}

			relationships.each do |n|

				unless users.has_key?(n[0])

					users[n[0]] = {
						:name  => n[1],
						:type  => :user,
						:id    => n[0],
						:group => 2,
						:index => user_index,
					}

					user_index = user_index + 1

				end

				out[:links] << {
					:source => repo_index,
					:target => n[0],
					:value  => 1,
				}

			end

			repo_index = repo_index + 1

		end

		# set the target index correctly for the javascript
		out[:links].each do |l|

			l[:target] = users[l[:target]][:index] + repo_index

		end

		out[:nodes] = repos.concat(users.values.to_a).flatten

		File.open(node_cache_file, 'w'){ |f| f << out.to_json }

		unless is_rake

			content_type :json
			#JSON.pretty_generate(out) # pretty print
			out.to_json # normal out

		end

	end

end

# interface
get '/' do
	erb :index
end

# get json for all repositories and their relationships
get '/nodes.json' do
	get_relationships
end

# get the json for the longest path
get '/longest.json' do
	get_longest_path
end

get '/nodes' do
	erb :nodes
end

get '/longest' do
	erb :longest
end