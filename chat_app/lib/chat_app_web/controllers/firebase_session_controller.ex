defmodule ChatAppWeb.FirebaseSessionController do
  use ChatAppWeb, :controller

  alias ChatApp.Accounts
  alias ChatApp.FirebaseIdToken
  alias ChatAppWeb.UserAuth

  def create(conn, %{"id_token" => token}) do
    with {:ok, claims} <- FirebaseIdToken.verify(token),
         {:ok, user} <- Accounts.get_or_create_google_user(claims) do
      conn
      |> put_flash(:info, "Signed in with Google.")
      |> UserAuth.log_in_user(user)
    else
      _ ->
        conn
        |> put_flash(:error, "Google sign-in could not be verified. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Google sign-in could not be verified. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end
end
