-- Claude subscription (Pro or Max) for maki, over the Claude Code OAuth flow.
-- The subscription token is accepted only when the system prompt opens with
-- the Claude Code identity line as its own block, which is the system prefix.

local SLUG = "claude"
local DISPLAY_NAME = "Claude subscription"
local IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."
local CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
local API_URL = "https://api.anthropic.com"
-- The provider origin: maki.net sends a browser user agent anywhere else, which
-- the token endpoint answers with a 429.
local TOKEN_URL = API_URL .. "/v1/oauth/token"
local MODELS_URL = API_URL .. "/v1/models?limit=1000"
local API_VERSION = "2023-06-01"
local REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
local SCOPES =
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
local LONG_CONTEXT = 1000000
local LONG_CONTEXT_SUFFIX = "-1m"
local REFRESH_MARGIN_S = 300
local PKCE_WAIT_MS = 10000
-- Prints a random verifier, then its S256 challenge in standard base64.
local PKCE_SCRIPT =
  'v=$(openssl rand -hex 32) && echo "$v" && printf %s "$v" | openssl dgst -sha256 -binary | openssl base64 -A'
local NOT_LOGGED_IN = "not logged in to Claude: run `maki auth login claude`"
-- maki replaces the message of a 401 with its own generic login hint.
local NEEDS_LOGIN = 403
local UNREACHABLE = 503
-- Claude Code sends this when the install is enrolled in a server-side
-- experiment. Override with CLAUDE_ATIS, or set it to "off" to omit the header.
local ATIS_DEFAULT = "d5ce23808f17634f"

-- A deliberate failure reaches the user as its message alone, where a raised
-- error would read as a broken hook with a stack trace.
local function fail(status, message)
  return nil, maki.provider.http_error({ status = status, body = message })
end

local function request(url, opts)
  local res, err = maki.net.request(url, opts)
  if not res then
    return fail(UNREACHABLE, url .. " unreachable: " .. tostring(err))
  end
  if res.status < 200 or res.status >= 300 then
    return nil, maki.provider.http_error(res)
  end
  return maki.json.decode(res.body)
end

local function urlencode(value)
  return (value:gsub("[^%w%-_%.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

local function pkce()
  local job, err = maki.fn.jobstart({ "sh", "-c", PKCE_SCRIPT }, { scope = "plugin" })
  if not job then
    return nil, "cannot run openssl: " .. tostring(err)
  end
  local result = maki.fn.jobwait(job, PKCE_WAIT_MS)
  local verifier, challenge = ((result and result.stdout) or ""):match("^(%x+)\n(%S+)")
  if not verifier then
    return nil, "openssl did not produce a PKCE pair, is it installed?"
  end
  return verifier, (challenge:gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- Posts to the token endpoint and stores what it grants.
local function grant(slug, body, previous)
  local data, err = request(TOKEN_URL, {
    method = "POST",
    headers = { ["content-type"] = "application/json", accept = "application/json" },
    body = maki.json.encode(body),
  })
  if not data then
    return nil, err
  end
  local refresh = type(data) == "table" and (data.refresh_token or (previous and previous.refresh))
  if not refresh or type(data.access_token) ~= "string" or type(data.expires_in) ~= "number" then
    return fail(UNREACHABLE, "token response is missing access_token, refresh_token or expires_in")
  end
  local creds = { access = data.access_token, refresh = refresh, expires = os.time() + math.floor(data.expires_in) }
  local ok, set_err = maki.provider.auth.set(slug, creds)
  if not ok then
    error("cannot store the Claude tokens: " .. tostring(set_err))
  end
  return creds
end

-- Accepts the `code#state` the callback page shows, or the redirect URL.
local function parse_code(input)
  local code = input:match("code=([^&#%s]+)") or input:match("^%s*([^#%s]+)")
  local state = input:match("state=([^&#%s]+)") or input:match("#(%S+)")
  return code, state
end

local function auth(ctx, purpose)
  local creds = maki.provider.auth.get(ctx.slug)
  if not creds then
    return fail(NEEDS_LOGIN, NOT_LOGGED_IN)
  end
  if purpose == "refresh" or (purpose == "resolve" and creds.expires <= os.time() + REFRESH_MARGIN_S) then
    local err
    creds, err =
      grant(ctx.slug, { grant_type = "refresh_token", client_id = CLIENT_ID, refresh_token = creds.refresh }, creds)
    if not creds then
      return nil, err
    end
  end
  local headers = { authorization = "Bearer " .. creds.access }
  local atis = maki.uv.os_getenv("CLAUDE_ATIS") or ATIS_DEFAULT
  if atis ~= "" and atis ~= "off" then
    headers["x-cc-atis"] = atis
  end
  return { headers = headers }
end

-- The models the subscription serves. Like Claude Code, a model with a 1M
-- window is offered only with it, under the `-1m` id that makes maki ask for
-- the long context.
local function list_models(ctx)
  local headers = { ["anthropic-version"] = API_VERSION }
  for name, value in pairs(ctx.headers) do
    headers[name] = value
  end
  local data, err = request(MODELS_URL, { headers = headers })
  if not data then
    return nil, err
  end
  local rows = {}
  for _, model in ipairs(data.data or {}) do
    local window = model.max_input_tokens or 0
    local long = window >= LONG_CONTEXT
    table.insert(rows, {
      id = long and (model.id .. LONG_CONTEXT_SUFFIX) or model.id,
      context_window = long and LONG_CONTEXT or (window > 0 and window or nil),
      max_output_tokens = model.max_tokens,
    })
  end
  return rows
end

local function login(ctx)
  local verifier, challenge = pkce()
  if not verifier then
    ctx.print(challenge)
    return
  end
  -- The authorize page accepts the verifier as state, which is what pi sends.
  local query = {
    "code=true",
    "client_id=" .. CLIENT_ID,
    "response_type=code",
    "redirect_uri=" .. urlencode(REDIRECT_URI),
    "scope=" .. urlencode(SCOPES),
    "code_challenge=" .. challenge,
    "code_challenge_method=S256",
    "state=" .. verifier,
  }
  local url = AUTHORIZE_URL .. "?" .. table.concat(query, "&")
  ctx.print("Log in to Claude in your browser:\n\n  " .. url .. "\n")
  ctx.open_url(url)
  local code, state = parse_code(ctx.prompt({ label = "Paste the code shown after you approve: " }) or "")
  if not code then
    ctx.print("No code entered, nothing was stored.")
    return
  end
  if state and state ~= verifier then
    ctx.print("OAuth state mismatch, start the login again.")
    return
  end
  local creds, err = grant(ctx.slug, {
    grant_type = "authorization_code",
    client_id = CLIENT_ID,
    code = code,
    state = verifier,
    redirect_uri = REDIRECT_URI,
    code_verifier = verifier,
  })
  if not creds then
    return nil, err
  end
  ctx.print("Logged in. Pick a model with /model.")
end

local function logout(ctx)
  maki.provider.auth.clear(ctx.slug)
  ctx.print("Claude tokens removed")
end

maki.provider.register({
  slug = SLUG,
  display_name = DISPLAY_NAME,
  codec = "anthropic",
  base_url = API_URL,
  system_prefix = IDENTITY,
  auth = auth,
  list_models = list_models,
  login = login,
  logout = logout,
})
