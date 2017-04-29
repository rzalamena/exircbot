defmodule IRCBot do
	use Application
	import Supervisor.Spec

	def start(_type, _args) do
		opts = %{
			nickname: Application.get_env(:ircbot, :nickname),
			server: Application.get_env(:ircbot, :server),
			port: Application.get_env(:ircbot, :port),
			channels: Application.get_env(:ircbot, :channels),
			ssl: Application.get_env(:ircbot, :ssl, false),
		}

		children = [
			worker(IRCBot.Bot, [opts])
		]

		Supervisor.start_link(children, strategy: :one_for_one)
	end
end