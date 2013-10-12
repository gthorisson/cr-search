# -*- coding: utf-8 -*-

# Main Sinatra file where the app is bootstrapped and routes are defined.
# Most configuration and all the business logic resides in lib/

require 'sinatra'
require 'sinatra/config_file'
require 'sinatra/partial'
require 'json'
require 'mongo'
require 'will_paginate'
require 'cgi'
# require 'gabba' uncomment to use Google Analytics
require 'rack-session-mongo'
require 'rack-flash'
require 'omniauth-orcid'
require 'oauth2'
require 'resque'
require 'open-uri'
require 'uri'

# Set up logging
require 'log4r'
include Log4r
logger = Log4r::Logger.new('test')
logger.trace = true
logger.level = DEBUG
formatter = Log4r::PatternFormatter.new(:pattern => "[%l] %t  %M")
Log4r::Logger['test'].outputters << Log4r::Outputter.stdout
Log4r::Logger['test'].outputters << Log4r::FileOutputter.new('logtest', 
                                              :filename =>  'log/app.log',
                                              :formatter => formatter)
logger.info 'got log4r set up'
logger.debug "This is a message with level DEBUG"
logger.info "This is a message with level INFO"
use Rack::Logger, logger


config_file 'config/settings.yml'

require_relative 'lib/configure'
require_relative 'lib/helpers'
#require_relative 'lib/paginate'
#require_relative 'lib/result' ## CHANGE to search_result or similar
require_relative 'lib/bootstrap'
require_relative 'lib/session'
require_relative 'lib/data'
require_relative 'lib/orcid_update'
require_relative 'lib/orcid_claim' ## CHANGE to orcid_add_externalid or similar

MIN_MATCH_SCORE = 2
MIN_MATCH_TERMS = 3
MAX_MATCH_TEXTS = 1000

after do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

before do
  logger.info "Fetching #{url}, params " + params.inspect
  load_config
end

get '/' do

  # If the user is signed in via ORCID, kick off a search. Otherwise show the splash page
  if !signed_in?
    erb :splash, :locals => {:page => {:query => ""}}
  else
    params['q'] = session[:orcid][:info][:name] if !params.has_key?('q')

    logger.debug "Initiating search with query string '#{params['q']}'"
    results = search settings.server, params['q']
    logger.debug "Full set of search results:\n" + results.ai
    results_page = {
      :bare_sort => params['sort'],
      :bare_query => params['q'],
    #  :query_type => query_type,
      :bare_filter => params['filter'],
      #:query => query_terms,
      #:page => query_page,
      :items => results,
      #:paginate => Paginate.new(query_page, query_rows, solr_result)
    }

    # format ISNI, cluster digits into fours separated by space
    #   isni.gsub(/(\d{4})/, '\1 \2').gsub(/\s$/, '')

    logger.debug "Rendering search results"
    erb :results, :locals => {page: results_page}
  end
end


get '/help/search' do
  erb :search_help, :locals => {:page => {query: ''}}
end

get '/orcid/activity' do
  if signed_in?
    erb :activity, :locals => {:page => {:query => ''}}
  else
    redirect '/'
  end
end

get '/orcid/claim' do ## RENAME route to /orcid/add_externalid or similar
  status = 'oauth_timeout'

  # REFACTOR!! get most/all of this into its own module

  if signed_in? && params['id']
    id = params['id']
    orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
    already_added = !orcid_record.nil? && orcid_record['locked_ids'].include?(id)

    logger.info "Initiating claim for identifier #{id}"
   
    if already_added
      logger.info "ID #{id} is already claimed, not doing anything!"
      status = 'ok'
    else
      logger.debug "Retrieving metadata from MongoDB for #{id}"
      bio_record = settings.bios.find_one({:id => id})

      if !bio_record
        status = 'no_such_id'
        logger.warn "No bio record found for #{id}"
      else       
        logger.debug "Got some bio metadata from MongoDB: " + bio_record.ai

        claim_ok = false
        begin
          claim_ok = OrcidClaim.perform(session_info, bio_record) 
        rescue => e
          # ToDo: need more useful error messaging here, for displaying to user
          status = "could not claim"
          logger.error "Caught exception from claim process: #{e}: \n" + e.backtrace.join("\n")
        end

        # Update MongoDB record for this ORCID
        if claim_ok          
          if orcid_record
            orcid_record['updated'] = true
            orcid_record['locked_ids'] << id
            orcid_record['locked_ids'].uniq!
            settings.orcids.save(orcid_record)
          else
            doc = {:orcid => sign_in_id, :ids => [], :locked_ids => [id]}
            settings.orcids.insert(doc)
          end
          
          # The ID could have been added as limited or public. If so we need
          # to tell the UI.
          OrcidUpdate.perform(session_info)
          updated_orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
          
          if updated_orcid_record['ids'].include?(id)
            status = 'ok_visible'
          else
            status = 'ok'
          end
        end
      end
    end
  end

  content_type 'application/json'
  {:status => status}.to_json
end

get '/orcid/unclaim' do
  if signed_in? && params['id']
    doi = params['id']

    logger.info "Initiating unclaim for #{id}"    
    orcid_record = settings.orcids.find_one({:orcid => sign_in_id})

    if orcid_record
      orcid_record['locked_ids'].delete(id)
      settings.orcids.save(orcid_record)
    end
  end

  content_type 'application/json'
  {:status => 'ok'}.to_json
end

get '/orcid/sync' do
  status = 'oauth_timeout'

  if signed_in?
    if OrcidUpdate.perform(session_info)
      status = 'ok'
    else
      status = 'oauth_timeout'
    end
  end

  content_type 'application/json'
  {:status => status}.to_json
end

get '/auth/orcid/callback' do
  session[:orcid] = request.env['omniauth.auth']
  Resque.enqueue(OrcidUpdate, session_info)
  logger.info "Signing in via ORCID"
  logger.debug "got session info:\n" + session.ai
  update_profile
  erb :auth_callback
end

get '/auth/orcid/import' do
  session[:orcid] = request.env['omniauth.auth']
  Resque.enqueue(OrcidUpdate, session_info)
  logger.info "Signing in via ORCID"
  logger.debug "got session info:\n" + session.ai
  update_profile
  redirect to("/?q=#{session[:orcid][:info][:name]}")
end

get '/auth/orcid/check' do

end

# Used to sign out a user but can also be used to mark that a user has seen the
# 'You have been signed out' message. Clears the user's session cookie.
get '/auth/signout' do
  session.clear
  redirect(params[:redirect_uri])
end

get "/auth/failure" do
  flash[:error] = "Authentication failed with message \"#{params['message']}\"."
  erb :auth_callback
end

get '/auth/:provider/deauthorized' do
  haml "#{params[:provider]} has deauthorized this app."
end

get '/heartbeat' do
  content_type 'application/json'

  params['q'] = 'fish'

  begin
    # Attempt a query with solr
    solr_result = select(search_query)

    # Attempt some queries with mongo
    result_list = search_results(solr_result)

    {:status => :ok}.to_json
  rescue StandardError => e
    {:status => :error, :type => e.class, :message => e}.to_json
  end
end
