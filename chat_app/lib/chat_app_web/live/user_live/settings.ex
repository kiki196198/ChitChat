defmodule ChatAppWeb.UserLive.Settings do
  use ChatAppWeb, :live_view

  on_mount {ChatAppWeb.UserAuth, :require_authenticated}

  alias ChatApp.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="settings-grid">
        <aside class="settings-aside">
          <div class="eyebrow">Your space</div>
          <h1>Account settings</h1>
          <p>Manage the details that keep your conversations yours.</p>
          <p class="mt-8">Signed in as <strong>{@current_scope.user.display_name}</strong></p>
          <p>@{@current_scope.user.username}</p>
        </aside>
        <section class="settings-card">
          <.header>
            Profile
            <:subtitle>How people see you in conversations.</:subtitle>
          </.header>

          <div :if={@current_scope.user.avatar_url} class="mb-6 flex items-center gap-4">
            <img
              src={@current_scope.user.avatar_url}
              alt=""
              class="size-14 rounded-full object-cover"
            />
            <span class="text-sm text-base-content/60">Google profile photo</span>
          </div>

          <.form
            for={@profile_form}
            id="profile_form"
            phx-change="validate_profile"
            phx-submit="update_profile"
          >
            <.input field={@profile_form[:display_name]} type="text" label="Display name" required />
            <.input field={@profile_form[:username]} type="text" label="Username" required />
            <.input field={@profile_form[:avatar_url]} type="url" label="Avatar URL" />
            <.button variant="primary" phx-disable-with="Saving...">Save profile</.button>
          </.form>

          <p class="mt-8 border-t border-base-content/10 pt-5 text-sm text-base-content/55">
            Sign-in and email verification are managed by Google through Firebase Authentication.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {:ok, assign(socket, :profile_form, to_form(Accounts.change_user_profile(user)))}
  end

  @impl true
  def handle_event("validate_profile", %{"user" => user_params}, socket) do
    profile_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :profile_form, profile_form)}
  end

  def handle_event("update_profile", %{"user" => user_params}, socket) do
    case Accounts.update_user_profile(socket.assigns.current_scope.user, user_params) do
      {:ok, user} ->
        current_scope = %{socket.assigns.current_scope | user: user}

        {:noreply,
         socket
         |> assign(:current_scope, current_scope)
         |> assign(:profile_form, to_form(Accounts.change_user_profile(user)))
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, action: :insert))}
    end
  end
end
