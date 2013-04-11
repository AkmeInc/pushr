# The bundler can't be used due to BUNDLE_GEMFILE bug, see e09c65 commit.
# Required gems:
#   - rake
#   - sinatra
#   - thin
#   - json
#   - haml
#   - sass

require 'rubygems'
require 'sinatra'
require 'yaml'
require 'logger'
require 'json'
require 'haml'
require 'sass'
require 'yaml'

# = Pushr
# Deploy Rails applications by Github Post-Receive URLs launching Capistrano's commands

CONFIG = YAML.load_file( File.join(File.dirname(__FILE__), 'config.yml') ) unless defined? CONFIG

class String
  # http://github.com/rails/rails/blob/master/activesupport/lib/active_support/core_ext/string/inflections.rb#L44-49
  def camelize
    self.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }
  end
end

module Pushr

  # == Shared logger
  module Logger
    unless defined? LOGGER
      LOGGER       = ::Logger.new(File.join(File.dirname(__FILE__), 'deploy.log'), 'weekly')
      LOGGER.level = ::Logger::INFO
    end
    def log; LOGGER; end
  end

  # == Wrapping Git stuff
  class Repository

    include Logger

    Struct.new('Info', :revision, :message, :author, :when, :datetime) unless defined? Struct::Info

    def initialize(path)
      @path = path
    end

    def info
      info = `cd #{@path}/current; git log --pretty=format:'%h --|-- %s --|-- %an --|-- %ar --|-- %ci' -n 1`
      @info ||= Struct::Info.new( *info.split(/\s{1}--\|--\s{1}/) )
    end

    def reload!
      @info = nil
      info
    end

  end # end Repository

  # == Wrapping application logic
  class Application

    include Logger

    attr_reader :path, :application, :repository, :success, :cap_output

    def initialize(path)
      log.fatal('Pushr.new') { "Path not valid: #{path}" } and raise ArgumentError, "File not found: #{path}" unless File.exists?(path)
      @path = path
      @application = ::CONFIG['application'] || "You really should set this to something"
      @repository  = Repository.new(path)
    end

    def deploy!(options = {})
      cap_command = CONFIG['cap_command'] || 'deploy:migrations'
      rails_env = options[:rails_env] || CONFIG['cap_default_rails_env']

      command = "BRANCH=#{options[:branch]} bundle exec cap #{rails_env} #{cap_command}"

      log.info(application) { "Deployment starting..." }
      @cap_output  = %x[cd #{path}/shared/cached-copy; bundle install && #{command} 2>&1]
      @success     = $?.success?
      @repository.reload!  # Update repository info (after deploy)

      update_statistics(options)

      log_deploy_result
    end

    def available_envs
      CONFIG['cap_staging_envs']
    end

    def remote_branches
      output = %x[cd #{path}/shared/cached-copy; git ls-remote --heads origin]
      output.scan(/\S+\s+refs\/heads\/(.+)$/).flatten
    end

    def statistics
      file = File.join File.dirname(__FILE__), 'statistics.yaml'
      File.open(file, "r") { |f| YAML.load(f) } || {}
    end

    def update_statistics(options)
      opts = { 'name'   => (options[:name] || 'rails'),
               'branch' => (options[:branch] || 'master'),
               'at'     => Time.now }

      updated = statistics.merge(options[:rails_env] => opts)

      file = File.join File.dirname(__FILE__), 'statistics.yaml'
      File.open(file, "w") { |f| f.puts updated.to_yaml }
    end

    private

    def log_deploy_result
      if @success
        log.info('[SUCCESS]')   { "Successfuly deployed application with revision #{repository.info.revision} (#{repository.info.message}). Capistrano output:" }
        log.info('Capistrano')  { @cap_output.to_s }
      else
        log.warn('[FAILURE]')   { "Error when deploying application! Check Capistrano output below:" }
        log.warn('Capistrano')  { @cap_output.to_s }
      end
    end

  end # end Application

end # end Pushr

# -------  Sinatra gets on stage here  --------------------------------------------------

# -- Authorize all requests with username/password set in <tt>config.yml</tt>
before do
  halt [404, "Not configured\n"] and return unless configured?
  response['WWW-Authenticate'] = %(Basic realm="[pushr] #{CONFIG['application']}") and \
  halt([401, "Not authorized\n"]) and \
  return unless authorized?
end

# -- Helpers
helpers do

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials.first == CONFIG['username'] && @auth.credentials.last == CONFIG['password']
  end

  def configured?
    CONFIG['username'] && !CONFIG['username'].nil? && CONFIG['password'] && !CONFIG['password'].nil?
  end

end

# == Get info
get '/' do
  @pushr = Pushr::Application.new(CONFIG['path'])
  @name = request.cookies["username"]
  haml :info
end

# == Deploy!
post '/' do
  @pushr = Pushr::Application.new(CONFIG['path'])

  if params[:payload]
    # GitHub Post-Receive Hook
    push = JSON.parse(params[:payload])
    @pushr.deploy! if push['ref'] == 'refs/heads/master'
    [200, 'OK']
  else
    # Deploy via web GUI
    @pushr.deploy!(params)
    response.set_cookie("username", :value => params[:name], :expires => (Time.now + 60 * 60 * 24 * 30))
    haml :deployed
  end
end

# == Look nice
get '/style.css' do
  content_type 'text/css', :charset => 'utf-8'
  sass :style
end
get( '/favicon.ico' ) { content_type 'image/gif' }

post '/updatedb-salesworker-production' do
  `updatedb-salesworker-production`
  redirect '/'
end

post '/env-use-salesworker-production' do
  `env-use-salesworker-production #{params[:rails_env]}`
  redirect '/'
end

post '/reindex-elastic-search' do
  env_path = "#{CONFIG['path']}/../#{CONFIG['application'].downcase}-#{params[:rails_env]}/current"
  `cd #{env_path} && RAILS_ENV=#{params[:rails_env]} bundle exec rake tire:bootstrap`
  redirect '/'
end

__END__

@@ layout
%html
  %head
    %title= "[pushr] #{@pushr.application}"
    %meta{ 'http-equiv' => 'Content-Type', :content => 'text/html;charset=utf-8' }
    %link{ :rel => 'stylesheet', :type => 'text/css', :href => "/style.css" }
  %body
    = yield

@@ info
#wrapper
  #elastic-search
    %strong elastic search
    %form{:action => "/reindex-elastic-search", :method => 'post'}
      %input{:type => 'submit', :value => 'reindex on'}
      %select{:name => "rails_env"}
        - @pushr.available_envs.each do |stage|
          %option= stage
  #release
    %strong salesworker_production
    %form{:action => "/updatedb-salesworker-production", :method => 'post'}
      %input{:type => 'submit', :value => 'Update DB'}
    %form{:action => "/env-use-salesworker-production", :method => 'post'}
      %input{:type => 'submit', :value => 'Use DB on'}
      %select{:name => "rails_env"}
        - @pushr.available_envs.each do |stage|
          %option= stage
  %form{:action => "/", :method => 'post', :id => 'deploy', :onsubmit => "this.submit.disabled='true'"}
    Deploy
    %select{:name => "branch"}
      - @pushr.remote_branches.each do |branch|
        %option= branch
    to
    %select{:name => "rails_env"}
      - @pushr.available_envs.each do |stage|
        %option= stage
    by
    %input{:type => 'text', :name => 'name', :placeholder => 'Your name', :class => 'name', :value => @name}
    %input{:type => 'submit', :value => 'Run', :name => 'submit', :class => 'submit'}
  #statistics
    - @pushr.statistics.each do |env, opts|
      %div
        %strong #{env}:
        = opts['branch']
        %span was deployed by
        = opts['name']
        %span at
        = opts['at']
  #last_revision
    Last deployed revision of
    %strong= @pushr.application
    is
    %strong= @pushr.repository.info.revision
    \:
    %strong= @pushr.repository.info.message
    committed
    %strong= @pushr.repository.info.when
    by
    = @pushr.repository.info.author

@@ deployed
- if @pushr.success
  #wrapper.success
    %h2
      Application deployed successfully.
    %form{ 'action' => "", :method => 'get' }
      %p
        %input{ 'type' => 'submit', 'value' => 'Return to index' }
    %pre
      = @pushr.cap_output
- else
  #wrapper.failure
    %h2
      There were errors when deploying the application!
    %form{ 'action' => "", :method => 'get' }
      %p
        %input{ 'type' => 'submit', 'value' => 'Return to index' }
    %pre
      = @pushr.cap_output

@@ style
body
  :color #333
  :font-size 90%
  :font-family Helvetica, Tahoma, sans-serif
  :line-height 1.5
  :padding 10%
a
  :color #000
pre
  :color #444
  :font-size 95%
  :text-align left
  :word-wrap  break-word
  :white-space pre
  :white-space pre-wrap
  :white-space -moz-pre-wrap
  :white-space -o-pre-wrap
#wrapper
  :border 4px solid #ccc
  :padding 1.5em 2em
  h2
    :margin-bottom 1em
#wrapper.success h2
  :color #128B45
#wrapper.failure h2
  :color #E21F3A
#release, #elastic-search
  :float right
  :margin-left 20px
  form
    :margin-bottom 0
#statistics
  :margin-top 2em
  span
    :color #888
#last_revision
  :margin-top 2em
  :font-size 12px
#deploy
  select
    :margin 0 5px
  input.name
    :margin 0 5px 0 5px
    :width 100px
  input.submit
    :font-weight bold
