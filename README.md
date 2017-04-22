# IRCBot

An IRC bot implementation in Elixir.


# Example

Here is a quick example how to start a bot:

1. Open an interactive Elixir shell:

	```shell
	$ iex -S mix
	```

	Then spawn a new bot:

	```elixir
	IRCBot.start_link(%{server: "foobar", port: 6697, nickname: "foobarbaz", channels: ["#foobar"], ssl: true})
	```

2. Create your own Elixir application.


# Extending the bot

Enable the debug messages to aid you debugging the bot interactions.
To do this comment out the logger configuration in the config/config.exs file.