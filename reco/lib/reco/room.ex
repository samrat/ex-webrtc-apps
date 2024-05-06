defmodule Example.Pipeline do
  use Membrane.Pipeline

  alias Membrane.WebRTC

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      [
        child(:webrtc, %WebRTC.Source{
          signaling: opts[:signaling_channel]
        }),
        child(:matroska, Membrane.Matroska.Muxer),
        get_child(:webrtc)
        |> via_out(:output, options: [kind: :audio])
        |> child(Membrane.Opus.Parser)
        |> get_child(:matroska),
        get_child(:webrtc)
        |> via_out(:output, options: [kind: :video])
        |> get_child(:matroska),
        get_child(:matroska)
        |> child(:sink, %Membrane.File.Sink{location: "recording.mkv"})
      ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_element_end_of_stream(:sink, :input, _ctx, state) do
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end
end


defmodule Reco.Room do
  use GenServer, restart: :temporary

  require Logger

  alias ExWebRTC.{ICECandidate, PeerConnection, SessionDescription}
  alias ExWebRTC.RTP.VP8Depayloader

  @max_session_time_s Application.compile_env!(:reco, :max_session_time_s)
  @session_time_timer_interval_ms 1_000

  defp id(room_id), do: {:via, Registry, {Reco.RoomRegistry, room_id}}

  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: id(room_id))
  end

  def connect(room_id, channel_pid) do
    GenServer.call(id(room_id), {:connect, channel_pid})
  end

  def receive_signaling_msg(room_id, msg) do
    GenServer.cast(id(room_id), {:receive_signaling_msg, msg})
  end

  def stop(room_id) do
    GenServer.stop(id(room_id), :shutdown)
  end

  @impl true
  def init(room_id) do
    Logger.info("Starting room: #{room_id}")
    Process.send_after(self(), :session_time, @session_time_timer_interval_ms)

    signaling_channel = Membrane.WebRTC.SignalingChannel.new()
    {:ok, supervisor, _pipeline} = Membrane.Pipeline.start(Example.Pipeline, signaling_channel: signaling_channel)
    Membrane.WebRTC.SignalingChannel.register_peer(signaling_channel, message_format: :json_data)

    Process.monitor(supervisor)

    {:ok,
     %{
       id: room_id,
       pc: nil,
       channel: nil,
       task: nil,
       session_start_time: System.monotonic_time(:millisecond),
       signaling_channel: signaling_channel
     }}
  end

  @impl true
  def handle_call({:connect, channel_pid}, _from, %{channel: nil} = state) do
    Process.monitor(channel_pid)
    {:ok, pc} = PeerConnection.start_link()

    state =
      state
      |> Map.put(:channel, channel_pid)
      |> Map.put(:pc, pc)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:connect, _channel_pid}, _from, state) do
    {:reply, {:error, :already_connected}, state}
  end

  @impl true
  def handle_cast({:receive_signaling_msg, msg}, state) do
    IO.inspect("Received signaling message: #{inspect(msg)}")
    Membrane.WebRTC.SignalingChannel.signal(state.signaling_channel, Jason.decode!(msg))

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if pid != state.channel do
      {:noreply, state}
    else
      Logger.info("Shutting down room as peer left")
      {:stop, :shutdown, state}
    end
  end

  @impl true
  def handle_info(:session_time, state) do
    Process.send_after(self(), :session_time, @session_time_timer_interval_ms)
    now = System.monotonic_time(:millisecond)
    duration = floor((now - state.session_start_time) / 1000)

    rem_time = max(0, @max_session_time_s - duration)

    if state.channel != nil do
      send(state.channel, {:session_time, rem_time})
    end

    if duration >= @max_session_time_s do
      if state.channel != nil do
        send(state.channel, :session_expired)
      end

      Logger.info("Session expired. Shutting down the room.")
      {:stop, {:shutdown, :session_expired}, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({Membrane.WebRTC.SignalingChannel, _pid, msg}, state) do
    IO.inspect("Sending signaling message: #{inspect(msg)}")
    send(state.channel, {:signaling, msg})
    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, predicitons}, state) do
    send(state.channel, {:img_reco, predicitons})
    state = %{state | task: nil}
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
