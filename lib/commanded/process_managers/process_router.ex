defmodule Commanded.ProcessManagers.ProcessRouter do
  @moduledoc """
  Process router is responsible for starting, continuing and completing process managers in response to raised domain events.
  """

  use GenServer
  require Logger

  alias Commanded.ProcessManagers.{ProcessManagerInstance,Supervisor}

  defmodule State do
    defstruct [
      process_manager_name: nil,
      process_manager_module: nil,
      command_dispatcher: nil,
      process_managers: %{},
      supervisor: nil,
      last_seen_event_id: nil,
      pending_events: [],
      subscription: nil,
    ]
  end

  def start_link(process_manager_name, process_manager_module, command_dispatcher) do
    GenServer.start_link(__MODULE__, %State{
      process_manager_name: process_manager_name,
      process_manager_module: process_manager_module,
      command_dispatcher: command_dispatcher
    })
  end

  def init(%State{command_dispatcher: command_dispatcher} = state) do
    {:ok, supervisor} = Supervisor.start_link(command_dispatcher)

    state = %State{state | supervisor: supervisor}

    GenServer.cast(self, {:subscribe_to_events})

    {:ok, state}
  end

  @doc """
  Acknowlegde successful handling of the given event id by a process manager instance
  """
  def ack_event(process_router, event_id) when is_integer(event_id) do
    GenServer.cast(process_router, {:ack_event, event_id})
  end

  @doc """
  Fetch the state of an individual process manager instance identified by the given `process_uuid`
  """
  def process_state(process_router, process_uuid) do
    GenServer.call(process_router, {:process_state, process_uuid})
  end

  def handle_call({:process_state, process_uuid}, _from, %State{process_managers: process_managers} = state) do
    reply = case Map.get(process_managers, process_uuid) do
      nil -> {:error, :process_manager_not_found}
      process_manager -> ProcessManagerInstance.process_state(process_manager)
    end

    {:reply, reply, state}
  end

  @doc """
  Subscribe the process router to all events
  """
  def handle_cast({:subscribe_to_events}, %State{process_manager_name: process_manager_name} = state) do
    {:ok, _} = EventStore.subscribe_to_all_streams(process_manager_name, self)
    {:noreply, state}
  end

  def handle_cast({:ack_event, event_id}, %State{} = state) do
    confirm_receipt(state, event_id)

    # continue processing any pending events
    GenServer.cast(self, {:process_pending_events})

    {:noreply, state}
  end

  def handle_cast({:process_pending_events}, %State{pending_events: []} = state), do: {:noreply, state}
  def handle_cast({:process_pending_events}, %State{pending_events: [event | pending_events]} = state) do
    state = handle_event(event, state)

    {:noreply, %State{state | pending_events: pending_events}}
  end

  def handle_info({:events, events, subscription}, %State{process_manager_name: process_manager_name, pending_events: pending_events} = state) do
    Logger.debug(fn -> "process router \"#{process_manager_name}\" received events: #{inspect events}" end)

    unseen_events = Enum.filter(events, fn event -> !already_seen_event?(event, state) end)

    GenServer.cast(self, {:process_pending_events})

    {:noreply, %State{state | pending_events: pending_events ++ unseen_events, subscription: subscription}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %State{process_managers: process_managers} = state) do
    Logger.warn(fn -> "process manager process down due to: #{inspect reason}" end)

    {:noreply, %State{state | process_managers: remove_process_manager(process_managers, pid)}}
  end

  # ignore already seen event
  defp already_seen_event?(%EventStore.RecordedEvent{event_id: event_id} = event, %State{last_seen_event_id: last_seen_event_id})
  when not is_nil(last_seen_event_id) and event_id <= last_seen_event_id
  do
    Logger.debug(fn -> "process manager has already seen event: #{inspect event}" end)
    true
  end
  defp already_seen_event?(_event, _state), do: false

  defp handle_event(%EventStore.RecordedEvent{data: data, event_id: event_id} = event, %State{process_manager_module: process_manager_module, process_managers: process_managers} = state) do
    {process_uuid, process_manager} = case process_manager_module.interested?(data) do
      {:start, process_uuid} -> {process_uuid, start_process_manager(process_uuid, state)}
      {:continue, process_uuid} -> {process_uuid, continue_process_manager(process_uuid, state)}
      false -> {nil, nil}
    end

    case process_uuid do
      nil ->
        # no process instance, just confirm receipt of event
        confirm_receipt(state, event_id)
      _ ->
        # delegate event to process instance who will ack event processing on success
        :ok = delegate_event(process_manager, event)

        %State{state | process_managers: Map.put(process_managers, process_uuid, process_manager)}
    end
  end

  # confirm receipt of given event
  defp confirm_receipt(%State{process_manager_name: process_manager_name, subscription: subscription} = state, event_id) do
    Logger.debug(fn -> "process router \"#{process_manager_name}\" confirming receipt of event: #{event_id}" end)

    send(subscription, {:ack, event_id})

    %State{state | last_seen_event_id: event_id}
  end

  defp start_process_manager(process_uuid, %State{process_manager_name: process_manager_name, process_manager_module: process_manager_module, supervisor: supervisor}) do
    {:ok, process_manager} = Supervisor.start_process_manager(supervisor, process_manager_name, process_manager_module, process_uuid)
    Process.monitor(process_manager)
    process_manager
  end

  defp continue_process_manager(process_uuid, %State{process_managers: process_managers} = state) do
    case Map.get(process_managers, process_uuid) do
      nil -> start_process_manager(process_uuid, state)
      process_manager -> process_manager
    end
  end

  defp remove_process_manager(process_managers, pid) do
    Enum.reduce(process_managers, process_managers, fn
      ({process_uuid, process_manager_pid}, acc) when process_manager_pid == pid -> Map.delete(acc, process_uuid)
      (_, acc) -> acc
    end)
  end

  defp delegate_event(nil, _event), do: :ok
  defp delegate_event(process_manager, %EventStore.RecordedEvent{} = event) do
    ProcessManagerInstance.process_event(process_manager, event, self)
  end
end