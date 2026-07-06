ExUnit.start(exclude: [:live])

for env_file <- [".env", ".env.test"], File.exists?(env_file) do
  Dotenvy.source!(env_file)
end
