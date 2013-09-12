task :default do
  exec "rspec spec/"
end

task :run do
  exec "rackup config.ru"
end

task :deploy do
  exec "git push heroku master"
end
