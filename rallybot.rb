require 'cinch'

# You will need an api key to use rally_api to get one, you'll need to go to this URL:
# https://rally1.rallydev.com/login

require 'rally_api'
require_relative './utils.rb'

include Mongo

bot = Cinch::Bot.new do
  configure do |c|
    # get some basic defaults
    ENV['RALLY_BOT_QUIT_CODE'] ||= ""
    ENV['RALLY_BOT_NAME'] ||= "rallybot"
    ENV['RALLY_BOT_SERVER'] ||= "irc.freenode.net"

    c.server = ENV['RALLY_BOT_SERVER']
    c.nick = ENV['RALLY_BOT_NAME']

    unless ENV["RALLY_BOT_CHANNEL_KEY"].nil? or ENV["RALLY_BOT_CHANNEL_KEY"].empty?
      c.channels = ["#{ENV['RALLY_BOT_CHANNEL']} #{ENV['RALLY_BOT_CHANNEL_KEY']}"]
    else
      c.channels = [ENV['RALLY_BOT_CHANNEL']]
    end

    if ENV['RALLY_BOT_SERVER_USE_SSL'] == "true"
      c.port = ENV['RALLY_BOT_SERVER_SSL_PORT'] ||= "6697"
      c.ssl.use = true
    end
  end

  on :private do |m|
    case m.message
    when /^stories \w+/
      username = m.message.match(/^stories (\w+)/)[1]
      id_length = 1

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      rally = connect_rally(m.user.nick)
      r = rally.find do |q|
        q.type = 'story'
        q.fetch = 'FormattedID,Name'
        q.order = 'FormattedID Asc'
        q.query_string = "(Owner.Name = \"#{identify(m.user.nick)[:email]}\")"
      end

      if r.empty?
        m.reply "User \"#{username}\" has no stories assigned."
        next
      end

      r.each { |story| id_length = story.FormattedID.length if story.FormattedID.length > id_length }
      r.each do |story|
        m.reply "#{story.FormattedID.rjust(id_length)} : #{story.Name}"
      end
    when /^tasks \w+/
      username = m.message.match(/^tasks (\w+)/)[1]
      id_length = 1

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      rally = connect_rally(m.user.nick)
      r = rally.find do |q|
        q.type = 'task'
        q.fetch = 'FormattedID,Name'
        q.order = 'FormattedID Asc'
        q.query_string = "((Owner.Name = \"#{identify(m.user.nick)[:email]}\") and (State != \"Completed\"))"
      end

      if r.empty?
        m.reply "User \"#{username}\" has no tasks assigned."
        next
      end

      r.each { |task| id_length = task.FormattedID.length if task.FormattedID.length > id_length }
      r.each do |task|
        m.reply "#{task.FormattedID.rjust(id_length)} : #{task.Name}"
      end
    when /^task \w+ update name/
      match = m.message.match(/^task (\w+) update name (.*)/)
      task = match[1]
      fields = {}
      fields[:Name] = match[2]

      rally = connect_rally(m.user.nick)
      updated_task = rally.update('task', "FormattedID|#{task}", fields)

      m.reply "#{task} is now named #{updated_task.Name}"
    when /^task \w+ hours/
      match = m.message.match(/^task (\w+) hours (\d+)/)
      task = match[1]
      fields = {}
      fields[:Actuals] = match[2].to_i

      rally = connect_rally(m.user.nick)
      old_hours = rally.read('task', "FormattedID|#{task}").Actuals
      fields[:Actuals] += old_hours.to_i

      updated_task = rally.update('task', "FormattedID|#{task}", fields)

      m.reply "#{updated_task.FormattedID} has consumed #{updated_task.Actuals} hour(s)"
    when /^register/
      m.reply "Go to https://rally1.rallydev.com/login . Log in and click on the API Keys tab at the top of the page and generate a full access key."
      m.reply "then /msg #{ENV['RALLY_BOT_NAME']} confirm <rally email> <api key>"
    when /^confirm/
      nick = parse_nick(m.user.nick)
      match = /^confirm (.*) (.*)/.match(m.message)
      if match
        m.reply "Registering #{nick} as #{match[1]}"
        register(nick, match[1], match[2])
        m.reply "Done!"
      else
        m.reply "That didn't make any sense..."
      end
    when /^quit\s*\w*/
      code = /^quit\s*(\w*)/.match(m.message)[1]
      bot.quit if ENV['RALLY_BOT_QUIT_CODE'].eql?(code)

      if code.empty?
        m.reply "There is a quit code required for this bot, sorry."
      else
        m.reply "That is not the correct quit code required for this bot, sorry."
      end
    else
      usage(m)
    end
  end
end

bot.start
