require 'rake'
require 'yaml'

CONFIG = YAML.load_file( File.join(File.dirname(__FILE__), 'config.yml') ) unless defined? CONFIG

# -- Shortcuts

desc "Start application in development mode"
task :default => 'start:development'

desc "Start application in production mode with Thin"
task :start   => 'start:production'

# -- Start/Stop

namespace :start do
  task :development do
    system "ruby pushr.rb -p 4000"
  end
  task :production do
    %x[thin -R config.ru -d -P thin.pid -l production.log -e production -p 4000 start]
  end
end

desc "Stop application in production mode"
task :stop do
  %x[thin -R config.ru -d -P thin.pid -l production.log -e production -p 4000 stop]
end

# -- Maintenance

namespace :app do
  desc "Check dependencies of the application"
  task :check do
    begin
      require 'rubygems'
      require 'sinatra'
      require 'haml'
      require 'sass'
      require 'capistrano'
      require 'thin'
      puts "\n[*] Good! You seem to have all the neccessary gems for Pushr"
    rescue LoadError => e
      puts "[!] Bad! Some gems for Pushr are missing!"
      puts e.message
    ensure
      Sinatra::Base.set(:run, false)
    end
  end
  desc "Add public key for the user@server to 'itself' (so Cap can SSH to localhost)"
  task :add_public_key_to_localhost do
    # TODO : Ask for key name with Highline
    `cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys`
  end
end
