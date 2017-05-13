defmodule IRCBot.Bot do
  @moduledoc """
  Documentation for IRCBot.
  """
  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :socket, :server, :port, :nickname, :ssl, :channels,
      :cur_server, :ping_timer, :sendq, :send_timer,
    ]

    @type t :: %__MODULE__{
      server: String.t, port: non_neg_integer, nickname: String.t,
      ssl: boolean, channels: [String.t], cur_server: String.t | none,
      ping_timer: reference | none, send_timer: reference | none,
    }
  end

  @rate_bucket "ircbot-ratelimit"
  @rate_time 1_000
  @rate_amount 1

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
    {:ok, %State{}} |
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
         do: {:ok, %State{
          server: server,
          port: port,
          nickname: nickname,
          channels: channels,
          ssl: ssl,
          sendq: :queue.new(),
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
    state
  end

  # Prepare message to send
  @spec senddata(State.t, String.t) :: State.t
  defp senddata(state, data) do
    sendq = :queue.in(data, state.sendq)
    %State{state | sendq: sendq}
    |> schedule_send()
  end

  # Send message using the correct method.
  defp send_now(state, data) do
    case state.ssl do
      true ->
        :ssl.send(state.socket, data)
      false ->
        :gen_tcp.send(state.socket, data)
    end
  end

  # Send message to specified destination
  @spec reply(State.t, String.t, String.t) :: State.t
  defp reply(state, who, msg) do
    senddata(state, "PRIVMSG #{who} :#{msg}\n")
  end

  # Handle karma.
  @spec handle_karma(State.t, String.t, String.t) :: State.t
  defp handle_karma(state, message, to) do
    r = Regex.scan(~r/([^ ]+)(\+\+|\-\-)/, message)
    if Enum.empty?(r) do
      state
    else
      Enum.reduce(r, state, fn(x, nstate) ->
        what = x
          |> Enum.at(1)
          |> String.downcase
        type = x
          |> Enum.at(2)
        karma_op =
          if type == "++" do
            &IRCBot.Karma.karma_add/1
          else
            &IRCBot.Karma.karma_rem/1
          end
        case karma_op.(what) do
          {:ok, karma} ->
            reply(nstate, to, "#{karma.what} has now #{karma.score} point(s)")
          {:error, _} ->
            reply(nstate, to, "Failed to register #{what}, sorry about that :(")
        end
      end)
    end
  end

  # Handle channel/people messages.
  @spec handle_privmsg(State.t, String.t, String.t, String.t) :: State.t
  defp handle_privmsg(state, who, where, message) do
    botnick = state.nickname
    to =
      case where do
        ^botnick ->
          # Respond to channel where the message came from.
          who
        _ ->
          # Respond privately to whom asked.
          where
      end

    state = handle_karma(state, message, to)

    cond do
      String.match?(message, ~r/^ping/i) ->
        case where do
          ^botnick ->
            reply(state, to, "pong")
          _ ->
            reply(state, to, "#{who}: pong")
        end
      true ->
        Logger.debug(fn -> "#{who}@#{where}: #{message})" end)
        state
    end
  end

  # Handle server messages.
  @spec handle_server(State.t, String.t, [String.t]) :: State.t
  defp handle_server(state, server, m) do
    case m do
      ["PONG" | _] ->
        # Nothing to do, the server just replied our ping.
        state
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
        state
    end
  end

  # Generic message handling
  @spec handle_message(State.t, [String.t]) :: State.t
  defp handle_message(state, m) do
    case m do
      ["PING" | tail] ->
        server = Enum.at(tail, 0)
          |> String.trim
        send_now(state, "PONG #{server}\n")
        state
      [server | tail] ->
        %State{state | cur_server: server}
        |> handle_server(server, tail)
      _ ->
        Logger.debug(fn -> "Unhandled: #{inspect m}" end)
        state
    end
  end

  @doc """
  Handle IRC messages, connect events and socket status.
  """
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, socket} ->
        nstate = %State{state | socket: socket}
        send_now(nstate, "USER #{state.nickname} * * :#{state.nickname}\n")
        send_now(nstate, "NICK #{state.nickname}\n")
        for channel <- nstate.channels,
          do: send_now(nstate, "JOIN #{channel}\n")
        nstate = schedule_ping(nstate)
        {:noreply, nstate}
      {:error, _} ->
        schedule_connect(5000)
        {:noreply, state}
    end
  end

  def handle_info(:ping, state) do
    send_now(state, "PING #{state.cur_server}\n")
    state = schedule_ping(state)
    {:noreply, state}
  end

  # This function handles the server output speed.
  #
  # It also schedule and cancel server pings to reduce the traffic and avoid being
  # flagged by the IRC server as a flooder.
  def handle_info(:send, state) do
    state =
      case :queue.out(state.sendq) do
        {:empty, _} ->
          # No more messages to send, ping the server to keep alive.
          schedule_ping(state)
        {{_, data}, newq} ->
          case ExRated.check_rate(@rate_bucket, @rate_time, @rate_amount) do
            {:ok, _} ->
              # Output queued data.
              send_now(state, data)
              %State{state | sendq: newq}
              |> ping_cancel()
              |> schedule_send()
            {:error, _} ->
              # We exceeded our send rate, wait for next time slot.
              {_, _, delay, _, _} = ExRated.inspect_bucket(@rate_bucket, @rate_time, @rate_amount)
              ping_cancel(state)
              |> schedule_send(delay)
          end
      end
    {:noreply, state}
  end

  def handle_info({:tcp, _, msg}, state) do
    m = String.split(msg, " ", parts: 4)
    nstate = state
      |> handle_message(m)
      |> recvmore()
    {:noreply, nstate}
  end

  def handle_info({:ssl, _, msg}, state) do
    m = String.split(msg, " ", parts: 4)
    nstate = state
      |> handle_message(m)
      |> recvmore()
    {:noreply, nstate}
  end

  # Schedule connect
  defp schedule_connect(timeout \\ 0) do
    Process.send_after(self(), :connect, timeout)
  end

  # Cancel ping schedule
  defp ping_cancel(state) do
    if state.ping_timer do
      Process.cancel_timer(state.ping_timer)
    end
    %State{state | ping_timer: nil}
  end

  # Schedule ping
  defp schedule_ping(state, timeout \\ 60000) do
    state = ping_cancel(state)
    ping_timer = Process.send_after(self(), :ping, timeout)
    %State{state | ping_timer: ping_timer}
  end

  # Schedule data send
  defp schedule_send(state, timeout \\ 100) do
    if state.send_timer do
      Process.cancel_timer(state.send_timer)
    end
    send_timer = Process.send_after(self(), :send, timeout)
    %State{state | send_timer: send_timer}
  end
end
