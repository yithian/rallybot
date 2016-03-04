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
    info = identify(username)

    case m.message

    # list out all known projects
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

    # select a project from which to work
    when /^project\s+(.*)/
      project = $1

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

    # tell rallybot to use a custom state field for items in the current project
    when /custom\s+state\s+(\w*)/
      custom_state = $1

      store_custom_state(info[:project], custom_state)

      m.reply "your current project will now use #{custom_state(info[:project])} as its state"

    # list items of the specified type
    #
    # this can be filtered by:
    # date
    # email
    # state
    when /^list\s+(#{$items.keys.select { |i| i != :tasks }.join('|')})(?:\s+--months\s+(\d+))?(?:\s+--email\s+?(\w+@\w+\.\w+))?(?:\s+(.*))?$/
      type_plural = $1.to_sym
      prev_date = $2 ? Date.today << $2.to_i : Date.today - 14
      time = DateTime.new(prev_date.year, prev_date.month, prev_date.day).strftime('%FT%T.%3NZ')
      email = $3
      state = $4.to_sym if $4

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
        m.reply 'only Stories can be in a Completed state'
        next
      end
      item = $items[type_plural]

      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # if an email address is provided, use that. otherwise, use the email of
      # the (registered) user talking to the bot
      items_for = email ? email : info[:email]

      actual_item_state = custom_state(info[:project]) || item.state

      # query rally
      proj_name = ''
      allowed = []

      r = connect_rally(username) do |rally|
        # get the project name for output
        if info[:project]
          p = rally.find do |q|
            q.type = 'Project'
            q.fetch = 'Name'
            q.query_string = "(ObjectID = \"#{info[:project]}\")"
          end
          proj_name = p[0]['Name']
        end

        # need the allowed values for the item so we can sorty by them
        allowed = rally.allowed_values(item.singular, "#{actual_item_state == item.state ? '' : 'c_'}#{actual_item_state}").keys
        allowed = allowed - ['Null']

        # query for the items
        rally.find do |q|
          q.type = item.singular
          q.fetch = "FormattedID,Name,Ready,Tasks,#{actual_item_state},TaskIndex,#{$items[:tasks].state},DragAndDropRank"
          q.project = {'_ref' => "/project/#{info[:project]}"} if info[:project]
          q.project_scope_down = true

          q.query_string = "(((Owner.Name = #{items_for})"
          # add type-specific state query (if needed)
          if state
            q.query_string << " and (#{actual_item_state} = \"#{state}\")"
          else
            q.query_string << " and (#{actual_item_state} < \"#{allowed.last}\")"
          end
          # add time query
          q.query_string << ") and (LastUpdateDate > #{time})"
          # close off the query string
          q.query_string << ")"
          # query string should end up looking like
          # (((Owner.name = email@address.tld) and (State < Closed)) and (LastUpdateDate > 2014-09-18T19:39:14.026Z))
        end
      end
      r = r.to_a

      if r.empty?
        response = "User \"#{items_for}\" has no"
        response << " " + state.to_s if state
        response << " #{type_plural} assigned that have been updated since #{prev_date}."
        m.reply response
        next
      end

      # sort the items based on the order of the allowed states
      # this depends on rally returning the allowed states in the correct order!
      ordered_allowed = {}
      allowed.reverse!.each_index { |i| ordered_allowed[allowed[i]] = i } # creates a hash of {state: order} pairs
      r.sort! do |a, b|
        if ordered_allowed[a[actual_item_state]] == ordered_allowed[b[actual_item_state]]
          a.DragAndDropRank <=> b.DragAndDropRank
        else
          ordered_allowed[a[actual_item_state]] <=> ordered_allowed[b[actual_item_state]]
        end
      end

      # get some formatting information
      r.each do |thing|
        thing[:id_length] = 1
        thing[:name_length] = 1

        thing.Tasks.each do |task|
          thing[:id_length] = task.FormattedID.length if task.FormattedID.length > thing[:id_length]
          thing[:name_length] = task.Name.length if task.Name.length > thing[:name_length]
        end
      end

      # actually reply with the user's items
      m.reply proj_name unless proj_name.empty?
      r.each do |thing|
        m.reply "#{thing.FormattedID} : #{thing.Name} : #{thing[actual_item_state]} :#{' not' unless thing.Ready} ready"

        thing.Tasks.sort_by { |t| t.TaskIndex }.each do |task|
          m.reply "  #{task.FormattedID.rjust(thing[:id_length])} : #{task.Name.ljust(thing[:name_length])} : #{task[$items[:tasks].state]}"
        end
      end

    # create an item
    when /(#{$items.values.select { |i| i.singular != 'task' }.map { |i| i.singular }.join('|')})\s+create\s+(.+)/
      itype = $items.select{ |k,v| v.singular == $1 }.values.first
      fields = {}
      fields[:Name] = $2
      fields[:Project] = info[:project]

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # actually create the new item
      new_item = connect_rally(username) do |rally|
        fields[:Owner] = rally_user(username, rally)

        rally.create(itype.singular, fields)
      end

      m.reply "#{new_item.FormattedID} : #{new_item.Name} has been created"

    # update the name of the specified item
    when /^(#{$items.values.map { |i| i.singular }.join('|')})\s+(\w+)\s+name\s+(.*)/
      itype = $items.select{ |k,v| v.singular == $1 }.values.first
      item = $2
      fields = {}
      fields[:Name] = $3

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      # update rally
      updated_item = connect_rally(username) { |rally| rally.update(itype.singular, "FormattedID|#{item}", fields) }

      # reply back with success
      m.reply "#{item} is now named #{updated_item.Name}"

    # change the state of an item
    when /^(#{$items.values.map { |i| i.singular }.join('|')})\s+(\w+)\s+state\s+(.*)/
      itype = $items.select{ |k,v| v.singular == $1 }.values.first
      item = $2
      state = $3

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      actual_item_state = custom_state(info[:project]) || itype.state

      connect_rally(username) do |rally|
        fields = {}
        fields[actual_item_state] = state
        fields['Ready'] = false

        begin
          updated_item = rally.update(itype.singular, "FormattedID|#{item}", fields)
          updated_item.rank_to_bottom

          # reply back that the task is completed
          m.reply "#{updated_item.FormattedID} is now marked as #{updated_item[actual_item_state]}"
        rescue Exception => e
          allowed = rally.allowed_values(itype.singular, "#{actual_item_state == itype.state ? '' : 'c_'}#{actual_item_state}").keys
          allowed = allowed - ['Null']

          # reply back with allowed values
          m.reply "allowed values for #{actual_item_state} are: #{allowed.join(', ')}"
        end
      end

    # mark an item as (not) ready to pull
    when /(#{$items.values.select { |i| i.singular != 'task' }.map { |i| i.singular }.join('|')})\s+(\w+)(?:\s+(not))?\s+ready/
      itype = $items.select{ |k,v| v.singular == $1 }.values.first
      item = $2
      ready = $3.nil?

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      updated_item = connect_rally(username) do |rally|
        rally.update(itype.singular, "FormattedID|#{item}", {'Ready' => ready})
      end

      # reply back that all's well
      m.reply "#{updated_item.FormattedID} is now#{' not' unless updated_item.Ready} ready to pull"

    # add a task to an item
    when /^(#{$items.values.select { |i| i.singular != 'task' }.map { |i| i.singular }.join('|')})\s+(\w+)\s+task\s+add\s+(.*)/
      itype = $items.select{ |k,v| v.singular == $1 }.values.first
      item = $2
      task_name = $3

      # make sure everything is ok before doing anything
      unless registered_nicks.include?(username)
        m.reply "User '#{username}' isn't registered with me :("
        next
      end

      task = connect_rally(username) do |rally|
        # get the actual item from rally. this is needed to set up the task as a child of the item
        result = rally.find do |q|
          q.type = itype.singular
          q.fetch = 'Name,FormattedID,Owner'
          q.query_string = "(FormattedID = \"#{item}\")"
        end

        if result.count == 0
          m.reply "#{itype.singular} #{item} can't be found :("
        else
          item = result.first

          task = rally.create('task', {'Name' => task_name, 'WorkProduct' => item, 'Owner' => rally_user(username, rally)})

          m.reply "Task #{task['FormattedID']} has been created"
        end
      end

    # add time worked for a task
    #
    # optionally, this may not decrement the remaining hours on the task
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

    # supply the remaining hours for a task
    when /^task\s+(\w+)\s+todo\s+(\d+)/
      task = $1
      fields = {}
      fields[:ToDo] = $2

      updated_task = connect_rally(username) do |rally|
        rally.update('task', "FormattedID|#{task}", fields)
      end

      # reply back with new To Do hours
      m.reply "#{updated_task.FormattedID} has #{updated_task.ToDo} hours remaining"

    # register with rallybot
    #
    # this is really just returning a link for where to get the api key
    when /^register/
      m.reply "Go to https://rally1.rallydev.com/login . Log in and click on the API Keys tab at the top of the page and generate a full access key."
      m.reply "then /msg #{ENV['RALLY_BOT_NAME']} confirm <rally email> <api key>"

    # confirm registration with rallybot
    #
    # this is really just supplying your api key, which rallybot stores in the db
    when /^confirm\s+(.*)\s+(.*)/
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

    when /help/
      usage(m)

    else
      m.reply "I don't know how to do that. Please type 'help' for usage."
    end
  end
end

bot.start
