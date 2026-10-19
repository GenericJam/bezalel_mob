import Config

# Host tests: a throwaway database per run instead of the device's data dir
# (the OS pid keeps concurrent runs, e.g. two checkouts, apart).
config :bezalel, Bezalel.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "bezalel_test_#{System.pid()}_#{System.unique_integer([:positive])}.db"
    )

config :logger, level: :warning

# Sign-ins and API keys in memory, and the sign-in page "opened" into the
# test process's mailbox (Bezalel.Test.Fakes), so nothing reaches a
# keychain or a browser.
config :rho,
  credential_store: Bezalel.Test.MemoryStore,
  open_url: {Bezalel.Test.Browser, :open, []}

# The study library: nothing fetches the published manifest (the pack
# tests serve their own, Bezalel.Test.PackServer), and the connection is
# Wi-Fi unless a test says otherwise (Bezalel.Test.Network).
config :bezalel, :packs_manifest_url, "http://127.0.0.1:9/packs/manifest.json"
config :bezalel, :network_state, {Bezalel.Test.Network, :state, []}

# Materials: the phone's pickers, camera, microphone and voice are recorded
# instead of called (Bezalel.Test.Native), Whisper answers from a script
# (Bezalel.Test.Whisper), and mob_media decodes WAV for real and scripted
# answers for anything else (MobMedia.Engine.Fake). The store's directories
# are set in test_helper.exs (under the run's temp data dir).
config :bezalel, :native, Bezalel.Test.Native
config :bezalel, :whisper, Bezalel.Test.Whisper
config :mob_media, engine: MobMedia.Engine.Fake

# No naming of conversations after replies (Bezalel.Titles): the scripted
# model answers only the replies a test scripts. The titles tests turn it on.
config :bezalel, Bezalel.Titles, enabled: false
