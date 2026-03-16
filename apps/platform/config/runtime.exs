import Config

if System.get_env("PHX_SERVER") do
  config :platform, PlatformWeb.Endpoint, server: true
end

vault_key =
  case {config_env(), System.get_env("VAULT_MASTER_KEY")} do
    {:prod, nil} ->
      raise "environment variable VAULT_MASTER_KEY is missing"

    {_, nil} ->
      Base.encode64(:crypto.strong_rand_bytes(32))

    {_, key} ->
      key
  end

config :platform, Platform.Vault.Encryption,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: Base.decode64!(vault_key), iv_length: 12
    }
  ]

if config_env() != :test do
  pool_size = String.to_integer(System.get_env("POOL_SIZE", "10"))

  socket_options =
    case System.get_env("ECTO_IPV6") do
      value when value in ["true", "1"] -> [:inet6]
      _ -> []
    end

  default_dev_database = System.get_env("PLATFORM_DEV_DATABASE", "platform_dev")

  database_url =
    if config_env() == :prod do
      System.get_env("DATABASE_URL") ||
        raise "environment variable DATABASE_URL is missing"
    else
      System.get_env("DATABASE_URL")
    end

  normalized_database_url =
    case {database_url, config_env()} do
      {nil, _} ->
        nil

      {"", _} ->
        nil

      {url, :prod} ->
        url

      {url, _} ->
        uri = URI.parse(url)

        if uri.path in [nil, "", "/"] do
          %{uri | path: "/#{default_dev_database}"}
          |> URI.to_string()
        else
          url
        end
    end

  if normalized_database_url do
    config :platform, Platform.Repo,
      url: normalized_database_url,
      pool_size: pool_size,
      socket_options: socket_options
  else
    config :platform, Platform.Repo,
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      database: default_dev_database,
      pool_size: pool_size,
      socket_options: socket_options
  end

  app_url = System.get_env("APP_URL") || "http://localhost:4000"

  # Only enable when behind a trusted reverse proxy (Traefik, nginx, etc.).
  # See PlatformWeb.Plugs.RewriteRemoteIp for security notes.
  config :platform, :trust_proxy_headers, System.get_env("TRUST_PROXY_HEADERS") in ["true", "1"]

  is_prod = config_env() == :prod

  oidc_client_id =
    case System.get_env("OIDC_CLIENT_ID") do
      value when value in [nil, ""] -> if(is_prod, do: nil, else: "dev-client-id")
      value -> value
    end

  oidc_client_secret =
    case System.get_env("OIDC_CLIENT_SECRET") do
      value when value in [nil, ""] -> if(is_prod, do: nil, else: "dev-client-secret")
      value -> value
    end

  oidc_issuer =
    case System.get_env("OIDC_ISSUER") do
      value when value in [nil, ""] -> if(is_prod, do: nil, else: "https://issuer.example.com")
      value -> value
    end

  config :platform, :oidc,
    client_id: oidc_client_id,
    client_secret: oidc_client_secret,
    issuer: oidc_issuer,
    app_url: app_url,
    # PKCE (RFC 7636): set OIDC_PKCE_ENABLED=true when the provider enforces it.
    # Defaults to false for compatibility with providers that don't support PKCE.
    pkce_enabled: System.get_env("OIDC_PKCE_ENABLED") in ["true", "1"]

  config :platform, PlatformWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# Agent workspace (sign-of-life — will be replaced by full agent runtime)
config :platform,
  agent_workspace_path: System.get_env("AGENT_WORKSPACE_PATH", "/data/agents/zip/workspace"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  chat_attachments_root: System.get_env("CHAT_ATTACHMENTS_ROOT", "/data/platform/chat_uploads")

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :platform, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :platform, PlatformWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
