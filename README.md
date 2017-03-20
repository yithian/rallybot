rallybot
========

an irc bot to interact with rally:

```
rallybot | projects - list your projects
rallybot | select project <project name> - select a project on which to operate
rallybot | list [stories|defects] (<state>) (<number> months) (<email>) - list stuff assigned to you
rallybot |   (<state> - list items in the speicified state
rallybot |      can be one of [backlog|defined|in-progress|completed|closed|accepted])
rallybot |   (<email> - list stuff assigned to the specified user)
rallybot |   (<number> months - display all matching items updated within this many months)
rallybot | [story|defect] create <...> - create an item
rallybot | [story|task|defect] <id> name <...> - change the name of an item
rallybot | [story|task|defect] <id> state [defined|in-progress|completed] - change the state of an item
rallybot | [story|defect] <id> task add <...> - add a task to an item
rallybot | task <id> hours <number> (--no-todo) - add hours worked on a task and decrease the todo hours
rallybot |   (with --no-todo, this will not the task's todo hours)
rallybot | task <id> todo <number> - specify total remaining hours for a task
rallybot | register - create an api key for use with rallybot
rallybot | confirm <email> <api_key> - store your api key for use with rallybot
```


rallybot relies on the following environment variables:

* RALLY_BOT_SERVER: hostname of the irc server rallybot should connect to
* RALLY_BOT_CHANNEL: comma-separated list of channels rallybot should hang out in (this is mostly just a reminder for folks that it exists)
* RALLY_BOT_NAME: irc nick for rallybot
* RALLY_BOT_WORKSPACE: name of the workspace rally should operate in
* MONGODB_USER: mongodb username
* MONGODB_PASSWORD: mongodb password
* MONGODB_DATABASE: mongodb database
