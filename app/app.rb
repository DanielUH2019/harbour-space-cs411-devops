require 'sinatra'
require 'json'

set :bind, '0.0.0.0'
set :port, 4444
set :protection, false

get '/' do
  content_type :json

  {
    Name: 'Hello',
    Description: 'World',
    Url: request.host_with_port
  }.to_json
end