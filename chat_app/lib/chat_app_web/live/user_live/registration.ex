defmodule ChatAppWeb.UserLive.Registration do
  use ChatAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, redirect(socket, to: "/users/log-in")}
  end
end
