require 'sinatra/base'
require 'sinatra/reloader'

require 'omniauth'
require 'mongo_mapper'
require 'haml'
require 'time-ago-in-words'
require 'sinatra/content_for'
require 'twitter'
require 'pony'
require 'bcrypt'
require 'ostatus'

require_relative 'models'

module Sinatra
  module UserHelper

    # This incredibly useful helper gives us the currently logged in user. We
    # keep track of that by just setting a session variable with their id. If it
    # doesn't exist, we just want to return nil.
    def current_user
      return User.first(:id => session[:user_id]) if session[:user_id]
      nil
    end

    # This very simple method checks if we've got a logged in user. That's pretty
    # easy: just check our current_user.
    def logged_in?
      current_user != nil
    end

    # Our `admin_only!` helper will only let admin users visit the page. If
    # they're not an admin, we redirect them to either / or the page that we
    # specified when we called it.
    def admin_only!(opts = {:return => "/"})
      unless logged_in? && current_user.admin?
        flash[:error] = "Sorry, buddy"
        redirect opts[:return]
      end
    end

    # Similar to `admin_only!`, `require_login!` only lets logged in users access
    # a particular page, and redirects them if they're not.
    def require_login!(opts = {:return => "/"})
      unless logged_in?
        flash[:error] = "Sorry, buddy"
        redirect opts[:return]
      end
    end
  end

  helpers UserHelper
end

class Rstatus < Sinatra::Base

  set :port, 8088


  # The `PONY_VIA_OPTIONS` hash is used to configure `pony`. Basically, we only
  # want to actually send mail if we're in the production environment. So we set
  # the hash to just be `{}`, except when we want to send mail.
  configure :test do
    PONY_VIA_OPTIONS = {}
  end

  configure :development do
    PONY_VIA_OPTIONS = {}
  end

  # We're using [SendGrid](http://sendgrid.com/) to send our emails. It's really
  # easy; the Heroku addon sets us up with environment variables with all of the
  # configuration options that we need.
  configure :production do
    PONY_VIA_OPTIONS =  {
      :address        => "smtp.sendgrid.net",
      :port           => "25",
      :authentication => :plain,
      :user_name      => ENV['SENDGRID_USERNAME'],
      :password       => ENV['SENDGRID_PASSWORD'],
      :domain         => ENV['SENDGRID_DOMAIN']
    }
  end

  use Rack::Session::Cookie, :secret => ENV['COOKIE_SECRET']
  set :root, File.dirname(__FILE__)
  set :haml, :escape_html => true
  set :config, YAML.load_file("config.yml")[ENV['RACK_ENV']]
  set :method_override, true

  require 'rack-flash'
  use Rack::Flash

  configure :development do
    register Sinatra::Reloader
  end

  configure do
    if ENV['MONGOHQ_URL']
      MongoMapper.config = {ENV['RACK_ENV'] => {'uri' => ENV['MONGOHQ_URL']}}
      MongoMapper.database = ENV['MONGOHQ_DATABASE']
      MongoMapper.connect("production")
    else
      MongoMapper.connection = Mongo::Connection.new('localhost')
      MongoMapper.database = "rstatus-#{settings.environment}"
    end
  end

  helpers Sinatra::UserHelper
  helpers Sinatra::ContentFor

  helpers do
    [:development, :production, :test].each do |environment|
      define_method "#{environment.to_s}?" do
        return settings.environment == environment.to_sym
      end
    end
  end

  use OmniAuth::Builder do
    provider :twitter, Rstatus.settings.config["CONSUMER_KEY"], Rstatus.settings.config["CONSUMER_SECRET"]
    provider :facebook, Rstatus.settings.config["APP_ID"], Rstatus.settings.config["APP_SECRET"]
  end

  get '/' do
    if logged_in?
      @updates = current_user.timeline
      haml :dashboard
    else
      haml :index, :layout => :'external-layout'
    end
  end

  get '/home' do
    haml :index, :layout => :'external-layout'
  end

  get '/replies' do
    if logged_in?
      haml :replies
    else
      haml :index, :layout => :'external-layout'
    end
  end

  get '/auth/:provider/callback' do
    auth = request.env['omniauth.auth']
    unless @auth = Authorization.find_from_hash(auth)
      @auth = Authorization.create_from_hash(auth, uri("/"), current_user)
    end

    session[:oauth_token] = auth['credentials']['token']
    session[:oauth_secret] = auth['credentials']['secret']
    session[:user_id] = @auth.user.id

    flash[:notice] = "You're now logged in."
    redirect '/'
  end

  get "/logout" do
    session[:user_id] = nil
    flash[:notice] = "You've been logged out."
    redirect '/'
  end

  # show user profile
  get "/users/:slug" do
    @user = User.first :username => params[:slug]
    haml :"users/show"
  end

  # subscriber receives updates
  post "/feeds/:id.atom" do
    feed = Feed.first :id => params[:id]
    feed.update_entries(request.body.read, request.url, request.env['HTTP_X_HUB_SIGNATURE'])
  end

  get "/subscribe" do
    feed_url = params[:url]

    f = current_user.follow! feed_url
    unless f
      flash[:notice] = "The was a problem following #{params[:url]}."
      redirect "/users/#{@user.username}"
    else
      name = f.author.username
      flash[:notice] = "Now following #{name}."
      redirect "/"
    end
  end

  # publisher will feed the atom to a hub
  # subscribers will verify a subscription
  get "/feeds/:id.atom" do
    feed = Feed.first :id => params[:id]
    if params['hub.challenge']
      sub = OSub::Subscription.new(request.url, feed.url)

      # perform the hub's challenge
      respond = sub.perform_challenge(params['hub.challenge'])

      # verify that the random token is the same as when we
      # subscribed with the hub initially and that the topic
      # url matches what we expect
      verified = params['hub.topic'] == feed.url
      if verified and sub.verify_subscription(params['hub.verify_token'])
        body respond[:body]
        status respond[:status]
      else
        # if the verification fails, the specification forces us to
        # return a 404 status
        status 404
      end
    else
      # TODO: Abide by headers that supply cache information
      body feed.atom(uri("/"))
    end
  end

  # an alias for the above route
  get "/users/:name/feed" do
    feed = User.first(:username => params[:name]).feed
    redirect uri("/feeds/#{feed.id}.atom")
  end

  # users can follow each other, and this route takes care of it!
  get '/users/:name/follow' do
    require_login! :return => "/users/#{params[:name]}/follow"

    @user = User.first(:username => params[:name])
    redirect "/users/#{@user.username}" and return if @user == current_user

    #make sure we're not following them already
    if current_user.following? @user.feed.url
      flash[:notice] = "You're already following #{params[:name]}."
      redirect "/users/#{@user.username}"
      return
    end

    # then follow them!
    unless current_user.follow! @user.feed.url
      flash[:notice] = "The was a problem following #{params[:name]}."
      redirect "/users/#{@user.username}"
    else
      flash[:notice] = "Now following #{params[:name]}."
      redirect "/users/#{@user.username}"
    end
  end

  #this lets you unfollow a user
  get '/users/:name/unfollow' do
    require_login! :return => "/users/#{params[:name]}/unfollow"

    @user = User.first(:username => params[:name])
    redirect "/users/#{@user.username}" and return if @user == current_user

    #make sure we're following them already
    unless current_user.following? @user.feed.url
      flash[:notice] = "You're not following #{params[:name]}."
      redirect "/users/#{@user.username}"
      return
    end

    #unfollow them!
    current_user.unfollow! @user.feed

    flash[:notice] = "No longer following #{params[:name]}."
    redirect "/users/#{@user.username}"
  end

  # this lets us see followers.
  get '/users/:name/followers' do
    @user = User.first(:username => params[:name])

    haml :"users/followers"
  end

  # This lets us see who is following.
  get '/users/:name/following' do
    @user = User.first(:username => params[:name])
    haml :"users/following"
  end

  post '/updates' do
    u = Update.new(:text => params[:text], 
                   :author => current_user.author)

    # and entry to user's feed
    current_user.feed.updates << u
    current_user.feed.save
    current_user.save

    # tell hubs there is a new entry
    current_user.feed.ping_hubs

    flash[:notice] = "Update created."
    redirect "/"
  end

  get '/updates/:id' do
    @update = Update.first :id => params[:id]
    haml :"updates/show", :layout => :'updates/layout'
  end

  post '/signup' do
    u = User.create(:email => params[:email], 
                    :status => "unconfirmed")
    u.set_perishable_token

    if development?
      puts uri("/") + "confirm/#{u.perishable_token}"
    else
      Notifier.send_signup_notification(params[:email], u.perishable_token)
    end

    haml :"signup/thanks", :layout => :'external-layout'
  end

  get "/confirm/:token" do
    @user = User.first :perishable_token => params[:token]
    # XXX: Handle user being nil (invalid confirmation)
    @username = @user.email.match(/^([^@]+?)@/)[1]

    @valid_username = false
    unless User.first :username => @username
      @valid_username = true
    end

    haml :"signup/confirm"
  end

  post "/confirm" do
    user = User.first :perishable_token => params[:perishable_token]
    user.username = params[:username]
    user.password = params[:password]
    user.status = "confirmed"
    user.author = Author.create(:username => user.username)
    user.finalize(uri("/"))
    user.save
    session[:user_id] = user.id.to_s

    flash[:notice] = "Thanks for signing up!"
    redirect '/'
  end

  get "/login" do
    haml :"login"
  end

  post "/login" do
    if user = User.authenticate(params[:username], params[:password])
      session[:user_id] = user.id
      flash[:notice] = "Login successful."
      redirect "/"
    else
      flash[:notice] = "The username or password you entered was incorrect"
      redirect "/login"
    end
  end

  delete '/updates/:id' do |id|
    update = Update.first :id => params[:id]

    if update.user == current_user
      update.destroy

      flash[:notice] = "Update Baleeted!"
      redirect "/"
    else
      flash[:notice] = "I'm afraid I can't let you do that, " + current_user.name + "."
      redirect back
    end
  end

  not_found do
    haml :'404', :layout => false
  end

  get "/hashtags/:tag" do
    @hashtag = params[:tag]
    @updates = Update.hashtag_search(@hashtag)
    haml :dashboard
  end

  get "/open_source" do
    haml :opensource
  end

end

