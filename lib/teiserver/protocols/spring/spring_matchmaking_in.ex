defmodule Teiserver.Protocols.Spring.MatchmakingIn do
  alias Teiserver.Data.Matchmaking
  alias Teiserver.{Coordinator}
  alias Teiserver.Protocols.SpringIn
  import Teiserver.Protocols.SpringOut, only: [reply: 5]
  import Central.Helpers.NumberHelper, only: [int_parse: 1]
  require Logger

  @spec do_handle(String.t(), String.t(), String.t() | nil, Map.t()) :: Map.t()
  def do_handle("list_all_queues", _, msg_id, state) do
    queues = Matchmaking.list_queues()
    reply(:matchmaking, :full_queue_list, queues, msg_id, state)
  end

  def do_handle("list_my_queues", _, msg_id, state) do
    queues = Matchmaking.list_queues(state.queues)
    reply(:matchmaking, :your_queue_list, queues, msg_id, state)
  end

  def do_handle("get_queue_info", queue_id, msg_id, state) do
    queue_id = int_parse(queue_id)
    {queue, info} = Matchmaking.get_queue_and_info(queue_id)
    reply(:matchmaking, :queue_info, {queue, info}, msg_id, state)
  end

  def do_handle("join_queue", queue_id, msg_id, state) do
    queue_id = int_parse(queue_id)
    resp = Matchmaking.add_player_to_queue(queue_id, state.userid)

    joined =
      case resp do
        :ok -> true
        :duplicate -> true
        :failed -> false
      end

    case joined do
      true ->
        new_state = %{state | queues: Enum.uniq([queue_id | state.queues])}
        reply(:spring, :okay, "c.matchmaking.join_queue\t#{queue_id}", msg_id, new_state)

      false ->
        reply(:spring, :no, {"c.matchmaking.join_queue", "#{queue_id}"}, msg_id, state)
    end
  end

  def do_handle("leave_queue", queue_id, _msg_id, state) do
    queue_id = int_parse(queue_id)
    Matchmaking.remove_player_from_queue(queue_id, state.userid)
    %{state | queues: List.delete(state.queues, queue_id)}
  end

  def do_handle("leave_all_queues", _msg, _msg_id, state) do
    state.queues
    |> Enum.each(fn queue_id ->
      Matchmaking.remove_player_from_queue(queue_id, state.userid)
    end)

    %{state | queues: []}
  end

  def do_handle("ready", _msg, _msg_id, state) do
    case state.ready_queue_id do
      nil ->
        state

      queue_id ->
        Matchmaking.player_accept(queue_id, state.userid)
        state
    end
  end

  def do_handle("decline", _msg, _msg_id, state) do
    case state.ready_queue_id do
      nil ->
        state

      queue_id ->
        Matchmaking.player_decline(queue_id, state.userid)

        # Player has declined to ready up, remove them from all other queues
        do_handle("leave_all_queues", nil, nil, state)
    end
  end

  # Beherith is a moron (BIAM) command, this is not meant to be in spring matchmaking
  def do_handle("update", "TEifionisgonnakillme " <> json_str, _msg_id, state) do
    case Jason.decode(json_str) do
      {:ok, data} ->
        host_data = %{
          # host_boss: User.get_userid(data["boss"]),
          host_teamsize: data["teamSize"] |> int_parse,
          host_teamcount: data["nbTeams"] |> int_parse
        }
        Coordinator.cast_consul(state.lobby_id, {:host_update, state.userid, host_data})
      v ->
        Logger.error("BIAM instruction error #{Kernel.inspect v}, tried to decode #{json_str}")
    end
    state
  end

  def do_handle(cmd, data, msg_id, state) do
    SpringIn._no_match(state, "c.matchmaking." <> cmd, msg_id, data)
  end
end
