defmodule Teiserver.Protocols.Tachyon.V1.MatchmakingIn do
  # alias Teiserver.Client
  alias Teiserver.Data.Matchmaking
  import Teiserver.Protocols.Tachyon.V1.TachyonOut, only: [reply: 4]
  import Central.Helpers.NumberHelper, only: [int_parse: 1]

  @spec do_handle(String.t(), Map.t(), Map.t()) :: Map.t()
  def do_handle("query", %{"query" => _query}, state) do
    queues = Matchmaking.list_queues()
    reply(:matchmaking, :query, queues, state)
  end

  def do_handle("list_my_queues", _, state) do
    queues = Matchmaking.list_queues(state.queues)
    reply(:matchmaking, :your_queue_list, queues, state)
  end

  def do_handle("get_queue_info", %{"queue_id" => queue_id}, state) do
    queue_id = int_parse(queue_id)
    {queue, info} = Matchmaking.get_queue_and_info(queue_id)
    reply(:matchmaking, :queue_info, {queue, info}, state)
  end

  def do_handle("join_queue", %{"queue_id" => queue_id}, state) do
    queue_id = int_parse(queue_id)
    resp = Matchmaking.add_user_to_queue(queue_id, state.userid)

    joined =
      case resp do
        :ok -> true
        :duplicate -> true
        :failed -> false
        :missing -> false
      end

    case joined do
      true ->
        new_state = %{state | queues: Enum.uniq([queue_id | state.queues])}
        reply(:matchmaking, :join_queue_success, queue_id, new_state)

      false ->
        reason = case resp do
          :missing -> "No queue found"
          _ -> "Failure"
        end
        reply(:matchmaking, :join_queue_failure, {queue_id, reason}, state)
    end
  end

  def do_handle("leave_queue", %{"queue_id" => queue_id}, state) do
    queue_id = int_parse(queue_id)
    Matchmaking.remove_user_from_queue(queue_id, state.userid)
    %{state | queues: List.delete(state.queues, queue_id)}
  end

  def do_handle("leave_all_queues", _cmd, state) do
    state.queues
    |> Enum.each(fn queue_id ->
      Matchmaking.remove_user_from_queue(queue_id, state.userid)
    end)

    %{state | queues: []}
  end

  def do_handle("accept", %{"match_id" => match_id}, state) do
    Matchmaking.player_accept(match_id, state.userid)
    state
  end

  def do_handle("decline", %{"match_id" => match_id}, state) do
    Matchmaking.player_decline(match_id, state.userid)
    do_handle("leave_all_queues", nil, state)
  end

  # def do_handle(cmd, data, msg_id, state) do
  #   SpringIn._no_match(state, "c.matchmaking." <> cmd, msg_id, data)
  # end
end
