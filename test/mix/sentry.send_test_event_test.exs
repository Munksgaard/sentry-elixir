defmodule Mix.Tasks.Sentry.SendTestEventTest do
  use ExUnit.Case

  import ExUnit.CaptureIO
  import Sentry.TestEnvironmentHelper

  test "prints if :dsn is not set" do
    modify_env(:sentry, dsn: nil)

    output =
      capture_io(fn ->
        Mix.Tasks.Sentry.SendTestEvent.run([])
      end)

    assert output =~ """
           Client configuration:
           current environment_name: "test"
           hackney_opts: [recv_timeout: 50]
           """

    assert output =~ ~s(Event not sent because the :dsn option is not set)
  end

  test "sends event successfully when configured to" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Testing sending Sentry event"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    output =
      capture_io(fn ->
        Mix.Tasks.Sentry.SendTestEvent.run([])
      end)

    assert output =~ """
           Client configuration:
           server: http://localhost:#{bypass.port}/api/1/envelope/
           public_key: public
           secret_key: secret
           current environment_name: "test"
           hackney_opts: [recv_timeout: 50]
           """

    assert output =~ "Sending test event..."
    assert output =~ "Test event sent"
    assert output =~ "Event ID: 340"
  end

  @tag :capture_log
  test "handles error when Sentry server is failing" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 500, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      request_retries: []
    )

    assert_raise Mix.Error, ~r/Error sending event/, fn ->
      capture_io(fn -> Mix.Tasks.Sentry.SendTestEvent.run([]) end)
    end
  end
end
