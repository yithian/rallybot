require 'rally_api'
require 'mongo'

include Mongo

$login_collection = 'users'

def usage(msg)
  msg.reply 'projects - list your projects'
  msg.reply 'select project <project name> - select a project on which to operate'
  msg.reply "list [#{$items.keys.select { |i| i != :tasks }.join('|')}] (<state>) (<number> months) (<email>) - list stuff assigned to you"
  msg.reply '  (<state> - list items in the speicified state'
  msg.reply "     can be one of [#{$states.keys.join('|')}])"
  msg.reply '  (<email> - list stuff assigned to the specified user)'
  msg.reply '  (<number> months - display all matching items updated within this many months)'
  msg.reply "[#{$items.values.select { |i| i.singular != 'task' }.map { |i| i.singular }.join('|')}] create <...> - create an item"
  msg.reply "[#{$items.values.map { |i| i.singular }.join('|')}] <id> name <...> - change the name of an item"
  msg.reply "[#{$items.values.map { |i| i.singular }.join('|')}] <id> state [defined|in-progress|completed] - change the state of an item"
  msg.reply "[#{$items.values.select { |i| i.singular != 'task' }.map { |i| i.singular }.join('|')}] <id> task add <...> - add a task to an item"
  msg.reply 'task <id> hours <number> (--no-todo) - add hours worked on a task and decrease the todo hours'
  msg.reply '  (with --no-todo, this will not the task\'s todo hours)'
  msg.reply 'task <id> todo <number> - specify total remaining hours for a task'
  msg.reply "register - create an api key for use with #{ENV['RALLY_BOT_NAME']}"
  msg.reply "confirm <email> <api_key> - store your api key for use with #{ENV['RALLY_BOT_NAME']}"
end

# parse an irc nick into its base format
# eg: parse_nick('achvatal|away') => 'achvatal'
def parse_nick(nick)
  match = /([a-zA-Z\d]+)/.match(nick)
  shortnick = ''

  if match
    shortnick = match[1]
  else
    shortnick = nick
  end

  return shortnick
end

# return a list of registered nicks
def registered_nicks
  nicks = db_connect do |db|
    db[$login_collection].find({}, {fields: ['_id']}).to_a
  end

  nicks.collect { |n| n['_id'] }
end

# provide an authenticated connection to the openshift mongo db
def db_connect(&block)
  con = MongoClient.new(ENV['OPENSHIFT_MONGODB_DB_HOST'], ENV['OPENSHIFT_MONGODB_DB_PORT'])
  db = con.db(ENV['OPENSHIFT_APP_NAME'])
  db.authenticate(ENV['OPENSHIFT_MONGODB_DB_USERNAME'], ENV['OPENSHIFT_MONGODB_DB_PASSWORD'])
  if block
    result = yield db
    con.close
    result
  else
    db
  end
end

# store a nick/email/login in the db
def register(nick, email, key)
  db_connect do |db|
    db[$login_collection].update({_id: nick}, {_id: nick, email: email, key: key}, {:upsert => true})
  end
end

# update a user's preferred project
def select_project(nick, proj_id)
  db_connect do |db|
    u = db[$login_collection].find_one({_id: nick})
    u['project'] = proj_id

    db[$login_collection].update({_id: nick}, u, {:upsert => true})
  end
end

# return the rally user for an irc nick
def rally_user(nick, rally)
  rally = connect_rally(nick) unless rally

  result = rally.find do |q|
    q.type = 'User'
    q.fetch = 'DisplayName,EmailAddress'
    q.query_string = "(EmailAddress = \"#{identify(nick)[:email]}\")"
  end
  result.first
end

# given a nick, grab the stored email, project and api key from the db
def identify(nick)
  db_connect do |db|
    doc = db[$login_collection].find_one({_id: parse_nick(nick)})
    {email: doc['email'], project: doc['project'], key: doc['key']} if doc
  end
end

# provide a connection to rally via a stored api key
def connect_rally(nick, &block)
  deets = identify(nick)

  config = {
    base_url: 'https://rally1.rallydev.com/slm',
    api_key: deets[:key],
    workspace: ENV['RALLY_BOT_WORKSPACE'],
    headers: headers = RallyAPI::CustomHttpHeader.new({vendor: 'Brofaces', name: 'rallybot irc bot', version: '1.0'})
  }

  rally = RallyAPI::RallyRestJson.new(config)
  
  if block
    yield rally
  else
    rally
  end
end
