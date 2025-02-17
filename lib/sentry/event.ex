defmodule Sentry.Event do
  @moduledoc """
  Provides functions to create Sentry events from scratch, from exceptions, and so on.

  This module also contains the main event struct. Events are the fundamental data
  that clients send to the Sentry server.

  See <https://develop.sentry.dev/sdk/event-payloads>.
  """

  alias Sentry.{Config, Context, Interfaces, Sources, UUID}

  @sdk %Interfaces.SDK{
    name: "sentry-elixir",
    version: Mix.Project.config()[:version]
  }

  @typedoc """
  The level of an event.
  """
  @typedoc since: "9.0.0"
  @type level() :: :fatal | :error | :warning | :info | :debug

  @typedoc """
  The type for the event struct.

  All of the fields in this struct map directly to the fields described in the
  [Sentry documentation](https://develop.sentry.dev/sdk/event-payloads). These fields
  are the exceptions, and are specific to the Elixir Sentry SDK:

    * `:source` - the source of the event. `Sentry.LoggerBackend` and `Sentry.LoggerHandler`
      set this to `:logger`, while `Sentry.PlugCapture` and `Sentry.PlugContext` set it to
      `:plug`. You can set it to any atom. See the `:event_source` option in `create_event/1`
      and `transform_exception/2`.

    * `:original_exception` - the original exception that is being reported, if there's one.
      The Elixir Sentry SDK manipulates reported exceptions to make them fit the payload
      required by the Sentry API, and these end up in the `:exception` field. The
      `:original_exception` field, instead, contains the original exception as the raw Elixir
      term (such as `%RuntimeError{...}`).

  See also [`%Sentry.Event{}`](`__struct__/0`).
  """
  @type t() :: %__MODULE__{
          # Required
          event_id: <<_::256>>,
          timestamp: String.t() | number(),
          platform: :elixir,

          # Optional
          level: level() | nil,
          logger: String.t() | nil,
          transaction: String.t() | nil,
          server_name: String.t() | nil,
          release: String.t() | nil,
          dist: String.t() | nil,
          tags: %{optional(String.t()) => String.t()},
          environment: String.t() | nil,
          modules: %{optional(String.t()) => String.t()},
          extra: map(),
          fingerprint: [String.t()],

          # Interfaces.
          breadcrumbs: [Interfaces.Breadcrumb.t()],
          contexts: Interfaces.context(),
          exception: [Interfaces.Exception.t()],
          message: String.t() | nil,
          request: Interfaces.Request.t() | nil,
          sdk: Interfaces.SDK.t() | nil,
          user: Interfaces.user() | nil,

          # Non-payload fields.
          source: atom(),
          original_exception: Exception.t() | nil
        }

  @doc """
  The struct representing the event.

  You're not advised to manipulate this struct's fields directly. Instead,
  use functions such as `create_event/1` or `transform_exception/2` for creating
  events.

  See the `t:t/0` type for information on the fields and their types.
  """
  @enforce_keys [:event_id, :timestamp]
  defstruct [
    # Required. Hexadecimal string representing a uuid4 value. The length is exactly 32
    # characters. Dashes are not allowed. Has to be lowercase.
    event_id: nil,

    # Required. Indicates when the event was created in the Sentry SDK. The format is either a
    # string as defined in RFC 3339 or a numeric (integer or float) value representing the number
    # of seconds that have elapsed since the Unix epoch.
    timestamp: nil,

    # Optional fields.
    breadcrumbs: [],
    contexts: nil,
    dist: nil,
    environment: "production",
    exception: [],
    extra: %{},
    fingerprint: [],
    level: nil,
    logger: nil,
    message: nil,
    modules: %{},
    platform: :elixir,
    release: nil,
    request: %Interfaces.Request{},
    sdk: nil,
    server_name: nil,
    tags: %{},
    transaction: nil,
    user: %{},

    # "Culprit" is not documented anymore and we should move to transactions at some point.
    # https://forum.sentry.io/t/culprit-deprecated-in-favor-of-what/4871/9
    culprit: nil,

    # Non-payload "private" fields.
    source: nil,
    original_exception: nil
  ]

  # Removes all the non-payload keys from the event so that the client can render
  @doc false
  @spec remove_non_payload_keys(t()) :: map()
  def remove_non_payload_keys(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.drop([:original_exception, :source])
  end

  @doc """
  Creates an event struct out of collected context and options.

  > #### Merging Options with Context and Config {: .info}
  >
  > Some of the options documented below are **merged** with the Sentry context, or
  > with the Sentry context *and* the configuration. The option you pass here always
  > has higher precedence, followed by the context and finally by the configuration.
  >
  > See also `Sentry.Context` for information on the Sentry context and `Sentry` for
  > information on configuration.

  ## Options

    * `:exception` - an `t:Exception.t/0`. This is the exception that gets reported in the
      `:exception` field of `t:t/0`. The term passed here also ends up unchanged in the
      `:original_exception` field of `t:t/0`. This option is **required** unless the
      `:message` option is present. This is not present by default.

    * `:stacktrace` - a stacktrace, as in `t:Exception.stacktrace/0`. This is not present
      by default.

    * `:message` - a message (`t:String.t/0`). This is not present by default.

    * `:extra` - map of extra context, which gets merged with the current context
      (see `Sentry.Context.set_extra_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context. Defaults to `%{}`.

    * `:user` - map of user context, which gets merged with the current context
      (see `Sentry.Context.set_user_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context. Defaults to `%{}`.

    * `:tags` - map of tags context, which gets merged with the current context (see
      `Sentry.Context.set_tags_context/1`) and with the `:tags` option in the global
      Sentry configuration. If fields collide, the ones in the map passed through
      this option have precedence over the ones in the context, which have precedence
      over the ones in the configuration. Defaults to `%{}`.

    * `:request` - map of request context, which gets merged with the current context
      (see `Sentry.Context.set_request_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context. Defaults to `%{}`.

    * `:breadcrumbs` - list of breadcrumbs. This list gets **prepended** to the list
      in the context (see `Sentry.Context.add_breadcrumb/1`). Defaults to `[]`.

    * `:level` - error level (see `t:t/0`). Defaults to `:error`.

    * `:fingerprint` - list of the fingerprint for grouping this event (a list
      of `t:String.t/0`). Defaults to `["{{ default }}"]`.

    * `:event_source` - the source of the event. This fills in the `:source` field of the
      returned struct. This is not present by default.

  ## Examples

      iex> event = create_event(exception: %RuntimeError{message: "oops"}, level: :warning)
      iex> event.level
      :warning
      iex> hd(event.exception).type
      "RuntimeError"
      iex> event.original_exception
      %RuntimeError{message: "oops"}

      iex> event = create_event(message: "Unknown route", event_source: :plug)
      iex> event.source
      :plug

  """
  @spec create_event([option]) :: t()
        when option:
               {:user, Interfaces.user()}
               | {:request, map()}
               | {:extra, Context.extra()}
               | {:breadcrumbs, Context.breadcrumb()}
               | {:tags, Context.tags()}
               | {:level, level()}
               | {:fingerprint, [String.t()]}
               | {:message, String.t()}
               | {:event_source, atom()}
               | {:exception, Exception.t()}
               | {:stacktrace, Exception.stacktrace()}
  def create_event(opts) when is_list(opts) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)
      |> DateTime.to_iso8601()
      |> String.trim_trailing("Z")

    %{
      user: user_context,
      tags: tags_context,
      extra: extra_context,
      breadcrumbs: breadcrumbs_context,
      request: request_context
    } = Sentry.Context.get_all()

    level = Keyword.get(opts, :level, :error)
    fingerprint = Keyword.get(opts, :fingerprint, ["{{ default }}"])

    extra = Map.merge(extra_context, Keyword.get(opts, :extra, %{}))
    user = Map.merge(user_context, Keyword.get(opts, :user, %{}))
    request = Map.merge(request_context, Keyword.get(opts, :request, %{}))

    tags =
      Config.tags()
      |> Map.merge(tags_context)
      |> Map.merge(Keyword.get(opts, :tags, %{}))

    breadcrumbs =
      Keyword.get(opts, :breadcrumbs, [])
      |> Kernel.++(breadcrumbs_context)
      |> Enum.take(-1 * Config.max_breadcrumbs())
      |> Enum.map(&struct(Interfaces.Breadcrumb, &1))

    message = Keyword.get(opts, :message)
    exception = Keyword.get(opts, :exception)
    stacktrace = Keyword.get(opts, :stacktrace)
    source = Keyword.get(opts, :event_source)

    %__MODULE__{
      breadcrumbs: breadcrumbs,
      contexts: generate_contexts(),
      culprit: culprit_from_stacktrace(Keyword.get(opts, :stacktrace, [])),
      environment: Config.environment_name(),
      event_id: UUID.uuid4_hex(),
      exception: List.wrap(coerce_exception(exception, stacktrace, message)),
      extra: extra,
      fingerprint: fingerprint,
      level: level,
      message: message,
      modules: :persistent_term.get({:sentry, :loaded_applications}),
      original_exception: exception,
      release: Config.release(),
      request: coerce_request(request),
      sdk: @sdk,
      server_name: Config.server_name() || to_string(:net_adm.localhost()),
      source: source,
      tags: tags,
      timestamp: timestamp,
      user: user
    }
  end

  defp coerce_exception(_exception = nil, _stacktrace = nil, _message) do
    nil
  end

  defp coerce_exception(_exception = nil, stacktrace_or_nil, message) when is_binary(message) do
    stacktrace =
      if is_list(stacktrace_or_nil) do
        %Interfaces.Stacktrace{frames: stacktrace_to_frames(stacktrace_or_nil)}
      end

    %Interfaces.Exception{
      type: "message",
      value: message,
      stacktrace: stacktrace
    }
  end

  defp coerce_exception(exception, stacktrace_or_nil, _message) when is_exception(exception) do
    stacktrace =
      if is_list(stacktrace_or_nil) do
        %Interfaces.Stacktrace{frames: stacktrace_to_frames(stacktrace_or_nil)}
      end

    %Interfaces.Exception{
      type: inspect(exception.__struct__),
      value: Exception.message(exception),
      stacktrace: stacktrace
    }
  end

  defp coerce_exception(_exception = nil, stacktrace, _message = nil) do
    unless is_nil(stacktrace) do
      raise ArgumentError,
            "cannot provide a :stacktrace option without an exception or a message, got: #{inspect(stacktrace)}"
    end
  end

  @request_fields %Interfaces.Request{} |> Map.from_struct() |> Map.keys() |> MapSet.new()

  defp coerce_request(request) do
    Enum.reduce(request, %Interfaces.Request{}, fn {key, value}, acc ->
      if key in @request_fields do
        Map.replace!(acc, key, value)
      else
        raise ArgumentError, "unknown field for the request interface: #{inspect(key)}"
      end
    end)
  end

  @doc """
  Transforms an exception to a Sentry event.

  This essentially defers to `create_event/1`, inferring some options from
  the given `exception`.

  ## Options

  This function takes the same options as `create_event/1`.
  """
  @spec transform_exception(Exception.t(), keyword()) :: t()
  def transform_exception(exception, opts) when is_exception(exception) and is_list(opts) do
    opts
    |> Keyword.put(:exception, exception)
    |> create_event()
  end

  defp stacktrace_to_frames(stacktrace) when is_list(stacktrace) do
    in_app_module_allow_list = Config.in_app_module_allow_list()

    Enum.reduce(stacktrace, [], fn entry, acc ->
      [stacktrace_entry_to_frame(entry, in_app_module_allow_list) | acc]
    end)
  end

  defp stacktrace_entry_to_frame(entry, in_app_module_allow_list) do
    {module, function, location} =
      case entry do
        {mod, function, arity_or_args, location} ->
          {mod, Exception.format_mfa(mod, function, arity_to_integer(arity_or_args)), location}

        {function, arity_or_args, location} ->
          {nil, Exception.format_fa(function, arity_to_integer(arity_or_args)), location}
      end

    file =
      case Keyword.fetch(location, :file) do
        {:ok, file} when not is_nil(file) -> to_string(file)
        _other -> nil
      end

    line = location[:line]

    frame = %Interfaces.Stacktrace.Frame{
      module: module,
      function: function,
      filename: file,
      lineno: line,
      in_app: in_app?(entry, in_app_module_allow_list),
      vars: args_from_stacktrace([entry])
    }

    maybe_put_source_context(frame, file, line)
  end

  # There's no module here.
  defp in_app?({_function, _arity_or_args, _location}, _in_app_allow_list), do: false

  # No modules are allowed.
  defp in_app?(_stacktrace_entry, []), do: false

  defp in_app?({module, _function, _arity_or_args, _location}, in_app_module_allow_list) do
    split_module = module_split(module)

    Enum.any?(in_app_module_allow_list, fn module ->
      allowed_split_module = module_split(module)
      Enum.take(split_module, length(allowed_split_module)) == allowed_split_module
    end)
  end

  defp module_split(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
  end

  defp maybe_put_source_context(%Interfaces.Stacktrace.Frame{} = frame, file, line) do
    cond do
      not Config.enable_source_code_context?() ->
        frame

      source_map = Sources.get_source_code_map_from_persistent_term() ->
        {pre_context, context, post_context} = Sources.get_source_context(source_map, file, line)

        %Interfaces.Stacktrace.Frame{
          frame
          | context_line: context,
            pre_context: pre_context,
            post_context: post_context
        }

      true ->
        frame
    end
  end

  defp culprit_from_stacktrace([]), do: nil

  defp culprit_from_stacktrace([{m, f, a, _} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  defp culprit_from_stacktrace([{m, f, a} | _]) do
    Exception.format_mfa(m, f, arity_to_integer(a))
  end

  defp args_from_stacktrace([{_mod, _fun, args, _location} | _rest]) when is_list(args),
    do: stacktrace_args_to_vars(args)

  defp args_from_stacktrace([{_fun, args, _location} | _rest]) when is_list(args),
    do: stacktrace_args_to_vars(args)

  defp args_from_stacktrace([_other | _rest]), do: %{}

  defp stacktrace_args_to_vars(args) do
    for {arg, index} <- Enum.with_index(args), into: %{} do
      {"arg#{index}", String.slice(inspect(arg), 0, 513)}
    end
  end

  defp arity_to_integer(arity) when is_list(arity), do: Enum.count(arity)
  defp arity_to_integer(arity) when is_integer(arity), do: arity

  defp generate_contexts do
    {_, os_name} = :os.type()

    os_version =
      case :os.version() do
        {major, minor, release} -> "#{major}.#{minor}.#{release}"
        version_string -> version_string
      end

    %{
      os: %{name: Atom.to_string(os_name), version: os_version},
      runtime: %{name: "elixir", version: System.build_info().build}
    }
  end
end
