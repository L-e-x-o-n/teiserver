defmodule Teiserver.Matchmaking.PairingRoom do
  @moduledoc """
  This module handles all the interactions between players that have been
  matched for a game.
  It is responsible to kick off the start of the match when everyone is
  ready.
  """

  # Use a temporary restart strategy. Because there is no real way to recover
  # from a crash, the important transient state would be lost.
  use GenServer, restart: :temporary

  # import Teiserver.Matchmaking.QueueServer, only:
  alias Teiserver.Matchmaking.QueueServer
  alias Teiserver.Data.Types, as: T

  require Logger

  @type team :: [QueueServer.member()]
  @type lost_reason :: :cancel | :timeout | {:server_error, term()}
  @type ready_data :: %{
          user_id: T.userid(),
          name: String.t(),
          password: String.t()
        }

  @spec start(QueueServer.id(), QueueServer.queue(), [team()], timeout()) ::
          {:ok, pid()} | {:error, term()}
  def start(queue_id, queue, teams, timeout) do
    GenServer.start(__MODULE__, {queue_id, queue, teams, timeout})
  end

  @doc """
  to tell the room that the given player is ready for the match
  """
  @spec ready(pid(), ready_data()) :: :ok | {:error, :no_match}
  def ready(room_pid, ready_data) do
    GenServer.call(room_pid, {:ready, ready_data})
  end

  @spec cancel(pid(), T.userid()) :: :ok
  def cancel(room_pid, user_id) do
    GenServer.cast(room_pid, {:cancel, user_id})
  catch
    # If the pairing room is gone, there's no need to cancel anymore
    :exit, _ -> :ok
  end

  # TODO tachyon_mvp: transform this state into a simple state machine when
  # adding the step to setup the match (finding host and sending start script
  # to every player)
  @type state :: %{
          queue_id: QueueServer.id(),
          queue: QueueServer.queue(),
          teams: [team(), ...],
          awaiting: [T.userid()],
          # holds data from players that have readied up, in a format to be used to
          # create the start script. Maintain the same structure as `teams` but
          # the players for members are flatten
          readied: [[%{user_id: T.userid(), name: String.t(), password: String.t()}], ...]
        }

  @impl true
  def init({queue_id, queue, teams, timeout}) do
    Logger.metadata(queue_id: queue_id)

    initial_state =
      %{
        queue_id: queue_id,
        queue: queue,
        teams: teams,
        awaiting:
          Enum.flat_map(teams, fn team ->
            Enum.flat_map(team, fn member -> member.player_ids end)
          end),
        readied:
          for team <- teams do
            Enum.flat_map(team, fn member ->
              for p_id <- member.player_ids do
                %{user_id: p_id}
              end
            end)
          end
      }

    Logger.debug("Pairing room for players " <> Enum.join(initial_state.awaiting, ","))

    {:ok, initial_state, {:continue, {:notify_players, timeout}}}
  end

  @impl true
  # Let all the player know that they are now ready to start a match and should
  # ready up asap
  def handle_continue({:notify_players, timeout}, state) do
    Enum.each(state.awaiting, fn player_id ->
      Teiserver.Player.matchmaking_notify_found(player_id, state.queue_id, self(), timeout)
    end)

    :timer.send_after(timeout, :timeout)

    {:noreply, state}
  end

  # It's go time! Find an autohost, send it the start script and let all the players
  # know about the autohost waiting for them.
  def handle_continue(:start_match, state) do
    case Teiserver.Autohost.find_autohost() do
      nil ->
        Logger.warning("No autohost available to start a paired matchmaking")

        QueueServer.disband_pairing(state.queue_id, self())

        for team <- state.teams, member <- team, p_id <- member.player_ids do
          Teiserver.Player.matchmaking_notify_lost(p_id, {:server_error, :no_host_available})
        end

        {:stop, :normal, state}

      id ->
        engine = select_engine(state.queue.engines)
        %{spring_game: game} = select_game(state.queue.games)
        %{spring_name: map} = select_map(state.queue.maps)

        start_battle(state, id, engine, game, map)
    end
  end

  defp start_battle(state, host_id, engine, game, map) do
    start_script = start_script(state, engine, game, map)

    case Teiserver.TachyonBattle.start_battle(host_id, start_script) do
      {:error, reason} ->
        QueueServer.disband_pairing(state.queue_id, self())

        for team <- state.teams, member <- team, p_id <- member.player_ids do
          Teiserver.Player.matchmaking_notify_lost(p_id, {:server_error, reason})
        end

        {:stop, :normal, state}

      {:ok, host_data} ->
        QueueServer.disband_pairing(state.queue_id, self())

        ids =
          for team <- state.teams, member <- team, p_id <- member.player_ids do
            p_id
          end

        Logger.debug("Pairing completed for players " <> Enum.join(ids, ","))

        battle_start_data =
          host_data
          |> Map.put(:engine, engine)
          |> Map.put(:game, %{springName: game})
          |> Map.put(:map, %{springName: map})

        for team <- state.teams, member <- team, p_id <- member.player_ids do
          Teiserver.Player.battle_start(p_id, battle_start_data)
        end

        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:ready, ready_data}, _from, state) do
    user_id = ready_data.user_id

    case Enum.split_with(state.awaiting, fn waiting_id -> waiting_id == user_id end) do
      {[], _} ->
        {:reply, {:error, :no_match}, state}

      # TODO tachyon_mvp: if no more player is waiting, starts the game
      {[_], rest} ->
        max = state.queue.team_count * state.queue.team_size
        current = max - Enum.count(rest)

        for team <- state.teams, member <- team, p_id <- member.player_ids do
          Teiserver.Player.matchmaking_found_update(p_id, current, self())
        end

        readied =
          for team <- state.readied do
            for player <- team do
              if player.user_id == user_id do
                ready_data
              else
                player
              end
            end
          end

        new_state = %{state | awaiting: rest, readied: readied}

        case rest do
          [] -> {:reply, :ok, new_state, {:continue, :start_match}}
          _ -> {:reply, :ok, new_state}
        end
    end
  end

  @impl true
  def handle_cast({:cancel, user_id}, state) do
    # Assuming that the call is legit, so don't check that user_id is indeed
    # in the room and directly cancel everyone
    QueueServer.disband_pairing(state.queue_id, self())

    for team <- state.teams, member <- team, p_id <- member.player_ids, p_id != user_id do
      Teiserver.Player.matchmaking_notify_lost(p_id, :cancel)
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:timeout, state) when state.awaiting == [], do: {:noreply, state}

  def handle_info(:timeout, state) do
    QueueServer.disband_pairing(state.queue_id, self())

    for team <- state.teams, member <- team, player_id <- member.player_ids do
      Teiserver.Player.matchmaking_notify_lost(player_id, :timeout)
    end

    {:stop, :normal, state}
  end

  @spec start_script(state(), %{version: String.t()}, String.t(), String.t()) ::
          Teiserver.TachyonBattle.start_script()
  defp start_script(state, engine, game, map) do
    %{
      engineVersion: engine.version,
      gameName: game,
      mapName: map,
      startPosType: :ingame,
      allyTeams: get_ally_teams(state)
    }
  end

  @spec get_ally_teams(state()) :: [Teiserver.Autohost.ally_team(), ...]
  defp get_ally_teams(state) do
    for team <- state.readied do
      teams =
        for player <- team do
          player = player |> Map.drop([:user_id]) |> Map.put(:userId, to_string(player.user_id))
          %{players: [player]}
        end

      %{teams: teams}
    end
  end

  # TODO implement some smarter engine/game selection logic here in the future, get first for now
  @spec select_engine([%{version: String.t()}]) :: %{version: String.t()}
  def select_engine(engines) do
    Enum.at(engines, 0)
  end

  @spec select_game([%{spring_game: String.t()}]) :: %{spring_game: String.t()}
  def select_game(games) do
    Enum.at(games, 0)
  end

  @spec select_map([Teiserver.Asset.Map.t()]) :: Teiserver.Asset.Map.t()
  def select_map(maps) do
    Enum.random(maps)
  end
end
