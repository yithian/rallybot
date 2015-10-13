require 'cinch'

# You will need an api key to use rally_api to get one, you'll need to go to this URL:
# https://rally1.rallydev.com/login

require 'rally_api'
require_relative 'utils'
require_relative 'item'

$items = {stories: Item.new('story', 'ScheduleState', 'Completed'), tasks: Item.new('task', 'State', 'Completed'), defects: Item.new('defect', 'State', 'Closed')}
$states = {backlog: :Backlog, defined: :Defined, :'in-progress' => :'In-Progress', completed: :Completed, closed: :Closed, accepted: :Accepted}

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
      c.channels = ENV['RALLY_BOT_CHANNEL'].split(', ')
    end

    if ENV['RALLY_BOT_SERVER_USE_SSL'] == "true"
      c.port = ENV['RALLY_BOT_SERVER_SSL_PORT'] ||= "6697"
      c.ssl.use = true
    end
  end

  on :private do |m|
    username = parse_nick(m.user.nick)

    case m.message
    when /^projects/
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      projects = connect_rally(username) do |rally|
        rally.find do |q|
          q.type = 'project'
          q.fetch = 'Name,TeamMembers'
          q.order = 'Name asc'
          q.query_string = "(TeamMembers.EmailAddress = \"#{identify(username)[:email]}\")"
        end
      end

      if projects.count == 0
        m.reply 'you aren\'t on any projects :('
        next
      else
        m.reply 'you are on the following projects:'
        projects.each do |project|
          m.reply project.to_s
        end
      end
    when /^select project/
      project = m.message.match(/^select project (.*)/)[1]

      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # this query should only return one user with your email address
      p = connect_rally(username) do |rally|
        rally.find do |q|
          q.type = 'project'
          q.fetch = 'Name,ObjectID'
          q.order = 'Name'
          q.query_string = "(Name = \"#{project}\")"
        end
      end

      project_id = p.first.ObjectID

      select_project(username, project_id)
      m.reply "you are now operating on #{project}"
    when /^list\s+(#{$items.keys.join('|')})(?:\s+(#{$states.keys.join('|')}))?(?:\s+(\d+)\s+months)?(?:\s+?(\w+@\w+\.\w+))?/
      type_plural = $1.to_sym
      id_length = 1
      state = $2.to_sym if $2
      prev_date = $3 ? Date.today << $3.to_i : Date.today - 14
      time = DateTime.new(prev_date.year, prev_date.month, prev_date.day).strftime('%FT%T.%3NZ')
      email = $4

      # make sure everything is ok before doing anything
      unless $items.include?(type_plural)
        m.reply "I don't know what #{type_plural} are..."
        next
      end
      # defects get closed and stories/tasks get completed
      # i hate this terminology quirk of Rally
      if state == :closed and type_plural != :defects
        m.reply 'only Defects can be in a Closed state.'
        next
      elsif state == :completed and (type_plural != :tasks or type_plural != :stories)
        m.reply 'only Stories and Tasks can be in a Completed state'
        next
      end
      item = $items[type_plural]

      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end
      info = identify(username)

      # if an email address is provided, use that. otherwise, use the email of
      # the (registered) user talking to the bot
      items_for = email ? email : info[:email]

      # query rally
      r = connect_rally(username) do |rally|
        rally.find do |q|
          q.type = item.singular
          q.fetch = 'FormattedID,Name'
          q.order = 'FormattedID Asc'
          q.project = {'_ref' => "/project/#{info[:project]}"} if info[:project]

          q.query_string = "(((Owner.Name = #{items_for})"
          # add type-specific state query (if needed)
          if state
            q.query_string << " and (#{item.state} = #{$states[state]})"
          else
            q.query_string << " and (#{item.state} < #{item.closed})"
          end
          # add time query
          q.query_string << ") and (LastUpdateDate > #{time})"
          # close off the query string
          q.query_string << ")"
          # query string should end up looking like
          # (((Owner.name = email@address.tld) and (State < Closed)) and (LastUpdateDate > 2014-09-18T19:39:14.026Z))
        end
      end

      if r.empty?
        response = "User \"#{items_for}\" has no"
        response << " " + state.to_s if state
        response << " #{type_plural} assigned that have been updated since #{prev_date}."
        m.reply response
        next
      end

      # reply with the user's items, if there are any
      r.each { |thing| id_length = thing.FormattedID.length if thing.FormattedID.length > id_length }
      r.each { |thing| m.reply "#{thing.FormattedID.rjust(id_length)} : #{thing.Name}" }
    when /^(\w+) (\w+) update name (.*)/
      type_single = $s.to_sym
      item = $2
      fields = {}
      fields[:Name] = $3

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
    when /^task\s+(\w+)\s+hours\s+(\d+)(?:\s+(--no-todo))?/
      task = $1
      fields = {}
      actuals = $2.to_i
      todo = $3.nil?

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # update rally
      updated_task = connect_rally(username) do |rally|
        old_task = rally.read('task', "FormattedID|#{task}")
        old_hours = old_task.Actuals
        old_todo = old_task.ToDo
        fields[:Actuals] = old_hours.to_i + actuals
        fields[:ToDo] = old_todo - actuals if todo

        rally.update('task', "FormattedID|#{task}", fields)
      end

      # reply back with new actuals
      m.reply "#{updated_task.FormattedID} has consumed #{updated_task.Actuals} hour(s) with #{updated_task.ToDo} remaining"
    when /^task\s+(\w+)\s+todo\s+(\d+)/
      task = $1
      fields = {}
      fields[:ToDo] = $2

      updated_task = connect_rally(username) do |rally|
        rally.update('task', "FormattedID|#{task}", fields)
      end

      # reply back with new To Do hours
      m.reply "#{updated_task.FormattedID} has #{updated_task.ToDo} hours remaining"
    when /^(\w+) (\w+) state (Defined|In-Progress|Completed)/
      itype = $items[$1.to_sym]
      item = $2
      fields = {}
      fields[itype.state] = $3
      puts "fields = #{fields.inspect}"

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      updated_item = connect_rally(username) do |rally|
        rally.update(itype.singular, "FormattedID|#{item}", fields)
      end

      puts updated_item.inspect

      # reply back that the task is completed
      m.reply "#{updated_item.FormattedID} is now marked as #{updated_item[itype.state]}"
    when /^register/
      m.reply "Go to https://rally1.rallydev.com/login . Log in and click on the API Keys tab at the top of the page and generate a full access key."
      m.reply "then /msg #{ENV['RALLY_BOT_NAME']} confirm <rally email> <api key>"
    when /^confirm (.*) (.*)/
      email = $1
      api_key = $2

      m.reply "Registering #{username} as #{email}"
      register(username, email, api_key)
      m.reply "Done!"
    when /^quit\s*(\w*)/
      code = $1
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
