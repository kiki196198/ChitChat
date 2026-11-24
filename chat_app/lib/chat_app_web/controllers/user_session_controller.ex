defmodule ChatAppWeb.UserSessionController do
  use ChatAppWeb, :controller

  alias ChatAppWeb.UserAuth

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out successfully.")
    |> UserAuth.log_out_user()
  end
end
