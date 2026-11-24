// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/chat_app"
import topbar from "../vendor/topbar"
import {initializeApp} from "firebase/app"
import {getAuth, GoogleAuthProvider, signInWithPopup} from "firebase/auth"

const firebaseApp = initializeApp({
  apiKey: "AIzaSyB95C9aTbUf7PndQaJW2yDT5ISKCwYeHZo",
  authDomain: "chatrooms-63eac.firebaseapp.com",
  projectId: "chatrooms-63eac",
  storageBucket: "chatrooms-63eac.firebasestorage.app",
  messagingSenderId: "368058034333",
  appId: "1:368058034333:web:97ff3c9e656707dd734c74",
  measurementId: "G-EYH7HG2RGG",
})

const firebaseAuth = getAuth(firebaseApp)
const googleProvider = new GoogleAuthProvider()
googleProvider.setCustomParameters({prompt: "select_account"})

const firebaseSignInHook = {
  async mounted() {
    this.el.addEventListener("click", async () => {
      const status = document.getElementById("firebase-signin-status")
      this.el.disabled = true
      if (status) status.textContent = "Connecting to Google…"

      try {
        const result = await signInWithPopup(firebaseAuth, googleProvider)
        const idToken = await result.user.getIdToken()
        const form = document.createElement("form")
        form.method = "post"
        form.action = "/auth/firebase"

        for (const [name, value] of [
          ["_csrf_token", document.querySelector("meta[name='csrf-token']").content],
          ["id_token", idToken],
        ]) {
          const input = document.createElement("input")
          input.type = "hidden"
          input.name = name
          input.value = value
          form.append(input)
        }

        document.body.append(form)
        form.submit()
      } catch (error) {
        if (status) status.textContent = "Google sign-in did not complete. Please try again."
        console.error("Firebase Google sign-in failed", error)
        this.el.disabled = false
      }
    })
  },
}

const chatComposerHook = {
  mounted() {
    const roomId = this.el.dataset.roomId
    const draftKey = `chatrooms:draft:${roomId}`
    const clientIdKey = `chatrooms:client-id:${roomId}`
    const body = this.el.querySelector("#message-body")
    const clientId = this.el.querySelector("#client-message-id")
    const submit = this.el.querySelector("#send-message-button")

    const savedClientId = sessionStorage.getItem(clientIdKey)
    if (savedClientId) clientId.value = savedClientId
    else sessionStorage.setItem(clientIdKey, clientId.value)

    const savedDraft = sessionStorage.getItem(draftKey)
    if (savedDraft !== null) body.value = savedDraft
    body.addEventListener("input", () => {
      sessionStorage.setItem(draftKey, body.value)
      clearTimeout(this.typingTimer)
      clearTimeout(this.typingStopTimer)
      this.typingTimer = setTimeout(() => this.pushEvent("typing", {typing: true}), 400)
      this.typingStopTimer = setTimeout(() => this.pushEvent("typing", {typing: false}), 1800)
    })

    body.addEventListener("blur", () => {
      clearTimeout(this.typingTimer)
      clearTimeout(this.typingStopTimer)
      this.pushEvent("typing", {typing: false})
    })

    this.handleEvent("message-acknowledged", ({next_id}) => {
      sessionStorage.removeItem(draftKey)
      sessionStorage.setItem(clientIdKey, next_id)
      body.value = ""
      clientId.value = next_id
    })

    this.el.addEventListener("submit", () => {
      clearTimeout(this.typingTimer)
      clearTimeout(this.typingStopTimer)
      this.pushEvent("typing", {typing: false})
      if (clientId.value) sessionStorage.setItem(clientIdKey, clientId.value)
      sessionStorage.setItem(draftKey, body.value)
    })

    this.setConnected = connected => {
      body.disabled = !connected
      submit.disabled = !connected
      if (!connected) {
        document.getElementById("composer-status").textContent = "Reconnecting… your draft is kept."
      }
    }

    this.setConnected(true)
  },
  disconnected() {
    this.setConnected?.(false)
    clearTimeout(this.typingTimer)
    clearTimeout(this.typingStopTimer)
  },
  reconnected() {
    this.setConnected?.(true)
    this.pushEvent("sync_messages", {})
  },
}

const chatScrollHook = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
    this.markVisibleMessagesRead()
  },
  updated() {
    this.el.scrollTop = this.el.scrollHeight
    this.markVisibleMessagesRead()
  },
  markVisibleMessagesRead() {
    const lastMessage = this.el.querySelector("article[data-seq]:last-child")
    if (lastMessage) this.pushEvent("mark_read", {seq: lastMessage.dataset.seq})
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    FirebaseSignIn: firebaseSignInHook,
    ChatComposer: chatComposerHook,
    ChatScroll: chatScrollHook,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

