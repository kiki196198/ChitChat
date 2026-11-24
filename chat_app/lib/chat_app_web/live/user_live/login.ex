defmodule ChatAppWeb.UserLive.Login do
  use ChatAppWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="auth-shell">
        <section class="auth-panel space-y-7 text-center">
          <div>
            <p class="eyebrow">A quieter place to talk</p>
            <h1 class="mt-3 text-3xl font-semibold tracking-tight">Welcome to Chatrooms</h1>
            <p class="mt-3 text-sm text-base-content/65">
              Sign in securely with your Google account to continue.
            </p>
          </div>

          <button
            id="firebase-google-signin"
            type="button"
            phx-hook="FirebaseSignIn"
            class="btn btn-primary w-full"
          >
            <span class="mr-2 inline-flex size-6 items-center justify-center rounded-full bg-white text-sm font-bold text-slate-800">G</span>
            Continue with Google
          </button>
          <p
            id="firebase-signin-status"
            class="min-h-5 text-sm text-base-content/60"
            role="status"
            aria-live="polite"
          >
          </p>
          <p class="text-xs leading-5 text-base-content/45">
            Your Google identity is used to create your Chatrooms account. Your profile name and photo can be changed later.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ChatAppWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket), do: {:ok, socket}
end
