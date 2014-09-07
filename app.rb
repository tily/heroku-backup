require 'fileutils'
require 'logger'
require 'heroku-api'
require 'aws-sdk'
require 'sinatra/base'
require 'haml'

class X < Sinatra::Base
	enable :inline_templates

	def backup
		@heroku = Heroku::API.new(api_key: ENV['HEROKU_API_KEY'])
		@bucket = AWS::S3.new.buckets[ENV['AWS_BUCKET']]
		@apps = @heroku.get_apps.body
		upload
		report
	end

	def upload
		@app_names
		measure("backup") do
			@apps.each do |app|
				app_name = app['name']
				addons = @heroku.get_addons(app_name).body
				next unless addons.find {|addon| addon['name'].match(/^mongohq:/) }
				
				measure("backup #{app_name}") do
					config_vars = @heroku.get_config_vars(app_name).body
					mongohq_url = config_vars.find {|key, value| key == 'MONGOHQ_URL' }.last
					uri = URI.parse(mongohq_url)
					db = uri.path.gsub(/^\//, '')
					execute ["mongodump", "--host", uri.host, "--port", uri.port, "--db", db, "--username", uri.user, "--password", uri.password].join(' ')
					execute "cd dump/#{db}/ && tar czf ../#{db}.tgz * && cd ../.."
	
					object = @bucket.objects["#{app_name}_production/#{Time.now.strftime('%Y-%m-%d')}.tgz"]
					object.write File.read("dump/#{db}.tgz")
					object.acl = :private
					objects = @bucket.objects.with_prefix("#{app_name}_production/")
					objects.each do |object|
						time = Time.parse(object.key[/\d{4}-\d{2}-\d{2}\.tgz$/])
						if (Time.now - time) > 60*60*24*7
							logger.info "deleting #{object.key}"
							object.delete
						end
					end
				end
			end
		end
		FileUtils.rm_rf('dump/')
	end

	def report
		object = @bucket.objects['index.html']
		object.write haml(:index)
		object.acl = :public_read

		object = @bucket.objects['feed']
		object.write builder(:feed)
		object.acl = :public_read
	end
	
	def measure(message)
		logger.info "start of #{message}"
		start_time = Time.now
		yield
		ellapse = Time.now - start_time
		logger.info "end of #{message} (#{ellapse} sec)"
		ellapse
	end
	
	def logger
		@logger ||= Logger.new(STDOUT)
	end
	
	def execute(command)
		logger.info "executing: #{command}"
		system command
	end
end

X.new.instance_variable_get(:@instance).backup

__END__
@@ index
!!! 5
%html
	%head
		%meta{name:"viewport",content:"width=device-width,initial-scale=1.0"}
		%title= "heroku backup of #{ENV['BACKUP_TITLE']}"
		%link{rel:'stylesheet',href:'//maxcdn.bootstrapcdn.com/bootstrap/3.2.0/css/bootstrap.min.css'}
	%body
		%div.container
			%h1= "heroku backup of #{ENV['BACKUP_TITLE']}"
			%p= "Last Update: #{Time.now.rfc822}"
			- @apps.each do |app|
				- addons = @heroku.get_addons(app['name']).body
				- next unless addons.find {|addon| addon['name'].match(/^mongohq:/) }
				%h2= app['name']
				%ul.list-group
					- @bucket.objects.with_prefix("#{app['name']}_production").each do |object|
						%li.list-group-item
							= object.key
							%span.badge= "#{object.content_length/1000.0} KB"
@@ feed
xml.instruct! :xml, :version => '1.0'
xml.rss :version => "2.0", :"xmlns:atom" => "http://www.w3.org/2005/Atom" do
	xml.channel do
		xml.tag! "atom:link", :href => "http://#{ENV['AWS_BUCKET']}.s3-website-ap-northeast-1.amazonaws.com/feed", :rel => "self", :type => "application/rss+xml"
		xml.title "heroku backup of #{ENV['BACKUP_TITLE']}"
		xml.description "heroku backup of #{ENV['BACKUP_TITLE']}"
		xml.link "http://#{ENV['AWS_BUCKET']}.s3-website-ap-northeast-1.amazonaws.com/"
		xml.item do
			xml.title "heroku backup of #{ENV['BACKUP_TITLE']}"
			xml.description "heroku backup of #{ENV['BACKUP_TITLE']}"
			xml.link "http://#{ENV['AWS_BUCKET']}.s3-website-ap-northeast-1.amazonaws.com/"
			xml.pubDate Time.now.rfc822
			xml.guid({:isPermaLink => false}, Time.now.rfc822)
		end
	end
end
