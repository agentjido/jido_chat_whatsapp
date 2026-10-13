defmodule Jido.Chat.WhatsApp.Transport.AmarulaClient do
  @moduledoc """
  Default WhatsApp transport backed by `Amarula`.

  Loads Amarula's installed modules before reading persisted protocol records so
  safe term decoders recognize their atoms and structs even in a fresh VM.

  Authenticated identity reads the supplied connection's state and `me` fields
  with one-second call deadlines. Raw credentials remain inside this boundary.
  Only PN/LID aliases and an optional account name are returned; Amarula may not
  learn the name with history disabled. Identity reads never change history flags.
  """

  @behaviour Jido.Chat.WhatsApp.Transport

  require Logger

  alias Amarula.Protocol.Auth.QRCodeGenerator
  alias Amarula.Protocol.Socket.ConnectionSupervisor
  alias Jido.Chat.WhatsApp.Transport.{GuardedStorage, MediaReference}
  alias Jido.Chat.WhatsApp.{AccountIdentity, Message}

  @identity_call_timeout 1_000

  @impl true
  def media_reference(conn, media) do
    with {:ok, secret, profile} <- media_reference_identity(conn) do
      MediaReference.seal(media, secret, profile)
    end
  end

  @impl true
  def resolve_media_reference(conn, reference) do
    with {:ok, secret, profile} <- media_reference_identity(conn) do
      MediaReference.open(reference, secret, profile)
    end
  end

  # Read the stable identity, not evolving Signal session records. The derived
  # key is used only inside Transport and no new persistence writes are needed.
  defp media_reference_identity(conn) do
    with %{profile: profile} when is_atom(profile) or is_binary(profile) <-
           GenServer.call(conn, :conn, @identity_call_timeout),
         %{signed_identity_key: %{private: secret}} when is_binary(secret) and byte_size(secret) == 32 <-
           GenServer.call(conn, :get_auth_creds, @identity_call_timeout),
         true <- profile not in [nil, ""] do
      {:ok, secret, to_string(profile)}
    else
      _ -> {:error, :media_reference_unavailable}
    end
  rescue
    _ -> {:error, :media_reference_unavailable}
  catch
    :exit, _ -> {:error, :media_reference_unavailable}
  end

  @impl true
  def user_phone(conn, jid) when is_binary(jid) do
    case Message.normalize_jids([jid]) do
      [normalized] ->
        address =
          if String.ends_with?(normalized, "@lid"),
            do: Amarula.Contacts.pn_for_lid(conn, normalized),
            else: normalized

        pn = if is_struct(address, Amarula.Address), do: Amarula.Address.to_jid!(address), else: address
        {:ok, phone_from_jid(pn)}

      _ ->
        {:error, :invalid_user}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def user_phone(_, _), do: {:error, :invalid_user}

  defp phone_from_jid(jid) when is_binary(jid) do
    case Regex.run(~r/^([0-9]+)@s\.whatsapp\.net$/, jid) do
      [_, number] -> "+" <> number
      _ -> nil
    end
  end

  defp phone_from_jid(_), do: nil

  @impl true
  def account_jids(conn) do
    with {:ok, me} <- account_me(conn) do
      {:ok, Message.normalize_jids([me[:id], me[:lid]])}
    end
  end

  @impl true
  def account_identity(conn) do
    with :connected <- GenServer.call(conn, :get_connection_state, @identity_call_timeout),
         {:ok, me} <- account_me(conn) do
      AccountIdentity.normalize(%{account_jids: [me[:id], me[:lid]], display_name: me[:name]})
    else
      {:error, :timeout} -> {:error, :timeout}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  # Raw credentials stay inside this transport and are never returned to callers.
  defp account_me(conn) do
    me = conn |> GenServer.call(:get_auth_creds, @identity_call_timeout) |> Map.get(:me)
    {:ok, if(is_map(me), do: Map.take(me, [:id, :lid, :name]), else: %{})}
  rescue
    _ -> {:error, :identity_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :identity_unavailable}
  end

  @impl true
  def ensure_started(_opts) do
    case Process.whereis(Amarula.Supervisor) do
      nil -> start_supervisor()
      _pid -> :ok
    end
  end

  @impl true
  def connect(config, opts) when is_map(config) and is_list(opts) do
    with :ok <- validate_profile(config),
         :ok <- load_protocol_modules(),
         {:ok, built} <- build_connection(config, opts),
         {:ok, pid} <-
           make_socket(built, Keyword.put(opts, :parent_pid, opts[:parent] || opts[:parent_pid] || self()), 20) do
      finish_connect(pid)
    end
  rescue
    _ -> {:error, :connection_failed}
  catch
    :exit, _ -> {:error, :connection_failed}
  end

  @impl true
  def stop({:via, Registry, {Amarula.InstanceRegistry, {instance, :connection}}}, _opts) do
    case ConnectionSupervisor.stop_instance(instance) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, _ -> {:error, :stop_failed}
  end

  def stop(conn, _opts) do
    case GenServer.whereis(conn) do
      nil -> :ok
      pid -> Amarula.stop(pid)
    end
  catch
    :exit, _ -> {:error, :stop_failed}
  end

  @impl true
  def logout(conn, _opts) do
    with :ok <- Amarula.wipe_credentials(conn), do: stop(conn, [])
  catch
    :exit, _ -> {:error, :logout_failed}
  end

  @impl true
  def health(conn) do
    case Amarula.Connection.get_conn(conn).storage do
      %{adapter: GuardedStorage, state: state} ->
        if GuardedStorage.healthy?(state), do: :ok, else: {:error, :storage_failed}

      _ ->
        :ok
    end
  catch
    :exit, _ -> {:error, :connection_unavailable}
  end

  defp validate_profile(%{profile: profile}) when is_binary(profile) do
    if profile not in ["", ".", ".."] and not String.contains?(profile, ["/", "\\", <<0>>]),
      do: :ok,
      else: {:error, :invalid_profile}
  end

  defp validate_profile(%{profile: profile}) when is_atom(profile) and not is_nil(profile),
    do: validate_profile(%{profile: Atom.to_string(profile)})

  defp validate_profile(_), do: {:error, :missing_profile}

  defp load_protocol_modules do
    with result when result in [:ok, {:error, {:already_loaded, :amarula}}] <- Application.load(:amarula),
         :ok <- Code.ensure_all_loaded(Application.spec(:amarula, :modules)) do
      :ok
    else
      _ -> {:error, :connection_failed}
    end
  end

  defp build_connection(config, opts) do
    config =
      case Map.get(config, :storage) do
        nil ->
          case Map.get(config, :storage_root) do
            nil -> config
            root -> Map.put(config, :storage, {Amarula.Storage.File, root: root})
          end

        storage ->
          Map.put(config, :storage, {GuardedStorage, storage: storage, notify: opts[:parent] || opts[:parent_pid]})
      end

    conn = Amarula.new(config)
    # Fail before spawning the protocol tree on unreadable custom credentials.
    _ = Amarula.Storage.get(conn.storage, conn.profile, :creds, :self)
    {:ok, conn}
  end

  # Registry removes dead owners asynchronously after supervisor shutdown. Never
  # adopt or stop a live duplicate; only wait for a dead registration to disappear.
  defp make_socket(conn, opts, retries) do
    case Amarula.Connection.make_socket(conn, opts) do
      {:error, {:already_running, pid}} = error when retries > 0 ->
        if Process.alive?(pid) do
          error
        else
          Process.sleep(1)
          make_socket(conn, opts, retries - 1)
        end

      result ->
        result
    end
  end

  defp finish_connect(pid) do
    instance = GenServer.call(pid, :instance_id)
    server = ConnectionSupervisor.name(instance, :connection)

    case open_socket(pid) do
      :ok ->
        {:ok, server}

      {:error, _} ->
        stop(server, [])
        {:error, :connection_failed}
    end
  end

  defp open_socket(pid) do
    Amarula.Connection.connect(pid)
  catch
    :exit, _ -> {:error, :connection_failed}
  end

  @impl true
  def render_qr(qr, _opts) when is_binary(qr), do: QRCodeGenerator.render_terminal(qr)

  @impl true
  def resolve_conn(opts) when is_list(opts) do
    cond do
      conn = Keyword.get(opts, :conn) ->
        {:ok, conn}

      conn = Keyword.get(opts, :connection) ->
        {:ok, conn}

      profile = configured_profile(opts) ->
        resolve_profile(profile)

      true ->
        {:error, :missing_profile}
    end
  end

  @impl true
  def send_text(conn, jid, text, opts) do
    Amarula.send_text(conn, jid, text, opts)
  rescue
    exception ->
      Logger.warning("WhatsApp send_text failed: #{Exception.message(exception)}")
      {:error, exception}
  catch
    kind, reason ->
      Logger.warning("WhatsApp send_text failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @impl true
  def send_media(conn, jid, media_type, data, opts) do
    Amarula.send_media(conn, jid, media_type, data, opts)
  rescue
    exception ->
      Logger.warning("WhatsApp send_media failed: #{Exception.message(exception)}")
      {:error, exception}
  catch
    kind, reason ->
      Logger.warning("WhatsApp send_media failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @impl true
  def download_media(media) do
    Amarula.download_media(media)
  rescue
    exception ->
      Logger.warning("WhatsApp download_media failed: #{Exception.message(exception)}")
      {:error, exception}
  catch
    kind, reason ->
      Logger.warning("WhatsApp download_media failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @impl true
  def send_reaction(conn, message_ref, emoji), do: Amarula.send_reaction(conn, message_ref, emoji)

  @impl true
  def send_edit(conn, message_ref, text), do: Amarula.send_edit(conn, message_ref, text)

  @impl true
  def send_revoke(conn, message_ref), do: Amarula.send_revoke(conn, message_ref)

  @impl true
  def send_chatstate(conn, jid, state), do: Amarula.send_chatstate(conn, jid, state)

  @impl true
  def request_pairing_code(conn, phone, opts), do: Amarula.request_pairing_code(conn, phone, opts)

  defp start_supervisor do
    case Amarula.Supervisor.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_profile(profile) do
    case Amarula.whereis(profile) do
      nil -> {:error, :connection_not_running}
      _pid -> {:ok, Amarula.via(profile)}
    end
  rescue
    RuntimeError -> {:error, :connection_not_running}
  end

  defp configured_profile(opts) do
    Keyword.get(opts, :profile) ||
      Application.get_env(:jido_chat_whatsapp, :profile) ||
      Application.get_env(:jido_chat_whatsapp, :whatsapp_profile)
  end
end
