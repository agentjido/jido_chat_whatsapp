ExUnit.start(exclude: [:live])

for env_file <- [".env", ".env.test"], File.exists?(env_file) do
  Dotenvy.source!(env_file)
end

# Load test doubles only for ExUnit; they are not application modules.
for fixture <- Path.wildcard(Path.join(__DIR__, "support/fixtures/*.exs")) do
  Code.require_file(fixture)
end
