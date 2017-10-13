defmodule Commanded.ProcessManager.ProcessManagerErrorHandlingTest do
  use Commanded.StorageCase

  defmodule ExampleAggregate do
    @moduledoc false
    defstruct [:process_uuid]

    defmodule Commands do
      defmodule StartProcess, do: defstruct [:process_uuid, :strategy, :delay, :reply_to]
      defmodule AttemptProcess, do: defstruct [:process_uuid, :strategy, :delay, :reply_to]
    end

    defmodule Events do
      defmodule ProcessStarted, do: defstruct [:process_uuid, :strategy, :delay, :reply_to]
    end

    alias Commands.{StartProcess,AttemptProcess}
    alias Events.ProcessStarted

    def execute(
      %ExampleAggregate{},
      %StartProcess{process_uuid: process_uuid, strategy: strategy, delay: delay, reply_to: reply_to})
    do
      %ProcessStarted{process_uuid: process_uuid, strategy: strategy, delay: delay, reply_to: reply_to}
    end

    def execute(%ExampleAggregate{}, %AttemptProcess{}), do: {:error, :failed}

    def apply(%ExampleAggregate{} = aggregate, %ProcessStarted{}), do: aggregate
  end

  alias ExampleAggregate.Commands.{StartProcess,AttemptProcess}
  alias ExampleAggregate.Events.ProcessStarted

  defmodule ExampleRouter do
    @moduledoc false
    use Commanded.Commands.Router

    dispatch [StartProcess,AttemptProcess],
      to: ExampleAggregate, identity: :process_uuid
  end

  defmodule ErrorHandlingProcessManager do
    @moduledoc false
    use Commanded.ProcessManagers.ProcessManager,
      name: "ErrorHandlingProcessManager",
      router: ExampleRouter

    defstruct [:process_uuid]

    def interested?(%ProcessStarted{process_uuid: process_uuid}), do: {:start, process_uuid}

    def handle(
      %ErrorHandlingProcessManager{},
      %ProcessStarted{process_uuid: process_uuid, strategy: strategy, delay: delay, reply_to: reply_to})
    do
      %AttemptProcess{process_uuid: process_uuid, strategy: strategy, delay: delay, reply_to: reply_to}
    end

    # stop after three attempts
    def error({:error, :failed}, %AttemptProcess{strategy: :retry, reply_to: reply_to}, %{attempts: attempts} = context)
      when attempts >= 2
    do
      send(reply_to, {:error, :too_many_attempts, record_attempt(context)})

      {:stop, :too_many_attempts}
    end

    # retry command with delay
    def error({:error, :failed}, %AttemptProcess{strategy: :retry, delay: delay} = command, context)
      when is_integer(delay)
    do
      context = record_attempt(context)
      send_failure(command, Map.put(context, :delay, delay))

      {:retry, delay, context}
    end

    # retry command
    def error({:error, :failed}, %AttemptProcess{strategy: :retry} = command, context) do
      context = record_attempt(context)
      send_failure(command, context)

      {:retry, context}
    end

    # skip failed command, continue pending
    def error({:error, :failed}, %AttemptProcess{strategy: :skip, reply_to: reply_to}, context) do
      send(reply_to, {:error, :failed, record_attempt(context)})

      {:skip, :continue_pending}
    end

    defp record_attempt(context) do
      Map.update(context, :attempts, 1, fn attempts -> attempts + 1 end)
    end

    defp send_failure(%AttemptProcess{reply_to: reply_to}, context) do
      send(reply_to, {:error, :failed, context})
    end
  end

  test "should retry the event until process manager requests stop" do
    process_uuid = UUID.uuid4()
    command = %StartProcess{process_uuid: process_uuid, strategy: :retry, reply_to: self()}

    {:ok, process_router} = ErrorHandlingProcessManager.start_link()

    Process.unlink(process_router)
    ref = Process.monitor(process_router)

    assert :ok = ExampleRouter.dispatch(command)

    assert_receive {:error, :failed, %{attempts: 1}}
    assert_receive {:error, :failed, %{attempts: 2}}
    assert_receive {:error, :too_many_attempts, %{attempts: 3}}

    # should shutdown process router
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  test "should retry event with specified delay between attempts" do
    process_uuid = UUID.uuid4()
    command = %StartProcess{process_uuid: process_uuid, strategy: :retry, delay: 10, reply_to: self()}

    {:ok, process_router} = ErrorHandlingProcessManager.start_link()

    Process.unlink(process_router)
    ref = Process.monitor(process_router)

    assert :ok = ExampleRouter.dispatch(command)

    assert_receive {:error, :failed, %{attempts: 1, delay: 10}}
    assert_receive {:error, :failed, %{attempts: 2, delay: 10}}
    assert_receive {:error, :too_many_attempts, %{attempts: 3}}

    # should shutdown process router
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  test "should skip the event when process manager requests" do
    process_uuid = UUID.uuid4()
    command = %StartProcess{process_uuid: process_uuid, strategy: :skip, reply_to: self()}

    {:ok, process_router} = ErrorHandlingProcessManager.start_link()

    assert :ok = ExampleRouter.dispatch(command)

    assert_receive {:error, :failed, %{attempts: 1}}
    refute_receive {:error, :failed, %{attempts: 2}}

    # should not shutdown process router
    assert Process.alive?(process_router)
  end

  defmodule DefaultErrorHandlingProcessManager do
    @moduledoc false
    use Commanded.ProcessManagers.ProcessManager,
      name: "DefaultErrorHandlingProcessManager",
      router: ExampleRouter

    defstruct [:process_uuid]

    def interested?(%ProcessStarted{process_uuid: process_uuid}), do: {:start, process_uuid}

    def handle(%ErrorHandlingProcessManager{}, %ProcessStarted{process_uuid: process_uuid}) do
      %AttemptProcess{process_uuid: process_uuid}
    end
  end

  test "should stop process manager on error by default" do
    process_uuid = UUID.uuid4()
    command = %StartProcess{process_uuid: process_uuid}

    {:ok, process_router} = ErrorHandlingProcessManager.start_link()

    Process.unlink(process_router)
    ref = Process.monitor(process_router)

    assert :ok = ExampleRouter.dispatch(command)

    # should shutdown process router
    assert_receive {:DOWN, ^ref, _, _, _}
    refute Process.alive?(process_router)
  end
end
