defmodule IRCBot do
  @moduledoc """
  Documentation for IRCBot.
  """
  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:socket, :server, :port, :nickname, :ssl, :channels]
  end

  @doc """
  Start the bot with the configured parameters.

  ```elixir
  %{
    server: String.t,
    port: non_neg_integer,
    nickname: String.t,
    channels: [String.t],
    ssl: boolean | none,
  }
  ```
  """
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # parse the arguments provided by the caller.
  @spec parse_args(%{
    server: String.t,
    port: non_neg_integer,
    nickname: String.t,
    channels: [String.t],
    ssl: boolean | none,
  }) ::
    {:ok, %IRCBot.State{}} |
    :error
  defp parse_args(args) do
    ssl =
      case Map.fetch(args, :ssl) do
        {:ok, v} ->
          v
        :error ->
          false
      end

    with {:ok, server} <- Map.fetch(args, :server),
         {:ok, port} <- Map.fetch(args, :port),
         {:ok, nickname} <- Map.fetch(args, :nickname),
         {:ok, channels} <- Map.fetch(args, :channels),
         do: {:ok, %IRCBot.State{
          server: server,
          port: port,
          nickname: nickname,
          channels: channels,
          ssl: ssl,
         }}
  end

  @doc """
  IRC bot initialization code.
  """
  def init(args) do
    schedule_connect()
    case parse_args(args) do
      {:ok, state} ->
        {:ok, state}
      :error ->
        {:stop, "failed to parse arguments"}
    end
  end

  # Connect IRC bot to the IRC server
  defp connect(state) do
    opts = [mode: :binary, active: :once, packet: :line, nodelay: true]
    server = to_charlist(state.server)
    case state.ssl do
      true ->
        :ssl.connect(server, state.port, opts)
      false ->
        :gen_tcp.connect(server, state.port, opts)
    end
  end

  # Ask for more data
  defp recvmore(state) do
    case state.ssl do
      true ->
        :ssl.setopts(state.socket, active: :once)
      false ->
        :inet.setopts(state.socket, active: :once)
    end
  end

  # Send message using the correct method.
  defp senddata(state, data) do
    case state.ssl do
      true ->
        :ssl.send(state.socket, data)
      false ->
        :gen_tcp.send(state.socket, data)
    end
  end

  # Send message to specified destination
  defp reply(state, who, msg) do
    senddata(state, "PRIVMSG #{who} :#{msg}\r\n")
  end

  # Handle PING messages.
  defp handle_ping(state, m) do
    senddata(state, "PONG #{m}\r\n")
  end

  # Handle channel/people messages.
  defp handle_privmsg(state, who, where, message) do
    cond do
      String.match?(message, ~r/^ping/i) ->
        botnick = state.nickname
        case where do
          ^botnick ->
            # Respond to channel where the message came from.
            reply(state, who, "pong #{who}")
          _ ->
            # Respond privately to whom asked.
            reply(state, where, "pong #{who}")
        end
      true ->
        Logger.debug(fn -> "#{who}@#{where}: #{message})" end)
    end
  end

  # Handle server messages.
  defp handle_server(state, server, m) do
    case m do
      ["PRIVMSG" | tail] ->
        who = server
          |> String.trim_leading(":")
          |> String.split("!")
          |> Enum.at(0)
        where = tail
          |> Enum.at(0)
        message = tail
          |> Enum.at(1)
          |> String.trim("\r\n")
          |> String.trim_leading(":")
        handle_privmsg(state, who, where, message)
      _ ->
        Logger.debug(fn -> "#{server}: #{inspect m}" end)
    end
  end

  # Generic message handling
  defp handle_message(state, m) do
    case m do
      ["PING" | tail] ->
        server = Enum.at(tail, 0)
          |> String.trim
        Logger.debug(fn -> "PING: #{inspect tail}" end)
        handle_ping(state, server)
      [server | tail] ->
        handle_server(state, server, tail)
      _ ->
        Logger.debug(fn -> "Unhandled: #{inspect m}" end)
    end
  end

  @doc """
  Handle IRC messages, connect events and socket status.
  """
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, socket} ->
        nstate = %IRCBot.State{state | socket: socket}
        senddata(nstate, "USER #{state.nickname} * * :#{state.nickname}\r\n")
        senddata(nstate, "NICK #{state.nickname}\r\n")
        for channel <- nstate.channels,
          do: senddata(nstate, "JOIN #{channel}\r\n")
        {:noreply, nstate}
      {:error, _} ->
        schedule_connect(5000)
        {:noreply, state}
    end
  end

  def handle_info({:tcp, _, msg}, state) do
    m = String.split(msg, " ", parts: 4)
    handle_message(state, m)
    recvmore(state)
    {:noreply, state}
  end

  def handle_info({:ssl, _, msg}, state) do
    m = String.split(msg, " ", parts: 4)
    handle_message(state, m)
    recvmore(state)
    {:noreply, state}
  end

  # Schedule connect
  defp schedule_connect(timeout \\ 0) do
    Process.send_after(self(), :connect, timeout)
  end
end
