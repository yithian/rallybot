require 'rally_api'
require 'mongo'

include Mongo

$login_collection = 'users'

def usage(msg)
  msg.reply 'list [stories|tasks|defects] <user> - list stuff assigned to user'
  msg.reply '[story|task|defect] <id> update name <...> - change the name of a task'
  msg.reply 'task <id> hours <number> - add hours worked on a task'
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
    db[$login_collection].update({'_id' => nick}, {'_id' => nick, 'email' => email, 'key' => key}, {:upsert => true})
  end
end

# given a nick, grab the stored email and api key from the db
def identify(nick)
  db_connect do |db|
    doc = db[$login_collection].find_one({_id: parse_nick(nick)})
    {email: doc['email'], key: doc['key']} if doc
  end
end

# provide a connection to rally via a stored api key
def connect_rally(nick, &block)
  deets = identify(nick)

  config = {
    base_url: 'https://rally1.rallydev.com/slm',
    api_key: deets[:key],
    workspace: ENV['RALLY_BOT_WORKSPACE'],
    project: ENV['RALLY_BOT_PROJECT'],
    headers: headers = RallyAPI::CustomHttpHeader.new({vendor: 'Brofaces', name: 'rallybot irc bot', version: '1.0'})
  }

  rally = RallyAPI::RallyRestJson.new(config)
  
  if block
    yield rally
  else
    rally
  end
end
