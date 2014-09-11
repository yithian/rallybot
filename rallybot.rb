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

      # this query should only return one user with your email address
      u = connect_rally(username) do |rally|
        rally.find do |q|
          q.type = 'project'
          q.fetch = 'Name'
          q.order = 'Name asc'
          q.query_string = "(TeamMembers contains \"#{identify(username)[:email]}\")"
        end
      end

      if u.count == 0
        m.reply 'you aren\'t on any projects :('
        next
      else
        m.reply 'you are on the following projects:'
        u.each do |project|
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
    when /^list (stories|tasks|defects) (\w+@\w+\.\w+)/
      type_plural = $1.to_sym
      items_for = $2
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
          q.project = {'_ref' => "/project/#{identify(username)[:project]}"} if identify(username)[:project]
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
    when /^task (\w+) hours (\d+)/
      task = $1
      fields = {}
      fields[:Actuals] = $2.to_i

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
    when /^task (\w+) state (Defined|In-Progress|Completed)/
      task = $1
      fields = {}
      fields[:State] = $2

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      updated_task = connect_rally(username) do |rally|
        rally.update('task', "FormattedID|#{task}", fields)
      end

      # reply back that the task is completed
      m.reply "#{updated_task.FormattedID} is now marked as #{updated_task.State}"
    when /^register/
      m.reply "Go to https://rally1.rallydev.com/login . Log in and click on the API Keys tab at the top of the page and generate a full access key."
      m.reply "then /msg #{ENV['RALLY_BOT_NAME']} confirm <rally email> <api key>"
    when /^confirm (.*) (.*)/.match(m.message)
      if match
        m.reply "Registering #{username} as #{$1}"
        register(username, $1, $2)
        m.reply "Done!"
      else
        m.reply "That didn't make any sense..."
      end
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
