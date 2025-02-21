# frozen_string_literal: true
#
# ronin-app - a local web app for Ronin.
#
# Copyright (C) 2023 Hal Brodigan (postmodern.mod3@gmail.com)
#
# ronin-app is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ronin-app is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with ronin-app.  If not, see <http://www.gnu.org/licenses/>.
#

$LOAD_PATH.unshift(File.join(__dir__,'lib'))

# classes
require 'sinatra/base'
require 'sinatra/content_for'
require 'sinatra/flash'
require 'sinatra/reloader'

# configuration
require './config/database'
require './config/sidekiq'

# ronin libraries
require 'ronin/repos'
require 'ronin/payloads'
require 'ronin/exploits'
require 'ronin/support/encoding'

# param validations
require 'ronin/app/validations/install_repo_params'
require 'ronin/app/validations/recon_params'
require 'ronin/app/validations/nmap_params'
require 'ronin/app/validations/masscan_params'
require 'ronin/app/validations/import_params'
require 'ronin/app/validations/spider_params'

# schema builders
require 'ronin/app/schemas/payloads/encoders/encode_schema'
require 'ronin/app/schemas/payloads/build_schema'

# helpers
require 'ronin/app/helpers/html'

# worker classes
require './workers/install_repo'
require './workers/update_repo'
require './workers/update_repos'
require './workers/remove_repo'
require './workers/purge_repos'
require './workers/nmap'
require './workers/masscan'
require './workers/import'
require './workers/spider'
require './workers/recon'

require 'ronin/app/version'

#
# Main app class.
#
class App < Sinatra::Base

  include Ronin::App

  configure do
    enable :sessions
    register Sinatra::Flash
    helpers Sinatra::ContentFor
    helpers Helpers::HTML
  end

  configure :development do
    register Sinatra::Reloader
  end

  get '/' do
    erb :index
  end

  get '/repos' do
    @repos = Ronin::Repos.cache_dir

    erb :"repos/index"
  end

  get '/repos/install' do
    erb :"repos/install"
  end

  post '/repos/install' do
    result = Validations::InstallRepoParams.call(params)

    if result.success?
      Workers::InstallRepo.perform_async(result[:uri],result[:name])

      flash[:success] = "Installing repo at #{result[:uri]}"
      redirect '/repos'
    else
      @errors = result.errors

      flash[:danger] = 'Failed to install repo!'
      halt 400, erb(:"repos/install")
    end
  end

  post '/repos/update' do
    Workers::UpdateRepos.perform_async

    flash[:success] = 'All repos will be updated'
    redirect '/repos'
  end

  delete '/repos' do
    Workers::PurgeRepos.perform_async

    flash[:success] = 'All repos will be purged'
    redirect '/repos'
  end

  get '/repos/:name' do
    @repos = Ronin::Repos.cache_dir

    begin
      @repo = @repos[params[:name]]

      erb :"repos/show"
    rescue Ronin::Repos::RepositoryNotFound
      halt 404
    end
  end

  post '/repos/:name/update' do
    @repo = Ronin::Repos.cache_dir[params[:name]]

    Workers::UpdateRepo.perform_async(@repo.name)

    flash[:success] = "Repo #{@repo.name} enqueued for update"
    redirect "/repos/#{params[:name]}"
  rescue Ronin::Repos::RepositoryNotFound
    halt 404
  end

  delete '/repos/:name' do
    @repo = Ronin::Repos.cache_dir[params[:name]]

    Workers::RemoveRepo.perform_async(@repo.name)

    flash[:success] = "Repo #{@repo.name} enqueued for removal"
    redirect '/repos'
  rescue Ronin::Repos::RepositoryNotFound
    halt 404
  end

  get '/payloads' do
    @payloads = Ronin::Payloads.list_files

    erb :"payloads/index"
  end

  get '/payloads/encoders' do
    @payload_encoders = Ronin::Payloads::Encoders.list_files

    erb :"payloads/encoders/index"
  end

  get %r{/payloads/encoders/encode/(?<encoder_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @encoder_class = Ronin::Payloads::Encoders.load_class(params[:encoder_id])
    @encoder       = @encoder_class.new

    erb :"payloads/encoders/encode"
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  post %r{/payloads/encoders/encode/(?<encoder_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @encoder_class = Ronin::Payloads::Encoders.load_class(params[:encoder_id])
    @encoder       = @encoder_class.new

    form_schema = Schemas::Payloads::Encoders::EncodeSchema(@encoder_class)
    result      = form_schema.call(params)

    if result.success?
      encoder_params = result[:params].to_h
      encoder_params.compact!

      begin
        @encoder.params = encoder_params
      rescue Ronin::Core::Params::ParamError => error
        flash[:error] = "Failed to set params: #{error.message}"

        halt 400, erb(:"payloads/encoders/encode")
      end

      begin
        @encoder.validate
      rescue => error
        flash[:error] = "Failed to encode encoder: #{error.message}"

        halt 500, erb(:"payloads/encoders/encode")
      end

      @encoded_data = @encoder.encode(result[:data])

      erb :"payloads/encoders/encode"
    else
      @params = params
      @errors = result.errors

      halt 400, erb(:"payloads/encoders/encode")
    end
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  get %r{/payloads/encoders/(?<encoder_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @encoder = Ronin::Payloads::Encoders.load_class(params[:encoder_id])

    erb :"payloads/encoders/show"
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  get %r{/payloads/build/(?<payload_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @payload_class = Ronin::Payloads.load_class(params[:payload_id])
    @payload       = @payload_class.new

    erb :"payloads/build"
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  post %r{/payloads/build/(?<payload_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @payload_class = Ronin::Payloads.load_class(params[:payload_id])
    @payload       = @payload_class.new

    form_schema = Schemas::Payloads::BuildSchema(@payload_class)
    result      = form_schema.call(params)

    if result.success?
      payload_params = result[:params].to_h
      payload_params.compact!

      begin
        @payload.params = payload_params
      rescue Ronin::Core::Params::ParamError => error
        flash[:error] = "Failed to set params: #{error.message}"

        halt 400, erb(:"payloads/build")
      end

      begin
        @payload.perform_validate
        @payload.perform_build
      rescue => error
        flash[:error] = "Failed to build payload: #{error.message}"

        halt 500, erb(:"payloads/build")
      end

      @built_payload = @payload.to_s

      erb :"payloads/build"
    else
      @params = params
      @errors = result.errors

      halt 400, erb(:"payloads/build")
    end
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  get %r{/payloads/(?<payload_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @payload = Ronin::Payloads.load_class(params[:payload_id])

    erb :"payloads/show"
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  get '/exploits' do
    @exploits = Ronin::Exploits.list_files

    erb :"exploits/index"
  end

  get %r{/exploits(?<exploit_id>[a-z0-9_-]+(?:/[a-z0-9_-]+)*)} do
    @exploit = Ronin::Exploits.load_class(params[:exploit_id])

    erb :"exploits/show"
  rescue Ronin::Core::ClassRegistry::ClassNotFound
    halt 404
  end

  get '/db' do
    @host_name_count            = Ronin::DB::HostName.count
    @asn_count                  = Ronin::DB::ASN.count
    @ip_address_count           = Ronin::DB::IPAddress.count
    @mac_address_count          = Ronin::DB::MACAddress.count
    @open_port_count            = Ronin::DB::OpenPort.count
    @port_count                 = Ronin::DB::Port.count
    @service_count              = Ronin::DB::Service.count
    @url_count                  = Ronin::DB::URL.count
    @url_scheme_count           = Ronin::DB::URLScheme.count
    @url_query_param_name_count = Ronin::DB::URLQueryParamName.count
    @email_address_count        = Ronin::DB::EmailAddress.count
    @user_name_count            = Ronin::DB::UserName.count
    @password_count             = Ronin::DB::Password.count
    @credential_count           = Ronin::DB::Credential.count
    @advisory_count             = Ronin::DB::Advisory.count
    @software_count             = Ronin::DB::Software.count
    @software_vendor_count      = Ronin::DB::SoftwareVendor.count
    @oses_count                 = Ronin::DB::OS.count

    erb :db
  end

  get '/db/host_names' do
    @host_names = Ronin::DB::HostName.all

    erb :"db/host_names/index"
  end

  get '/db/host_names/:id' do
    @host_name = Ronin::DB::HostName.find(params[:id])

    if @host_name
      erb :"db/host_names/show"
    else
      halt 404
    end
  end

  get '/db/asns' do
    @asns = Ronin::DB::ASN.all

    erb :"db/asns/index"
  end

  get '/db/asns/:id' do
    @asn = Ronin::DB::ASN.find(params[:id])

    if @asn
      erb :"db/asns/show"
    else
      halt 404
    end
  end

  get '/db/ip_addresses' do
    @ip_addresses = Ronin::DB::IPAddress.all

    erb :"db/ip_addresses/index"
  end

  get '/db/ip_addresses/:id' do
    @ip_address = Ronin::DB::IPAddress.find(params[:id])

    if @ip_address
      erb :"db/ip_addresses/show"
    else
      halt 404
    end
  end

  get '/db/mac_addresses' do
    @mac_addresses = Ronin::DB::MACAddress.all

    erb :"db/mac_addresses/index"
  end

  get '/db/mac_addresses/:id' do
    @mac_address = Ronin::DB::MACAddress.find(params[:id])

    if @mac_address
      erb :"db/mac_addresses/show"
    else
      halt 404
    end
  end

  get '/db/open_ports' do
    @open_ports = Ronin::DB::OpenPort.all

    erb :"db/open_ports/index"
  end

  get '/db/open_ports/:id' do
    @open_port = Ronin::DB::OpenPort.find(params[:id])

    if @open_port
      erb :"db/open_ports/show"
    else
      halt 404
    end
  end

  get '/db/ports' do
    @ports = Ronin::DB::Port.all

    erb :"db/ports/index"
  end

  get '/db/ports/:id' do
    @port = Ronin::DB::Port.find(params[:id])

    if @port
      erb :"db/ports/show"
    else
      halt 404
    end
  end

  get '/db/services' do
    @services = Ronin::DB::Service.all

    erb :"db/services/index"
  end

  get '/db/services/:id' do
    @service = Ronin::DB::Service.find(params[:id])

    if @service
      erb :"db/services/show"
    else
      halt 404
    end
  end

  get '/db/urls' do
    @urls = Ronin::DB::URL.all

    erb :"db/urls/index"
  end

  get '/db/urls/:id' do
    @url = Ronin::DB::URL.find(params[:id])

    if @url
      erb :"db/urls/show"
    else
      halt 404
    end
  end

  get '/db/url_schemes' do
    @url_schemes = Ronin::DB::URLScheme.all

    erb :"db/url_schemes/index"
  end

  get '/db/url_schemes/:id' do
    @url_scheme = Ronin::DB::URLScheme.find(params[:id])

    if @url_scheme
      erb :"db/url_schemes/show"
    else
      halt 404
    end
  end

  get '/db/url_query_param_names' do
    @url_query_param_names = Ronin::DB::URLQueryParamName.all

    erb :"db/url_query_param_names/index"
  end

  get '/db/url_query_param_names/:id' do
    @url_query_param_name = Ronin::DB::URLQueryParamName.find(params[:id])

    if @url_query_param_name
      erb :"db/url_query_param_names/show"
    else
      halt 404
    end
  end

  get '/db/email_addresses' do
    @email_addresses = Ronin::DB::EmailAddress.all

    erb :"db/email_addresses/index"
  end

  get '/db/email_addresses/:id' do
    @email_address = Ronin::DB::EmailAddress.find(params[:id])

    if @email_address
      erb :"db/email_addresses/show"
    else
      halt 404
    end
  end

  get '/db/user_names' do
    @user_names = Ronin::DB::UserName.all

    erb :"db/user_names/index"
  end

  get '/db/user_names/:id' do
    @user_name = Ronin::DB::UserName.find(params[:id])

    if @user_name
      erb :"db/user_names/show"
    else
      halt 404
    end
  end

  get '/db/passwords' do
    @passwords = Ronin::DB::Password.all

    erb :"db/passwords/index"
  end

  get '/db/passwords/:id' do
    @password = Ronin::DB::Password.find(params[:id])

    if @password
      erb :"db/passwords/show"
    else
      halt 404
    end
  end

  get '/db/credentials' do
    @credentials = Ronin::DB::Credential.all

    erb :"db/credentials/index"
  end

  get '/db/credentials/:id' do
    @credential = Ronin::DB::Credential.find(params[:id])

    if @credential
      erb :"db/credentials/show"
    else
      halt 404
    end
  end

  get '/db/advisories' do
    @advisories = Ronin::DB::Advisory.all

    erb :"db/advisories/index"
  end

  get '/db/advisories/:id' do
    @advisory = Ronin::DB::Advisory.find(params[:id])

    if @advisory
      erb :"db/advisories/show"
    else
      halt 404
    end
  end

  get '/db/software' do
    @software = Ronin::DB::Software.all

    erb :"db/software/index"
  end

  get '/db/software/:id' do
    @software = Ronin::DB::Software.find(params[:id])

    if @software
      erb :"db/software/show"
    else
      halt 404
    end
  end

  get '/db/software_vendors' do
    @software_vendors = Ronin::DB::SoftwareVendor.all

    erb :"db/software_vendors/index"
  end

  get '/db/software_vendors/:id' do
    @software_vendor = Ronin::DB::SoftwareVendor.find(params[:id])

    erb :"db/software_vendors/show"
  end

  get '/db/oses' do
    @oses = Ronin::DB::OS.all

    erb :"db/oses/index"
  end

  get '/db/oses/:id' do
    @os = Ronin::DB::OS.find(params[:id])

    if @os
      erb :"db/oses/show"
    else
      halt 404
    end
  end

  get '/recon' do
    erb :recon
  end

  post '/recon' do
    result = Validations::ReconParams.call(params)

    if result.success?
      @jid = Workers::Recon.perform_async(result.to_h)

      scope = result[:scope]

      flash[:success] = "Recon of #{scope.join(', ')} enqueued"
      redirect '/recon'
    else
      @params = params
      @errors = result.errors

      flash[:danger] = 'Failed to submit recon request!'
      halt 400, erb(:recon)
    end
  end

  get '/nmap' do
    erb :nmap
  end

  post '/nmap' do
    result = Validations::NmapParams.call(params)

    if result.success?
      @jid = Workers::Nmap.perform_async(result.to_h)

      targets = result[:targets]

      flash[:success] = "Scan of #{targets.join(',')} enqueued"
      redirect '/nmap'
    else
      @params = params
      @errors = result.errors

      flash[:danger] = 'Failed to submit nmap scan!'
      halt 400, erb(:nmap)
    end
  end

  get '/masscan' do
    erb :masscan
  end

  post '/masscan' do
    result = Validations::MasscanParams.call(params)

    if result.success?
      @jid = Workers::Masscan.perform_async(result.to_h)

      targets = result[:ips]

      flash[:success] = "Scan of #{targets.join(',')} enqueued"
      redirect '/masscan'
    else
      @errors = result.errors

      flash[:danger] = 'Failed to submit masscan scan!'
      halt 400, erb(:masscan)
    end
  end

  get '/import' do
    erb :import
  end

  post '/import' do
    result = Validations::ImportParams.call(params)

    if result.success?
      @jid = Workers::Import.perform_async(result.to_h)

      type = result[:type]
      path = result[:path]

      flash[:success] = "Import of #{type} file #{path} enqueued"
      redirect '/import'
    else
      @errors = result.errors

      flash[:danger] = 'Failed to submit import job!'
      halt 400, erb(:import)
    end
  end

  get '/spider' do
    erb :spider
  end

  post '/spider' do
    result = Validations::SpiderParams.call(params)

    if result.success?
      @jid = Workers::Spider.perform_async(result.to_h)

      type   = result[:type]
      target = result[:target]

      flash[:success] = "Web spider of #{type} #{target} enqueued"
      redirect '/spider'
    else
      @errors = result.errors

      flash[:danger] = 'Failed to submit spider scan!'
      halt 400, erb(:spider)
    end
  end

  get '/about' do
    @lockfile = Bundler::LockfileParser.new(File.read(Bundler.default_lockfile))

    erb :about
  end

end
