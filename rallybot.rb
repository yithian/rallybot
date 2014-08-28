require 'cinch'

# You will need an api key to use rally_api to get one, you'll need to go to this URL:
# https://rally1.rallydev.com/login

require 'rally_api'
require_relative './utils.rb'

$items = {stories: :story, tasks: :task, defects: :defect}

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
    username = parse_nick(m.user.nick)

    case m.message
    when /^list \w+ \w+/
      match = m.message.match(/^list (\w+) (\w+@\w+\.\w+)/)
      if match.nil?
        m.reply "usage: list [stories|tasks|defects] <email>"
        next
      end
      type_plural = match[1].to_sym
      items_for = match[2]
      id_length = 1

      # make sure everything is ok before doing anything
      unless $items.include?(type_plural)
        m.reply "I don't know what #{type_plural} are..."
        next
      end
      type_single = $items[type_plural]

      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # query rally
      r = connect_rally(username) do |rally|
        rally.find do |q|
          q.type = type_single
          q.fetch = 'FormattedID,Name'
          q.order = 'FormattedID Asc'
          case type_single
          when :task
            q.query_string = "((Owner.Name = #{items_for}) and (State < Completed))"
          when :story
            q.query_string = "((Owner.Name = #{items_for}) and (ScheduleState < Completed))"
          when :defect
            q.query_string = "((Owner.Name = #{items_for}) and (State < Closed))"
          end
        end
      end

      if r.empty?
        m.reply "User \"#{items_for}\" has no #{type_plural} assigned."
        next
      end

      # reply with the user's items, if there are any
      r.each { |thing| id_length = thing.FormattedID.length if thing.FormattedID.length > id_length }
      r.each { |thing| m.reply "#{thing.FormattedID.rjust(id_length)} : #{thing.Name}" }
    when /^\w+ \w+ update name/
      match = m.message.match(/^(\w+) (\w+) update name (.*)/)
      type_single = match[1].to_sym
      item = match[2]
      fields = {}
      fields[:Name] = match[3]

      # make sure everything is ok before doing anything
      unless $items.has_value?(type_single)
        m.reply "I don't know what a #{type_single} is..."
        next
      end

      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # update rally
      updated_item = connect_rally(username) { |rally| rally.update(type_single, "FormattedID|#{item}", fields) }

      # reply back with success
      m.reply "#{item} is now named #{updated_item.Name}"
    when /^task \w+ hours/
      match = m.message.match(/^task (\w+) hours (\d+)/)
      task = match[1]
      fields = {}
      fields[:Actuals] = match[2].to_i

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # update rally
      updated_task = connect_rally(username) do |rally|
        old_hours = rally.read('task', "FormattedID|#{task}").Actuals
        fields[:Actuals] += old_hours.to_i

        rally.update('task', "FormattedID|#{task}", fields)
      end

      # reply back with new actuals
      m.reply "#{updated_task.FormattedID} has consumed #{updated_task.Actuals} hour(s)"
    when /^register/
      m.reply "Go to https://rally1.rallydev.com/login . Log in and click on the API Keys tab at the top of the page and generate a full access key."
      m.reply "then /msg #{ENV['RALLY_BOT_NAME']} confirm <rally email> <api key>"
    when /^confirm/
      match = /^confirm (.*) (.*)/.match(m.message)
      if match
        m.reply "Registering #{username} as #{match[1]}"
        register(username, match[1], match[2])
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
