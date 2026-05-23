# Reflection — introduction-to-builds

## What did I do?

I started by building the Go HTTP server into a Linux binary, then tried to run that binary in an Ubuntu 18.04 environment instead of only testing it on my own machine. The loop was: build the executable, copy or run it in the target-like environment, start the program, and then use `curl` against port `4444` to confirm whether the service actually responded with JSON. The first build reproduced the failure before the server could start, because the binary was dynamically linked against a newer glibc than Ubuntu 18.04 provides. After that, I changed the build options to use `CGO_ENABLED=0` with `GOOS=linux` and `GOARCH=amd64`, rebuilt the binary, ran it again in the same Ubuntu 18.04 setup, and used `curl` to verify that the server worked from the environment where it needed to run.

## What was most surprising?

What surprised me most was how much setup was needed to try to run an equivalent Ruby version in `app.rb`:

```ruby
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
```

After installing the `sinatra` gem and trying to run the script, I still got this error:

```text
Sinatra could not start, the required gems weren't found!

Add them to your bundle with:

    bundle add rackup puma

or install them with:

    gem install rackup puma
```

Just by looking at the code, it was not obvious that these dependencies were needed. After installing them, the app tab on the platform still did not work because of `attack prevented by Rack::Protection::HostAuthorization`. That made the difference between Ruby and Go feel concrete
## What's still unclear?

What is still unclear to me is the exact boundary between Go's internal linker and the system C linker. I would like to better understand which standard library packages or third-party dependencies commonly trigger cgo, and when a static build is not possible or not the right choice.
