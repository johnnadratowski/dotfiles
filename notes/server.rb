require 'sinatra'
require 'logger'

set :logger, Logger.new(STDOUT)

set :port, 52525

get '/build' do
  if system('./build.sh') != true
    500
  else
    204
  end 
end

post '/log' do
  request.body.rewind
  body = request.body.read
  begin
    logger.info JSON.pretty_generate JSON.parse body
  rescue
    logger.info body
  end
end